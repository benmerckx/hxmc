// A @:hxmc.noGc function that reads a runtime method's receiver (Bytes.length,
// as hxmc.dev.Hot.sendWeb does): with the explicit null tests (WebAssembly's
// default, -D hxmc.null-checks) it gets none, as the runtime's own code: a
// test throws, and a throw is a GC point, which @:hxmc.noGc rules out
class NullAccessNoGc {
	@:hxmc.noGc static function size(b:haxe.io.Bytes):Int
		return b.length;

	@:hxmc.noGc static function first(s:String):Int
		return StringTools.fastCodeAt(s, 0);

	static function main() {
		Sys.println(size(haxe.io.Bytes.alloc(3)));
		Sys.println(first("A"));
	}
}
