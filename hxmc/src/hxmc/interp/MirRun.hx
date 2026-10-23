package hxmc.interp;

#if hxmc.jit
import core.TType;
import hxmc.Obj;
import hxmc.ir.Ir;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// `--interp` and `--run` with -D hxmc.mir-run, in a compiler built with
// -D hxmc.jit: the program typed for hxmc (its std, not Eval's), its
// functions encoded for the Mir interpreter (InterpGen: all but the
// runtime's, which is the compiler's own), linked into the running compiler
// (macro.Loader: the std's types and statics are the compiler's where the
// program has them as the compiler does, the others new) and run here: its
// static initializers, then main, with the program's arguments.
@:access(hxmc.Driver)
@:access(hxmc.DataGen)
@:access(hxmc.ir.Facts)
@:access(hxmc.ir.Lower)
@:access(hxmc.macro.Guest)
@:access(hxmc.macro.Loader)
@:access(hxmc.rt.Start)
@:access(hxmc.rt.Gc)
class MirRun {
	// (-D turns the dash into an underscore)
	public static inline var DEFINE = "hxmc.mir_run";

	// the program's arguments (--run's after its module)
	static var args:Array<String> = [];

	// the command line with -D hxmc.mir-run: --interp and --run as an hxmc
	// compile that ends here (generateHook: run); null without it
	public static function rewrite(argv:Array<String>):Null<Array<String>> {
		var on = false;
		for (i in 0...argv.length - 1)
			if ((argv[i] == "-D" || argv[i] == "--define") && (argv[i + 1] == "hxmc.mir-run" || argv[i + 1] == DEFINE)) on = true;
		if (!on) return null;
		var out = [];
		var i = 0;
		while (i < argv.length) {
			var a = argv[i];
			if (a == "--interp") {
				i++;
				continue;
			}
			if (a == "--run" && i + 1 < argv.length) {
				out.push("-main");
				out.push(argv[i + 1]);
				args = argv.slice(i + 2);
				break;
			}
			out.push(a);
			i++;
		}
		return out.concat(["--custom-target", "hxmc", "-D", "hxmc.interp"]);
	}

	public static function run(com:context.Common.CommonContext) {
		if (com.main.mainPath == null) throw "a program needs an entry point: -main <module>";
		var mainClass = context.Common.getEntryPoint(com).cls;
		var o = Options.read(com);
		var abi = Abi.get(o.target);
		if (abi.name != "linux-x86_64" || o.libc != null) throw "-D hxmc.mir-run: linux-x86_64 (static) only, as the loader";
		abi.framePointers = abi.arm || o.framePointers; // (as Driver)
		hxmc.ir.Lower.targetOs = abi.osCode();
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		hxmc.ir.Lower.targetPlatform = abi.platformCode();
		hxmc.ir.Lower.bounds = o.bounds;
		hxmc.ir.Lower.resources = com.resources.fold((name, data, acc:Array<{name:String, data:haxe.io.Bytes}>) -> [{name: name, data: data}].concat(acc), []);
		var t0 = haxe.Timer.stamp();
		var l = new hxmc.ir.Lower();
		var prog = hxmc.ir.Lower.program(mainClass, com.types, com.basic, l);
		// (what a native build keeps: reflection sees the same methods)
		hxmc.ir.Reach.run(prog, o.stats);
		var d = new Driver(prog, "", o);
		d.inlineCandidates();
		var prep = d.prep;
		var e = prep.e;
		// (the runtime's functions are the compiler's, but those it lacks: a
		// runtime function is made when something calls it, @:hxmc.host)
		var host = hxmc.macro.Loader.hostSyms();
		InterpGen.emulatedTls = new Map();
		InterpGen.nativeTls = s -> {
			var h = host.get(s);
			h != null && h.k == "l";
		};
		// (and those whose source the program's defines change: -D hxmc.native-array-outofbounds)
		var ownRuntime = o.bounds != 0 ? ["hxmc.rt.Dyn" => true, "hxmc.rt.NArray" => true] : new Map<String, Bool>();
		var funcs = [for (f in prog.funcs) if (!hxmc.macro.Guest.runtime(f) || !host.exists(e.symbol(f)) || ownRuntime.exists(f.module)) f];
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
		var facts:Dynamic = hxmc.macro.Guest.facts(com, prog, e, l, mainClass);
		(facts.entries : Array<Dynamic>).push({name: "main", sym: e.symbol(prog.main)});
		// (haxe.EntryPoint.run after main, as an executable's start: the event loop, DataGen)
		if (prog.entryRun != null) (facts.entries : Array<Dynamic>).push({name: "entryRun", sym: e.symbol(prog.entryRun)});
		unshare(facts, host, l, e, com);
		// the std's functions the compiler has alike: its native code
		// (HXMC_MIR_HOST=0: all interpreted)
		var native = Sys.getEnv("HXMC_MIR_HOST") == "0" ? new Map() : hostFunctions(funcs, facts, prep, e, com, ownRuntime);
		funcs = [for (f in funcs) if (!native.exists(f)) f];
		d.interp = new InterpGen.InterpSet(o.interp, prep, native);
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
		dg.resources([]);
		var t1 = haxe.Timer.stamp();
		setArgs();
		var b = hxmc.macro.Loader.loadObj(obj, facts);
		if (o.stats)
			Sys.println('hxmc mir-run: ${funcs.length} functions (${Lambda.count(native)} native), compiled ${Std.int((t1 - t0) * 1000)} ms, loaded ${Std.int((haxe.Timer.stamp() - t1) * 1000)} ms');
		var main = b.entries.get("main");
		try {
			Mem.call0(main);
			if (b.entries.exists("entryRun")) Mem.call0(b.entries.get("entryRun"));
		} catch (e:Dynamic) {
			// (as the program would: hxmc.rt.Start's rt_throw without a handler)
			hxmc.rt.Gc.uncaught("Uncaught exception: ", e);
			Sys.exit(1);
		}
	}

	// the std's functions whose native code in the compiler is the program's:
	// from the std's files (no class of the program shadows them), the same
	// fingerprint (Fingerprint: the IR, layouts and callees by name; the
	// compiler's in <exe>.fps), every type they touch shared, every selector
	// they dispatch on implemented by shared types only, every function
	// they call directly such a function or the compiler's runtime (native
	// code calls its own; prior: those found so far for earlier code, MirMacros)
	static function hostFunctions(funcs:Array<FuncInfo>, facts:Dynamic, prep:Prep, e:hxmc.ir.Facts, com:context.Common.CommonContext,
			ownRuntime:Map<String, Bool>, ?prior:Map<FuncInfo, Bool>):Map<FuncInfo, Bool> {
		var fps = hostFps();
		var roots = [];
		for (cp in com.classPaths.asList())
			if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx")))
				roots.push(cp.path);
		function isStd(file:String):Bool {
			for (r in roots)
				if (StringTools.startsWith(file, r)) return true;
			return false;
		}
		var shared = new Map<String, Bool>();
		for (t in (facts.types : Array<Dynamic>))
			if (t.share == true) shared.set(t.sym, true);
		inline function sharedType(tindex:Int):Bool
			return tindex < Abi.T_FIRST || shared.exists(e.typeNames[tindex]);
		// (the selectors a type of the program's own implements: the compiler's
		// dispatch rows lack it, so its code may not dispatch on them)
		var ownSel = new Map<String, Bool>();
		for (sel in (facts.selectors : Array<Dynamic>))
			for (r in (sel.rows : Array<Dynamic>))
				if (!shared.exists(r.ty)) ownSel.set(sel.sym, true);
		var bundled = new Map<FuncInfo, Bool>();
		for (f in funcs)
			bundled.set(f, true);
		var cand = new Map<FuncInfo, Bool>();
		var calls = new Map<FuncInfo, Array<FuncInfo>>();
		for (f in funcs) {
			if (hxmc.macro.Guest.runtime(f) || f.pos == null || !isStd(f.pos.pfile)) continue;
			var h = fps.get(e.symbol(f));
			if (h == null) continue;
			var fp = new Fingerprint(prep, null);
			fp.func(f);
			if (fp.key() != h) continue;
			var ok = true, cs = [];
			function ex(x:Ex) {
				switch x {
					case EField(c, _, _) | EFieldAddr(c, _, _) | EInstOf(c, _) | ENewObj(c) | EType(TRClass(c)):
						if (!sharedType(c.tindex)) ok = false;
					case EEnumTag(_, en) | EType(TREnum(en)) if (en != null):
						if (!sharedType(en.tindex)) ok = false;
					case EEnumParam(ct, _, _) | ENewEnum(ct, _):
						if (!sharedType(ct.tindex) || !sharedType(ct.en.tindex)) ok = false;
					case ENewAnon(sh, _):
						if (!sharedType(sh.tindex)) ok = false;
					case ECall(g, _):
						cs.push(g);
					case ECallDispatch(sel, _, _):
						if (ownSel.exists(e.selNames[sel])) ok = false;
					case _:
				}
				hxmc.ir.Facts.iterEx(ex, x);
			}
			function st(s:Stmt) {
				switch s {
					case SSetField(c, _, _, _):
						if (!sharedType(c.tindex)) ok = false;
					case STry(_, cats):
						for (c in cats)
							if (c.test != null) ex(c.test(ELocal(c.l)));
					case _:
				}
				hxmc.ir.Facts.iterStmt(st, ex, s);
			}
			for (s in f.body)
				st(s);
			if (!ok) continue;
			cand.set(f, true);
			calls.set(f, cs);
		}
		// (the runtime's functions it calls: the compiler's, unless the program has its own)
		var changed = true;
		while (changed) {
			changed = false;
			for (f => _ in cand)
				for (g in calls.get(f))
					if (hxmc.macro.Guest.runtime(g) ? ownRuntime.exists(g.module) || (bundled.exists(g) && !cand.exists(g)) : !cand.exists(g) && !(prior != null && prior.exists(g))) {
						cand.remove(f);
						changed = true;
						break;
					}
		}
		return cand;
	}

	static var fpsCache:Null<hxmc.macro.SymFile.HostFps> = null;

	// the compiler's functions' fingerprints (<exe>.fps, beside <exe>.syms)
	static function hostFps():hxmc.macro.SymFile.HostFps {
		if (fpsCache != null) return fpsCache;
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		return fpsCache = new hxmc.macro.SymFile.HostFps(hxmc.macro.SymFile.read(exe + ".fps"));
	}

	// which of the std's types stay the compiler's own (Guest.facts: those the
	// compiler has): only those with the compiler's layout, that no new class
	// extends, whose supertypes are shared (an instance test is a type index
	// in a class's span: a new class has no place in the compiler's); a type
	// not shared has its statics and initializer of its own
	public static function unshare(facts:Dynamic, host:hxmc.macro.SymFile.HostSyms, l:hxmc.ir.Lower, e:hxmc.ir.Facts, com:context.Common.CommonContext, ?types:Array<ModuleType>) {
		var types:Array<Dynamic> = facts.types;
		var fids = new Map<String, Int>();
		for (f in (facts.fields : Array<Dynamic>)) {
			var h = host.get(f.sym);
			if (h != null && h.k == "a") fids.set(f.name, h.v);
		}
		var bySym = new Map<String, Dynamic>();
		for (t in types)
			bySym.set(t.sym, t);
		inline function shared(sym:Dynamic):Bool {
			var t = bySym.get(sym);
			return t != null && t.share == true;
		}
		for (t in types) {
			if (t.share != true) continue;
			var h = host.get(t.sym);
			// (one the compiler lacks: new, and so are the classes over it, the classes under it)
			if (h == null || h.k != "a") {
				t.share = false;
				continue;
			}
			var ok = true;
			for (f in (t.fields : Array<Dynamic>))
				if (!fids.exists(f.name)) ok = false;
			if (ok && hxmc.macro.Loader.sameLayout(h.v, t, fids) != null) ok = false;
			if (!ok) t.share = false;
		}
		var changed = true;
		while (changed) {
			changed = false;
			// (a new class implementing a shared interface: the compiler's code
			// dispatches on the interface through rows without the new class)
			// (and a shared class implementing an interface no longer shared: new,
			// its instance tests read the interfaces of its type entry)
			for (t in types)
				if (t.tk == "TK_CLASS")
					for (i in (t.ifaces : Array<Dynamic>)) {
						if (i == null || !bySym.exists(i)) continue;
						if (t.share != true && shared(i)) {
							bySym.get(i).share = false;
							changed = true;
						} else if (t.share == true && !shared(i)) {
							t.share = false;
							changed = true;
						}
					}
			for (t in types) {
				if (t.tk != "TK_CLASS" && t.tk != "TK_INTERFACE" && t.tk != "TK_CTOR") continue;
				var sup:Null<String> = t.sup;
				if (sup == null || sup == "TY_Object" || !bySym.exists(sup)) continue;
				// a new class over a shared one: that one is new too; a shared one over a new one: new
				if (t.share != true && shared(sup)) {
					bySym.get(sup).share = false;
					changed = true;
				} else if (t.share == true && !shared(sup)) {
					t.share = false;
					changed = true;
				}
			}
		}
		// the statics of the types no longer shared
		var own = new Map<String, Bool>();
		for (t in (types != null ? types : com.types))
			switch t {
				case TClassDecl(c):
					var ci = l.classes.get(c);
					if (ci == null || ci.tindex < 0 || hxmc.macro.Guest.runtimeClass(c)) continue;
					var sym = e.typeNames[ci.tindex];
					if (!bySym.exists(sym) || shared(sym)) continue;
					for (cf in c.clOrderedStatics) {
						var g = l.staticVars.get(cf);
						if (g != null) own.set(e.globalNames[g], true);
					}
				case _:
			}
		for (g in (facts.globals : Array<Dynamic>))
			if (own.exists(g.name)) g.share = false;
	}

	// the runtime's argc and argv the program reads (Sys.args): the compiler's
	// path, then the program's arguments
	static function setArgs() {
		var all = [Sys.programPath()].concat(args);
		var a = LibC.malloc(((all.length + 1) * 8 : I64));
		for (i in 0...all.length) {
			var bs = haxe.io.Bytes.ofString(all[i]);
			var s = LibC.malloc(((bs.length + 1) : I64));
			for (k in 0...bs.length)
				Mem.setI8(s, k, bs.get(k));
			Mem.setI8(s, bs.length, 0);
			Mem.setPtr(a, 8 * i, s);
		}
		Mem.setPtr(a, 8 * all.length, Ptr.nil());
		hxmc.rt.Start.argc = all.length;
		hxmc.rt.Start.argv = a;
	}
}
#end
