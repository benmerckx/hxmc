package hxmc.macro;

#if hxmc.jit
import core.TType;
import hxmc.Obj;
import hxmc.ir.Ir;

// The compile of macro code for the running compiler (Jit.hx), in a child
// process of it: the macro modules typed for hxmc in macro mode (`macro`
// defined, the macro context's typing rules), with Context's API bound to
// the compiler that loads them (GuestApi, written next to the entry), the
// functions compiled by hxmc's code generator and written as a relocatable
// object (<out>.o) and the program-wide facts the loader needs (<out>.json).
// Program-wide numbers stay symbolic (TY_*, FID_*, GI_*, ...): the loader
// takes the compiler's own for what it has, and new ones for the rest. The
// runtime (hxmc.rt) is not compiled: its functions and state are the
// compiler's.
@:access(hxmc.Driver)
@:access(hxmc.DataGen)
@:access(hxmc.ir.Facts)
@:access(hxmc.ir.Lower)
class Guest {
	public static inline var ENTRY = "HxmcMacroEntry";

	// in the child process: typing in macro mode, the bundle at `out` instead of an executable
	public static function install(out:String) {
		var prev = compiler.Compiler.beforeTypingHook;
		compiler.Compiler.beforeTypingHook = function(com, actx) {
			core.Define.rawDefineValue(com.defines, "macro", "1");
			com.isMacroContext = true;
			// (X.macro.hx before X.hx, as in the macro context)
			com.classPaths.lockContext(com.customExt, "macro", false);
			if (prev != null) prev(com, actx);
		};
		compiler.Compiler.generateHook = function(com) {
			try {
				generate(com, out);
			} catch (e:Dynamic) {
				sys.io.File.saveContent(out + ".error", Std.string(e));
			}
		};
	}

	static function runtime(f:FuncInfo):Bool
		return f.module != null && (StringTools.startsWith(f.module, "hxmc.rt.") || StringTools.startsWith(f.module, "hxmc.unsafe."));

	static function generate(com:context.Common.CommonContext, out:String) {
		var main:TClass = null;
		for (t in com.types)
			switch t {
				case TClassDecl(c) if (c.clPath.pack.length == 0 && c.clPath.name == ENTRY): main = c;
				case _:
			}
		if (main == null) throw "no entry class";
		var o = Options.read(com);
		var abi = Abi.get(o.target);
		abi.framePointers = abi.arm || o.framePointers; // (as Driver)
		hxmc.ir.Lower.targetOs = abi.osCode();
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		hxmc.ir.Lower.targetPlatform = abi.platformCode();
		entryCalls(com, main);
		mkPos(com);
		var l = new hxmc.ir.Lower();
		var prog = hxmc.ir.Lower.program(main, com.types, com.basic, l);
		var d = new Driver(prog, out, o);
		d.inlineCandidates();
		var prep = d.prep;
		var e = prep.e;
		var funcs = [for (f in prog.funcs) if (!runtime(f)) f];
		// the string literals (as Driver registers them)
		for (f in funcs) {
			var fp = new Fingerprint(prep, null);
			fp.func(f);
			var k = 0;
			while (k < fp.newStrings.length) {
				prep.addStr(fp.newStrings[k], fp.newStrings[k + 1]);
				k += 2;
			}
		}
		var obj = new Obj();
		var emit = Target.emitter(abi, obj);
		var ras = new Regalloc.Scratch(Target.selector(abi));
		for (f in funcs)
			d.compileFunc(f, obj, emit, ras);
		var dg = new DataGen(prep, abi, obj, mf -> d.compileMir(mf, emit, obj));
		dg.strings();
		for (s in prog.sigs) {
			d.compileMir(dg.dynTrampoline(s), emit, obj);
			d.compileMir(dg.boundTrampoline(s), emit, obj);
		}
		dg.allocStubs([], emit);
		dg.stubs([], emit);
		dg.cstrLiterals([]);
		dg.emptyArrays([]);
		sys.io.File.saveBytes(out + ".o", ElfWriter.write(obj, abi.arm));
		sys.io.File.saveContent(out + ".json", haxe.Json.stringify(facts(com, prog, e, l, main)));
	}

	static function kindChar(t:Null<Ty>):String
		return t == null ? "-" : switch t {
			case TI32: "i";
			case TBool: "b";
			case TF64: "f";
			case TI64: "l";
			case _: "p";
		};

	// what the loader needs to number, register and initialize the program's parts
	static function facts(com:context.Common.CommonContext, p:Program, e:hxmc.ir.Facts, l:hxmc.ir.Lower, main:TClass):Dynamic {
		var tn = e.typeNames;
		// what may be the compiler's own: the std's types and statics (hxmc's std, with the
		// runtime, included); the program's are its own even when named as one of the compiler's
		var roots = [];
		for (cp in com.classPaths.asList())
			if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx")))
				roots.push(cp.path);
		function isStd(file:String):Bool {
			for (r in roots)
				if (StringTools.startsWith(file, r)) return true;
			return false;
		}
		var stdTypes = new Map<String, Bool>();
		var globalShare = new Map<Int, Bool>();
		for (t in com.types) {
			var info = core.TFunctions.tInfos(t);
			var std = isStd(info.mtPos.pfile);
			if (std) stdTypes.set(core.Globals.sTypePath(info.mtPath), true);
			switch t {
				case TClassDecl(c):
					for (cf in c.clOrderedStatics) {
						var g = l.staticVars.get(cf);
						if (g != null) globalShare.set(g, std);
					}
				case _:
			}
		}
		for (en in p.enums)
			for (c in en.ctors)
				if (c.global >= 0) globalShare.set(c.global, stdTypes.exists(en.name));
		inline function tyName(i:Int):Dynamic
			return i < 0 ? null : i < Abi.T_FIRST ? Std.string(i) : tn[i];
		var share = new Map<Int, Bool>();
		var types = [];
		for (i in Abi.T_FIRST...e.types.length) {
			var t = e.types[i];
			share.set(i, switch t.tk {
				case "TK_ANON" | "TK_BOUND": true;
				case "TK_CLOSURE": false;
				case "TK_CTOR": share.get(t.sup) == true;
				case _: stdTypes.exists(t.name);
			});
			var supIsSig = t.tk == "TK_CLOSURE" || t.tk == "TK_BOUND";
			types.push({
				sym: tn[i],
				name: t.name,
				share: share.get(i),
				tk: t.tk,
				sup: supIsSig ? e.sigNames[t.sup] : tyName(t.sup),
				slots: [for (s in t.slots) kindChar(s)].join(""),
				fields: [for (f in t.fields) {name: f.name, slot: f.slot, kind: kindChar(f.ty)}],
				methods: [for (m in t.methods) {name: m.name, fn: m.fn, sig: e.sigNames[m.sig]}],
				ifaces: [for (x in t.ifaces) tyName(x)],
				tag: t.tag,
				ctors: [for (x in t.ctors) tyName(x)]
			});
		}
		// (statics: what Reflect finds on the class value, as DataGen writes them)
		function statics(c:ClassInfo):Array<Dynamic> {
			if (c.statics == null) return [];
			return [
				for (x in c.statics)
					if (x.clos != null) {name: x.name, kind: "c", ty: tn[x.clos.tindex], fn: e.symbol(x.clos.fn)}
					else if (Ir.isRef(p.globals[x.global].ty)) {name: x.name, kind: "p", global: e.globalNames[x.global]}
					else {name: x.name, kind: kindChar(p.globals[x.global].ty), sym: e.scalarGlobal(x.global)}
			];
		}
		var classes = [for (c in p.classes) if (c.tindex >= Abi.T_FIRST) {ty: tn[c.tindex], sup: c.sup == null || c.sup.tindex < 0 ? null : tn[c.sup.tindex], span: c.lastDescendant - c.id, statics: statics(c)}];
		var globals = [];
		for (g in 0...p.globals.length) {
			var gl = p.globals[g];
			if (gl.tls != null || gl.bss != null) continue;
			var ref = Ir.isRef(gl.ty);
			globals.push({
				name: e.globalNames[g],
				ref: ref,
				share: globalShare.get(g) == true,
				sym: ref ? "GIOFF_" + e.globalNames[g].substr(3) : e.scalarGlobal(g),
				size: gl.ty == TI32 || gl.ty == TBool ? 4 : 8,
				init: gl.init == null ? null : tn[gl.init.tindex]
			});
		}
		var inits = [];
		for (f in p.inits) {
			var c = l.initOf.get(f);
			if (c != null && runtimeClass(c)) continue;
			var ci = c == null ? null : l.classes.get(c);
			inits.push({fn: e.symbol(f), ty: ci == null || ci.tindex < 0 ? null : tn[ci.tindex], share: c != null && stdTypes.exists(core.Globals.sTypePath(c.clPath))});
		}
		var selectors = [];
		for (s in 0...p.selectors.length) {
			var rows = [];
			for (c in p.classes) {
				var m = c.findMethod(p.selectors[s].name);
				if (m != null && m.dispatchSel == s && c.tindex >= Abi.T_FIRST) rows.push({ty: tn[c.tindex], fn: e.symbol(m)});
			}
			selectors.push({sym: e.selNames[s], rows: rows});
		}
		var entries = [];
		for (cf in main.clOrderedStatics) {
			var f = l.funcs.get(cf);
			if (f != null && cf.cfName != "main") entries.push({name: cf.cfName, sym: e.symbol(f)});
		}
		// the singletons of constructors without arguments (the bridge's enum values)
		var singletons = [];
		for (en in p.enums)
			for (c in en.ctors)
				if (c.global >= 0) singletons.push({ty: tn[c.tindex], global: e.globalNames[c.global]});
		return {
			types: types,
			classes: classes,
			fields: [for (n in e.fieldNames) {name: n, sym: e.fidNames.get(n)}],
			sigs: [for (s in p.sigs) {sym: e.sigNames[s.id], key: s.key, dyn: "DYN" + s.id, bt: "BT" + s.id, bound: tn[e.boundTypes.get(s.id)]}],
			globals: globals,
			inits: inits,
			selectors: selectors,
			entries: entries,
			singletons: singletons
		};
	}

	// the entries call their macro function (@:hxmc.macroCall("pack.Class.f")) with
	// the arguments of their array: written here, on the typed AST, since a call
	// of a macro function in source is a macro call even in macro mode
	static function entryCalls(com:context.Common.CommonContext, main:TClass) {
		var b = com.basic;
		for (cf in main.clOrderedStatics) {
			var target = hxmc.ir.Lower.metaString(":hxmc.macroCall", cf.cfMeta);
			if (target == null) continue;
			var dot = target.lastIndexOf(".");
			var cpath = target.substr(0, dot), fname = target.substr(dot + 1);
			var c:TClass = null;
			for (t in com.types)
				switch t {
					case TClassDecl(k) if (core.Globals.sTypePath(k.clPath) == cpath): c = k;
					case _:
				}
			if (c == null) throw "no class " + cpath;
			var mf = c.clStatics.get(fname);
			if (mf == null) throw "no static " + target;
			var sig = switch core.TFunctions.follow(mf.cfType) {
				case TFun(s): s;
				case _: throw target + " is not a function";
			};
			switch cf.cfExpr.eexpr {
				case TFunction(tf):
					var p = cf.cfPos;
					var a = tf.tfArgs[0].variable;
					var tdyn = switch core.TFunctions.follow(a.vType) {
						case TInst(_, [t]): t;
						case _: throw "entry argument";
					};
					inline function arg(i:Int):TExpr
						return core.TFunctions.mk(TArray(core.Texpr.Builder.makeLocal(a, p), core.Texpr.Builder.makeInt(b, i, p)), tdyn, p);
					var ef = core.TFunctions.mk(TField(core.Texpr.Builder.makeStaticThis(c, p), FStatic(c, mf)), mf.cfType, p);
					var isVoid = switch core.TFunctions.follow(sig.ret) {
						case TAbstract({aPath: {pack: [], name: "Void"}}, _): true;
						case _: false;
					};
					// the call with k arguments, returning its result
					function callWith(k:Int):TExpr {
						var call = core.TFunctions.mk(TCall(ef, [for (i in 0...k) arg(i)]), sig.ret, p);
						var ret = core.TFunctions.mk(TReturn(isVoid ? core.TFunctions.mk(TConst(TNull), tdyn, p) : call), b.tvoid, p);
						return core.TFunctions.mk(TBlock(isVoid ? [call, ret] : [ret]), b.tvoid, p);
					}
					// trailing optional arguments that are null are left out (their
					// defaults apply, as when Eval calls the function with them null)
					var required = 0;
					while (required < sig.args.length && !sig.args[required].optional)
						required++;
					var body = callWith(required);
					for (k in required + 1...sig.args.length + 1) {
						var given = core.TFunctions.mk(TBinop(OpNotEq, arg(k - 1), core.TFunctions.mk(TConst(TNull), tdyn, p)), b.tbool, p);
						body = core.TFunctions.mk(TIf(given, callWith(k), body), b.tvoid, p);
					}
					tf.tfExpr = core.TFunctions.mk(TBlock([body]), b.tvoid, p);
				case _:
			}
		}
	}

	static function runtimeClass(c:TClass):Bool {
		var pk = c.clPath.pack;
		return pk.length >= 2 && pk[0] == "hxmc" && (pk[1] == "rt" || pk[1] == "unsafe");
	}

	// reification's positions in macro mode (`$__mk_pos__`, which Eval
	// evaluates to the expression's position) as calls of the compiler's
	// GuestApi.mkPos(file, min, max)
	static function mkPos(com:context.Common.CommonContext) {
		var host:TClass = null;
		for (t in com.types)
			switch t {
				case TClassDecl(c) if (c.clPath.pack.join(".") == "hxmc.macro" && c.clPath.name == "GuestHost"): host = c;
				case _:
			}
		if (host == null) return;
		var b = com.basic;
		function call(name:String, args:Array<TExpr>, t:T, p:core.Globals.Pos):TExpr {
			// (externs have their native names by now)
			var cf = host.clStatics.get(name);
			if (cf == null) throw "GuestHost." + name + " is missing (" + [for (k in host.clStatics.keys()) k].join(",") + ")";
			var ef = core.TFunctions.mk(TField(core.Texpr.Builder.makeStaticThis(host, p), FStatic(host, cf)), cf.cfType, p);
			return core.TFunctions.mk(TCall(ef, args.concat([
				core.Texpr.Builder.makeString(b, p.pfile, p),
				core.Texpr.Builder.makeInt(b, p.pmin, p),
				core.Texpr.Builder.makeInt(b, p.pmax, p)
			])), t, p);
		}
		var user = false; // (in the program's code, not the std's)
		function map(e:TExpr):TExpr {
			return switch e.eexpr {
				// a call of the macro API from the program's code: its position first
				// (Bridge.callPos), which the API gets from Eval's frames
				case TCall({eexpr: TField(_, FStatic(mc, _))}, _) if (user && ["haxe.macro.Context", "haxe.macro.Compiler"].indexOf(core.Globals.sTypePath(mc.clPath)) >= 0):
					var inner = core.Texpr.mapExpr(map, e);
					core.TFunctions.mk(TBlock([call("hxmc_macro_call_pos", [], b.tvoid, e.epos), inner]), e.etype, e.epos);
				// Context's `load(name, n)(args)` as hxmc_macro_api(name, [args])
				case TCall({eexpr: TCall({eexpr: TField(_, FStatic(lc, {cfName: "load"}))}, [name, _])}, args) if (core.Globals.sTypePath(lc.clPath) == "haxe.macro.Context"):
					var p = e.epos;
					var cf = host.clStatics.get("hxmc_macro_api");
					var ef = core.TFunctions.mk(TField(core.Texpr.Builder.makeStaticThis(host, p), FStatic(host, cf)), cf.cfType, p);
					var arr = core.TFunctions.mk(TArrayDecl([for (a in args) core.TFunctions.mk(TCast(map(a), null), b.tany, a.epos)]), b.tarray(b.tany), p);
					core.TFunctions.mk(TCall(ef, [map(name), arr]), e.etype, p);
				case TIdent("$__mk_pos__"):
					call("hxmc_macro_pos", [], e.etype, e.epos);
				// (the construction position of a macro API enum value, as Eval keeps it)
				case TCall({eexpr: TField(_, FEnum(en, _))}, _) if (en.ePath.pack.length == 2 && en.ePath.pack[0] == "haxe" && en.ePath.pack[1] == "macro"):
					call("hxmc_macro_enum_pos", [core.Texpr.mapExpr(map, e)], e.etype, e.epos);
				case _: core.Texpr.mapExpr(map, e);
			}
		}
		for (t in com.types)
			switch t {
				case TClassDecl(c) if (!runtimeClass(c)):
					user = !(c.clPath.pack.length >= 2 && c.clPath.pack[0] == "haxe" && c.clPath.pack[1] == "macro") && c.clPath.name != ENTRY;
					for (cf in c.clOrderedFields.concat(c.clOrderedStatics).concat(c.clConstructor == null ? [] : [c.clConstructor]))
						if (cf.cfExpr != null) cf.cfExpr = map(cf.cfExpr);
					if (c.clInit != null && c.clInit.cfExpr != null) c.clInit.cfExpr = map(c.clInit.cfExpr);
				case _:
			}
	}
}
#end
