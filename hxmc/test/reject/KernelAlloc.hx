// @:hxmc.kernel is checked as @:hxmc.unsafe is: no allocation, no GC point, the chain of calls named.
// expect: KernelAlloc.hx:11: KernelAlloc.leaf is declared @:hxmc.kernel but reaches a GC point: it calls KernelAlloc.helper, which allocates an array
class KernelAlloc {
	static var keep:Array<Int>;

	static function helper(n:Int):Int {
		keep = [n];
		return n;
	}

	@:hxmc.unsafe @:hxmc.kernel static function leaf(n:Int):Int
		return helper(n) + 1;

	static function main()
		trace(leaf(1));
}
