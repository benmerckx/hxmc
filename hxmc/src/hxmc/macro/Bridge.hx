package hxmc.macro;

#if hxmc.jit
import core.Globals.Pos;
import macros.eval.EvalValue.Value;
import macros.eval.EvalEncode;
import macros.eval.EvalHash;
import hxmc.unsafe.Mem;
import hxmc.rt.Gc;
import hxmc.macro.Loader.Bundle;

// Unsupported at the boundary: the engine falls back to Eval.
class Unsupported extends haxe.Exception {
	public function new(msg:String) {
		super(msg);
		if (Sys.getEnv("HXMC_MACRO_DEBUG") == "1") Sys.stderr().writeString("hxmc.macros: unsupported: " + msg + "\n");
	}
}

// (end: the index after the calls made during this one, by callbacks it ran: the
// native run, replayed, does not run them)
typedef ApiCall = {name:String, args:Array<Value>, result:Null<Value>, error:Null<Dynamic>, end:Int};

// verify mode: records the macro API calls of Eval runs (the API's functions
// wrapped once), into the list of the innermost macro call being recorded.
// The function values an API call returns (a Ref's get, MetaAccess's add, ...)
// are wrapped the same way, so their calls are recorded too.
class Recorder {
	public static var stack:Array<Array<ApiCall>> = [];
	static var installed = false;

	// a copy of the arrays, objects, enum values and Refs of v, with its
	// function values recording their calls (the rest shared)
	public static function wrap(v:Value, ?label = "function"):Value {
		return switch v {
			case VArray(a): VArray(new macros.eval.EvalValue.Varray(core.ds.VectorTools.init(a.alength, i -> wrap(a.avalues[i])), a.alength));
			case VObject(o):
				// (a function field is recorded under its name)
				var names = new Map<Int, String>();
				for (f in macros.eval.EvalContext.objectFields(o))
					names.set(f.name, macros.eval.EvalHash.revHash(f.name));
				var fs = o.ofields.copy();
				switch o.oproto {
					case OProto(p):
						for (i in 0...fs.length)
							fs[i] = wrap(o.ofields[i]);
						p.pinstanceNames.iter((h, i) -> fs[i] = wrap(o.ofields[i], "function " + names.get(h)));
					case _:
						fs = o.ofields.map(f -> wrap(f));
				}
				VObject(new macros.eval.EvalValue.Vobject(fs, o.oproto));
			case VEnumValue(e): VEnumValue(new macros.eval.EvalValue.VenumValue(e.eindex, e.eargs.map(a -> wrap(a)), e.epath, e.enpos));
			// (a Ref's get and toString are pure: called by both runs, their results wrapped)
			case VInstance(vi = {ikind: IRef(_)}): VInstance(new macros.eval.EvalValue.Vinstance(vi.ifields.map(pure), vi.iproto, vi.ikind));
			case VFunction(_, _) | VFieldClosure(_, _): recording(label, v);
			// (a copy of its value once forced: the runs force and change their own)
			case VLazy(l): VLazy(core.ds.AtomicLazy.fromFun(() -> wrap(l.force())));
			case _: v;
		}
	}

	static function pure(f:Value):Value {
		return switch f {
			case VFunction(_, isStatic): VFunction(vl -> wrap(macros.eval.EvalMisc.callValue(f, vl)), isStatic);
			case _: f;
		}
	}

	// the arguments as they were (the Eval run may change what it passed)
	static function copy(v:Value):Value {
		return switch v {
			case VArray(a): VArray(new macros.eval.EvalValue.Varray(core.ds.VectorTools.init(a.alength, i -> copy(a.avalues[i])), a.alength));
			case VObject(o): VObject(new macros.eval.EvalValue.Vobject(o.ofields.map(copy), o.oproto));
			case VEnumValue(e): VEnumValue(new macros.eval.EvalValue.VenumValue(e.eindex, e.eargs.map(copy), e.epath, e.enpos));
			case _: v;
		}
	}

	// f, recording its calls while a macro call is recorded, replaying them in
	// the native run
	static function recording(name:String, f:Value):Value {
		// (static or not as f: Eval passes `this` to the latter)
		var isStatic = switch f {
			case VFunction(_, s): s;
			case _: false;
		};
		return VFunction(vl -> {
			if (Bridge.replay != null) return Bridge.replayValue(name, vl);
			var top = stack.length == 0 ? null : stack[stack.length - 1];
			if (top == null) return macros.eval.EvalMisc.callValue(f, vl);
			var c:ApiCall = {name: name, args: [for (v in vl) copy(v)], result: null, error: null, end: 0};
			top.push(c);
			c.end = top.length;
			var r = try macros.eval.EvalMisc.callValue(f, vl) catch (e:Dynamic) {
				c.error = e;
				c.end = top.length;
				throw e;
			}
			c.end = top.length;
			c.result = wrap(r);
			return wrap(r);
		}, isStatic);
	}

	public static function install() {
		if (installed) return;
		installed = true;
		var lib = macros.eval.EvalContext.GlobalState.macroLib;
		for (name in [for (k in lib.keys()) k])
			lib.set(name, recording(name, lib.get(name)));
	}
}

// Native objects of a bundle to and from Eval values at the boundary of
// native macros, so MacroApi stays the one implementation of the macro API:
// arguments and results of macro calls, and of the API calls macro code
// makes (GuestApi: `hxmc_macro_api`). Native objects are read and made with
// the runtime's reflection, which knows the bundle's types (Loader).
// Strings, numbers, booleans, arrays, anonymous structures and enum values
// are converted; other values (positions, types, ...) pass through as the
// Eval values themselves, opaque to macro code. Enum values carry the
// positions Eval gives them: the declaration of a constructor without
// arguments, the construction for the others (recorded by the guest code:
// `hxmc_macro_enum_pos`).
@:access(hxmc.rt.Gc)
class Bridge {
	public static var bundle:Null<Bundle> = null;
	// the macro context's enums (the declaration positions of their constructors)
	public static var enumLookup:Null<String->Null<core.TType.TEnum>> = null;
	static var enumPos = new haxe.ds.ObjectMap<Dynamic, Null<Pos>>();
	public static var apiCalls = 0;

	// (the maps of positions and origins stay: macro code keeps values across calls in
	// its statics. They keep what they hold alive: a production version needs weak maps)
	public static function reset() {
		callFile = null;
	}

	// ---- the exports macro code calls

	// the position of the last call of a macro API function (Context, Compiler) in
	// macro code: what Eval's frames give the API (EvalMain.getApiCallPos)
	static var callFile:Null<String> = null;
	static var callMin = 0;
	static var callMax = 0;

	@:hxmc.export("hxmc_macro_call_pos") static function callPos(file:String, min:Int, max:Int):Void {
		callFile = file;
		callMin = min;
		callMax = max;
	}

	@:hxmc.export("hxmc_macro_api") static function api(name:String, args:Array<Dynamic>):Dynamic {
		apiCalls++;
		var f = macros.eval.EvalContext.GlobalState.macroLib.get(name);
		if (f == null) throw new Unsupported("macro API " + name);
		var vl = [for (a in args) toValue(a)];
		if (replay != null) return replayCall(name, vl);
		// (the frames of the caller and of the API function, as Eval has them)
		var ctx = macros.eval.EvalContext.getCtx();
		var envs = [];
		if (callFile != null) {
			var info = macros.eval.EvalContext.createEnvInfo(true, callFile, ctx.fileKeys.get(callFile), macros.eval.EvalContext.EnvKind.EKMethod(0, 0), macros.eval.EvalDebugMisc.newIntHashtbl(), 0, 0);
			var outer = macros.eval.EvalContext.pushEnvironment(ctx, info);
			outer.envLeavePmin = callMin;
			outer.envLeavePmax = callMax;
			envs = [macros.eval.EvalContext.pushEnvironment(ctx, info), outer];
		}
		var r = try macros.eval.EvalMisc.callValue(f, vl) catch (e:Dynamic) {
			for (env in envs)
				macros.eval.EvalContext.popEnvironment(ctx, env);
			return rethrow(e);
		}
		for (env in envs)
			macros.eval.EvalContext.popEnvironment(ctx, env);
		return ofValue(r);
	}

	// ---- verify mode: the API calls of the Eval run, recorded (Recorder), replayed
	// to the native run: compared, not made again (no side effect twice)

	public static var replay:Null<Array<ApiCall>> = null;
	public static var replayAt = 0;
	public static var replayMismatch:Null<String> = null;

	static function replayCall(name:String, vl:Array<Value>):Dynamic {
		var c = replayNext(name, vl);
		if (c.error != null) return rethrow(c.error);
		return ofValue(c.result);
	}

	// (a recorded function value's call: Recorder)
	public static function replayValue(name:String, vl:Array<Value>):Value {
		var c = replayNext(name, vl);
		if (c.error != null) throw c.error;
		return c.result;
	}

	static function replayNext(name:String, vl:Array<Value>):ApiCall {
		if (Sys.getEnv("HXMC_MACRO_DEBUG") == "1") Sys.stderr().writeString("hxmc.macros: replay " + replayAt + " " + name + " (" + (replayAt < replay.length ? replay[replayAt].name : "-") + ")\n");
		var k = replayAt++;
		if (k >= replay.length) {
			if (replayMismatch == null) replayMismatch = "API call " + name + " that Eval did not make";
			throw new Unsupported("API call " + name + " that Eval did not make");
		}
		var c = replay[k];
		replayAt = c.end;
		if (c.name != name) {
			if (replayMismatch == null) replayMismatch = "API call " + k + ": " + name + " where Eval called " + c.name;
			throw new Unsupported("API call sequence differs");
		}
		for (i in 0...(vl.length > c.args.length ? vl.length : c.args.length)) {
			var d = NativeEngine.diff(i < c.args.length ? c.args[i] : VNull, i < vl.length ? vl[i] : VNull, name + " argument " + i);
			if (d != null && replayMismatch == null) replayMismatch = d;
		}
		return c;
	}

	// an exception of an API call into macro code: Eval's exceptions as the value
	// thrown, which macro code can catch (and the same exception again if it does not)
	static var apiErrors = new haxe.ds.ObjectMap<Dynamic, Dynamic>();

	static function rethrow(e:Dynamic):Dynamic {
		if (Std.isOfType(e, macros.eval.EvalContext.RunTimeException)) {
			var v:Dynamic = ofValue((e : macros.eval.EvalContext.RunTimeException).value);
			if (v != null) apiErrors.set(v, e);
			throw v;
		}
		throw e;
	}

	// the exception of the compiler that e stands for
	public static function original(e:Dynamic):Dynamic {
		var v:Dynamic = e;
		if (Std.isOfType(v, haxe.ValueException)) v = (v : haxe.ValueException).value;
		var o = v == null ? null : apiErrors.get(v);
		return o != null ? o : e;
	}

	// what macro code threw, as an Eval value (null: an exception of the compiler)
	public static function guestThrown(e:Dynamic):Null<Value> {
		var v:Dynamic = e;
		if (Std.isOfType(v, haxe.ValueException)) v = (v : haxe.ValueException).value;
		if (v != null && apiErrors.exists(v)) return null; // (the API's exception: rethrown as it is, below)
		if (v == null) return VNull;
		switch Type.typeof(v) {
			case TInt | TFloat | TBool: return toValue(v);
			case TClass(c) if (c == String): return toValue(v);
			case _:
		}
		if (Loader.isBundleObject(v)) return try toValue(v) catch (_:Unsupported) null;
		return null;
	}

	@:hxmc.export("hxmc_macro_pos") static function mkPos(file:String, min:Int, max:Int):Dynamic
		return EvalEncode.encodePos({pfile: file, pmin: min, pmax: max});

	@:hxmc.export("hxmc_macro_enum_pos") static function enumAt(v:Dynamic, file:String, min:Int, max:Int):Dynamic {
		enumPos.set(v, {pfile: file, pmin: min, pmax: max});
		return v;
	}

	// ---- native to Eval

	static function isValue(v:Dynamic):Bool
		return switch Type.typeof(v) {
			case TEnum(e): e == Value;
			case _: false;
		}

	// native objects standing for Eval values (Refs): the value when they come back
	static var origin = new haxe.ds.ObjectMap<Dynamic, Value>();

	// the positions of the shared values of constructors without arguments, by place (container, slot)
	static var slotPos = new haxe.ds.ObjectMap<Dynamic, Map<String, Null<Pos>>>();

	static function placed(c:Dynamic, k:String):{found:Bool, p:Null<Pos>} {
		var m = c == null ? null : slotPos.get(c);
		return m != null && m.exists(k) ? {found: true, p: m.get(k)} : {found: false, p: null};
	}

	static function place(c:Dynamic, pend:Array<{k:String, p:Null<Pos>}>) {
		if (pend.length == 0) return;
		var m = slotPos.get(c);
		if (m == null) slotPos.set(c, m = new Map());
		for (x in pend)
			m.set(x.k, x.p);
	}

	public static function toValue(v:Dynamic, ?c:Dynamic, ?k:String):Value {
		if (v == null) return VNull;
		var o = origin.get(v);
		if (o != null) return o;
		switch Type.typeof(v) {
			case TNull: return VNull;
			case TInt: return VInt32(v);
			case TFloat: return VFloat(v);
			case TBool: return v ? VTrue : VFalse;
			case TClass(cl) if (cl == String): return EvalEncode.encodeString(v);
			case TClass(cl) if (cl == Array):
				var n:Int = v.length;
				return EvalEncode.encodeArray([for (i in 0...n) toValue(v[i], v, "i" + i)]);
			case TEnum(e) if (e == Value):
				return (v : Value);
			case TEnum(e):
				var name = Type.getEnumName(e);
				var idx = Type.enumIndex(v);
				var params = Type.enumParameters(v);
				var p:Null<Pos> = null;
				if (params.length == 0) {
					var at = placed(c, k);
					p = at.found ? at.p : declPos(name, idx);
				} else if (enumPos.exists(v)) {
					p = enumPos.get(v);
				} else throw new Unsupported("enum value without a position: " + name + "." + Type.enumConstructor(v));
				return EvalEncode.encodeEnumValue(EvalHash.hash(name), idx, core.ds.VectorTools.init(params.length, i -> toValue(params[i], v, "a" + i)), p);
			case TFunction:
				// (called back by the compiler, maybe after this macro call)
				var f:Dynamic = v, bnd = bundle;
				return VFunction(vl -> {
					var old = bundle;
					bundle = bnd;
					var r = toValue(Reflect.callMethod(null, f, [for (x in vl) ofValue(x)]));
					bundle = old;
					return r;
				}, false);
			case TObject:
				var fs = Reflect.fields(v);
				return EvalEncode.encodeObjS([for (f in fs) {name: f, value: toValue(Reflect.field(v, f), v, "f" + f)}]);
			case t:
				throw new Unsupported("native value " + Std.string(t));
		}
	}

	static function declPos(name:String, idx:Int):Null<Pos> {
		var en = enumLookup == null ? null : enumLookup(name);
		if (en == null) return null;
		for (ef in en.eConstrs)
			if (ef.efIndex == idx) return ef.efPos;
		return null;
	}

	// ---- Eval to native

	// pend: where the caller records the position of a shared constructor value it gets for slot k
	public static function ofValue(v:Value, ?pend:Array<{k:String, p:Null<Pos>}>, ?k:String):Dynamic {
		return switch v {
			case VNull: null;
			case VTrue: true;
			case VFalse: false;
			case VInt32(i): i;
			case VFloat(f): f;
			case VString(s): s.sstring;
			case VArray(a):
				var r:Array<Dynamic> = [];
				var mine = [];
				for (i in 0...a.alength)
					r.push(ofValue(a.avalues[i], mine, "i" + i));
				place(r, mine);
				r;
			case VEnumValue(ev):
				var name = EvalHash.revHash(ev.epath);
				var to = bundle.typeObjs.get(name);
				if (to == null) throw new Unsupported("enum " + name + " not in the native code");
				var e:Enum<Dynamic> = Mem.obj(to);
				if (ev.eargs.length == 0) {
					var t = Mem.getI32(to, 0);
					var ct = Mem.getI32At(Mem.getPtr(Mem.sym("rt_types").add(t * 112), 88), 0, ev.eindex);
					var g = bundle.singletons.get(ct);
					if (g == null) throw new Unsupported("no shared value of " + name + "#" + ev.eindex);
					if (pend != null) pend.push({k: k, p: ev.enpos});
					Mem.getRef(Gc.globals, 8 * g);
				} else {
					var mine = [];
					var args = [for (i in 0...ev.eargs.length) ofValue(ev.eargs[i], mine, "a" + i)];
					var o:Dynamic = Type.createEnumIndex(e, ev.eindex, args);
					place(o, mine);
					enumPos.set(o, ev.enpos);
					o;
				}
			case VObject(o):
				var fs = macros.eval.EvalContext.objectFields(o);
				var names = [for (f in fs) EvalHash.revHash(f.name)];
				var r = newAnon(names);
				var mine = [];
				for (i in 0...fs.length)
					Reflect.setField(r, names[i], ofValue(fs[i].value, mine, "f" + names[i]));
				place(r, mine);
				r;
			case VInstance({ikind: IRef(_)}):
				// a Ref: the bundle's GuestRef calling it; the same Ref when it comes back
				var to = bundle.typeObjs.get("hxmc.macro.GuestRef");
				if (to == null) throw new Unsupported("no GuestRef");
				var rv = v;
				var o = Type.createEmptyInstance(Mem.obj(to));
				var getF:Void->Dynamic = () -> ofValue(macros.eval.EvalMisc.callValue(macros.eval.EvalField.field(rv, EvalHash.hash("get")), []));
				var strF:Void->String = () -> macros.eval.EvalDecode.decodeString(macros.eval.EvalMisc.callValue(macros.eval.EvalField.field(rv, EvalHash.hash("toString")), []));
				Reflect.setField(o, "g", getF);
				Reflect.setField(o, "s", strF);
				origin.set(o, v);
				o;
			// (an API function value, as MetaAccess's: up to four arguments, the
			// missing ones null, as Eval's functions take them)
			case VFunction(_, _) | VFieldClosure(_, _):
				var fv = v;
				(a:Dynamic, b:Dynamic, c:Dynamic, d:Dynamic) -> {
					var args:Array<Dynamic> = [a, b, c, d];
					while (args.length > 0 && args[args.length - 1] == null)
						args.pop();
					var r = try macros.eval.EvalMisc.callValue(fv, [for (x in args) toValue(x)]) catch (e:Dynamic) return rethrow(e);
					return ofValue(r);
				};
			// (forced: Eval forces it when macro code reads it)
			case VLazy(l): ofValue(l.force(), pend, k);
			case _: v; // opaque: a position, a type, ...
		}
	}

	// an object of the bundle's anonymous structure with the most of these fields (the others overflow)
	static function newAnon(names:Array<String>):Dynamic {
		var best = -1, bestN = -1;
		for (s in bundle.shapes) {
			var ok = true;
			for (f in s.fields)
				if (names.indexOf(f) < 0) {
					ok = false;
					break;
				}
			if (ok && s.fields.length > bestN) {
				best = s.tindex;
				bestN = s.fields.length;
			}
		}
		if (best < 0) throw new Unsupported("no anonymous structure for {" + names.join(", ") + "}");
		var n = Mem.getI32(Mem.sym("rt_types").add(best * 112), 16);
		return Mem.alloc(n > 0 ? n : 1, best, 0);
	}
}
#end
