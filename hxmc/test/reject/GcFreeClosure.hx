// No closure in GC-free code: making one allocates.
// expect: GcFreeClosure.hx:7: GcFreeClosure.make: the local g is a function (gcfree: no closures)
class GcFreeClosure {
	@:hxmc.gcfree static function make(v:Int):Int {
		var x = v + 1;
		var y = x * 2;
		var g = function(z:Int) return z + v;
		return y;
	}

	static function main()
		trace(make(2));
}
