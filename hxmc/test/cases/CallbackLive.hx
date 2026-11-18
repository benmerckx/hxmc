import hxmc.unsafe.*;

// not-live: Viewer.open Viewer.started Viewer.idle Server.new Server.serve
// A @:hxmc.callback is live only where live code takes its address. Viewer
// is never made (only tested for), so its `open`, which takes its callbacks'
// addresses, is dead, and so are they (`started` through its wrapper, `idle`
// @:hxmc.unsafe: the function itself) and Server, which only they use: a web
// view's callbacks kept the loopback server behind it in an app that made no
// web view. `twice` and `add`, whose addresses main takes, are called back
// through C function pointers.
@:hxmc.c extern class Through {
	@:hxmc.indirect static function call(f:Ptr, a:Int, b:Int):Int;
}

class Server {
	public var port:Int;

	public function new(port:Int)
		this.port = port;

	public function serve():String
		return "serving on " + port;
}

class View {
	public function new() {}

	public function open():Int
		return 0;
}

class Viewer extends View {
	override public function open():Int
		return Through.call(Callback.addr(started), 1, 2) + Through.call(Callback.addr(idle), 3, 1);

	@:hxmc.callback static function started(a:Int, b:Int):Int
		return new Server(a + b).serve().length;

	@:hxmc.callback @:hxmc.unsafe static function idle(a:Int, b:Int):Int
		return a - b;
}

class CallbackLive {
	static var calls:Array<String> = [];

	static function main() {
		Sys.println(Through.call(Callback.addr(twice), 20, 1));
		Sys.println(Through.call(Callback.addr(add), 40, 2));
		Sys.println(calls.join(","));
		var v = new View();
		Sys.println(v.open());
		Sys.println(Std.isOfType(v, Viewer));
	}

	@:hxmc.callback static function twice(a:Int, b:Int):Int {
		calls.push("twice " + a);
		return a * 2 + b;
	}

	@:hxmc.callback @:hxmc.unsafe static function add(a:Int, b:Int):Int
		return a + b;
}
