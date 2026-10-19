package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Domainslib.Task on one domain: a pool runs tasks to completion in the
// calling thread, in order (parallel_for runs start..finish ascending).
class DomainslibTaskPool {
	public var live = true;
	public final name:Null<String>;
	public function new(name:Null<String>) this.name = name;
}

class DomainslibTaskPromise<T> {
	public final result:T;
	public function new(r:T) result = r;
}

class Domainslib__Task {
	public static function setupPool(numDomains:Int63, _:Unit, ?name:String):DomainslibTaskPool {
		if (Int63.lt(numDomains, Int63.zero)) throw new InvalidArgument("Task.setup_pool: num_domains must be at least 0");
		return new DomainslibTaskPool(name);
	}
	public static function teardownPool(pool:DomainslibTaskPool):Unit {
		pool.live = false;
		return Unit.value;
	}
	static function check(pool:DomainslibTaskPool) {
		if (!pool.live) throw new InvalidArgument("pool already torn down");
	}
	public static function run<T>(pool:DomainslibTaskPool, f:Unit->T):T {
		check(pool);
		return f(Unit.value);
	}
	public static function async<T>(pool:DomainslibTaskPool, f:Unit->T):DomainslibTaskPromise<T> {
		check(pool);
		return new DomainslibTaskPromise(f(Unit.value));
	}
	public static function await<T>(pool:DomainslibTaskPool, p:DomainslibTaskPromise<T>):T return p.result;
	public static function parallelFor(start:Int63, finish:Int63, body:Int63->Unit, pool:DomainslibTaskPool, ?chunkSize:Int63):Unit {
		check(pool);
		if (chunkSize != null && Int63.lt(chunkSize, Int63.one)) throw new InvalidArgument("Task.parallel_for: chunk_size must be at least 1");
		var i = start;
		while (Int63.le(i, finish)) {
			body(i);
			i = Int63.add(i, Int63.one);
		}
		return Unit.value;
	}
}
