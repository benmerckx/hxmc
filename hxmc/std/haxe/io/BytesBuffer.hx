// hxmc: haxe/upstream/std/eval/_std/haxe/io/BytesBuffer.hx (an extern), a growable byte
// buffer in the runtime (hxmc.rt.Bytes), over BytesData: a Bytes added is its
// data, the result is wrapped

package haxe.io;

extern class BytesBuffer {
	var length(get, never):Int;
	function new():Void;
	private function get_length():Int;
	function addByte(byte:Int):Void;
	inline function add(src:Bytes):Void
		addData(src.getData(), 0, src.length);
	function addString(v:String, ?encoding:Encoding):Void;
	function addInt32(v:Int):Void;
	inline function addInt64(v:haxe.Int64):Void {
		addInt32(v.low);
		addInt32(v.high);
	}
	function addFloat(v:Float):Void;
	function addDouble(v:Float):Void;
	inline function addBytes(src:Bytes, pos:Int, len:Int):Void
		addData(src.getData(), pos, len);
	inline function getBytes():Bytes
		return Bytes.ofData(getData());
	// (src's bytes [pos, pos + len), else "OutsideBounds")
	private function addData(src:BytesData, pos:Int, len:Int):Void;
	// (a copy of the bytes added)
	private function getData():BytesData;
}
