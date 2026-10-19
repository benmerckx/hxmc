package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.Abi;
import hxmc.MirBuild.Unsupported;

// One run of the tool. Functions are compiled per Haxe module (the unit of
// the object cache): each module becomes an object of its own, cached under
// a key hashing its Fingerprint (with the tool and the target) in the store
// (ObjectStore: shared by every output; else in <out>.hxmc/), so a rebuild
// after an edit compiles only the modules whose code can change. The program's data (DataGen) is regenerated every time, and
// everything is linked with the runtime object (Link).
class Driver {
	var prep:Prep;
	var abi:Abi;
	var o:Options;
	var out:String;
	var dumpSet:Null<Map<String, Bool>>;
	var tm = [0.0, 0.0, 0.0, 0.0];
	var slow:Array<{name:String, t:Float}> = [];

	function new(prog:Program, out:String, o:Options) {
		this.o = o;
		this.out = o.output != null ? o.output : out;
		prep = new Prep(prog);
		abi = Abi.get(o.target);
		abi.setLibc(o.libc);
		if (o.segAlign > 0) abi.segAlign = o.segAlign;
		if (o.pic) abi.reloc = Pic;
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
	}

	// (-D hxmc.jit: every function stays, for the native macros the compiler
	// loads, and closures are made as they are in those, Prep.staticClosures;
	// native macros' own code makes a Driver itself, Guest)
	public static function run(prog:Program, out:String, o:Options) {
		var t0 = haxe.Timer.stamp();
		if (!o.jit) hxmc.ir.Reach.run(prog, o.stats);
		var d = new Driver(prog, out, o);
		d.prep.staticClosures = !o.jit;
		var t1 = haxe.Timer.stamp();
		d.build(t0, t1);
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
	static var sroa = Sys.getEnv("HXMC_SROA") != "0";
	var raRounds = 0;
	var raInsns = 0;
	var raFuncs = 0;

	// the Mir of the callees inlined, built once (shared by the threads: read only once made)
	var templates = new haxe.ds.ObjectMap<FuncInfo, {t:Null<Inline.Template>}>();
	var tlock = new sys.thread.Mutex();

	function template(fn:FuncInfo):Null<Inline.Template> {
		tlock.acquire();
		var e = templates.get(fn);
		tlock.release();
		if (e != null) return e.t;
		var cb = new MirBuild(prep, abi, fn);
		cb.icSym = prep.funcSym(fn) + "__ic";
		var t = try Inline.template(cb, cb.build()) catch (_:Unsupported) null;
		tlock.acquire();
		var e2 = templates.get(fn);
		if (e2 == null) templates.set(fn, {t: t}) else t = e2.t;
		tlock.release();
		return t;
	}

	// one function into `obj` (with its emitter)
	function compileFunc(fn:FuncInfo, obj:Obj, emit:Target.Emitter, ras:Regalloc.Scratch) {
		var name = prep.funcSym(fn);
		try {
			var s0 = haxe.Timer.stamp();
			var mb = new MirBuild(prep, abi, fn);
			mb.icSym = name + "__ic";
			var mf = mb.build();
			if (o.opt) {
				// to a depth (Fingerprint keys callers with their callees' callees)
				var todo = mb.inlineSites;
				var ic = {sym: mb.icSym, count: mb.icaches};
				for (_ in 0...Inline.DEPTH) {
					if (todo.length == 0) break;
					var sites = [];
					var inLoop = Inline.loopBlocks(mf);
					for (s in todo) {
						var t = template(s.fn);
						if (t != null && s.fn != fn && t.size <= Inline.maxSize(abi.wasm, s.call.block.mark == inLoop, StringTools.startsWith(s.fn.module, "hxmc.rt.")))
							sites.push({call: s.call, callee: t});
					}
					todo = Inline.run(mf, sites, ic);
				}
				mb.icaches = ic.count;
			}
			if (o.opt && sroa) new Sroa(mf).run();
			if (o.opt) new Opt(mf).run();
			if (dumpSet != null && dumpSet.exists(name)) Sys.println(mf.dump());
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
			var s2 = haxe.Timer.stamp();
			var ra = new Regalloc(lf, isel, ras);
			ra.run();
			var s3 = haxe.Timer.stamp();
			// the runtime's Haxe functions: a section each, dropped by the linker
			// when nothing reaches them (the exported ones are always compiled)
			var rtFunc = StringTools.startsWith(fn.module, "hxmc.rt.");
			if (rtFunc) emit.useSection(Link.GC_PREFIX + name);
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
	function toolKey():String {
		var p = Sys.programPath();
		var st = try sys.FileSystem.stat(p) catch (_:Dynamic) null;
		return "hxmc|" + abi.rtName + (abi.ios() ? "+" + abi.platform : "") + (o.wasmLegacyEh ? "+legacy-eh" : "") + (abi.framePointers ? "+fp" : "") + (hxmc.ir.Lower.lines ? "+lines" : "")
			+ (abi.output == SharedLibrary ? "+shared" : "") + "|" +(st == null ? "?" : st.size + "@" + st.mtime.getTime()) + "|";
	}

	// the functions that may be inlined (before the keys: they are part of them)
	function inlineCandidates() {
		if (!o.opt) return;
		var m = new Map<FuncInfo, Bool>();
		for (f in prep.p.funcs)
			if (Inline.candidate(f)) m.set(f, true);
		MirBuild.inlineCands = m;
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

	function build(t0:Float, t1:Float) {
		inlineCandidates();
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
		// the objects: in the store (ObjectStore), else next to the output
		var store = ObjectStore.open(out);
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
		var paths = [for (m in order) dir + "/" + moduleFile(m)];
		var memPaths = paths.copy();
		var keys = [for (_ in 0...nm) ""];
		var lits:Array<Array<String>> = [for (_ in 0...nm) null];
		var objs:Array<Obj> = [for (_ in 0...nm) null];
		var s0 = haxe.Timer.stamp();
		// (the functions that may be inlined: their digests first, Fingerprint.Inlined)
		var inlined:Null<Fingerprint.Inlined> = null;
		if (MirBuild.inlineCands != null) {
			var cands = MirBuild.inlineCands;
			inlined = new Fingerprint.Inlined(prep, [for (f in p.funcs) if (cands.exists(f)) f]);
			var d = Inline.DEPTH;
			while (d >= 1) {
				var depth = d;
				parallel(inlined.funcs.length, jobs, k -> inlined.compute(depth, k));
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
			if (store != null) paths[mi] = store.objectPath(key, moduleFile(order[mi]));
			if (mem != null && mem.key == key) objs[mi] = mem.obj;
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
				misses++;
			}
		}
		// largest modules first, so the last ones to finish are small
		var weight = [for (m in order) 0];
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
			for (f in byModule.get(order[mi]))
				compileFunc(f, obj, emit, ras);
			lock.acquire();
			scratches.push(ras);
			lock.release();
			// (WebAssembly objects are not cached: ElfWriter has no relocations for them)
			if (!abi.wasm) {
				var b = ElfWriter.write(obj, abi.arm);
				if (store != null) store.save(paths[mi], b) else sys.io.File.saveBytes(paths[mi], b);
			}
			objs[mi] = obj;
		});
		if (store != null) {
			if (!abi.wasm) store.record([for (p in paths) haxe.io.Path.withoutDirectory(p)]);
			// (a server build has no end where ModuleCache.finish settles it)
			if (resident) CacheDir.settle();
		} else
			sys.io.File.saveContent(indexPath, newIndex.toString());
		// (LinkPE drops sections from the objects it links: not kept)
		if (resident && abi.os != "windows")
			for (mi in 0...nm)
				memObjs.set(memPaths[mi], {key: keys[mi], obj: objs[mi]});
		if (store == null)
			for (f in sys.FileSystem.readDirectory(dir))
				if (StringTools.endsWith(f, ".o") && !keep.exists(f)) sys.FileSystem.deleteFile(dir + "/" + f);
		var t2 = haxe.Timer.stamp();
		stats(t0, t1, t2);
		var data = new Obj();
		var demit = Target.emitter(abi, data);
		var dg = new DataGen(prep, abi, data, mf -> compileMir(mf, demit, data));
		if (o.jit) {
			dg.spareTypes = hxmc.macro.Jit.SPARE_TYPES;
			dg.spareSigs = hxmc.macro.Jit.SPARE_SIGS;
		}
		dg.run();
		dg.allocStubs(objs, demit);
		dg.stubs(objs, demit);
		dg.cstrLiterals(objs);
		dg.emptyArrays(objs);
		if (o.stats) Sys.println('hxmc: data: ' + [for (x in dg.sizes) '${x.part} ${x.bytes} bytes'].join(", "));
		var t3 = haxe.Timer.stamp();
		if (abi.wasm) {
			var stack = Sys.getEnv("HXMC_WASM_STACK_KB");
			var lw = new hxmc.wasm.LinkWasm([data].concat(objs), stack != null ? Std.parseInt(stack) << 10 : 1 << 20);
			lw.nameSection = !o.strip;
			lw.legacyEh = o.wasmLegacyEh;
			var wasm = lw.link();
			sys.io.File.saveBytes(out, wasm);
			if (o.stats) Sys.println('hxmc: data ${ms(t3 - t2)}, link ${ms(haxe.Timer.stamp() - t3)}');
			return;
		}
		var rtPath = o.rtObj != null ? o.rtObj : Options.rtDir() + abi.rtName + "/rt.o";
		if (!sys.FileSystem.exists(rtPath)) throw "hxmc: the runtime object " + rtPath + " is missing (make rt)";
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
		// may define the name too, as compiler-rt's weak cos)
		if (abi.os == "linux" && !abi.linksDynamically())
			for (n => lib in hxmc.ir.CInterop.LIBS)
				if (lib.indexOf(".so") >= 0)
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
		var bundle = abi.ios() && hxmc.ios.Bundle.isBundle(out) ? new hxmc.ios.Bundle(out, abi, o.ios) : null;
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
			l.link("mainCRTStartup");
		} : abi.os == "macos" ? {
			var l = new LinkMachO(all, abi);
			l.symbols = !o.strip;
			if (abi.output == SharedLibrary) l.installName = "@rpath/" + haxe.io.Path.withoutDirectory(out);
			l.dylibs = dylibs;
			if (bundle != null) {
				l.sign = bundle.sign;
				l.minos = bundle.minos;
			}
			l.link("main");
		} : {
			// (an APK: its lib<name>.so, Apk)
			var apk = abi.android && StringTools.endsWith(out, ".apk");
			var l = if (abi.linksDynamically()) {
				var d = new LinkDyn(all, abi);
				d.libs = dylibs;
				if (abi.output == SharedLibrary) d.soname = apk ? "lib" + hxmc.android.Apk.libName(out) + ".so" : haxe.io.Path.withoutDirectory(out);
				if (abi.android && !apk) d.optional = ["ANativeActivity_onCreate"];
				// (a library named without a directory or a version: next to the executable)
				d.origin = Lambda.exists([for (f in dylibs) f], f -> f.indexOf("/") < 0 && StringTools.endsWith(f, ".so"));
				d;
			} else new Link(all, abi);
			l.symbols = !o.strip;
			// (-D hxmc.jit: every runtime function stays, for the native macros it loads)
			if (Sys.getEnv("HXMC_NOGC") != "1" && !o.jit) l.collect = rts;
			if (o.jit) l.hostSyms = new StringBuf();
			var exe = l.link("_start");
			if (o.jit) sys.io.File.saveContent(out + ".syms", l.hostSyms.toString());
			exe;
		};
		if (abi.os == "windows" && abi.output != SharedLibrary && !StringTools.endsWith(out, ".exe")) out += ".exe";
		// iOS: the app bundle (or its .ipa) around the executable
		if (bundle != null) {
			bundle.write(out, exe);
			return;
		}
		// Android: the shared library alone (lib<name>.so), or in an APK
		if (abi.android && StringTools.endsWith(out, ".apk")) {
			// (classes.dex: Glue's classes, for a program with listeners; views: org.hxmc.Activity)
			var glue = false, views = false;
			for (f in prep.p.funcs) {
				if (f.name == hxmc.android.Glue.USED_BY) glue = true;
				if (f.name == hxmc.android.Glue.VIEWS_USED_BY) views = true;
			}
			hxmc.android.Apk.write(out, exe, glue ? hxmc.android.Glue.dex() : null, views, abi, o.android, hxmc.android.Apk.keyFile(o.android, CacheDir.root()));
			return;
		}
		sys.io.File.saveBytes(out, exe);
		markExecutable(out);
		if (hxmc.x64.Emit.sizeStats) {
			var ks = [for (k in hxmc.x64.Emit.statBytes.keys()) k];
			ks.sort((x, y) -> hxmc.x64.Emit.statBytes.get(y) - hxmc.x64.Emit.statBytes.get(x));
			for (k in ks)
				Sys.println('  size ${hxmc.x64.Emit.statBytes.get(k)}\t$k');
		}
		if (o.stats) {
			Sys.println('hxmc: modules ${order.length}: ${hits} cached, ${misses} compiled (keys and reading ${ms(tKey)})');
			Sys.println('hxmc: data ${ms(t3 - t2)}, runtime read ${ms(t4 - t3)}, link ${ms(haxe.Timer.stamp() - t4)}');
		}
	}

	static function ms(s:Float):String
		return Std.int(s * 1000) + " ms";

	// under WASI (the tool as a WebAssembly module) there are no processes:
	// whoever runs the module marks the output executable (HXMC_EXE_LIST
	// names a file the output's path is added to, one per line)
	// (Windows hosts need no mode)
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

// The order blocks are laid out in: reverse postorder, the cold blocks (slow
// paths) at the end.
class Layout {
	public static function order(f:MFunc):Array<MBlock> {
		var seen = f.newMark();
		var post = [];
		// iterative DFS: the first successor is visited first
		var stack:Array<MBlock> = [f.entry];
		var idx:Array<Int> = [0];
		f.entry.mark = seen;
		while (stack.length > 0) {
			var top = stack.length - 1;
			var b = stack[top];
			var k = idx[top];
			if (k < b.succs.length) {
				idx[top] = k + 1;
				var s = b.succs[k];
				if (s.mark != seen) {
					s.mark = seen;
					stack.push(s);
					idx.push(0);
				}
			} else {
				post.push(b);
				stack.pop();
				idx.pop();
			}
		}
		post.reverse();
		var hot = [for (b in post) if (!b.cold) b];
		var cold = [for (b in post) if (b.cold) b];
		return hot.concat(cold);
	}
}
