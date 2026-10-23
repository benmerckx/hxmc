package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Threads.Mutator;
import hxmc.rt.C;
import hxmc.rt.Os.Report;
import hxmc.unsafe.*;

// hxmc.NativeThread on the native targets (once the API half of
// hxmc/c/rt_thread.c): threads, park/unpark, re-entrant mutexes, condition
// variables, counting semaphores and thread-local values over Threads and
// Os. The synchronization objects are malloc'ed OS structures behind native
// handles (Gc.nativeNew: freed by the collector); their mutexes are taken
// with Threads.lockSafe (a holder may wait for a collection when it leaves a
// wait), waits are safe regions, and a handle stays rooted while its thread
// waits (the collector could otherwise free it under the wait). Typed with
// hxmc.NativeThread, for the programs that use threads.
class ThreadApi {
	// a mutex: the OS mutex, the owner's record (atomic: compared with the
	// running thread's without the lock), the depth
	static inline function owner(m:Ptr):Ptr
		return Ptr.ofI64(Atomic.load64(m.add(Os.MUTEX_BYTES)));

	static inline function setOwner(m:Ptr, t:Ptr)
		Atomic.store64(m.add(Os.MUTEX_BYTES), t.toI64());

	static inline function depthAt(m:Ptr):Ptr
		return m.add(Os.MUTEX_BYTES + 8);

	// a handle's C resource (slot 0)
	@:hxmc.noGc static inline function res(o:Dynamic):Ptr
		return Mem.getPtr(Mem.addr(o), 0);

	// a new thread running job (a `() -> Void`)
	public static function spawn(job:Dynamic):Int
		return Threads.spawn(job);

	// the calling thread, started by someone else (a system's thread calling
	// Haxe through @:hxmc.callback functions), made a Haxe thread; call it
	// before its first such call (from no-GC code): false when it is one already
	@:hxmc.noGc public static function attach():Bool
		return Threads.attach();

	@:hxmc.noGc public static inline function current():Int
		return Threads.current();

	// live threads
	@:hxmc.noGc public static function count():Int
		return Atomic.load32(Mem.sym("rt_nthreads"));

	// threads run in parallel (1:1 build)
	@:hxmc.noGc public static function parallel():Bool
		return true;

	@:hxmc.collects public static function yield():Void
		Threads.yield();

	// ---- park/unpark: the thread's parker (a mutex, a condition, the permit)

	// blocks until unparked (true) or timeout seconds pass (false); timeout <
	// 0: no timeout. An unpark of a thread that is not parked makes its next
	// park return at once.
	@:hxmc.collects public static function park(timeout:Float):Bool
		return parkSafe(timeout);

	@:hxmc.noGc static function parkSafe(timeout:Float):Bool {
		var p = Threads.self.value.pk;
		var c = p.add(Os.MUTEX_BYTES), permit = p.add(Os.MUTEX_BYTES + Os.COND_BYTES);
		var ts = Ptr.nil();
		if (timeout >= 0) {
			ts = Mem.stack(16);
			Os.deadline(ts, timeout);
		}
		Threads.lockSafe(p);
		var woken = true;
		while (Mem.getI32(permit, 0) == 0) {
			if (!Threads.condWaitSafe(c, p, ts)) {
				woken = Mem.getI32(permit, 0) != 0;
				break;
			}
		}
		Mem.setI32(permit, 0, 0);
		Os.unlock(p);
		return woken;
	}

	@:hxmc.collects public static function unpark(id:Int):Void
		unparkSafe(id);

	@:hxmc.noGc static function unparkSafe(id:Int) {
		Os.lock(Threads.wl);
		var t = Threads.byIdGet(id);
		var p = t.isNull() ? Ptr.nil() : t.value.pk;
		Os.unlock(Threads.wl);
		if (p.isNull()) return;
		Threads.lockSafe(p);
		Mem.setI32(p, Os.MUTEX_BYTES + Os.COND_BYTES, 1);
		Os.signal(p.add(Os.MUTEX_BYTES));
		Os.unlock(p);
	}

	// ---- mutexes

	@:hxmc.callback @:hxmc.noGc static function freeMutex(p:Ptr):Void {
		Os.mutexDestroy(p);
		LibC.free(p);
	}

	public static function mutexNew():Dynamic {
		var m = LibC.malloc(Os.MUTEX_BYTES + 16);
		LibC.memset(m, 0, Os.MUTEX_BYTES + 16);
		Os.mutexInit(m);
		return Gc.nativeNew(m, Callback.addr(freeMutex), 0);
	}

	@:hxmc.collects public static function mutexAcquire(mo:Dynamic):Void {
		var m = res(mo);
		var me:Ptr = Threads.self;
		if (owner(m) == me) {
			Mem.setI32(depthAt(m), 0, Mem.getI32(depthAt(m), 0) + 1);
			return;
		}
		if (!Os.tryLock(m)) {
			var root = Gc.pushRoot(mo); // the handle stays alive while this thread waits
			lockContended(m);
			Gc.popRoots(root);
		}
		setOwner(m, me);
		Mem.setI32(depthAt(m), 0, 1);
	}

	@:hxmc.noGc static function lockContended(m:Ptr) {
		var t0 = Threads.thrStats ? Os.now() : 0.0;
		Leaf.rt_blocking_enter();
		Os.lock(m);
		Leaf.rt_blocking_leave();
		if (Threads.thrStats) {
			// (approximate across mutexes)
			Threads.stContended++;
			Threads.stContendedSecs += Os.now() - t0;
		}
	}

	@:hxmc.noGc public static function mutexTryAcquire(mo:Dynamic):Bool {
		var m = res(mo);
		var me:Ptr = Threads.self;
		if (owner(m) == me) {
			Mem.setI32(depthAt(m), 0, Mem.getI32(depthAt(m), 0) + 1);
			return true;
		}
		if (!Os.tryLock(m)) return false;
		setOwner(m, me);
		Mem.setI32(depthAt(m), 0, 1);
		return true;
	}

	// (ignored unless the calling thread holds it)
	@:hxmc.noGc public static function mutexRelease(mo:Dynamic):Void {
		var m = res(mo);
		if (owner(m) != (Threads.self : Ptr)) return;
		var d = Mem.getI32(depthAt(m), 0) - 1;
		Mem.setI32(depthAt(m), 0, d);
		if (d > 0) return;
		setOwner(m, Ptr.nil());
		Os.unlock(m);
	}

	// ---- condition variables

	@:hxmc.callback @:hxmc.noGc static function freeCond(p:Ptr):Void {
		Os.condDestroy(p);
		LibC.free(p);
	}

	public static function condNew():Dynamic {
		var c = LibC.malloc(Os.COND_BYTES);
		Os.condInit(c, true);
		return Gc.nativeNew(c, Callback.addr(freeCond), 0);
	}

	// waits for a signal (true) or until timeout seconds pass (false; < 0: no
	// timeout); the calling thread holds mutex mo, which is released meanwhile
	// (fully) and taken back at the same depth. May wake spuriously (as
	// pthread conditions).
	@:hxmc.collects public static function condWait(co:Dynamic, mo:Dynamic, timeout:Float):Bool {
		var c = res(co), m = res(mo);
		var me:Ptr = Threads.self;
		if (owner(m) != me) Rt.rt_throw("Condition.wait: the mutex is not held");
		var ts = Mem.stack(16);
		if (timeout >= 0) Os.deadline(ts, timeout);
		var root = Gc.pushRoot(co);
		Gc.pushRoot(mo);
		var depth = Mem.getI32(depthAt(m), 0);
		setOwner(m, Ptr.nil());
		var r = Threads.condWaitSafe(c, m, timeout >= 0 ? ts : Ptr.nil());
		setOwner(m, me);
		Mem.setI32(depthAt(m), 0, depth);
		Gc.popRoots(root);
		return r;
	}

	@:hxmc.noGc public static function condSignal(co:Dynamic):Void
		Os.signal(res(co));

	@:hxmc.noGc public static function condBroadcast(co:Dynamic):Void
		Os.broadcast(res(co));

	// ---- counting semaphores: a mutex, a condition, the count

	@:hxmc.callback @:hxmc.noGc static function freeSem(p:Ptr):Void {
		Os.mutexDestroy(p);
		Os.condDestroy(p.add(Os.MUTEX_BYTES));
		LibC.free(p);
	}

	public static function semNew(value:Int):Dynamic {
		var s = LibC.malloc(Os.MUTEX_BYTES + Os.COND_BYTES + 8);
		Os.mutexInit(s);
		Os.condInit(s.add(Os.MUTEX_BYTES), true);
		Mem.setI32(s, Os.MUTEX_BYTES + Os.COND_BYTES, value);
		return Gc.nativeNew(s, Callback.addr(freeSem), 0);
	}

	// takes a unit (true), or times out (false) after timeout seconds (0: just try; < 0: no timeout)
	@:hxmc.collects public static function semAcquire(so:Dynamic, timeout:Float):Bool {
		var s = res(so);
		var root = Gc.pushRoot(so);
		var r = semAcquireSafe(s, timeout);
		Gc.popRoots(root);
		return r;
	}

	@:hxmc.noGc static function semAcquireSafe(s:Ptr, timeout:Float):Bool {
		var c = s.add(Os.MUTEX_BYTES), count = s.add(Os.MUTEX_BYTES + Os.COND_BYTES);
		var ts = Ptr.nil();
		if (timeout > 0) {
			ts = Mem.stack(16);
			Os.deadline(ts, timeout);
		}
		Threads.lockSafe(s);
		var r = true;
		while (Mem.getI32(count, 0) == 0) {
			if (timeout == 0 || !Threads.condWaitSafe(c, s, ts)) {
				r = Mem.getI32(count, 0) > 0;
				break;
			}
		}
		if (r) Mem.setI32(count, 0, Mem.getI32(count, 0) - 1);
		Os.unlock(s);
		return r;
	}

	@:hxmc.collects public static function semRelease(so:Dynamic):Void {
		var s = res(so);
		var root = Gc.pushRoot(so);
		Threads.lockSafe(s);
		Mem.setI32(s, Os.MUTEX_BYTES + Os.COND_BYTES, Mem.getI32(s, Os.MUTEX_BYTES + Os.COND_BYTES) + 1);
		Os.signal(s.add(Os.MUTEX_BYTES));
		Os.unlock(s);
		Gc.popRoots(root);
	}

	// ---- thread-local values (sys.thread.Tls): per thread, a K_PARR object
	// indexed by Tls id (a root of the thread's record)

	@:hxmc.bss(8) static var tlsNext:Ptr;

	@:hxmc.noGc public static function tlsNew():Int
		return Atomic.add32(tlsNext, 1);

	@:hxmc.noGc public static function tlsGet(id:Int):Dynamic {
		var a = Threads.self.value.tls;
		return !a.isNull() && id >= 0 && id < Mem.getI32(a, -4) ? Mem.getRef(a, 8 * id) : null;
	}

	public static function tlsSet(id:Int, v:Dynamic):Void {
		if (id < 0) return;
		var a = Threads.self.value.tls;
		if (a.isNull() || id >= Mem.getI32(a, -4)) {
			var n = a.isNull() ? 8 : Mem.getI32(a, -4) * 2;
			if (n <= id) n = id + 1;
			var na:Dynamic = Mem.alloc(n, Types.T_ADATA_P, Types.K_PARR);
			grow(na);
		}
		Mem.setRefBarrier(Mem.obj(Threads.self.value.tls), 8 * id, v);
	}

	// (after the allocation: the old values, read again, into the new array)
	@:hxmc.noGc static function grow(na:Dynamic) {
		var a = Threads.self.value.tls;
		if (!a.isNull())
			for (i in 0...Mem.getI32(a, -4))
				Mem.setRefBarrier(na, 8 * i, Mem.getRef(a, 8 * i));
		Threads.self.value.tls = Mem.addr(na);
	}
}
