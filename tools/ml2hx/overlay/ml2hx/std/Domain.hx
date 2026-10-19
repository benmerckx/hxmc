package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Stdlib.Domain on one domain: spawn runs the function to completion.
class DomainT<T> {
	public final result:T;
	public function new(r:T) result = r;
}

typedef DomainId = Int63;

class Domain {
	public static function spawn<T>(f:Unit->T):DomainT<T> return new DomainT(f(Unit.value));
	public static function join<T>(d:DomainT<T>):T return d.result;
	public static function self(_:Unit):DomainId return Int63.zero;
	public static function recommendedDomainCount(_:Unit):Int63 return Int63.one;
	public static function isMainDomain(_:Unit):Bool return true;
	public static inline function cpuRelax(_:Unit):Unit return Unit.value;
}
