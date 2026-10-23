package hxmc;

import haxe.io.BytesData;
import haxe.io.Encoding;

// The runtime's functions over haxe.io.BytesData (NativeArray storage of
// bytes, hxmc.rt.Bytes; under -D hxmc.wasm-gc some are instructions,
// hxmc.wasmgc.FuncGen), which haxe.io.Bytes wraps: out of bounds, the ones
// taking a range throw "OutsideBounds"; the accessors of a position do not
// test it (as haxe.io.Bytes.get).
extern class NativeBytes {
	static function blit(b:BytesData, pos:Int, src:BytesData, srcpos:Int, len:Int):Void;
	static function fill(b:BytesData, pos:Int, len:Int, value:Int):Void;
	static function sub(b:BytesData, pos:Int, len:Int):BytesData;
	// the difference of the first differing bytes, else of the lengths
	static function compare(a:BytesData, b:BytesData):Int;
	static function getDouble(b:BytesData, pos:Int):Float;
	static function getFloat(b:BytesData, pos:Int):Float;
	static function setDouble(b:BytesData, pos:Int, v:Float):Void;
	static function setFloat(b:BytesData, pos:Int, v:Float):Void;
	static function getUInt16(b:BytesData, pos:Int):Int;
	static function setUInt16(b:BytesData, pos:Int, v:Int):Void;
	static function getInt32(b:BytesData, pos:Int):Int;
	static function setInt32(b:BytesData, pos:Int, v:Int):Void;
	static function getString(b:BytesData, pos:Int, len:Int, encoding:Null<Encoding>):String;
	static function toHex(b:BytesData):String;
	static function ofString(s:String, encoding:Null<Encoding>):BytesData;
	static function ofHex(s:String):BytesData;
}
