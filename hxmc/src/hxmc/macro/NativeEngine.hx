package hxmc.macro;

#if hxmc.jit
import core.TType;
import core.TFunctions;
import macros.MacroApi.CompilerApi;
import macros.eval.EvalContext;
import macros.eval.EvalValue.Value;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.macro.Loader.Bundle;

// The macro engine of `-D hxmc.macros=native|verify` (HaxeMain installs it
// in a compiler built with -D hxmc.jit): Eval for everything, except macro
// calls that run natively. A macro function is compiled on its first call
// (Guest, in a child process; then Loader) and called with its arguments
// converted (Bridge); what cannot be compiled, loaded or converted runs on
// Eval. verify runs both engines for each call, Eval's result being the one
// used, compares the results (the values, positions included) and errors,
// and reports mismatches and fallbacks.
@:access(hxmc.macro.Bridge)
class NativeEngine extends macros.MacroEngine.EvalEngine {
	public var verify = false;
	// (-D hxmc.macros=mir or mir-verify: interpreted bundles)
	public var interp = false;
	var types:Array<ModuleType> = [];
	var com:Null<context.Common.CommonContext> = null;
	var compiled = new Map<String, Null<Bundle>>(); // class -> its bundle (null: on Eval)
	var dir:String;
	var ncompiled = 0;
	// -D hxmc.macros=native or verify (else this is Eval: set when the macro context is created)
	public var enabled = false;
	// statistics (printed at exit with HXMC_MACRO_STATS=1 or in verify mode)
	public var calls = 0;
	public var native = 0;
	public var matched = 0;
	public var mismatched = 0;
	public var fallbacks = 0;
	public var tNative = 0.0;
	public var tEval = 0.0;
	public var tCompile = 0.0;

	public function new() {
		super();
		dir = haxe.io.Path.join([Sys.getEnv("TMPDIR") != null ? Sys.getEnv("TMPDIR") : "/tmp", "hxmc-macros-" + Std.string(Std.int(Sys.time() * 1000) % 1000000000) + "-" + Std.string(Std.random(1 << 30))]);
	}

	function note(s:String)
		if (verify || Sys.getEnv("HXMC_MACRO_STATS") == "1") Sys.stderr().writeString("hxmc.macros: " + s + "\n");

	override public function create(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):Context {
		this.com = com;
		var m = core.Define.rawDefined(com.defines, "hxmc.macros") ? core.Define.rawDefinedValue(com.defines, "hxmc.macros") : "eval";
		// (mir, mir-verify: the macro classes compiled for the Mir interpreter, -D hxmc.interp)
		enabled = m == "native" || m == "verify" || m == "mir" || m == "mir-verify";
		verify = m == "verify" || m == "mir-verify";
		interp = m == "mir" || m == "mir-verify";
		// (before any macro code runs: Eval may keep the API functions it looked up)
		if (verify) Bridge.Recorder.install();
		return super.create(com, api, isMacro, args);
	}

	override public function addTypes(ctx:Context, types:Array<ModuleType>, ready:ModuleType->Void):Void {
		super.addTypes(ctx, types, ready);
		this.types = types;
	}

	function findClass(path:Array<String>):Null<TClass> {
		var name = path.join(".");
		for (t in types)
			switch t {
				case TClassDecl(c) if (core.Globals.sTypePath(c.clPath) == name): return c;
				case _:
			}
		return null;
	}

	function findEnum(name:String):Null<TEnum> {
		for (t in types)
			switch t {
				case TEnumDecl(e) if (core.Globals.sTypePath(e.ePath) == name): return e;
				case _:
			}
		return null;
	}

	override public function callPath(ctx:Context, path:Array<String>, f:String, vl:Array<Value>, api:CompilerApi):haxe.ds.Option<Value> {
		if (!enabled) return super.callPath(ctx, path, f, vl, api);
		if (ctx.hadError) return None;
		calls++;
		var cls = path.join(".");
		var key = cls + "." + f;
		// (a class's macro functions are compiled together: all of them run natively
		// or none, with one static state)
		var b = compiled.exists(cls) ? compiled.get(cls) : compile(cls, path);
		var entry = b == null ? null : b.entries.get("e_" + f);
		if (entry == null) {
			fallbacks++;
			if (b != null) note(key + ": no entry (rest arguments): on Eval");
			return super.callPath(ctx, path, f, vl, api);
		}
		var c = {bundle: b, entry: entry};
		if (!verify) {
			var t0 = haxe.Timer.stamp();
			var r = runNative(ctx, path, f, c, vl, api);
			tNative += haxe.Timer.stamp() - t0;
			switch r {
				case Ok(v):
					native++;
					return Some(v);
				case Failed(msg, e) if (e == null):
					// (unsupported at the boundary: Eval runs it instead)
					fallbacks++;
					note(key + ": " + msg + ": on Eval");
					return super.callPath(ctx, path, f, vl, api);
				case Failed(_, e):
					native++;
					// as Eval ends a macro call that throws (EvalMain.callPath): what
					// macro code threw becomes Eval's exception, the compiler's own pass
					var thrown = Bridge.guestThrown(e);
					if (thrown == null) throw Bridge.original(e);
					var old = ctx.curapi;
					ctx.curapi = api;
					return macros.eval.EvalExceptions.catchExceptions(ctx, () -> throw new RunTimeException(thrown, [], api.pos), api.pos, () -> ctx.curapi = old);
			}
		}
		// verify: Eval's result is the one used
		var t0 = haxe.Timer.stamp();
		var evo:haxe.ds.Option<Value> = None, eerr:Null<Dynamic> = null;
		// (its API calls recorded, then replayed to the native run: Bridge.Recorder)
		Bridge.Recorder.install();
		var rec = [];
		Bridge.Recorder.stack.push(rec);
		try evo = super.callPath(ctx, path, f, vl, api) catch (e:Dynamic) eerr = e;
		var ev:Null<Value> = switch evo {
			case Some(v): v;
			case None: null;
		};
		Bridge.Recorder.stack.pop();
		tEval += haxe.Timer.stamp() - t0;
		var t1 = haxe.Timer.stamp();
		Bridge.replay = rec;
		Bridge.replayAt = 0;
		Bridge.replayMismatch = null;
		var r = runNative(ctx, path, f, c, vl, api);
		Bridge.replay = null;
		tNative += haxe.Timer.stamp() - t1;
		var rm = Bridge.replayMismatch;
		if (rm == null && eerr == null && r.match(Ok(_)) && Bridge.replayAt < rec.length) rm = "native made " + Bridge.replayAt + " API calls, Eval " + rec.length;
		if (rm != null) {
			native++;
			mismatched++;
			note(key + ": MISMATCH: " + rm);
			if (eerr != null) throw eerr;
			return evo;
		}
		switch r {
			case Failed(msg, e) if (e == null):
				fallbacks++;
				note(key + ": " + msg + ": on Eval");
			case Failed(msg, e):
				native++;
				if (eerr != null) matched++ else {
					mismatched++;
					note(key + ": MISMATCH: native failed (" + msg + "), Eval did not");
				}
			case Ok(nv):
				native++;
				if (eerr != null) {
					mismatched++;
					note(key + ": MISMATCH: Eval failed (" + Std.string(eerr) + "), native did not");
				} else {
					var d = diff(ev, nv, "");
					if (d == null) matched++ else {
						mismatched++;
						note(key + ": MISMATCH at " + d);
					}
				}
		}
		if (eerr != null) throw eerr;
		return evo;
	}

	public function report() {
		// (the children's directories)
		if (Sys.getEnv("HXMC_MACRO_KEEP") != "1" && sys.FileSystem.exists(dir)) try removeDir(dir) catch (_:Dynamic) {}
		if (calls == 0) return;
		note('$calls macro calls: $native native (${matched} matched, ${mismatched} mismatched), $fallbacks on Eval; compile ${ms(tCompile)}, native ${ms(tNative)}' + (verify ? ', eval ${ms(tEval)}' : '') + ', ${Bridge.apiCalls} API calls');
	}

	static function ms(s:Float):String
		return Std.int(s * 1000) + " ms";

	function runNative(ctx:Context, path:Array<String>, f:String, c:{bundle:Bundle, entry:Ptr}, vl:Array<Value>, api:CompilerApi):NativeResult {
		var old = ctx.curapi;
		ctx.curapi = api;
		EvalContext.select(ctx);
		Bridge.bundle = c.bundle;
		Bridge.enumLookup = findEnum;
		Bridge.reset();
		// the macro call's frame, as EvalMain.callPath pushes it
		var p = api.pos;
		var ph = macros.eval.EvalHash.pathHash(new core.Globals.GlobalTypePath(path.slice(0, path.length - 1), path[path.length - 1]));
		var info = EvalContext.createEnvInfo(true, p.pfile, ctx.fileKeys.get(p.pfile), EKMacro(ph, macros.eval.EvalHash.hash(f)), macros.eval.EvalDebugMisc.newIntHashtbl(), 0, 0);
		var env = EvalContext.pushEnvironment(ctx, info);
		env.envLeavePmin = p.pmin;
		env.envLeavePmax = p.pmax;
		function done() {
			EvalContext.popEnvironment(ctx, env);
			ctx.curapi = old;
		}
		try {
			var args:Array<Dynamic> = [for (v in vl) Bridge.ofValue(v)];
			var r:Dynamic = Mem.callRef1(c.entry, args);
			var v = Bridge.toValue(r);
			done();
			return Ok(v);
		} catch (e:Bridge.Unsupported) {
			done();
			return Failed(e.message, null);
		} catch (e:Dynamic) {
			done();
			return Failed(Std.string(e), e);
		}
	}

	// ---- compiling a macro function

	function compile(key:String, path:Array<String>):Null<Bundle> {
		var t0 = haxe.Timer.stamp();
		var r = try compileImpl(key, path) catch (e:Dynamic) {
			note(key + ": not compiled: " + Std.string(e).split("\n")[0]);
			null;
		}
		tCompile += haxe.Timer.stamp() - t0;
		compiled.set(key, r);
		return r;
	}

	function compileImpl(key:String, path:Array<String>):Bundle {
		var c = findClass(path);
		if (c == null) throw "class not in the macro context";
		// an entry per static function (but those with rest arguments)
		var fns = [];
		for (cf in c.clOrderedStatics) {
			if (!cf.cfKind.match(Method(_)) || cf.cfExpr == null) continue;
			var rest = switch TFunctions.follow(cf.cfType) {
				case TFun(s): core.ds.VectorTools.exists(s.args, a -> TFunctions.follow(a.type).match(TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, _)));
				case _: true;
			};
			if (!rest) fns.push(cf.cfName);
		}
		var n = ncompiled++;
		var d = dir + "/" + n;
		if (sys.FileSystem.exists(d)) removeDir(d);
		sys.FileSystem.createDirectory(d + "/hxmc/macro");
		sys.FileSystem.createDirectory(d + "/haxe/macro");
		// (the class's module is a root of the child's compile: no reference by name,
		// which an abstract's implementation class has not)
		var mp = core.Globals.sTypePath(c.clModule.mPath);
		sys.io.File.saveContent(d + "/" + Guest.ENTRY + ".hx", 'class ${Guest.ENTRY} {\n'
			+ '\tstatic function main() {\n' + [for (f in fns) '\t\te_' + f + '(null);\n'].join("") + '\t\thxmc.macro.GuestHost.mkPos("", 0, 0);\n\t\thxmc.macro.GuestHost.enumPos(null, "", 0, 0);\n\t\thxmc.macro.GuestHost.api("", []);\n\t\thxmc.macro.GuestHost.callPos("", 0, 0);\n\t\tnew hxmc.macro.GuestHost.GuestRef(null, null).toString();\n' + [for (en in EXPR_ENUMS) '\t\tType.getEnumName(haxe.macro.' + en + ');\n'].join("") + '\t}\n\n'
			+ [for (f in fns) '\t@:hxmc.macroCall("' + key + "." + f + '")\n\tpublic static function e_' + f + '(a:Array<Dynamic>):Dynamic\n\t\treturn null;\n\n'].join("") + '}\n');
		sys.io.File.saveContent(d + "/hxmc/macro/GuestHost.hx", GUEST_HOST);
		sys.io.File.saveContent(d + "/haxe/macro/Context.hx", contextSource());
		// the child: this compiler, typing the entry in macro mode for hxmc (Guest)
		var cargs = [];
		var cps = com.classPaths.asList().copy();
		cps.reverse();
		for (cp in cps)
			switch cp.scope {
				case Std | StdTarget:
				case _: if (cp.path != "") cargs = cargs.concat(["-cp", cp.path]);
			}
		cargs = cargs.concat(["-cp", hxmcStd(), "-cp", d]);
		var raw = compiler.Args.toRawArgs(com.parsedArgs);
		for (i in 0...raw.length - 1)
			if (raw[i] == "-D" || raw[i] == "--define") {
				var k = raw[i + 1].split("=")[0];
				if (!StringTools.startsWith(k, "hxmc.") && k != "dump" && k != "dump-dependencies") cargs = cargs.concat(["-D", raw[i + 1]]);
			}
		if (com.customExt != null) cargs = cargs.concat(["--custom-extension", com.customExt]);
		var out = d + "/bundle";
		cargs = cargs.concat(["-D", "hxmc.target=linux-x86_64", "-D", "disable-parallelism", "-dce", "no", "-main", Guest.ENTRY, mp, "--custom-target", "hxmc=" + out]);
		if (interp) cargs = cargs.concat(["-D", "hxmc.interp"]);
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		Sys.putEnv("HXMC_MACRO_GUEST", out);
		// (through sh, its output to a file: no pipes in this process)
		var code = Sys.command("sh", ["-c", "exec \"$0\" \"$@\" > \"" + out + ".log\" 2>&1", exe].concat(cargs));
		var log = sys.FileSystem.exists(out + ".log") ? sys.io.File.getContent(out + ".log") : "";
		Sys.putEnv("HXMC_MACRO_GUEST", "");
		if (sys.FileSystem.exists(out + ".error")) throw sys.io.File.getContent(out + ".error");
		if (code != 0 || !sys.FileSystem.exists(out + ".o")) throw "the child compile failed: " + StringTools.trim(log);
		var b = Loader.load(out);
		if (Sys.getEnv("HXMC_MACRO_KEEP") != "1") removeDir(d);
		note(key + ": compiled (" + b.codeBytes + " bytes of code)");
		return b;
	}

	static function removeDir(d:String) {
		for (n in sys.FileSystem.readDirectory(d)) {
			var p = d + "/" + n;
			if (sys.FileSystem.isDirectory(p)) removeDir(p) else sys.FileSystem.deleteFile(p);
		}
		sys.FileSystem.deleteDirectory(d);
	}

	function hxmcStd():String {
		var e = Sys.getEnv("HXMC_STD");
		if (e != null && e != "") return e;
		for (cp in com.classPaths.asStringList())
			if (cp != "" && sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp) + "hxmc/rt/Runtime.hx")) return cp;
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		return haxe.io.Path.directory(haxe.io.Path.directory(exe)) + "/hxmc/std";
	}

	// the std's haxe.macro.Context with its API bound to this compiler (GuestHost.load)
	function contextSource():String {
		for (cp in com.classPaths.asList())
			if (cp.scope == Std) {
				var p = haxe.io.Path.addTrailingSlash(cp.path) + "haxe/macro/Context.hx";
				if (sys.FileSystem.exists(p)) {
					var s = sys.io.File.getContent(p);
					s = StringTools.replace(s, "#if eval", "#if true");
					s = StringTools.replace(s, "return eval.vm.Context.callMacroApi(f);", "return hxmc.macro.GuestHost.load(f);");
					return s;
				}
			}
		throw "no haxe/macro/Context.hx in the std";
	}

	// the enums of haxe.macro.Expr and haxe.macro.Type, in every bundle (the bridge makes their values)
	static var EXPR_ENUMS = [
		for (e in ["StringLiteralKind", "Constant", "Binop", "Unop", "EFieldKind", "QuoteStatus", "FunctionKind", "ExprDef", "DisplayKind", "ComplexType", "TypeParam", "Access", "FieldType", "TypeDefKind", "AbstractFlag", "ImportMode"]) "Expr." + e
	].concat([
		for (e in ["Type", "AnonStatus", "ClassKind", "FieldKind", "VarAccess", "MethodKind", "TConstant", "ModuleType", "FieldAccess", "TypedExprDef"]) "Type." + e
	]);

	static var GUEST_HOST = "package hxmc.macro;\n\n"
		+ "// native macros: the compiler running this code (hxmc/src/hxmc/macro/Bridge.hx)\n"
		+ "@:keep @:hxmc.rt extern class GuestHost {\n"
		+ "\t@:native(\"hxmc_macro_api\") static function api(name:String, args:Array<Dynamic>):Dynamic;\n"
		+ "\t@:native(\"hxmc_macro_pos\") static function mkPos(file:String, min:Int, max:Int):Dynamic;\n"
		+ "\t@:native(\"hxmc_macro_enum_pos\") static function enumPos(v:Dynamic, file:String, min:Int, max:Int):Dynamic;\n"
		+ "\t@:native(\"hxmc_macro_call_pos\") static function callPos(file:String, min:Int, max:Int):Void;\n\n"
		+ "\t// (Context's calls `load(name, n)(args)` call api directly: Guest)\n"
		+ "\tstatic inline function load(f:String):Dynamic\n"
		+ "\t\treturn Reflect.makeVarArgs(args -> api(f, args));\n"
		+ "}\n\n"
		+ "// a Ref of the compiler (Bridge): get and toString call it\n"
		+ "@:keep class GuestRef {\n"
		+ "\tvar g:Void->Dynamic;\n"
		+ "\tvar s:Void->String;\n\n"
		+ "\tpublic function new(g, s) {\n\t\tthis.g = g;\n\t\tthis.s = s;\n\t}\n\n"
		+ "\tpublic function get():Dynamic\n\t\treturn g();\n\n"
		+ "\tpublic function toString():String\n\t\treturn s();\n"
		+ "}\n";

	// ---- comparing results: null when equal, else where they differ

	public static function diff(a:Null<Value>, b:Null<Value>, at:String):Null<String> {
		if (a == null) a = VNull;
		if (b == null) b = VNull;
		switch a {
			case VLazy(l): a = l.force();
			case _:
		}
		switch b {
			case VLazy(l): b = l.force();
			case _:
		}
		inline function no(what:String):String
			return (at == "" ? "the result" : at) + ": " + what;
		return switch [a, b] {
			case [VNull, VNull] | [VTrue, VTrue] | [VFalse, VFalse]: null;
			case [VInt32(x), VInt32(y)]: x == y ? null : no(x + " vs " + y);
			case [VFloat(x), VFloat(y)]: x == y || (Math.isNaN(x) && Math.isNaN(y)) ? null : no(x + " vs " + y);
			case [VString(x), VString(y)]: x.sstring == y.sstring ? null : no('"${x.sstring}" vs "${y.sstring}"');
			case [VArray(x), VArray(y)]:
				if (x.alength != y.alength) return no("length " + x.alength + " vs " + y.alength);
				for (i in 0...x.alength) {
					var d = diff(x.avalues[i], y.avalues[i], at + "[" + i + "]");
					if (d != null) return d;
				}
				null;
			case [VEnumValue(x), VEnumValue(y)]:
				var name = macros.eval.EvalHash.revHash(x.epath);
				if (x.epath != y.epath || x.eindex != y.eindex) return no(name + "#" + x.eindex + " vs " + macros.eval.EvalHash.revHash(y.epath) + "#" + y.eindex);
				if (!samePos(x.enpos, y.enpos)) return no(name + "#" + x.eindex + " position " + sPos(x.enpos) + " vs " + sPos(y.enpos));
				for (i in 0...x.eargs.length) {
					var d = diff(x.eargs[i], y.eargs[i], at + "(" + i + ")");
					if (d != null) return d;
				}
				null;
			case [VObject(x), VObject(y)]:
				var fx = EvalContext.objectFields(x), fy = EvalContext.objectFields(y);
				var mx = new Map<Int, Value>(), my = new Map<Int, Value>();
				for (f in fx) mx.set(f.name, f.value);
				for (f in fy) my.set(f.name, f.value);
				for (f in fx) {
					var n = macros.eval.EvalHash.revHash(f.name);
					var yv = my.get(f.name);
					var d = diff(f.value, yv == null ? VNull : yv, at + "." + n);
					if (d != null) return d;
				}
				for (f in fy)
					if (!mx.exists(f.name)) {
						var d = diff(VNull, f.value, at + "." + macros.eval.EvalHash.revHash(f.name));
						if (d != null) return d;
					}
				null;
			case [VFunction(_, _) | VFieldClosure(_, _), VFunction(_, _) | VFieldClosure(_, _)]: null; // (not comparable)
			case [VInstance({ikind: IRef(x)}), VInstance({ikind: IRef(y)})]:
				x == y ? null : no("Ref to another value");
			case [VInstance({ikind: IPos(p)}), VInstance({ikind: IPos(q)})]:
				samePos(p, q) ? null : no("position " + sPos(p) + " vs " + sPos(q));
			case _:
				a == b ? null : no(macros.eval.EvalPrinting.valueString(a) + " vs " + macros.eval.EvalPrinting.valueString(b));
		}
	}

	static function samePos(p:Null<core.Globals.Pos>, q:Null<core.Globals.Pos>):Bool
		return p == null ? q == null : q != null && p.pfile == q.pfile && p.pmin == q.pmin && p.pmax == q.pmax;

	static function sPos(p:Null<core.Globals.Pos>):String
		return p == null ? "none" : p.pfile + ":" + p.pmin + "-" + p.pmax;
}

enum NativeResult {
	Ok(v:Value);
	// e: the exception the native call raised (null: unsupported, Eval runs the call)
	Failed(msg:String, e:Null<Dynamic>);
}
#end
