// @:hxmc.noGc, @:hxmc.unsafe's former name, is an error rather than ignored.
// expect: UnsafeFormerName.leaf: @:hxmc.noGc is now @:hxmc.unsafe
class UnsafeFormerName {
	@:hxmc.noGc static function leaf(n:Int):Int
		return n + 1;

	static function main()
		trace(leaf(1));
}
