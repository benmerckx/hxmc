package hxmc.wasmgc;

import hxmc.ir.Ir;
import hxmc.Mir;

// -D hxmc.wasm-gc: the program's IR (after Lower) as a WasmGC module, an
// experiment to compare with the linear-memory target (docs/plans/targets.md,
// "WasmGC"). What is emitted is what the program-wide reachability keeps
// (hxmc.ir.Reach, as for linear memory: method-level, by name), the runtime's
// exports where this target's code calls them (runtimeCalls).
class GcGen {
	// the functions by their symbol in the Mir (MirBuild.gcSymOf: Uses)
	public static var funcBySym:Map<String, FuncInfo>;

	// HXMC_GC_SURVEY=1: what is emitted, then what the module would lack (each
	// unsupported construct, the functions with it); =2: also the module
	// written, those functions trapping (to measure the rest)
	public static function run(prog:Program, out:String, o:Options) {
		// (twice: then over the bodies as optimized, without what was inlined everywhere: Uses.summary)
		var calls:hxmc.ir.Reach.RuntimeCalls = {
			ex: runtimeCalls,
			stmt: s -> switch s {
				case SAnonSet(_): "gc_anon_set";
				// (null tested: FuncGen.derefAs, Helpers' array paths)
				case SSetField(_) | SArrSet(_) | SArrPush(_) if (hxmc.ir.Lower.nullChecks): "rt_null_access";
				case _: null;
			}
		};
		hxmc.ir.Reach.run(prog, o.stats, calls);
		var t0 = haxe.Timer.stamp();
		var u = new Uses(prog, o.opt, o.jobs > 0 ? o.jobs : hxmc.Driver.domains());
		var t1 = haxe.Timer.stamp();
		hxmc.ir.Reach.run(prog, o.stats, calls, u.summary);
		u.scan();
		if (o.stats) {
			var t2 = haxe.Timer.stamp();
			Sys.println('hxmc: wasm-gc Mir ${Std.int((t1 - t0) * 1000)} ms, reach and uses ${Std.int((t2 - t1) * 1000)} ms, ${u.sitesReplaced} allocation sites replaced, ${u.devirtualized} virtual calls made direct, ${Lambda.count(u.unbuilt)} functions not built');
			for (f => why in u.unbuilt)
				Sys.println('  ${f.name}: $why');
		}
		var survey = Sys.getEnv("HXMC_GC_SURVEY");
		if (survey != "1" && survey != "2") {
			var t3 = haxe.Timer.stamp();
			sys.io.File.saveBytes(out, new GcModule(prog, u, !o.strip).build());
			if (o.stats) Sys.println("hxmc: wasm-gc module " + Std.int((haxe.Timer.stamp() - t3) * 1000) + " ms");
			return;
		}
		u.report();
		GcModule.survey = new Map();
		var bytes = try new GcModule(prog, u, !o.strip).build() catch (e:Dynamic) {
			GcModule.note(Std.string(e), "(the module)");
			null;
		}
		var ks = [for (k in GcModule.survey.keys()) k];
		ks.sort(Reflect.compare);
		Sys.println('unsupported (${ks.length}):');
		for (k in ks) {
			var fs = GcModule.survey.get(k);
			Sys.println('  $k: ${fs.length} (${fs.slice(0, 4).join(", ")}${fs.length > 4 ? ", ..." : ""})');
		}
		if (survey == "2" && bytes != null) sys.io.File.saveBytes(out, bytes);
	}

	// the runtime's exports this target's code calls for an expression
	// (FuncGen: structural access it does not know the layout of, enum
	// comparisons, NativeArray's error and slow path, type tests)
	static function runtimeCalls(e:Ex):Null<String>
		return switch e {
			case EAnonGet(_): "gc_anon_get";
			case ECallAnon(_): "gc_anon_call";
			case ECallHost("hxmc_rt_gc_W_enumEq", _, _): "gc_dyn_eq";
			case ECallHost("hxmc_narray_new", _, _): "hx_narray_bad_length";
			case ECallHost("hxmc_narray_dset", _, _): "hx_narray_set_slow";
			// (a type known at run time only, an Int: FuncGen.typeTest)
			case ECallHost("Std_isOfType" | "Std_is" | "hx_is" | "Std_downcast" | "hx_cast", args, _):
				switch args[1] {
					case EType(TRBuiltin("Int")): "gc_is_int";
					case EType(_): null;
					case _: "gc_is";
				}
			// (a reference tested against null before it is dereferenced: FuncGen.derefAs,
			// Helpers' array paths)
			case EField(_) | EEnumTag(_) | EEnumParam(_) | EArrLen(_) | EArrGet(_) | EArrGetU(_) | ECallDispatch(_) | ECallClos(_)
				| ECallHost("String_length" | "String_charCodeAt_i" | "hxmc_narray_length", _, _) if (hxmc.ir.Lower.nullChecks):
				"rt_null_access";
			case ECallHost(n, _, _) if (hxmc.ir.Lower.nullChecks && (StringTools.startsWith(n, "hxmc_narray_get_") || StringTools.startsWith(n, "hxmc_narray_set_"))):
				"rt_null_access";
			case _: null;
		}
}

// What the emitted functions use: each one's object-level Mir as emitted
// (MirBuild, inlined, its allocations replaced, optimized: wasmgc.MirGen
// emits it), the host functions it calls, the classes it makes (or has the
// class value of), the selectors it dispatches on, the closures and
// anonymous structures it makes
class Uses {
	public final prog:Program;
	public final funcs:Array<FuncInfo> = [];
	public final hosts = new Map<String, Int>();
	public final sels = new Map<Int, Bool>();
	public final classes = new Map<ClassInfo, Bool>();
	public final lambdas = new Map<LambdaInfo, Bool>();
	public final shapes = new Map<ShapeInfo, Bool>();
	public final mirs = new Map<FuncInfo, MFunc>();
	// the functions MirBuild does not take, with why (the IR walker writes them: FuncGen)
	public final unbuilt = new Map<FuncInfo, String>();
	public var sitesReplaced = 0; // (Escape)
	public var devirtualized = 0; // (Inline.devirtualize)
	final cands = new Map<FuncInfo, Bool>(); // (the functions that may be inlined: Inline.candidate)
	final inlined = new Map<FuncInfo, Map<FuncInfo, Bool>>(); // (each function's: the callees inlined into it, to any depth)
	final summaries = new Map<FuncInfo, haxe.ds.Vector<Stmt>>();
	// the program works on linear memory (hxmc.unsafe, C functions: GcModule.memory)
	public var memory = false;
	// the class of dates, the runtime's hxmc.rt.gc.GcDate (GcRepr.dateOf): Date's
	// (TRBuiltin("Date"): its class value, GcModule.typeValue, and type tests,
	// FuncGen.typeTest); null when nothing lowered names it (no date can exist)
	public final dateClass:Null<ClassInfo>;

	public function new(prog:Program, optimize:Bool, jobs:Int) {
		this.prog = prog;
		dateClass = Lambda.find(prog.classes, c -> c.name == "hxmc.rt.gc.GcDate");
		// the functions by symbol (MirBuild's calls name their callee: MirGen)
		var syms = new haxe.ds.ObjectMap<FuncInfo, String>();
		var bySym = new Map<String, FuncInfo>();
		for (k in 0...prog.funcs.length) {
			var s = "f" + k;
			syms.set(prog.funcs[k], s);
			bySym.set(s, prog.funcs[k]);
		}
		GcGen.funcBySym = bySym;
		MirBuild.gcSymOf = g -> {
			var s = syms.get(g);
			s != null ? s : "?" + g.name;
		};
		if (optimize)
			for (f in prog.funcs)
				if (Inline.candidate(f)) cands.set(f, true);
		MirBuild.inlineCands = optimize ? cands : null;
		var abi = Abi.get("wasm32-wasi");
		var dump = Sys.getEnv("HXMC_GC_DUMP"); // (a function's Mir, by its name)
		var inl = new haxe.ds.Vector<Map<FuncInfo, Bool>>(prog.funcs.length);
		var bisect = Sys.getEnv("HXMC_GC_BISECT") == null ? [0, 1 << 30] : [for (x in Sys.getEnv("HXMC_GC_BISECT").split(",")) Std.parseInt(x)];
		// (each function's on its own, on threads: the callees' templates shared)
		var templates = new haxe.ds.ObjectMap<FuncInfo, {t:Null<Inline.Template>}>();
		var tlock = new sys.thread.Mutex();
		function template(fn:FuncInfo):Null<Inline.Template> {
			tlock.acquire();
			var e = templates.get(fn);
			tlock.release();
			if (e != null) return e.t;
			var cb = new MirBuild(null, abi, fn);
			cb.gc = true;
			// (judged on the size of its lowering as natively, Inline.size, but kept
			// when what MirGen makes of it fits the loop limit: rounds' objectsMeet)
			var t:Null<Inline.Template> = try {
				var tm = cb.objects();
				var n = Inline.size(tm);
				n >= 0 && Inline.size(tm, true) <= Inline.MAX_LOOP ? {mf: tm, sites: cb.inlineSites, size: n} : null;
			} catch (_:MirBuild.Unsupported) null;
			tlock.acquire();
			var e2 = templates.get(fn);
			if (e2 == null) templates.set(fn, {t: t}) else t = e2.t;
			tlock.release();
			return t;
		}
		function build(fn:FuncInfo, k:Int):MFunc {
			var mb = new MirBuild(null, abi, fn);
			mb.gc = true;
			var mf = mb.objects();
			if (!optimize) return mf;
			var into = new Map<FuncInfo, Bool>();
			// (to a depth; a call left out for its size is looked at again in the
			// next round, when what an inlined callee made may now meet it:
			// Inline.objectsMeet)
			function rounds(todo:Array<{call:MIns, fn:FuncInfo}>) {
				for (_ in 0...Inline.DEPTH) {
					if (todo.length == 0) break;
					var sites = [];
					var left = [];
					var inLoop = Inline.loopBlocks(mf);
					for (s in todo) {
						var t = template(s.fn);
						if (t == null || s.fn == fn || s.call.dead || s.call.op != Call) continue;
						if (t.size <= Inline.maxSize(true, s.call.block.mark == inLoop, StringTools.startsWith(s.fn.module, "hxmc.rt."))
							|| s.call.block.mark == inLoop && Inline.objectsMeet(mf, s.call, t) && Inline.size(t.mf, true) <= Inline.MAX_LOOP) {
							sites.push({call: s.call, callee: t});
							into.set(s.fn, true);
						} else if (s.call.block.mark == inLoop) left.push(s);
					}
					todo = Inline.run(mf, sites).concat(left);
				}
			}
			rounds(mb.inlineSites);
			if (Escape.on && mf.allocs > 0 && Escape.part("closures"))
				rounds(Escape.closureCalls(mf, g -> g.module == fn.module && cands.exists(g), MirBuild.gcSymOf));
			if (Inline.devirtOn && mf.allocs > 0) {
				var d = Inline.devirtualize(mf, fn.module, prog.selectors, MirBuild.gcSymOf);
				if (d.length > 0) {
					tlock.acquire();
					devirtualized += d.length;
					tlock.release();
					rounds([for (s in d) if (cands.exists(s.fn)) s]);
				}
			}
			if (Escape.on) {
				var es = new Escape(mf);
				es.run();
				if (es.removed > 0) {
					tlock.acquire();
					sitesReplaced += es.removed;
					tlock.release();
				}
			}
			inl[k] = into;
			if (dump != null && (dump == fn.name || dump == "#" + k || fn.display != null && fn.display == dump)) Sys.println(fn.name + " before Opt:\n" + mf.dump());
			if (k >= bisect[0] && k < bisect[1]) new Opt(mf).run();
			if (dump != null && (dump == fn.name || dump == "#" + k || fn.display != null && fn.display == dump)) Sys.println(mf.dump());
			return mf;
		}
		var fs = prog.funcs;
		var out = new haxe.ds.Vector<MFunc>(fs.length);
		var next = 0, failure:Null<String> = null;
		var lock = new sys.thread.Mutex();
		function work() {
			while (true) {
				lock.acquire();
				var k = next;
				next += 16;
				lock.release();
				if (k >= fs.length || failure != null) return;
				var end = k + 16 < fs.length ? k + 16 : fs.length;
				for (i in k...end)
					try {
						out[i] = build(fs[i], i);
					} catch (e:MirBuild.Unsupported) {
						// (what MirBuild does not take: the function traps, GcModule.survey)
						out[i] = null;
						lock.acquire();
						unbuilt.set(fs[i], e.msg);
						lock.release();
					} catch (e:Dynamic) {
						lock.acquire();
						if (failure == null) failure = fs[i].name + ": " + Std.string(e) + haxe.CallStack.toString(haxe.CallStack.exceptionStack());
						lock.release();
						return;
					}
			}
		}
		if (jobs > fs.length >> 4) jobs = (fs.length >> 4) + 1;
		if (jobs <= 1) work() else {
			var done = new sys.thread.Lock();
			for (_ in 0...jobs)
				sys.thread.Thread.create(() -> {
					work();
					done.release();
				});
			for (_ in 0...jobs)
				done.wait();
		}
		if (failure != null) throw failure;
		for (i in 0...fs.length)
			if (out[i] != null) {
				mirs.set(fs[i], out[i]);
				if (inl[i] != null) inlined.set(fs[i], inl[i]);
			}
	}

	// What Reach's second pass reads of f (Reach.bodyOf): its IR, flattened,
	// each call of a callee inlined into it (Uses.inlined) followed by the
	// callee's body, its parameters replaced by the arguments (so that the
	// names passed to lookups are still seen: Reach.findSinks), a call its Mir
	// no longer makes dropped; what the Mir dropped otherwise stays, which
	// keeps more than needed, never less
	public function summary(f:FuncInfo):haxe.ds.Vector<Stmt> {
		var mf = mirs.get(f);
		if (mf == null) return f.body;
		var done = summaries.get(f);
		if (done != null) return done;
		var called = new Map<String, Bool>();
		for (b in mf.blocks)
			for (i in b.ins)
				if (!i.dead && i.op == Call && i.sym != null) called.set(i.sym, true);
		var into = inlined.get(f);
		var out:Array<Stmt> = [];
		var open:Array<FuncInfo> = [f];
		function flatten(body:haxe.ds.Vector<Stmt>, subst:Null<Map<Local, Ex>>) {
			function ex(e:Ex):Ex {
				switch e {
					case ELocal(l) if (subst != null && subst.exists(l)):
						return subst.get(l);
					case ECall(g, args):
						var xs = args.map(ex);
						if (into != null && into.exists(g) && open.indexOf(g) < 0) {
							var m = new Map<Local, Ex>();
							for (k in 0...g.args.length)
								if (k < xs.length) m.set(g.args[k], xs[k]);
							open.push(g);
							flatten(g.body, m);
							open.pop();
						}
						return called.exists(MirBuild.gcSymOf(g)) ? ECall(g, xs) : ECallHost("hxmc_gc_inlined", xs, g.ret);
					// (a method called on an object made here, inlined: Inline.devirtualize)
					case ECallDispatch(sel, s, args) if (into != null):
						var xs = args.map(ex);
						for (g in into.keys())
							if (g.dispatchSel == sel && open.indexOf(g) < 0) {
								var m = new Map<Local, Ex>();
								for (k in 0...g.args.length)
									if (k < xs.length) m.set(g.args[k], xs[k]);
								open.push(g);
								flatten(g.body, m);
								open.pop();
							}
						return ECallDispatch(sel, s, xs);
					// (a closure called where it is made, inlined there: Escape.closureCalls)
					case ENewClos(l, _) if (into != null && into.exists(l.fn) && open.indexOf(l.fn) < 0):
						open.push(l.fn);
						flatten(l.fn.body, null);
						open.pop();
						return hxmc.ir.Facts.mapEx(ex, e);
					case _:
						return hxmc.ir.Facts.mapEx(ex, e);
				}
			}
			function st(s:Stmt) {
				switch s {
					case SSet(l, e): out.push(SSet(l, ex(e)));
					case SExpr(e) | SReturn(e) if (e != null): out.push(SExpr(ex(e)));
					case SReturn(_) | SBreak | SContinue | SPos(_):
					case SThrow(e): out.push(SThrow(ex(e)));
					case SSetGlobal(g, e): out.push(SSetGlobal(g, ex(e)));
					case SSetField(c, idx, o, v): out.push(SSetField(c, idx, ex(o), ex(v)));
					case SAnonSet(n, t, o, v): out.push(SAnonSet(n, t, ex(o), ex(v)));
					case SBoxSet(t, o, v): out.push(SBoxSet(t, ex(o), ex(v)));
					case SArrSet(t, a, i, v): out.push(SArrSet(t, a, ex(i), ex(v)));
					case SArrPush(t, a, v): out.push(SArrPush(t, a, ex(v)));
					case SIf(EInt(c), a, b): // (MirBuild builds the branch taken only)
						for (x in (c != 0 ? a : b))
							st(x);
					case SIf(c, a, b):
						out.push(SExpr(ex(c)));
						for (x in a)
							st(x);
						for (x in b)
							st(x);
					case SLoop(body):
						for (x in body)
							st(x);
					case SCold(_, x):
						st(x);
					case SSwitch(e, cases, def):
						out.push(SExpr(ex(e)));
						for (c in cases)
							for (x in c.body)
								st(x);
						for (x in def)
							st(x);
					case STry(body, catches):
						for (x in body)
							st(x);
						for (c in catches) {
							out.push(SSet(c.l, ENull(c.l.ty)));
							if (c.test != null) out.push(SExpr(ex(c.test(ELocal(c.l)))));
							for (x in c.body)
								st(x);
						}
					case SExpr(_):
				}
			}
			for (s in body)
				st(s);
		}
		flatten(f.body, null);
		var r = haxe.ds.Vector.fromArrayCopy(out);
		summaries.set(f, r);
		return r;
	}

	// (the functions the program keeps: what they use)
	public function scan() {
		for (f in prog.funcs) {
			funcs.push(f);
			var mf = mirs.get(f);
			if (mf == null) {
				for (s in f.body)
					stmt(s);
				continue;
			}
			for (b in mf.blocks)
				for (i in b.ins) {
					if (i.dead) continue;
					var o = i.info;
					switch i.op {
						case IrNode:
							if (o.ex != null) ex(o.ex) else stmt(o.stmt);
						case VirtualCall:
							sels.set(o.sel, true);
						case New:
							if (o.cls != null) cls(o.cls);
							if (o.shape != null) shapes.set(o.shape, true);
							if (o.lambda != null) lambdas.set(o.lambda, true);
						case _:
					}
				}
		}
		// (the classes Type.createInstance makes: Meta.createInstance)
		for (c in prog.classes)
			if (c.maker != null && c.maker.fn != null) cls(c);
	}

	function cls(c:ClassInfo) {
		var k = c;
		while (k != null && !classes.exists(k)) {
			classes.set(k, true);
			// (the statics reached through the class value whose closures Reach
			// kept: Meta.staticGet)
			if (k.statics != null)
				for (s in k.statics)
					if (s.clos != null && (prog.live == null || prog.live.exists(s.clos.fn))) lambdas.set(s.clos, true);
			k = k.sup;
		}
	}

	function stmt(s:Stmt)
		hxmc.ir.Facts.iterStmt(stmt, ex, s);

	function ex(e:Ex) {
		switch e {
			case ECallDispatch(sel, _, _): sels.set(sel, true);
			case ECallHost(n, args, _):
				hosts.set(n, (hosts.exists(n) ? hosts.get(n) : 0) + 1);
				if (StringTools.startsWith(n, "hxmc_unsafe_Mem_") || n == "hxmc_rt_gc_W_memToBytes" || n == "hxmc_rt_gc_W_bytesToMem"
					|| hxmc.ir.CInterop.SIGS.exists(n)) memory = true;
				if (n == "Type_createEmptyInstance") switch args[0] {
					case EType(TRClass(c)): cls(c);
					case _:
				}
			case ENewObj(c): cls(c);
			case ENewAnon(s, _): shapes.set(s, true);
			case EType(TRClass(c)) if (!c.isInterface): cls(c);
			case EType(TRBuiltin("Date")) if (dateClass != null): cls(dateClass);
			case ENewClos(l, _): lambdas.set(l, true);
			case _:
		}
		hxmc.ir.Facts.iterEx(ex, e);
	}

	public function report() {
		Sys.println('wasm-gc survey: ${funcs.length} functions, ${Lambda.count(classes)} classes, ${Lambda.count(sels)} selectors, ${Lambda.count(lambdas)} closures');
		var mods = new Map<String, Int>();
		for (f in funcs)
			mods.set(f.module, (mods.exists(f.module) ? mods.get(f.module) : 0) + 1);
		var ms = [for (k in mods.keys()) k];
		ms.sort(Reflect.compare);
		for (m in ms)
			Sys.println('  module $m: ${mods.get(m)}');
		var hs = [for (k in hosts.keys()) k];
		hs.sort(Reflect.compare);
		Sys.println('host calls (${hs.length}):');
		for (h in hs)
			Sys.println('  $h ${hosts.get(h)}');
	}
}
