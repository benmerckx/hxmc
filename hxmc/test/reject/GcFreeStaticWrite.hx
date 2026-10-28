// GC-free code reads statics but does not write them (two jobs writing one), also a struct static's field.
// expect: GcFreeStaticWrite.hx:15: GcFreeStaticWrite.count: a write of the static calls (gcfree: statics are read-only in GC-free code)
// expect: GcFreeStaticWrite.hx:16: GcFreeStaticWrite.count: a write of the static last (gcfree: statics are read-only in GC-free code)
@:hxmc.struct @:publicFields class Pair {
	var a:Int;
	var b:Int;
}

class GcFreeStaticWrite {
	static var calls = 0;
	static var last:Pair;
	static final LIMIT = 10;

	@:hxmc.gcfree static function count(v:Int):Int {
		calls++;
		last.a = v;
		return v < LIMIT ? v : LIMIT;
	}

	static function main()
		trace(count(3));
}
