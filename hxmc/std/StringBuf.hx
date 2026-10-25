// hxmc: haxe/upstream/std/eval/_std/StringBuf.hx (an extern), a growable UTF-16 buffer in
// the runtime (hxmc.rt.Str)

extern class StringBuf {
	var length(get, never):Int;
	function new():Void;
	private function get_length():Int;
	function add<T>(x:T):Void;
	function addChar(c:Int):Void;
	function addSub(s:String, pos:Int, ?len:Int):Void;
	// (haxe.format.JsonPrinter's: s quoted, hxmc.rt.Str.sbAddJson)
	@:noCompletion function addJsonString(s:String):Void;
	function clear():Void;
	function toString():String;
}
