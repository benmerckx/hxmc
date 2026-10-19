package ml2hx.prim;

import ml2hx.rt.*;

// OCaml's extern.c and intern.c (Marshal, output_value, input_value) need
// the static types of the values to rebuild them as Haxe values, which the
// runtime does not have: marshalling is not supported (README, gaps).
class Runtime {
	static function unsupported<T>(what:String):T throw new Failure('$what: marshalling is not supported by ml2hx');
	public static function camlOutputValue<T>(oc:Io.OutChannel, v:T, flags:Dynamic):Unit return unsupported("output_value");
	public static function camlOutputValueToBytes<T>(v:T, flags:Dynamic):haxe.io.Bytes return unsupported("Marshal.to_bytes");
	public static function camlOutputValueToString<T>(v:T, flags:Dynamic):String return unsupported("Marshal.to_string");
	public static function camlOutputValueToBuffer<T>(b:haxe.io.Bytes, ofs:Int63, len:Int63, v:T, flags:Dynamic):Int63 return unsupported("Marshal.to_buffer");
	public static function camlInputValue<T>(ic:Io.InChannel):T return unsupported("input_value");
	public static function camlInputValueFromBytes<T>(b:haxe.io.Bytes, ofs:Int63):T return unsupported("Marshal.from_bytes");
	public static function camlMarshalDataSize(b:haxe.io.Bytes, ofs:Int63):Int63 return unsupported("Marshal.data_size");
}
