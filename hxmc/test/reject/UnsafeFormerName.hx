// @:hxmc.noGc, @:hxmc.unsafe's former name, is still accepted and checked as it.
// expect: UnsafeFormerName.hx:9: UnsafeFormerName.leaf is declared @:hxmc.unsafe but reaches a GC point: it allocates an array
class UnsafeFormerName {
	static var keep:Array<Int>;

	@:hxmc.noGc static function ok(n:Int):Int
		return n * 2;

	@:hxmc.noGc static function leaf(n:Int):Int {
		keep = [n];
		return n;
	}

	static function main() {
		trace(ok(1) + leaf(2));
	}
}
