package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Layouts as L;
import hxmc.rt.C;
import hxmc.rt.Os.Report;
import hxmc.unsafe.*;

// The threads of the native runtime as the collector sees them (once
// hxmc/c/rt_thread.c with rt_gc.h): every Haxe thread is an OS thread
// (pthreads; Windows: its threads, SRW locks and condition variables), and
// threads run in parallel. Each has a record (Mutator) and thread-local
// runtime state (Gc: shadow stack, allocation buffer, exception handlers,
// current exception). The collector stops the world: a thread that needs a
// collection sets rt_gc_requested and waits until every other thread is
// stopped at a safepoint (an allocation slow path) or in a safe region (a
// blocking call between rt_blocking_enter and rt_blocking_leave, which holds
// no heap address outside its shadow-stack slots); it then works on every
// thread's roots and remembered set and resumes them. A thread that stops
// copies the part of its thread-local state the collector reads and writes
// into its record (publish), and takes it back when it runs again (reload):
// while a thread is stopped its record is authoritative. The world lock `wl`
// guards the thread list and the handshake.
//
// The API of hxmc.NativeThread (spawn, park, mutexes, conditions,
// semaphores, thread-local values) is ThreadApi, typed with it.
@:hxmc.native @:keep @:allow(hxmc.rt)
class Threads {
	static inline var RUNNING = 0;
	static inline var SAFE = 1; // in a safe region, or stopped at a safepoint
	public static inline var CSTACK_BYTES:I64 = 64 << 20; // reserved, committed as touched
	public static inline var SSTACK_BYTES:I64 = 64 << 20; // shadow stack (the main thread's is 1 GB, Gc)

	// live Haxe threads; with one, the blocking natives keep their plain
	// blocking calls (nothing else runs): a heuristic, written atomically under wl
	@:hxmc.export("rt_nthreads") static var nthreads:Int;
	// a second thread was ever started: the runtime's leaf locks are taken from then on
	@:hxmc.export("rt_mt") static var mt:Int;
	@:hxmc.export("rt_gc_requested") static var gcRequested:Int;
	// the running thread's record
	@:hxmc.threadLocal("rt_mut") public static var self:Ptr<Mutator>;

	static var wl:Ptr; // the world lock
	// the thread collecting, with the world stopped (a fault there is not a
	// null access of the program's: Faults)
	static var collector:Ptr<Mutator>;
	static var wlStopped:Ptr; // a thread became safe (the collector waits)
	static var wlResumed:Ptr; // a collection ended
	static var allThreads:Ptr<Mutator>; // under wl
	static var byId:Ptr; // under wl
	static var byIdCap:Int;
	static var nextId:Int;
	// the remembered sets of the threads that ended (no stack, no allocation buffer)
	public static var deadMut:Ptr<Mutator>;

	// RT_STATS: threads started, contended mutex acquisitions and their waits,
	// collections and the time from a request until every thread had stopped
	static var thrStats:Bool;
	static var stSpawned:Int;
	static var stContended:Int;
	static var stStw:Int;
	static var stStwMaxUs:Int;
	static var stContendedSecs:Float;
	static var stStwSecs:Float;

	// ---- records

	@:hxmc.noGc static function newRecord():Ptr<Mutator> {
		var m:Ptr<Mutator> = LibC.malloc(Struct.sizeOf(Mutator));
		LibC.memset(m, 0, Struct.sizeOf(Mutator));
		var r = LibC.malloc(8 * 256);
		LibC.memset(r, 0, 8 * 256);
		m.value.recent = r;
		return m;
	}

	@:hxmc.noGc static function newParker():Ptr {
		var p = LibC.malloc(Os.MUTEX_BYTES + Os.COND_BYTES + 8);
		Os.mutexInit(p);
		Os.condInit(p.add(Os.MUTEX_BYTES), true);
		Mem.setI32(p, Os.MUTEX_BYTES + Os.COND_BYTES, 0); // the permit
		return p;
	}

	// from rt_init: the main thread's record (its shadow stack: Gc)
	@:hxmc.noGc static function init(sbase:Ptr) {
		nthreads = 1;
		nextId = 2;
		wl = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(wl);
		wlStopped = LibC.malloc(Os.COND_BYTES);
		Os.condInit(wlStopped, false);
		wlResumed = LibC.malloc(Os.COND_BYTES);
		Os.condInit(wlResumed, false);
		var m = newRecord();
		m.value.id = 1;
		m.value.state = RUNNING;
		m.value.started = 1;
		m.value.pk = newParker();
		m.value.base = sbase;
		deadMut = newRecord();
		allThreads = m;
		byIdCap = 64;
		byId = LibC.malloc(8 * byIdCap);
		LibC.memset(byId, 0, 8 * byIdCap);
		Mem.setPtr(byId, 8, m);
		self = m;
		thrStats = Os.has("RT_STATS");
		if (thrStats) {
			#if hxmc.shared
			if (Mem.target() >= 9) C.__cxa_atexit(Callback.addr(thrReport), Ptr.nil(), Mem.sym("__dso_handle"));
			#else
			if (Mem.target() >= 9) C.__cxa_atexit(Callback.addr(thrReport), Ptr.nil(), Mem.sym("__dso_handle")) else C.atexit(Callback.addr(thrReport));
			#end
		}
	}

	@:hxmc.callback @:hxmc.noGc static function thrReport():Void {
		var r = new Report(Mem.stack(Report.BYTES));
		r.str("threads: ");
		r.int(stSpawned, 0);
		r.str(" started; ");
		r.int(stContended, 0);
		r.str(" contended mutex acquisitions (");
		r.fixed(stContendedSecs, 3, 0);
		r.str("s waiting); ");
		r.int(stStw, 0);
		r.str(" stops of the world, ");
		r.fixed(stStwSecs, 3, 0);
		r.str("s until stopped (max ");
		r.int(stStwMaxUs, 0);
		r.str(" us)\n");
		r.flush();
	}

	// the collector's part of the thread-local state into the record
	@:hxmc.noGc static inline function publish(m:Ptr<Mutator>) {
		m.value.sp = Gc.sp;
		m.value.hw = Gc.hw;
		m.value.exn = Gc.exn;
		m.value.yptr = Gc.yptr;
		m.value.ylim = Gc.ylim;
		m.value.yrlim = Gc.yrlim;
	}

	@:hxmc.noGc static inline function reload(m:Ptr<Mutator>) {
		Gc.sp = m.value.sp;
		Gc.hw = m.value.hw;
		Gc.exn = m.value.exn;
		Gc.yptr = m.value.yptr;
		Gc.ylim = m.value.ylim;
		Gc.yrlim = m.value.yrlim;
	}

	@:hxmc.noGc static inline function stateOf(m:Ptr<Mutator>):Int
		return Atomic.load32(m.add(Struct.offsetOf(Mutator, "state")));

	@:hxmc.noGc static inline function setState(m:Ptr<Mutator>, s:Int):Int
		return Atomic.exchange32(m.add(Struct.offsetOf(Mutator, "state")), s);

	@:hxmc.noGc static inline function requested():Bool
		return Atomic.load32(Mem.sym("rt_gc_requested")) != 0;

	// ---- the handshake

	// under wl, while a collection is requested: safe until it ends (the
	// record is current)
	@:hxmc.noGc static function waitHere() {
		var m = self;
		setState(m, SAFE);
		Os.broadcast(wlStopped);
		while (requested())
			Os.condWait(wlResumed, wl);
		setState(m, RUNNING);
	}

	// under wl, a running thread: stopped until the collection ends
	@:hxmc.noGc static function stopHere() {
		var m = self;
		publish(m);
		waitHere();
		reload(m);
	}

	// Stops every other thread at a safepoint or in a safe region; the
	// caller's own state is published (its record is current until
	// worldResume). False when another thread was collecting meanwhile: the
	// caller waited for it as at a safepoint, and should retry its allocation
	// instead of collecting.
	@:hxmc.noGc static function worldStop():Bool {
		var t0 = thrStats ? Os.now() : 0.0;
		Os.lock(wl);
		if (requested()) {
			stopHere();
			Os.unlock(wl);
			return false;
		}
		Atomic.store32(Mem.sym("rt_gc_requested"), 1);
		var me = self;
		while (true) {
			var all = true;
			var t = allThreads;
			while (!t.isNull()) {
				if (t != me && stateOf(t) == RUNNING) {
					all = false;
					break;
				}
				t = t.value.next;
			}
			if (all) break;
			Os.condWait(wlStopped, wl);
		}
		if (thrStats && !allThreads.value.next.isNull()) {
			var d = Os.now() - t0;
			stStw++;
			stStwSecs += d;
			if (d * 1e6 > stStwMaxUs) stStwMaxUs = Std.int(d * 1e6);
		}
		publish(me);
		collector = me;
		return true; // wl stays held during the collection
	}

	@:hxmc.noGc static function worldResume() {
		collector = Ptr.nil();
		reload(self);
		Atomic.store32(Mem.sym("rt_gc_requested"), 0);
		Os.broadcast(wlResumed);
		Os.unlock(wl);
	}

	// at an allocation slow path: stopped while another thread collects
	@:hxmc.noGc static inline function safepoint() {
		if (Atomic.load32(Mem.sym("rt_gc_requested")) != 0) safepointSlow();
	}

	@:hxmc.noGc static function safepointSlow() {
		Os.lock(wl);
		if (requested()) stopHere();
		Os.unlock(wl);
	}

	// Entering a safe region publishes the thread's state, then makes it safe
	// (seq_cst): a collector that set rt_gc_requested before this thread
	// looked sees it safe, else this thread sees the request and wakes the
	// collector. Both keep errno (natives read it after their blocking call).
	// (Entering again inside a safe region changes nothing.)
	@:hxmc.export("rt_blocking_enter") @:hxmc.noGc static function blockingEnter():Void {
		var m = self;
		if (m.value.state == SAFE) return;
		publish(m);
		setState(m, SAFE);
		if (requested()) {
			var e = Os.errno();
			Os.lock(wl);
			Os.broadcast(wlStopped);
			Os.unlock(wl);
			Os.setErrno(e);
		}
	}

	// Leaving it waits for a collection in progress, then takes the state back
	// (a collection may have moved what it refers to). Outside a safe region
	// (a callback called by a fast C call) it changes nothing.
	@:hxmc.export("rt_blocking_leave") @:hxmc.noGc static function blockingLeave():Void {
		var m = self;
		if (setState(m, RUNNING) == RUNNING) return;
		if (requested()) {
			var e = Os.errno();
			Os.lock(wl);
			if (requested()) waitHere();
			Os.unlock(wl);
			Os.setErrno(e);
		}
		reload(m);
	}

	// Takes a mutex that a thread may hold while it leaves a safe region (and
	// so waits for a collection): a thread blocked on it must be in a safe region.
	@:hxmc.noGc static function lockSafe(m:Ptr) {
		if (Os.tryLock(m)) return;
		Leaf.rt_blocking_enter();
		Os.lock(m);
		Leaf.rt_blocking_leave();
	}

	// waits on c (m held), in a safe region: false when the deadline passed
	@:hxmc.noGc static function condWaitSafe(c:Ptr, m:Ptr, deadline:Ptr):Bool {
		var r = true;
		Leaf.rt_blocking_enter();
		if (deadline.isNull()) Os.condWait(c, m) else r = Os.condTimedWait(c, m, deadline);
		Leaf.rt_blocking_leave();
		return r;
	}

	// ---- thread lifetimes

	// a new thread's first function (the OS's thread entry, t its record):
	// it is safe until its Haxe part leaves the safe region (the wrapper of
	// the @:hxmc.callback run), and safe again when it ends
	@:hxmc.callback @:hxmc.noGc static function entry(t:Ptr):Ptr {
		var m:Ptr<Mutator> = t;
		self = m;
		Gc.hcur = Ptr.nil();
		Os.lock(wl); // no collection runs: the record is the thread's from now on
		m.value.started = 1;
		Os.unlock(wl);
		Ind.call1(Callback.addr(run), t);
		exit(m);
		return Ptr.nil();
	}

	// the thread's job (its entry closure, a root in the record until here)
	@:hxmc.callback static function run(t:Ptr):Void {
		var m:Ptr<Mutator> = t;
		var job:Dynamic = Mem.obj(m.value.job);
		m.value.job = Ptr.nil();
		try {
			job();
		} catch (e:Dynamic) {
			// the hxmc sys.thread.Thread catches everything: only a raw spawn gets here
			Gc.uncaught("Uncaught exception in thread " + m.value.id + ": ", e);
		}
	}

	// a thread's end, in a safe region: it touches no heap object
	@:hxmc.noGc static function exit(m:Ptr<Mutator>) {
		Os.lock(wl);
		if (!m.value.prev.isNull()) m.value.prev.value.next = m.value.next else allThreads = m.value.next;
		if (!m.value.next.isNull()) m.value.next.value.prev = m.value.prev;
		Mem.setPtr(byId, 8 * m.value.id, Ptr.nil());
		// its old-to-young slots stay remembered until the next minor collection
		var d = deadMut;
		if (m.value.remLen > 0) {
			if (d.value.remLen + m.value.remLen > d.value.remCap) {
				d.value.remCap = (d.value.remLen + m.value.remLen) * 2;
				d.value.rem = LibC.realloc(d.value.rem, (d.value.remCap : I64) * 8);
			}
			LibC.memcpy(d.value.rem.add(8 * d.value.remLen), m.value.rem, (m.value.remLen : I64) * 8);
			d.value.remLen = d.value.remLen + m.value.remLen;
		}
		if (m.value.robjsLen > 0) {
			if (d.value.robjsLen + m.value.robjsLen > d.value.robjsCap) {
				d.value.robjsCap = (d.value.robjsLen + m.value.robjsLen) * 2;
				d.value.robjs = LibC.realloc(d.value.robjs, (d.value.robjsCap : I64) * 8);
			}
			LibC.memcpy(d.value.robjs.add(8 * d.value.robjsLen), m.value.robjs, (m.value.robjsLen : I64) * 8);
			d.value.robjsLen = d.value.robjsLen + m.value.robjsLen;
		}
		Atomic.add32(Mem.sym("rt_nthreads"), -1);
		Os.unlock(wl);
		LibC.free(m.value.rem);
		LibC.free(m.value.robjs);
		LibC.free(m.value.recent);
		Names.threadExit();
		Os.release(m.value.sbase, SSTACK_BYTES);
		LibC.free(m);
	}

	// a new thread running job; its id
	@:hxmc.collects static function spawn(job:Dynamic):Int {
		var m = newRecord();
		var sbase = Os.reserve(SSTACK_BYTES);
		if (sbase.isNull()) {
			LibC.free(m.value.recent);
			LibC.free(m);
			Rt.rt_throw("cannot allocate the stacks of a new thread");
			return 0;
		}
		m.value.sbase = sbase;
		m.value.base = sbase;
		m.value.sp = sbase;
		m.value.hw = sbase;
		m.value.state = SAFE;
		m.value.pk = newParker();
		var id = insert(m, job);
		if (!Os.spawn(Callback.addr(entry), m, CSTACK_BYTES)) {
			// never started: taken out again (it is safe, its job a root until now)
			Os.lock(wl);
			if (!m.value.prev.isNull()) m.value.prev.value.next = m.value.next else allThreads = m.value.next;
			if (!m.value.next.isNull()) m.value.next.value.prev = m.value.prev;
			Mem.setPtr(byId, 8 * m.value.id, Ptr.nil());
			Atomic.add32(Mem.sym("rt_nthreads"), -1);
			Os.unlock(wl);
			Os.release(sbase, SSTACK_BYTES);
			LibC.free(m.value.recent);
			LibC.free(m);
			Rt.rt_throw("cannot start a new thread");
		}
		return id;
	}

	// the calling thread, which the runtime did not start (a system's thread
	// that calls Haxe: Android's main thread), made one of its threads: a
	// record and a shadow stack, safe until a @:hxmc.callback's wrapper leaves
	// the safe region (it calls Haxe through such a callback from then on);
	// kept until the process ends. False when it is one already.
	@:hxmc.noGc static function attach():Bool {
		if (!self.isNull()) return false;
		var m = newRecord();
		var sbase = Os.reserve(SSTACK_BYTES);
		if (sbase.isNull()) Gc.dieC(Mem.cstr("cannot allocate the shadow stack of an attached thread\n"));
		m.value.sbase = sbase;
		m.value.base = sbase;
		m.value.sp = sbase;
		m.value.hw = sbase;
		m.value.state = SAFE;
		m.value.pk = newParker();
		insert(m, null);
		self = m;
		Gc.hcur = Ptr.nil();
		Os.lock(wl);
		m.value.started = 1;
		Os.unlock(wl);
		return true;
	}

	// (no safepoint from the call to the insertion: job is a root from then on)
	@:hxmc.noGc static function insert(m:Ptr<Mutator>, job:Dynamic):Int {
		Os.lock(wl);
		m.value.job = Mem.addr(job);
		var id = nextId++;
		m.value.id = id;
		if (id >= byIdCap) {
			var n = byIdCap * 2;
			while (n <= id)
				n *= 2;
			byId = LibC.realloc(byId, (n : I64) * 8);
			LibC.memset(byId.add(8 * byIdCap), 0, ((n - byIdCap) : I64) * 8);
			byIdCap = n;
		}
		Mem.setPtr(byId, 8 * id, m);
		m.value.next = allThreads;
		allThreads.value.prev = m;
		allThreads = m;
		Atomic.add32(Mem.sym("rt_nthreads"), 1);
		stSpawned++;
		mt = 1;
		Os.unlock(wl);
		return id;
	}

	@:hxmc.noGc static function current():Int
		return self.value.id;

	// the record of thread id, or null (under wl)
	@:hxmc.noGc static function byIdGet(id:Int):Ptr<Mutator>
		return id > 0 && id < byIdCap ? Mem.getPtr(byId, 8 * id) : Ptr.nil();

	// ---- waiting for descriptors, sleeping

	@:hxmc.collects static function yield() {
		safepoint();
		Os.yield();
	}

	// lets other runnable threads (and due timers and descriptors) run
	@:hxmc.collects static function preempt()
		safepoint();

	// <= 0: gives way to the other runnable threads
	@:hxmc.host("rt_sleep") @:hxmc.collects static function sleep(seconds:Float):Void {
		if (seconds <= 0) {
			yield();
			return;
		}
		sleepSafe(seconds);
	}

	@:hxmc.noGc static function sleepSafe(seconds:Float) {
		Leaf.rt_blocking_enter();
		Os.sleep(seconds);
		Leaf.rt_blocking_leave();
	}

	// per descriptor (below FD_GENS): incremented by rt_fd_closed; a thread
	// waiting for a descriptor looks at it every POLL_SLICE seconds, so a close
	// by another thread makes its wait fail (EBADF)
	static inline var FD_GENS = 4096;
	static inline var POLL_SLICE = 0.1;

	@:hxmc.bss(16384) static var fdGens:Ptr;

	@:hxmc.noGc static inline function fdGen(fd:Int):Int
		return fd >= 0 && fd < FD_GENS ? Atomic.load32(fdGens.add(4 * fd)) : 0;

	// before close(fd): waiters on fd fail instead of polling a reused number
	@:hxmc.host("rt_fd_closed") @:hxmc.noGc static function fdClosed(fd:Int):Void
		if (fd >= 0 && fd < FD_GENS) Atomic.add32(fdGens.add(4 * fd), 1);

	// waits for any of n struct pollfd (revents set), letting other threads
	// run: 1 ready, 0 timeout (seconds; < 0: none), -1 a descriptor was closed meanwhile
	@:hxmc.host("rt_wait_fds") @:hxmc.collects static function waitFds(fds:Ptr, n:Int, timeout:Float):Int
		return waitFdsSafe(fds, n, timeout);

	@:hxmc.noGc static function waitFdsSafe(fds:Ptr, n:Int, timeout:Float):Int {
		var size = L.POLLFD_SIZE, rev = L.POLLFD_REVENTS;
		for (i in 0...n)
			Mem.setI16(fds, size * i + rev, 0);
		var r = Os.poll(fds, n, 0);
		if (r != 0 || timeout == 0) return r != 0 ? 1 : 0; // a poll failure: let the caller's own call report it
		var gensBuf = Mem.stack(32);
		var gens = n <= 8 ? gensBuf : LibC.malloc((n : I64) * 4);
		for (i in 0...n)
			Mem.setI32(gens, 4 * i, fdGen(Mem.getI32(fds, size * i)));
		var deadline = timeout < 0 ? -1.0 : Os.now() + timeout;
		var result = 0, closed = false;
		Leaf.rt_blocking_enter();
		while (true) {
			var slice = POLL_SLICE;
			if (deadline >= 0) {
				var left = deadline - Os.now();
				if (left <= 0) break;
				if (left < slice) slice = left;
			}
			r = Os.poll(fds, n, Std.int(slice * 1000.0 + 0.999));
			for (i in 0...n)
				if (fdGen(Mem.getI32(fds, size * i)) != Mem.getI32(gens, 4 * i)) closed = true;
			if (closed) break;
			if (r != 0 && (r > 0 || Os.errno() != L.EINTR)) {
				result = 1;
				break;
			}
		}
		Leaf.rt_blocking_leave();
		if (gens != gensBuf) LibC.free(gens);
		if (closed) {
			Os.setErrno(L.EBADF);
			return -1;
		}
		return result;
	}

	// waits until fd is readable (write 0) or writable (write 1)
	@:hxmc.host("rt_wait_fd") @:hxmc.collects static function waitFd(fd:Int, write:Int, timeout:Float):Int {
		var p = Mem.stack(16);
		LibC.memset(p, 0, 16);
		Mem.setI32(p, 0, fd);
		Mem.setI16(p, L.POLLFD_EVENTS, write != 0 ? L.POLLOUT : L.POLLIN);
		return waitFdsSafe(p, 1, timeout);
	}
}

// A thread's record (rt_thread and rt_mutator in C): malloc'ed, freed when
// the thread ends (parkers never are: an unpark may find one after its
// thread ended).
@:hxmc.struct @:publicFields class Mutator {
	// the thread-local state the collector reads and writes, while the
	// thread is stopped (Threads.publish)
	var sp:Ptr;
	var hw:Ptr;
	var exn:Ptr; // the current exception (a root)
	var yptr:Ptr;
	var ylim:Ptr;
	var yrlim:Ptr;
	var base:Ptr; // the shadow stack's bottom
	// the remembered set: slots of old objects that may hold young pointers,
	// and old objects scanned whole (rt_barrier_range of long ranges), with a
	// cache of the 256 recent ones
	var rem:Ptr;
	var remLen:Int;
	var remCap:Int;
	var robjs:Ptr;
	var robjsLen:Int;
	var robjsCap:Int;
	var recent:Ptr;
	var next:Ptr<Mutator>; // the live threads (under wl)
	var prev:Ptr<Mutator>;
	var id:Int;
	var state:Int; // atomic
	var started:Int; // the thread runs its own code (under wl)
	var job:Ptr; // the entry closure until the thread starts (a root)
	var tls:Ptr; // Tls values (a root)
	var sbase:Ptr; // the shadow stack's reservation (the main thread's is Gc's)
	var pk:Ptr; // park/unpark: a mutex, a condition, the permit
}

@:hxmc.c @:hxmc.fast private extern class C {
	static function atexit(f:Ptr):Int;
	static function __cxa_atexit(f:Ptr, arg:Ptr, dso:Ptr):Int;
}

// a call through a C function pointer (the @:hxmc.callback run: its
// wrapper leaves the thread's safe region first)
@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
}
