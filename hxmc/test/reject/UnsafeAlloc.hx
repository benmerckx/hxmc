// @:hxmc.unsafe is a checked rule: the chain of calls to the first GC point is named.
// expect: UnsafeAlloc.hx:11: UnsafeAlloc.leaf is declared @:hxmc.unsafe but reaches a GC point: it calls UnsafeAlloc.helper, which allocates an array
class UnsafeAlloc {
	static var keep:Array<Int>;

	static function helper(n:Int):Int {
		keep = [n];
		return n;
	}

	@:hxmc.unsafe static function leaf(n:Int):Int
		return helper(n) + 1;

	static function main()
		trace(leaf(1));
}
