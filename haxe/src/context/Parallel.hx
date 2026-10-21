package context;

import core.Timer;
import core.ds.TaskPool;
import sys.thread.Mutex;

// port: core.ds.TaskPool stands in for Domainslib.Task.pool and isolates host threading differences.
@:structInit class ManagedPoolData {
	public var setup:Void->TaskPool;
	public var pool:Null<TaskPool>;
	public var mutex:Mutex;

	public inline function new(setup:Void->TaskPool, pool:Null<TaskPool>, mutex:Mutex) {
		this.setup = setup;
		this.pool = pool;
		this.mutex = mutex;
	}

	public inline function clone():ManagedPoolData return new ManagedPoolData(setup, pool, mutex);
}

class Parallel {
	public static var enable = true;

	public static function runParallelFor(numDomains:Int, length:Int, f:Int->Void, chunkSize:Int = 0):Void {
		if (!enable) {
			for (i in 0...length) f(i);
			return;
		}
		var pool = new TaskPool(numDomains - 1);
		pool.run(function() pool.parallelFor(0, length - 1, f, chunkSize));
		pool.close();
	}

	public static function runInNewPool<A>(timerCtx:core.Timer.TimerContext, f:Null<TaskPool>->A):A {
		if (!enable) return f(null);
		var pool = Timer.time(timerCtx, ["domainslib", "setup"], function(_) return new TaskPool(TaskPool.recommendedDomainCount() - 1),
			null);
		inline function cleanup():Void Timer.time(timerCtx, ["domainslib", "teardown"], function(_) {
			pool.close();
			return null;
		}, null);
		var result:A;
		try result = pool.run(function() return f(pool))
		catch (e:haxe.Exception) {
			cleanup();
			throw e;
		}
		cleanup();
		return result;
	}

	public static function runWithPool<A>(mp:ManagedPoolData, f:Null<TaskPool>->A):A {
		if (!enable) return f(null);
		var pool = ManagedPool.acquire(mp);
		return pool.run(function() return f(pool));
	}
}

class ParallelArray {
	public static function iter<A>(pool:Null<TaskPool>, f:A->Void, a:Array<A>):Void {
		if (pool == null) for (value in a) f(value);
		else pool.parallelFor(0, a.length - 1, function(i) f(a[i]));
	}

	// port: inline, the output (upstream's `Array.make length x`) a Vector of the caller's element type
	public static inline function map<A, B>(pool:Null<TaskPool>, f:A->B, a:Array<A>, x:B):haxe.ds.Vector<B> {
		var output = new haxe.ds.Vector<B>(a.length, x);
		if (pool == null) for (i in 0...a.length) output[i] = f(a[i]);
		else pool.parallelFor(0, a.length - 1, function(i) output[i] = f(a[i]));
		return output;
	}
}

class ParallelSeq {
	public static function iter<A>(pool:Null<TaskPool>, f:A->Void, seq:Iterator<A>):Void ParallelArray.iter(pool, f, [for (a in seq) a]);
}

// A pool that can be acquired on demand and released when idle.
// Unlike AtomicLazy, supports teardown and re-creation so that
// domain workers don't stay alive during phases that don't need them
// (e.g. eval interpretation).
class ManagedPool {
	public static function create(setup:Void->TaskPool):ManagedPoolData return {setup: setup, pool: null, mutex: new Mutex()};

	static function protect<A>(mp:ManagedPoolData, f:Void->A):A {
		mp.mutex.acquire();
		var result:A;
		try result = f()
		catch (e:haxe.Exception) {
			mp.mutex.release();
			throw e;
		}
		mp.mutex.release();
		return result;
	}

	public static function acquire(mp:ManagedPoolData):TaskPool return protect(mp, function() {
		if (mp.pool == null) mp.pool = mp.setup();
		return mp.pool;
	});

	public static function release(mp:ManagedPoolData):Void protect(mp, function() {
		if (mp.pool != null) {
			mp.pool.close();
			mp.pool = null;
		}
		return null;
	});

	public static function isActive(mp:ManagedPoolData):Bool return protect(mp, function() return mp.pool != null);
}
