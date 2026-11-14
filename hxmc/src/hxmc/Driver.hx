package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.Abi;
import hxmc.MirBuild.Unsupported;

// One run of the tool. Functions are compiled per Haxe module (the unit of
// the object cache): each module becomes an object of its own, cached under
// a key hashing its Fingerprint (with the tool and the target) in the store
// (CacheStore: shared by every output; else in <out>.hxmc/), so a rebuild
// after an edit compiles only the modules whose code can change. The program's data (DataGen) is regenerated every time, and
// everything is linked with the runtime object (Link).
class Driver {
	var prep:Prep;
	var abi:Abi;
	var o:Options;
	var out:String;
	var dumpSet:Null<Map<String, Bool>>;
	// -D hxmc.interp: the functions interpreted (hxmc.interp.InterpGen)
	var interp:Null<hxmc.interp.InterpGen.InterpSet>;
	var tm = new haxe.ds.Vector<Float>(4); // cpu seconds: mir, isel, regalloc, emit
	var slow:Array<{name:String, t:Float}> = [];

	function new(prog:Program, out:String, o:Options) {
		this.o = o;
		this.out = o.output != null ? o.output : out;
		prep = new Prep(prog);
		abi = Abi.get(o.target);
		abi.setLibc(o.libc);
		abi.framePointers = !abi.wasm && (abi.arm || o.framePointers);
		if (o.shared && (abi.os == "macos" || abi.os == "windows")) {
			// (macOS and iOS: a Mach-O dylib, LinkMachO; Windows: a DLL, LinkPE; the code is position-independent already)
			abi.output = SharedLibrary;
		} else if (o.shared && !abi.android) {
			// (Linux in the dynamic glibc mode: the C library's imports; Android always is one)
			if (abi.interp == null) throw "hxmc: -D hxmc.shared: a shared library is written for Linux in the dynamic glibc mode (-D hxmc.libc=glibc) and Android";
			abi.reloc = Pic;
			abi.output = SharedLibrary;
			abi.tls = Desc;
		}
		for (e in o.exports)
			if (abi.exports.indexOf(e) < 0) abi.exports.push(e);
		dumpSet = o.dump == null ? null : [for (n in o.dump.split(",")) n => true];
		if (o.interp != null) interp = new hxmc.interp.InterpGen.InterpSet(o.interp, prep);
	}

	// (a Mir host, Options.mirHost: every function stays, for the code it
	// loads, which calls the std's and the runtime's functions it has; and no
	// closure is made static, Prep.staticClosures, which costs a Mir host more
	// than it saves: measured, docs/plans/compiler.md, "Mir macros")
	public static function run(prog:Program, out:String, o:Options) {
		var t0 = haxe.Timer.stamp();
		if (!o.mirHost) hxmc.ir.Reach.run(prog, o.stats);
		// (a Mir host keeps every function, and the table of its functions and
		// lines: the stacks of the code it loads go through its frames,
		// hxmc.rt.Stacks; its own throws record none, StackTable.flags)
		else prog.stacks = hxmc.ir.Lower.lines;
		var d = new Driver(prog, out, o);
		d.prep.staticClosures = !o.mirHost;
		var t1 = haxe.Timer.stamp();
		try d.build(t0, t1) catch (e:Dynamic) {
			release();
			throw e;
		}
		release();
	}

	// what a build set for its code generation and no later build reads (a
	// resident compiler would keep the program's functions with it until the
	// next build: MirBuild.inlineCands, 21 MB of helder's ts-todo)
	static function release() {
		MirBuild.inlineCands = null;
		Escape.refSlots = null;
	}

	// ---- compiling

	// guards what workers share: the queue and the statistics
	var lock = new sys.thread.Mutex();

	// runs work(0...n) on up to `jobs` threads (the first failure is rethrown)
	function parallel(n:Int, jobs:Int, work:Int->Void) {
		var next = 0;
		var failure:Null<String> = null;
		function run() {
			while (true) {
				lock.acquire();
				var k = next++;
				lock.release();
				if (k >= n || failure != null) return;
				try work(k) catch (e:Dynamic) {
					lock.acquire();
					if (failure == null) failure = Std.string(e);
					lock.release();
					return;
				}
			}
		}
		if (jobs > n) jobs = n;
		if (jobs <= 1) run() else {
			var done = new sys.thread.Lock();
			for (_ in 0...jobs)
				sys.thread.Thread.create(() -> {
					run();
					done.release();
				});
			for (_ in 0...jobs)
				done.wait();
		}
		if (failure != null) throw failure;
	}
	var raRounds = 0;
	var escRemoved = 0;
	var escFolds = 0;
	var loopsVersioned = 0; // (LoopVersion)
	var allocsFolded = 0; // (Fold)
	var rootStores = 0; // (Frames)
	var freshStores = 0; // (Opt.freshTargets)
	var framesRemoved = 0;
	var mirBefore = 0;
	var mirAfter = 0;
	var devirtualized = 0; // (Inline.devirtualize)
	var escTime = 0.0;
	var escSlow:Array<{name:String, t:Float}> = [];
	var raInsns = 0;
	var raFuncs = 0;

	// the Mir of the callees inlined, built once (shared by the threads: read only once made)
	var templates = new haxe.ds.ObjectMap<FuncInfo, {t:Null<Inline.Template>}>();
	var once = new Map<FuncInfo, FuncInfo>(); // (Inline.once: a kernel, its one caller)
	var tlock = new sys.thread.Mutex();

	// (experimental) LLVM: the module's functions LlvmGen takes, per module
	var llvmFuncs = 0;
	var llvmWhy = new Map<String, Int>();

	var llvmPending:Array<LlvmGen> = [];
	var llvmWhole:Null<LlvmGen> = null;

	// LLVM's code compiled after the data (the program-wide numbers known, or
	// the whole program as one LLVM module): not in the module objects
	inline function llvmDeferred():Bool
		return o.llvm != null && (o.llvmWhole || o.llvmConsts);

	function llvmFor(module:String):Null<LlvmGen> {
		if (o.llvm == null || abi.wasm || interp != null) return null;
		if (!o.llvmRt && StringTools.startsWith(module, "hxmc.rt.")) return null;
		if (o.llvmWhole) {
			lock.acquire();
			if (llvmWhole == null) {
				var g = newLlvm("program");
				g.shared = true;
				llvmWhole = g;
			}
			lock.release();
			return llvmWhole;
		}
		return newLlvm(module);
	}

	function newLlvm(module:String):LlvmGen {
		if (LlvmGen.triple(abi) == null) throw "hxmc: -D hxmc.llvm: no LLVM triple for " + abi.name;
		var dir = out + ".hxmc/llvm";
		lock.acquire();
		if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
		lock.release();
		var g = new LlvmGen(abi, o.llvm, o.llvmClang, module, dir, o.llvmCpu);
		g.tbaa = o.llvmTbaa;
		g.flags = o.llvmFlags;
		g.pgo = o.llvmPgo;
		g.lines = hxmc.ir.Lower.lines;
		g.keepFrames = prep.p.stacks && !o.llvmInline;
		return g;
	}

	function template(fn:FuncInfo):Null<Inline.Template> {
		tlock.acquire();
		var e = templates.get(fn);
		tlock.release();
		if (e != null) return e.t;
		// (object-level Mir, judged on the size of its lowering: Inline.size)
		var cb = new MirBuild(prep, abi, fn);
		cb.icSym = prep.funcSym(fn) + "__ic";
		var t = try Inline.template(cb, cb.objects(), once.exists(fn)) catch (_:Unsupported) null;
		tlock.acquire();
		var e2 = templates.get(fn);
		if (e2 == null) templates.set(fn, {t: t}) else t = e2.t;
		tlock.release();
		return t;
	}

	// one function into `obj` (with its emitter)
	function compileFunc(fn:FuncInfo, obj:Obj, emit:Target.Emitter, ras:Regalloc.Scratch, ?llvm:LlvmGen) {
		var name = prep.funcSym(fn);
		try {
			var s0 = haxe.Timer.stamp();
			var mb = new MirBuild(prep, abi, fn);
			mb.icSym = name + "__ic";
			// object-level Mir: inlined, its allocations replaced (Escape), then
			// lowered (MemLower) for the memory-level passes and the back ends
			var mf = mb.objects();
			if (o.opt) {
				// to a depth (Fingerprint keys callers with their callees' callees);
				// (fn and the kernels called once inlined into it: each is in mf
				// once, and so is each one's single call of a kernel called once)
				// (a view's functions a round more: they stand for the inline
				// accessors the kernel calling them had, Fingerprint)
				var here = [fn => true];
				function rounds(todo:Array<{call:MIns, fn:FuncInfo}>) {
					for (r in 0...Inline.DEPTH + 1) {
						if (todo.length == 0) break;
						var sites = [];
						var inLoop = Inline.loopBlocks(mf);
						for (s in todo) {
							if (r == Inline.DEPTH && !s.fn.view) continue;
							var t = template(s.fn);
							// (a kernel of the runtime as any function, and a view's function
							// (StrView) as at a call in a loop: what the runtime's code read
							// inline before it reads through one; a kernel called once at
							// its call, Inline.once)
							var rt = StringTools.startsWith(s.fn.module, "hxmc.rt.") && !s.fn.declKernel;
							var max = Inline.maxSize(abi.wasm, s.call.block.mark == inLoop || s.fn.view, rt);
							var caller = once.get(s.fn), one = caller != null && here.exists(caller);
							if (one && max < Inline.MAX_ONCE) max = Inline.MAX_ONCE;
							if (t != null && s.fn != fn && t.size <= max) {
								sites.push({call: s.call, callee: t});
								if (one) here.set(s.fn, true);
							}
						}
						todo = Inline.run(mf, sites);
					}
				}
				rounds(mb.inlineSites);
				// closures called where they are made: the call goes to their
				// function, inlined when it may be and is of this module (its
				// body and its callees' are in the module's key), so that
				// Escape may replace the closure (not for code loaded at run time
				// compiled to native code, interp.Tier: the closure's frame
				// stays in stacks, as when interpreted)
				if ((interp == null || (!interp.wants(fn) && interp.nativeNow != fn)) && mf.allocs > 0) {
					var todo = [];
					for (c in Escape.closureCalls(mf, g -> g.module == fn.module && MirBuild.inlineCands.exists(g), prep.funcSym))
						todo.push(c);
					rounds(todo);
				}
				// virtual calls on objects made here: direct, then inlined where they may be
				if (mf.allocs > 0) {
					var d = Inline.devirtualize(mf, fn.module, prep.p.selectors, prep.funcSym);
					if (d.length > 0) {
						lock.acquire();
						devirtualized += d.length;
						lock.release();
						rounds([for (s in d) if (MirBuild.inlineCands.exists(s.fn)) s]);
					}
				}
			}
			// (not for the interpreter: no gain there, measured on the macro benchmarks, and a third of the passes' time)
			if (o.opt && (interp == null || !interp.wants(fn))) {
				var es = new Escape(mf);
				var te = haxe.Timer.stamp();
				es.run();
				te = haxe.Timer.stamp() - te;
				lock.acquire();
				escRemoved += es.removed;
				escFolds += es.folds;
				escTime += te;
				if (o.stats && te > 0.005) escSlow.push({name: name + " (" + mf.vals.length + " values)", t: te});
				lock.release();
			}
			// the optimizer on object-level Mir (struct values in frame slots
			// replaced first), then the frame's slots nothing reads; after the
			// lowering only allocation folding, the CFG's cleanup and
			// dead code
			if (o.opt) new Sroa(mf).run();
			// (Array reads in counted loops tested once before them)
			if (o.opt && (interp == null || !interp.wants(fn))) {
				var lv = new LoopVersion(mf);
				lv.run();
				if (lv.versioned > 0) {
					lock.acquire();
					loopsVersioned += lv.versioned;
					lock.release();
				}
			}
			if (o.opt) {
				var op = new Opt(mf);
				op.run();
				// (slots whose address the optimizer made one again, as a phi of
				// the slots of a branch it decided: promoted, and optimized again)
				var s2 = new Sroa(mf);
				s2.run();
				if (s2.promoted > 0) {
					op = new Opt(mf);
					op.run();
				}
				// (the rooted locals' slots nothing reads any more)
				var fs = new Frames(mf);
				fs.run();
				if (fs.storesRemoved > 0 || fs.frameRemoved || op.freshStores > 0) {
					lock.acquire();
					freshStores += op.freshStores;
					rootStores += fs.storesRemoved;
					if (fs.frameRemoved) framesRemoved++;
					lock.release();
				}
			}
			mb.lower();
			if (o.opt && mf.allocs > 1) {
				var fo = new Fold(mf);
				fo.run();
				if (fo.folded > 0) {
					lock.acquire();
					allocsFolded += fo.folded;
					lock.release();
				}
			}
			// divisions by constants multiplied (not interpreted: one instruction there)
			if (o.opt && (interp == null || !interp.wants(fn))) DivConst.run(mf);
			if (o.opt) Opt.lowered(mf);
			var before = mf.vals.length;
			mf.compact();
			if (o.stats) {
				lock.acquire();
				mirBefore += before;
				mirAfter += mf.vals.length;
				lock.release();
			}
			if (dumpSet != null && dumpSet.exists(name)) Sys.println(mf.dump());
			if (interp != null && interp.wants(fn)) {
				var g = new hxmc.interp.InterpGen(prep, abi, obj, mf, interp, (m, global) -> compileStub(m, emit, global));
				g.display = fn.display;
				g.run();
				if (mb.icaches > 0) {
					var bss = obj.section(".bss", Bss, 16);
					bss.bssSize = (bss.bssSize + 15) & ~15;
					obj.define(mb.icSym, bss, bss.bssSize, Abi.IC_SIZE * mb.icaches, false);
					bss.bssSize += Abi.IC_SIZE * mb.icaches;
				}
				return;
			}
			// (experimental) LLVM: the function as LLVM IR, compiled with the module (LlvmGen)
			if (llvm != null) {
				var why = llvm.accepts(mf);
				if (why == null) {
					llvm.func(mf, hxmc.ir.Lower.lines ? (fn.display != null ? fn.display : name) : null);
					if (mb.icaches > 0) {
						var bss = obj.section(".bss", Bss, 16);
						bss.bssSize = (bss.bssSize + 15) & ~15;
						obj.define(mb.icSym, bss, bss.bssSize, Abi.IC_SIZE * mb.icaches, llvmDeferred()); // (global: LLVM's object is another one then)
						bss.bssSize += Abi.IC_SIZE * mb.icaches;
					}
					lock.acquire();
					llvmFuncs++;
					lock.release();
					return;
				}
				lock.acquire();
				llvmWhy.set(why, (llvmWhy.exists(why) ? llvmWhy.get(why) : 0) + 1);
				lock.release();
			}
			if (abi.wasm) {
				// WebAssembly: structured code from the Mir, no instruction selection or registers
				var s1 = haxe.Timer.stamp();
				new hxmc.wasm.WasmGen(obj, o.wasmLegacyEh).func(mf);
				lock.acquire();
				tm[0] += s1 - s0;
				tm[3] += haxe.Timer.stamp() - s1;
				raFuncs++;
				lock.release();
				if (mb.icaches > 0) {
					var bss = obj.section(".bss", Bss, 16);
					bss.bssSize = (bss.bssSize + 15) & ~15;
					obj.define(mb.icSym, bss, bss.bssSize, Abi.IC_SIZE * mb.icaches, false);
					bss.bssSize += Abi.IC_SIZE * mb.icaches;
				}
				return;
			}
			var layout = Layout.order(mf);
			var s1 = haxe.Timer.stamp();
			var isel = Target.selector(abi);
			var lf = isel.select(mf, layout);
			if (hxmc.ir.Lower.lines) lf.display = fn.display != null ? fn.display : name;
		lf.foreignPasses = fn.foreignPasses;
			var s2 = haxe.Timer.stamp();
			var ra = new Regalloc(lf, isel, ras);
			ra.run();
			var s3 = haxe.Timer.stamp();
			// the runtime's Haxe functions: a section each, dropped by the linker
			// when nothing reaches them (the exported ones are always compiled)
			var rtFunc = StringTools.startsWith(fn.module, "hxmc.rt.");
			if (rtFunc) emit.useSection(LinkCore.GC_PREFIX + name);
			emit.func(lf, ra.usedRegs, true);
			if (rtFunc) emit.useSection(null);
			var s4 = haxe.Timer.stamp();
			lock.acquire();
			tm[0] += s1 - s0;
			tm[1] += s2 - s1;
			tm[2] += s3 - s2;
			tm[3] += s4 - s3;
			raRounds += ra.rounds;
			raInsns += ra.insns;
			raFuncs++;
			if (o.stats && s4 - s0 > 0.05) slow.push({name: name + " (" + mf.vals.length + " values, " + mf.blocks.length + " blocks)", t: s4 - s0});
			lock.release();
			if (mb.icaches > 0) {
				var bss = obj.section(".bss", Bss, 16);
				bss.bssSize = (bss.bssSize + 15) & ~15;
				obj.define(mb.icSym, bss, bss.bssSize, Abi.IC_SIZE * mb.icaches, false);
				bss.bssSize += Abi.IC_SIZE * mb.icaches;
			}
		} catch (e:Unsupported) {
			throw 'hxmc: $name: ${e.msg}';
		}
	}

	// (a Mir host) the program's types by ident, true for the std's (Main: HostTable.idents)
	public static var hostIdents:Null<Map<String, Bool>> = null;

	// each function's fingerprint: code loaded at run time calls this
	// compiler's native function where its own is the same (interp.MirRun),
	// and what callers of its native code need to know of it, which code
	// loaded at run time calls without having its body (HostFps flags,
	// interp.MacroRuntime)
	function hostFingerprints():Array<{sym:String, key:String, flags:Int}> {
		var fps = [];
		for (f in prep.p.funcs) {
			var fp = new Fingerprint(prep, null);
			fp.func(f);
			var flags = (f.noGc ? hxmc.macro.HostTable.HostFps.NO_GC : 0) | (f.blocks ? hxmc.macro.HostTable.HostFps.BLOCKS : 0)
				| (MirBuild.inlineCands != null && MirBuild.inlineCands.exists(f) ? hxmc.macro.HostTable.HostFps.INLINE : 0);
			fps.push({sym: prep.funcSym(f), key: fp.key(), flags: flags});
		}
		return fps;
	}

	// an interpreted function's stub (InterpGen) into its module's object
	function compileStub(mf:MFunc, emit:Target.Emitter, global:Bool) {
		var isel = Target.selector(abi);
		var lf = isel.select(mf, Layout.order(mf));
		var ra = new Regalloc(lf, isel);
		ra.run();
		emit.func(lf, ra.usedRegs, global);
	}

	// a synthetic function (DataGen) for the interpreter, into obj (code loaded
	// at run time: interp.InterpGen.InterpSet.loaded, which has no native code)
	function compileInterp(mf:MFunc, obj:Obj) {
		new hxmc.interp.InterpGen(prep, abi, obj, mf, interp, (_, _) -> throw "hxmc: " + mf.name + ": a stub in code loaded for the interpreter").run();
	}

	// a synthetic function (DataGen) into obj
	function compileMir(mf:MFunc, emit:Target.Emitter, obj:Obj) {
		if (abi.wasm) {
			new hxmc.wasm.WasmGen(obj, o.wasmLegacyEh).func(mf);
			return;
		}
		var isel = Target.selector(abi);
		var lf = isel.select(mf, Layout.order(mf));
		var ra = new Regalloc(lf, isel);
		ra.run();
		emit.func(lf, ra.usedRegs, true);
	}

	function stats(t0:Float, t1:Float, t2:Float) {
		if (!o.stats) return;
		Sys.println('hxmc: ${prep.p.funcs.length} functions');
		Sys.println('hxmc: prepare ${ms(t1 - t0)}, codegen ${ms(t2 - t1)} (cpu: mir ${ms(tm[0])}, isel ${ms(tm[1])}, regalloc ${ms(tm[2])}, emit ${ms(tm[3])})');
		Sys.println('hxmc: regalloc: $raFuncs functions, $raRounds rounds, $raInsns instructions');
		Sys.println('hxmc: MIR value table: $mirBefore -> $mirAfter entries before backends');
		Sys.println('hxmc: escape: $escRemoved allocation sites replaced, $escFolds type tests folded (cpu ${ms(escTime)})');
		Sys.println('hxmc: $allocsFolded allocations folded into the one before them (Fold)');
		Sys.println('hxmc: $loopsVersioned loops versioned (LoopVersion)');
		if (o.llvm != null) Sys.println('hxmc: llvm: $llvmFuncs functions; native: ' + [for (k => v in llvmWhy) '$v ($k)'].join(", "));
		Sys.println('hxmc: frames: $rootStores root stores and $framesRemoved frames removed; $freshStores write barriers of objects just allocated left out; $devirtualized virtual calls made direct');
		escSlow.sort((a, b) -> a.t < b.t ? 1 : -1);
		for (x in escSlow.slice(0, 8))
			Sys.println('  escape ${ms(x.t)}\t${x.name}');
		slow.sort((a, b) -> a.t < b.t ? 1 : -1);
		for (x in slow.slice(0, 5))
			Sys.println('  ${ms(x.t)}\t${x.name}');
	}

	// ---- per-module objects, cache, own linker

	static function moduleFile(m:String):String {
		var r = new StringBuf();
		for (i in 0...m.length) {
			var c = m.charCodeAt(i);
			r.addChar((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == ".".code || c == "_".code ? c : "_".code);
		}
		return r.toString() + ".o";
	}

	// what every key includes: the tool binary (its size and date) and the target
	// the key of an output's entry in the store (by its absolute path)
	public static function outputKey(kind:CacheKind, out:String):CacheKey
		return CacheKey.of(kind, "hxmc-out|" + (try sys.FileSystem.absolutePath(out) catch (_:Dynamic) out));

	// (+pgo=: the LLVM profile's path, time and size: codeKey has only the flag)
	function toolKey():String {
		var p = Sys.programPath();
		var st = try sys.FileSystem.stat(p) catch (_:Dynamic) null;
		return "hxmc|" + abi.rtName + (abi.uikit() ? "+" + abi.platform : "") + (o.wasmLegacyEh ? "+legacy-eh" : "") + (abi.framePointers ? "+fp" : "") + (hxmc.ir.Lower.lines ? "+lines" : "")
			+ (hxmc.ir.Lower.nullChecks != abi.wasm ? "+null-checks=" + (hxmc.ir.Lower.nullChecks ? 1 : 0) : "") + (hxmc.ir.Lower.spanChecks ? "" : "+span-checks=0") + (hxmc.ir.Lower.verifyTags ? "+verify-tags" : "")
			+ (abi.output == SharedLibrary ? "+shared" : "") + (o.interp != null ? "+interp=" + o.interp : "") + (o.mirHost ? "+mirhost" : "") + o.codeKey
			+ (o.llvm != null && o.llvmPgo != null && o.llvmPgo != "gen" ? "+pgo=" + o.llvmPgo + "@" + sys.FileSystem.stat(o.llvmPgo).mtime.getTime() + ":" + sys.FileSystem.stat(o.llvmPgo).size : "") + "|" +(st == null ? "?" : st.size + "@" + st.mtime.getTime()) + "|";
	}

	// the functions that may be inlined (before the keys: they are part of them);
	// with the kernels called once (Inline.once) when the keys are the
	// modules' (not the Mir bundles', a function's each)
	function inlineCandidates(?modules:Bool) {
		if (!o.opt) return;
		once = modules ? Inline.once(prep.p.funcs) : new Map();
		var m = new Map<FuncInfo, Bool>();
		for (f in prep.p.funcs)
			if (Inline.candidate(f, once.exists(f))) m.set(f, true);
		MirBuild.inlineCands = m;
		// (the slots of each type that hold references: Escape keeps a
		// Mem.alloc object's on the shadow stack)
		var refs = new Map<Int, haxe.ds.Vector<Bool>>();
		var types = prep.e.types;
		for (ti in 0...types.length)
			refs.set(ti, core.ds.VectorTools.mapToVector(types[ti].slots, s -> s != null && s.match(TRef(_))));
		Escape.refSlots = refs;
	}

	// the processors (asked once: TaskPool runs getconf, 10-15 ms a build of the resident compiler)
	static var domainCount = 0;

	public static function domains():Int {
		if (domainCount == 0) domainCount = core.ds.TaskPool.recommendedDomainCount();
		return domainCount;
	}

	// resident (the compilation server): the objects of the last builds, by
	// file, with their keys (a build reuses them without reading the cache)
	public static var resident = false;
	static var memObjs = new Map<String, {key:String, obj:Obj}>();

	// the objects kept of the output out (ServerMemory: its group dropped)
	public static function forgetOutput(out:String) {
		var dir = out + ".hxmc/";
		for (k in [for (k in memObjs.keys()) k])
			if (StringTools.startsWith(k, dir)) memObjs.remove(k);
	}

	function build(t0:Float, t1:Float) {
		inlineCandidates(true);
		var p = prep.p;
		// modules in the order of their first function
		var order:Array<String> = [];
		var byModule = new Map<String, Array<FuncInfo>>();
		for (f in p.funcs) {
			var m = f.module == null ? "_" : f.module;
			var fs = byModule.get(m);
			if (fs == null) {
				byModule.set(m, fs = []);
				order.push(m);
			}
			fs.push(f);
		}
		// each module's functions by their symbols, not in the order the
		// lowering reached them: an edit elsewhere that reaches them in
		// another order (helder's markup using a style setter first) leaves
		// the module's key, and its object, as they were
		for (m in order)
			byModule.get(m).sort((a, b) -> {
				var x = prep.funcSym(a), y = prep.funcSym(b);
				x < y ? -1 : x > y ? 1 : 0;
			});
		// the objects: in the store, else next to the output
		var store = CacheStore.open();
		var dir = out + ".hxmc";
		if (store == null && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
		var index = new Map<String, String>();
		var indexPath = dir + "/index";
		if (store == null && sys.FileSystem.exists(indexPath))
			for (l in sys.io.File.getContent(indexPath).split("\n")) {
				var sp = l.indexOf(" ");
				if (sp > 0) index.set(l.substr(0, sp), l.substr(sp + 1));
			}
		var tk = toolKey();
		var hits = 0, misses = 0;
		var tWrite = 0.0;
		var keep = new Map<String, Bool>();
		var jobs = o.jobs > 0 ? o.jobs : domains();
		// the modules' keys, and the cached objects that match, in parallel
		// (the threads only read the program); then, in module order, the
		// string literals they found are registered and the index written
		var nm = order.length;
		var paths = new haxe.ds.Vector<String>(nm);
		for (mi in 0...nm)
			paths[mi] = dir + "/" + moduleFile(order[mi]);
		var memPaths = paths.copy();
		var keys = new haxe.ds.Vector<String>(nm, "");
		var lits = new haxe.ds.Vector<Array<String>>(nm);
		var objs:Array<Obj> = [for (_ in 0...nm) null];
		var compiled = new haxe.ds.Vector<Bool>(nm, false);
		var s0 = haxe.Timer.stamp();
		// (the functions that may be inlined: their digests first, Fingerprint.Inlined)
		var inlined:Null<Fingerprint.Inlined> = null;
		if (MirBuild.inlineCands != null) {
			var cands = MirBuild.inlineCands;
			inlined = new Fingerprint.Inlined(prep, haxe.ds.Vector.fromArrayCopy([for (f in p.funcs) if (cands.exists(f)) f]));
			var d = Fingerprint.Inlined.DEEPEST;
			while (d >= 1) {
				var depth = d;
				parallel(inlined.funcs.length, jobs, k -> if (inlined.at(depth, k)) inlined.compute(depth, k));
				d--;
			}
		}
		parallel(nm, jobs, mi -> {
			var fp = new Fingerprint(prep, inlined);
			fp.text(tk);
			for (f in byModule.get(order[mi]))
				fp.func(f);
			var key = fp.key();
			keys[mi] = key;
			lits[mi] = fp.newStrings;
			var mem = resident ? memObjs.get(memPaths[mi]) : null;
			if (store != null) paths[mi] = store.objectPath(CacheKey.ofHash(ModuleObject, key), moduleFile(order[mi]));
			if (llvmDeferred()) {} // (LLVM's code compiled after the data: not cached)
			else if (mem != null && mem.key == key) objs[mi] = mem.obj;
			else if (!abi.wasm && (store != null || index.get(moduleFile(order[mi])) == key) && sys.FileSystem.exists(paths[mi])) {
				var o = try ElfReader.read(sys.io.File.getBytes(paths[mi])) catch (_:Dynamic) null;
				if (o != null) objs[mi] = o;
			}
		});
		var tKey = haxe.Timer.stamp() - s0;
		var newIndex = new StringBuf();
		var todo:Array<Int> = [];
		for (mi in 0...nm) {
			var l = lits[mi];
			var k = 0;
			while (k < l.length) {
				prep.addStr(l[k], l[k + 1]);
				k += 2;
			}
			var file = moduleFile(order[mi]);
			keep.set(file, true);
			newIndex.add(file + " " + keys[mi] + "\n");
			if (objs[mi] != null) {
				hits++;
			} else {
				todo.push(mi);
				compiled[mi] = true;
				misses++;
			}
		}
		// largest modules first, so the last ones to finish are small
		var weight = new haxe.ds.Vector<Int>(nm);
		for (mi in todo)
			for (f in byModule.get(order[mi]))
				weight[mi] += f.body.length + f.locals.length;
		todo.sort((a, b) -> weight[b] - weight[a]);
		// the register allocator's working storage, taken by a module and given
		// back (at most one per thread: its arrays keep their capacity)
		var scratches:Array<Regalloc.Scratch> = [];
		parallel(todo.length, jobs, k -> {
			var mi = todo[k];
			var obj = new Obj();
			var emit = Target.emitter(abi, obj);
			lock.acquire();
			var ras = scratches.pop();
			lock.release();
			if (ras == null) ras = new Regalloc.Scratch(Target.selector(abi));
			var llvm = llvmFor(order[mi]);
			for (f in byModule.get(order[mi]))
				compileFunc(f, obj, emit, ras, llvm);
			if (llvm != null && !llvmDeferred()) {
				var lo = llvm.compile();
				if (lo != null) {
					obj.append(lo);
					llvm.records(obj);
				}
			} else if (llvm != null && llvm.count > 0) {
				lock.acquire();
				if (llvmPending.indexOf(llvm) < 0) llvmPending.push(llvm);
				lock.release();
			}
			// (one grown by a giant function is dropped: kept, its arrays would
			// hold hundreds of MB per thread until the end of the build)
			if (!ras.oversized()) {
				lock.acquire();
				scratches.push(ras);
				lock.release();
			}
			// (WebAssembly objects are not cached: ElfWriter has no relocations for them)
			if (!abi.wasm && !llvmDeferred()) {
				var b = ElfWriter.write(obj, abi.arm);
				if (store != null) store.writeObject(CacheKey.ofHash(ModuleObject, keys[mi]), moduleFile(order[mi]), b) else sys.io.File.saveBytes(paths[mi], b);
			}
			objs[mi] = obj;
		});
		if (store != null) {
			if (!abi.wasm) store.writeList(outputKey(ObjectList, out), [for (mi in 0...nm) CacheStore.objectName(CacheKey.ofHash(ModuleObject, keys[mi]), moduleFile(order[mi]))]);
			// (a server build has no end where ModuleCache.finish settles it)
			if (resident) CacheDir.settle();
		} else
			sys.io.File.saveContent(indexPath, newIndex.toString());
		// (LinkPE drops sections from the objects it links: not kept)
		if (resident && abi.os != "windows" && !llvmDeferred()) {
			for (mi in 0...nm)
				memObjs.set(memPaths[mi], {key: keys[mi], obj: objs[mi]});
			ServerMemory.output(out);
		}
		if (store == null)
			for (f in sys.FileSystem.readDirectory(dir))
				if (StringTools.endsWith(f, ".o") && !keep.exists(f)) sys.FileSystem.deleteFile(dir + "/" + f);
		var t2 = haxe.Timer.stamp();
		stats(t0, t1, t2);
		var data = new Obj();
		var demit = Target.emitter(abi, data);
		var dg = new DataGen(prep, abi, data, mf -> compileMir(mf, demit, data));
		if (o.mirHost) {
			dg.spareTypes = hxmc.macro.MirHost.SPARE_TYPES;
			dg.spareSigs = hxmc.macro.MirHost.SPARE_SIGS;
		}
		dg.run();
		// (LLVM's code compiled after the data: what it refers to, for the data)
		var dobjs = objs.concat([for (g in llvmPending) g.refs()]);
		dg.allocStubs(dobjs, demit);
		dg.stubs(dobjs, demit);
		dg.cstrLiterals(dobjs);
		dg.cVars(dobjs);
		dg.emptyArrays(dobjs);
		var jni = dg.jniCells(dobjs);
		dg.objcRefs(dobjs);
		dg.objcCaught(demit);
		dg.resources(dobjs);
		// (-D hxmc.interp: the functions interpreted, by entry stub, for the interpreter's indirect calls)
		if (interp != null) interp.table(data) else if (Lambda.exists(prep.p.funcs, f -> f.module == "hxmc.rt.Interp")) hxmc.interp.InterpGen.InterpSet.emptyTable(data);
		// (the functions and their lines for the runtime's stacks: StackTable)
		Dwarf.enabled = o.debugLines;
		data.defineAbs(StackTable.FLAGS, (prep.p.stacks && !abi.wasm && !o.mirHost ? StackTable.flags(prep.p) : 0) | (jni > 0 ? StackTable.JNI : 0)
			| (o.llvm != null && abi.os == "windows" && !abi.arm ? StackTable.WIN64_LLVM : 0));
		// (LLVM, deferred: compiled now, the program-wide numbers known: -D hxmc.llvm-consts)
		if (llvmPending.length > 0) {
			var abs:Null<Map<String, Int>> = null;
			if (o.llvmConsts) {
				abs = new Map();
				for (s in data.symbols)
					if (s.abs) abs.set(s.name, s.offset);
			}
			var tl = haxe.Timer.stamp();
			var los:Array<Obj> = [for (_ in llvmPending) null];
			parallel(llvmPending.length, jobs, k -> los[k] = llvmPending[k].compile(abs));
			for (k in 0...los.length)
				if (los[k] != null) {
					llvmPending[k].records(los[k]);
					objs.push(los[k]);
				}
			if (o.stats) Sys.println('hxmc: llvm: ${llvmPending.length} deferred module(s) compiled ${ms(haxe.Timer.stamp() - tl)}');
		}
		// (after LLVM's deferred code: its functions are in the table too)
		StackTable.add(data, objs, prep.p.stacks && !abi.wasm);
		if (o.stats) Sys.println('hxmc: data: ' + [for (x in dg.sizes) '${x.part} ${x.bytes} bytes'].join(", "));
		var t3 = haxe.Timer.stamp();
		if (abi.wasm) {
			// (the linker's stack runs rt_init only: the runtime's takes over, wasm/Gc.hx)
			var lw = new hxmc.wasm.LinkWasm([data].concat(objs), 64 << 10);
			lw.nameSection = !o.strip;
			lw.legacyEh = o.wasmLegacyEh;
			lw.maxPages = o.wasmMemoryMaxMb << 4;
			var wasm = lw.link();
			sys.io.File.saveBytes(out, wasm);
			if (o.stats) Sys.println('hxmc: data ${ms(t3 - t2)}, link ${ms(haxe.Timer.stamp() - t3)}');
			return;
		}
		var rtPath = o.rtObj != null ? o.rtObj : Options.rtDir(abi.rtName) + "rt.o";
		if (!sys.FileSystem.exists(rtPath)) throw o.rtObj != null ? "hxmc: the runtime object " + rtPath + " is missing (HXMC_RT_OBJ)" : Options.rtMissing(abi.rtName);
		var rt = ElfReader.read(sys.io.File.getBytes(rtPath));
		var t4 = haxe.Timer.stamp();
		var all = [data].concat(objs).concat([rt]);
		// sys.ssl and libuv (mbedtls, libuv and their bindings; or stubs that
		// throw, without them): separate objects next to the runtime object,
		// linked when the program refers to what they define
		var rts = [rt];
		var wanted = new Map<String, Bool>();
		for (o in [data].concat(objs))
			for (s in o.symbols)
				if (s.global && s.section == null && !s.abs) wanted.set(s.name, true);
		for (name in ["ssl", "uv"]) {
			var p = haxe.io.Path.directory(rtPath) + "/" + name + ".o";
			if (!sys.FileSystem.exists(p)) continue;
			var ext = ElfReader.read(sys.io.File.getBytes(p));
			if (Lambda.exists(ext.symbols, s -> s.global && (s.section != null || s.abs) && wanted.exists(s.name))) {
				all.push(ext);
				rts.push(ext);
			}
		}
		// the program's own objects and archives, and its imports from DLLs
		// and dylibs (LinkInputs)
		function undefinedNames():{undef:Array<String>, defined:Map<String, Bool>} {
			var defined = new Map<String, Bool>();
			for (x in all)
				for (s in x.symbols)
					if (s.global && (s.section != null || s.abs)) defined.set(s.name, true);
			var undef = [], seen = new Map<String, Bool>();
			for (x in all)
				for (s in x.symbols)
					if (s.global && s.section == null && !s.abs && !defined.exists(s.name) && !seen.exists(s.name)) {
						seen.set(s.name, true);
						undef.push(s.name);
					}
			undef.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			return {undef: undef, defined: defined};
		}
		var links = o.links.concat(hxmc.ir.CInterop.LINKS);
		// (Linux: also without LLVM, as the runtime's writer is typed in, hxmc.rt.Pgo)
		if (o.llvmPgo == "gen" && (o.llvm != null || abi.os == "linux")) links.push(LlvmGen.profileRuntime(abi, o.llvmClang));
		if (links.length > 0) {
			var u = undefinedNames();
			for (x in LinkInputs.load(links, abi, u.undef, u.defined)) {
				all.push(x);
				rts.push(x);
			}
		}
		var still = links.length > 0 || hxmc.ir.CInterop.USER.keys().hasNext() || hxmc.ir.CInterop.LIBS.keys().hasNext() ? undefinedNames().undef : [];
		var dylibs = new Map<String, String>();
		// (a shared object named as such, libm.so.6: never from an object, which
		// may define the name too, as compiler-rt's weak cos; of the functions
		// the program calls, not of those lowered and then dropped: Reach)
		if (abi.os == "linux" && !abi.linksDynamically())
			for (n => lib in hxmc.ir.CInterop.LIBS)
				if (lib.indexOf(".so") >= 0 && wanted.exists(n))
					throw 'hxmc: link: the C function $n of the shared library $lib (@:hxmc.lib): Linux executables are static with musl (the default); shared libraries need the dynamic glibc mode (-D hxmc.libc=glibc)';
		for (n in still) {
			var lib = hxmc.ir.CInterop.LIBS.get(n);
			if (abi.os == "linux" && !abi.linksDynamically() && lib != null)
				throw 'hxmc: link: the C function $n of the shared library $lib (@:hxmc.lib): Linux executables are static with musl (the default); shared libraries need the dynamic glibc mode (-D hxmc.libc=glibc)';
			if (abi.os == "linux" && !abi.linksDynamically() && hxmc.ir.CInterop.USER.exists(n))
				throw 'hxmc: link: the C function $n is defined nowhere: Linux executables are static, so it must come from an object or archive (-D hxmc.link=<file>, or @:hxmc.link), or from a shared library in the dynamic glibc mode (-D hxmc.libc=glibc, @:hxmc.lib)';
			if ((abi.os == "macos" || abi.linksDynamically()) && lib != null) dylibs.set(n, LinkInputs.libFile(lib, abi));
		}
		if (abi.os == "windows") {
			var imp = LinkInputs.peImports(still, abi);
			if (imp != null) all.push(imp);
		}
		// a Mir host: what code loaded at run time crosses into native code
		// through (interp.InterpAbi: the call-outs, the entries' pools, the
		// thread-local variables' accessors), then the table of the
		// executable's symbols and fingerprints it links against
		// (macro.HostTable)
		if (o.mirHost) {
			var th = new Obj();
			var temit = Target.emitter(abi, th);
			hxmc.interp.InterpAbi.thunks(prep, abi, mf -> compileMir(mf, temit, th));
			hxmc.interp.InterpAbi.poolTables(th);
			hxmc.interp.InterpAbi.tlsAccessors(prep, abi, hxmc.macro.HostTable.tlsNames(all), mf -> compileMir(mf, temit, th));
			all.push(th);
			// (the table of functions and lines with them: a walk goes on through
			// them to the interpreted frames and the native code calling them, hxmc.rt.Stacks)
			StackTable.rebuild(all, _ -> true);
			// (what code loaded at run time can reach: the std's and the runtime's, HostTable.named)
			var idents = hostIdents != null ? hostIdents : new Map();
			var named = n -> hxmc.macro.HostTable.named(n, idents);
			var fps = hostFingerprints().filter(x -> named(x.sym));
			all.push(hxmc.macro.HostTable.build(all, abi, fps, hxmc.macro.HostTable.imports(all, abi), named, o.stats));
		}
		// (-D hxmc.codesign-*: a Mach-O output's signature binds the files a
		// packager wrote for the bundle around it, Options)
		if (o.codesigned() && abi.os != "macos") throw "hxmc: -D hxmc.codesign-*: a Mach-O output's (macOS, iOS) only";
		// the runtime objects' sections and the runtime's Haxe functions that
		// nothing reaches are left out (LinkCore.gc; a Mir host: every runtime
		// function stays, for the code it loads)
		var collect = !o.mirHost ? rts : null;
		var exe = abi.os == "windows" ? {
			var l = new LinkPE(all, abi.arm);
			if (abi.output == SharedLibrary) {
				l.dll = true;
				l.exports = abi.exports;
				l.dllName = haxe.io.Path.withoutDirectory(out);
				// (-D hxmc.dll-base=<hex>: where it prefers to load; hxmc dev alternates two)
				if (o.dllBase != null) l.dllBase = Std.parseInt(o.dllBase);
			}
			l.symbols = !o.strip;
			l.collect = collect;
			l.link("mainCRTStartup");
		} : abi.os == "macos" ? {
			var l = new LinkMachO(all, abi);
			l.symbols = !o.strip;
			l.heapWindow = hxmc.ir.Lower.compactTypes == 1;
			l.collect = collect;
			if (abi.output == SharedLibrary) l.installName = "@rpath/" + haxe.io.Path.withoutDirectory(out);
			l.dylibs = dylibs;
			l.loads = [for (lib in hxmc.ir.CInterop.LOADS.keys()) LinkInputs.libFile(lib, abi)];
			l.loads.sort(Reflect.compare);
			if (abi.uikit()) {
				l.minos = o.iosMinos;
				l.sdk = o.iosSdk;
			}
			if (o.codesigned()) {
				inline function file(p:Null<String>) return p != null ? sys.io.File.getBytes(p) : null;
				l.sign = CodeSign.adhoc(o.codesignId ?? haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(out)), file(o.codesignInfoPlist),
					file(o.codesignResources), file(o.codesignEntitlements));
			}
			l.link("main");
		} : {
			var l = if (abi.linksDynamically()) {
				var d = new LinkDyn(all, abi);
				d.libs = dylibs;
				// (the soname: the output's file name, whatever packages it)
				if (abi.output == SharedLibrary) d.soname = haxe.io.Path.withoutDirectory(out);
				// (Android: ANativeActivity_onCreate when the program defines it, an app's entry)
				if (abi.android) d.optional = ["ANativeActivity_onCreate"];
				// (a library named without a directory or a version: next to the executable)
				d.origin = Lambda.exists([for (f in dylibs) f], f -> f.indexOf("/") < 0 && StringTools.endsWith(f, ".so"));
				d;
			} else new Link(all, abi);
			l.symbols = !o.strip;
			l.collect = collect;
			// (a Mir host: the symbols also as a file, for people: RT_CENSUS_WHY's globals; nothing reads it)
			if (o.mirHost) l.hostSyms = new StringBuf();
			var exe = l.link("_start");
			if (o.mirHost) sys.io.File.saveContent(out + ".syms", l.hostSyms.toString());
			exe;
		};
		if (abi.os == "windows" && abi.output != SharedLibrary && !StringTools.endsWith(out, ".exe")) out += ".exe";
		writeExecutable(out, exe);
		// (Java: the proxies the glue must have, next to the output: Jni.manifest)
		var manifest = hxmc.ir.Jni.manifest([for (ci in prep.p.classes) if (ci.jniProxy != null && prep.p.isLive(ci.jniProxy.desc)) ci]);
		if (manifest != null) sys.io.File.saveContent(out + ".jni.json", manifest);
		if (o.stats && prep.p.stacks) Sys.println('hxmc: stack table: ' + StackTable.stats + ', flags ' + StackTable.flags(prep.p));
		if (o.stats) {
			Sys.println('hxmc: modules ${order.length}: ${hits} cached, ${misses} compiled (keys and reading ${ms(tKey)})');
			// (which, the first ten in module order)
			if (misses > 0) {
				var names = [for (mi in 0...nm) if (compiled[mi]) order[mi]];
				Sys.println('hxmc: compiled ' + names.slice(0, 10).join(", ") + (names.length > 10 ? ', ... (${names.length})' : ''));
			}
			Sys.println('hxmc: data ${ms(t3 - t2)}, runtime read ${ms(t4 - t3)}, link ${ms(haxe.Timer.stamp() - t4)}');
		}
	}

	static function ms(s:Float):String
		return Std.int(s * 1000) + " ms";

	// under WASI (the tool as a WebAssembly module) there are no processes:
	// whoever runs the module marks the output executable (HXMC_EXE_LIST
	// names a file the output's path is added to, one per line)
	// (Windows hosts need no mode)
	// an executable written anew, not over the old one's bytes: macOS caches
	// a file's code signature, and kills the next launch of an executable
	// that ran and was then rewritten in place (SIGKILL, "exit 137"); as
	// ld64 does, the new file goes next to it and replaces it (a rename). On
	// Windows (a running .exe cannot be replaced; rename does not overwrite)
	// and WASI in place
	public static function writeExecutable(path:String, bytes:haxe.io.Bytes) {
		var host = Sys.systemName();
		if (host == "Windows" || host == "Wasi" || !sys.FileSystem.exists(path)) {
			sys.io.File.saveBytes(path, bytes);
			markExecutable(path);
			return;
		}
		var tmp = path + ".hxmc-new";
		sys.io.File.saveBytes(tmp, bytes);
		markExecutable(tmp);
		sys.FileSystem.rename(tmp, path);
	}

	public static function markExecutable(path:String) {
		if (Sys.systemName() == "Windows") {} else if (Sys.systemName() != "Wasi")
			Sys.command("chmod", ["755", path]);
		else if (Sys.getEnv("HXMC_EXE_LIST") != null) {
			var f = sys.io.File.append(Sys.getEnv("HXMC_EXE_LIST"));
			f.writeString(sys.FileSystem.absolutePath(path) + "\n");
			f.close();
		}
	}
}

// The order blocks are laid out in: reverse postorder (Cfg), the cold blocks
// (slow paths) at the end.
class Layout {
	public static function order(f:MFunc):haxe.ds.Vector<MBlock> {
		var rpo = f.cfg().rpo;
		var r = new haxe.ds.Vector<MBlock>(rpo.length);
		var k = 0;
		for (b in rpo)
			if (!b.cold) r[k++] = b;
		for (b in rpo)
			if (b.cold) r[k++] = b;
		return r;
	}
}
