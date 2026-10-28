// @:hxmc.gcfree is checked as @:hxmc.unsafe is: no allocation, no GC point, the chain of calls named.
// expect: GcFreeAlloc.hx:11: GcFreeAlloc.leaf is declared @:hxmc.gcfree but reaches a GC point: it calls GcFreeAlloc.helper, which allocates an array
class GcFreeAlloc {
	static var keep:Array<Int>;

	static function helper(n:Int):Int {
		keep = [n];
		return n;
	}

	@:hxmc.unsafe @:hxmc.gcfree static function leaf(n:Int):Int
		return helper(n) + 1;

	static function main()
		trace(leaf(1));
}
