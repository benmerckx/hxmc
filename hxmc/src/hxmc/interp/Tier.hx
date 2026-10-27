package hxmc.interp;

import hxmc.Mir;
import hxmc.Obj;
import hxmc.ir.Ir;
import hxmc.macro.Loader;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// What compiles a function of code loaded at run time to native code later
// (Tier): the driver and generation of the latest step (interp.MirMacros:
// each step's Prep numbers the program's types again), what is set around
// the compilation, and the literals an earlier step named
class TierSite {
	public function new() {}

	public function driver():Driver
		throw "abstract";

	public function gen():hxmc.macro.Loader.Gen
		throw "abstract";

	public function enter() {}

	public function leave() {}

	public function literals(obj:Obj) {}
}

// The native tier of code loaded at run time into a Mir host (Mir macros,
// --run on Mir; docs/hxmc.md, "The native tier"): the interpreter counts
// each descriptor's calls (hxmc.rt.Interp.tierHook), and a function called
// HXMC_MIR_TIER times (a power of two; 0: never) is compiled to native code
// as the program's own code is (the optimizer on), loaded below 2 GB
// (Loader.loadNative), and its descriptor made a forwarder's: an
// interpreted function of its signature calling the native code (CALLX).
// Whatever holds the descriptor (a call's symbol table, a pool entry)
// reaches the native code from then on; frames running the interpreted code
// finish on it. The native code calls interpreted functions through their
// pool entries, as the compiler's own code does, and the compiler's
// functions directly.
//
// Compiling collects, so it happens only where a collection may: a
// function whose calls are no GC point (its callers keep references in
// registers across it) waits until a function that is one is counted.
// A function the native tier cannot load (a symbol it lacks, a thread-local
// variable emulated for the interpreter) stays interpreted. Once the
// window is full (Loader.full) the tier stops: nothing is counted any more,
// and what is compiled from then on is compiled for the interpreter.
//
// HXMC_MIR_TIER=native: a function is compiled to native code when first
// called (its stub's, compileStub: the interpreter's code only when that
// fails); the functions whose calls are no GC point once their bundle is
// loaded (loaded), where the loader is one; the static initializers stay
// interpreted (they run as the bundle loads).
@:access(hxmc.Driver)
@:access(hxmc.MirWriter)
@:access(hxmc.rt.Interp)
@:access(hxmc.rt.Gc)
class Tier {
	public static var calls = {
		var v = Sys.getEnv("HXMC_MIR_TIER");
		var n = v == null ? DEFAULT : v == "native" ? 1 : Std.parseInt(v);
		if (n == null || n < 0) n = 0;
		var p = 1;
		while (p < n)
			p <<= 1;
		n == 0 ? 0 : p;
	};
	static inline var DEFAULT = 1024;
	// (HXMC_MIR_TIER=native: compiled when first called, compileStub)
	public static final eager = Sys.getEnv("HXMC_MIR_TIER") == "native";
	// the native code's own symbol, which its forwarder calls
	static inline var NATIVE = "hxmc_tier$";

	// the functions registered, by their number - 1 (in their descriptors' flags, above the D_* bits)
	static var fns:Array<TierFn> = [];
	// (functions waiting for a GC point: noted by their state alone, as noting allocates nothing)
	static var pending = 0;
	static var busy = false;
	public static final lock = new sys.thread.Mutex();
	// (HXMC_MACRO_STATS)
	public static var tiered = 0;
	public static var failed = 0;
	public static var time = 0.0;
	// (HXMC_MIR_TIER_MAX: at most this many functions compiled, to bisect)
	static var max = Sys.getEnv("HXMC_MIR_TIER_MAX") == null ? -1 : Std.parseInt(Sys.getEnv("HXMC_MIR_TIER_MAX"));
	static var stats = Sys.getEnv("HXMC_MACRO_STATS") == "1" || Sys.getEnv("HXMC_MIR_TIER_LOG") == "1";

	// whether hot functions are compiled to native code (Loader.nativeTier, HXMC_MIR_TIER)
	public static function on():Bool
		return calls > 0 && Loader.nativeTier();

	// before the first bundle loads: its memory in the window, the interpreter counting
	public static function install() {
		if (!on()) return;
		Loader.low = true;
		hxmc.rt.Interp.tierMask = calls - 1;
		hxmc.rt.Interp.tierHook = hook;
	}

	// the function of descriptor desc may be compiled to native code by site
	// (its number in the descriptor's flags: Interp.tierCheck), with the
	// optimizer as for the interpreter (`optimize`: its inlining decides
	// which frames a stack has, hxmc.rt.Stacks.addMade)
	public static function add(desc:Ptr, f:FuncInfo, site:TierSite, optimize = true) {
		if (!on() || f.cAbi != null || f.sret) return;
		fns.push(new TierFn(desc, f, site, optimize));
		var flags = Mem.getI32(desc, InterpGen.H_FLAGS);
		Mem.setI32(desc, InterpGen.H_FLAGS, (flags & 0xff) | (fns.length << 8));
	}

	// (Interp.tierHook) the function numbered id + 1 called tierMask + 1 more
	// times, its arguments at args. Nothing is allocated before it is known
	// to be a GC point (the callers of a function that is none keep
	// references in registers across it) and its arguments are rooted. While
	// a second thread runs interpreted code nothing is compiled: a descriptor
	// made another's (Interp.become) is read by its callers in parts.
	static function hook(id:Int, args:Ptr) {
		if (busy || hxmc.rt.Interp.threads > 1) return;
		if (Loader.full) {
			stop();
			return;
		}
		var t = fns[id - 1];
		// (a stub is compiled for the interpreter first, interp.MirMacros: its object is kept, BundleCache)
		if (t.state != TierState.WAITING || hxmc.rt.Interp.isStub(t.desc)) return;
		var f = t.f;
		if (f.noGc && !f.blocks) {
			// (compiled at the next GC point)
			t.state = TierState.PENDING;
			pending++;
			return;
		}
		busy = true;
		var rs = root(f, args);
		lock.acquire();
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = false;
		var t0 = haxe.Timer.stamp();
		compilePending();
		compile(t, t.optimize);
		time += haxe.Timer.stamp() - t0;
		hxmc.rt.EvalCompat.on = order;
		lock.release();
		unroot(f, args, rs);
		busy = false;
	}

	// (eager) the function of stub desc called the first time (its arguments
	// rooted, the lock held, EvalCompat off: MirMacros.compileLazy,
	// MirRun.compileLazy) compiled to native code, optimized unless cold, and
	// desc made its forwarder's; false: it is to be compiled for the
	// interpreter (none registered, a second thread running interpreted
	// code as for the hook, the native tier failed)
	public static function compileStub(desc:Ptr, optimize:Bool):Bool {
		var id = Mem.getI32(desc, InterpGen.H_FLAGS) >>> 8;
		if (!eager || id == 0 || busy || hxmc.rt.Interp.threads > 1 || Loader.full) return false;
		var t = fns[id - 1];
		busy = true;
		var t0 = haxe.Timer.stamp();
		compilePending();
		compile(t, optimize);
		time += haxe.Timer.stamp() - t0;
		busy = false;
		return t.state == TierState.DONE;
	}

	// (eager) a bundle loaded, its functions added: those whose calls are no
	// GC point (no stub: they are compiled with the bundle) compiled now, at
	// the loader's GC point, as none of their calls is one
	public static function loaded() {
		if (!eager || !on() || hxmc.rt.Interp.threads > 1 || Loader.full) return;
		lock.acquire();
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = false;
		busy = true;
		var t0 = haxe.Timer.stamp();
		while (fresh < fns.length) {
			var t = fns[fresh++];
			if (t.f.noGc && !t.f.blocks && (t.state == TierState.WAITING || t.state == TierState.PENDING)) {
				if (t.state == TierState.PENDING) pending--;
				compile(t, t.optimize);
			}
		}
		time += haxe.Timer.stamp() - t0;
		busy = false;
		hxmc.rt.EvalCompat.on = order;
		lock.release();
	}

	// (loaded: the functions added before, looked at)
	static var fresh = 0;

	// (the functions waiting for a GC point: at one)
	static function compilePending() {
		if (pending == 0) return;
		pending = 0;
		for (p in fns)
			if (p.state == TierState.PENDING) compile(p, p.optimize);
	}

	// the references among f's arguments at args (the interpreter's
	// registers, which no collection sees) pushed on this thread's shadow
	// stack before anything is allocated, which may collect and move what
	// they reference; the first slot. Inline: pushed in the caller's frame,
	// above its slots, given back as it returns or unwinds (its frame's pop)
	public static inline function root(f:FuncInfo, args:Ptr):Ptr {
		var first = hxmc.rt.Gc.sp;
		for (j in 0...f.args.length)
			if (f.args[j].ty.match(TRef(_))) hxmc.rt.Gc.pushRoot(Mem.obj(Mem.getPtr(args, 8 * j)));
		return first;
	}

	// (root's references, as collections left them, written back to args)
	public static inline function unroot(f:FuncInfo, args:Ptr, first:Ptr) {
		var s = first;
		for (j in 0...f.args.length)
			if (f.args[j].ty.match(TRef(_))) {
				Mem.setPtr(args, 8 * j, Mem.getPtr(s, 0));
				s = s.add(8);
			}
		hxmc.rt.Gc.popRoots(first);
	}

	// t done with (compiled, or left interpreted): its descriptor no longer
	// given to the hook (the forwarder's calls, under eager every one, cost nothing more)
	static function settle(t:TierFn, state:TierState) {
		t.state = state;
		Mem.setI32(t.desc, InterpGen.H_FLAGS, Mem.getI32(t.desc, InterpGen.H_FLAGS) & 0xff);
	}

	// t's function compiled to native code and loaded, its descriptor made
	// the forwarder's; on a failure, it stays interpreted
	static function compile(t:TierFn, optimize:Bool) {
		if (t.state == TierState.DONE || t.state == TierState.FAILED) return;
		if (Loader.full) {
			settle(t, TierState.FAILED);
			return;
		}
		var site = t.site, f = t.f;
		if (max >= 0 && tiered >= max) {
			settle(t, TierState.FAILED);
			return;
		}
		for (k in 0...4)
			if (hxmc.rt.Interp.poolRoom(k) <= 0) {
				// (the pools' entries its calls of interpreted code would take: an eighth left for what must have one)
				settle(t, TierState.FAILED);
				failed++;
				if (stats) Sys.stderr().writeString('hxmc tier: ${site.driver().prep.funcSym(f)} stays interpreted: the pools are nearly given out\n');
				return;
			}
		site.enter();
		var d = site.driver();
		var opt = d.o.opt;
		try {
			var prep = d.prep, abi = d.abi;
			var sym = prep.funcSym(f);
			var obj = new Obj();
			var emit = Target.emitter(abi, obj);
			var ras = new Regalloc.Scratch(Target.selector(abi));
			d.interp.nativeNow = f;
			d.o.opt = optimize;
			d.compileFunc(f, obj, emit, ras);
			d.interp.nativeNow = null;
			d.o.opt = opt;
			site.literals(obj);
			// (the data its generation has, its literals and empty arrays among them: the same objects, not copies)
			var gen = site.gen();
			for (s in obj.symbols)
				if (s.section == null && !s.abs) {
					var x = gen.xb.get(s.name);
					if (x != null && x.k == "d") {
						s.abs = true;
						s.offset = x.v.toInt();
					}
				}
			var dg = new DataGen(prep, abi, obj, mf -> d.compileMir(mf, emit, obj));
			dg.allocStubs([obj], emit);
			dg.stringsUsed();
			dg.cstrLiterals([]);
			dg.emptyArrays([]);
			dg.resources([]);
			var code = Loader.loadNative(obj, sym, gen);
			// the forwarder: the function's signature, a call of the native code
			var params = haxe.ds.Vector.fromArrayCopy([for (a in f.args) MirBuild.mty(a.ty) == Void ? I32 : MirBuild.mty(a.ty)]);
			var ret = MirBuild.mty(f.ret);
			var mf = MirBuild.synthetic(prep, abi, sym, params, ret, (b, ps) -> {
				var r = b.call(NATIVE + sym, ps, ret);
				b.ret(ret == Void ? -1 : r);
			});
			var wobj = new Obj();
			d.compileInterp(mf, wobj);
			var fwd = Loader.loadLate(wobj, InterpGen.DESC + sym, gen, [NATIVE + sym => code.toI64()]);
			hxmc.rt.Interp.become(t.desc, fwd);
			settle(t, TierState.DONE);
			tiered++;
			if (stats) Sys.stderr().writeString('hxmc tier: $sym native at 0x${StringTools.hex(code.toI64().toInt())}\n');
		} catch (x:Dynamic) {
			d.interp.nativeNow = null;
			d.o.opt = opt;
			settle(t, TierState.FAILED);
			failed++;
			if (stats) Sys.stderr().writeString('hxmc tier: ${d.prep.funcSym(f)} stays interpreted: ${Std.string(x)}\n');
		}
		site.leave();
	}

	// (the window full) no more counting, nor compiling
	static function stop() {
		if (hxmc.rt.Interp.tierMask == -1) return;
		hxmc.rt.Interp.tierMask = -1;
		if (stats) Sys.stderr().writeString('hxmc tier: the window is full: stopped, ${Loader.nativeBytes} bytes of code\n');
	}

	public static function report():String
		return 'native tier: $tiered functions compiled (${Loader.nativeBytes} bytes of code), $failed left interpreted, ${Std.int(time * 1000)} ms';
}

private class TierFn {
	public final desc:Ptr;
	public final f:FuncInfo;
	public final site:TierSite;
	public final optimize:Bool;
	public var state:TierState = TierState.WAITING;

	public function new(desc, f, site, optimize) {
		this.desc = desc;
		this.f = f;
		this.site = site;
		this.optimize = optimize;
	}
}

private enum abstract TierState(Int) {
	var WAITING;
	var PENDING;
	var DONE;
	var FAILED;
}
