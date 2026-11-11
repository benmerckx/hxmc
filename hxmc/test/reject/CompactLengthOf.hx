// @:hxmc.lengthOf reads its NativeArray field's 8-byte slot: not a compressed
// reference's.
// expect: @:hxmc.lengthOf("data") on Buf.length: data is a compressed reference (@:hxmc.compact)
@:hxmc.compact
class Buf {
	public var data:hxmc.NativeArray<Int>;
	@:hxmc.lengthOf("data") public var length(get, never):Int;

	function get_length()
		return data.length;

	public function new()
		data = new hxmc.NativeArray(3);
}

class CompactLengthOf {
	static function main()
		trace(new Buf().length);
}
