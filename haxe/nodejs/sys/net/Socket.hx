package sys.net;

// Stand-in for the Node.js compiler build (see Host.hx): hxnodejs' Socket lacks most
// of the sys.net.Socket API the compilation server uses, and Node sockets are
// asynchronous. The server is haxe/nodejs/NodeServer.hx, on Node's net.
class Socket {
	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	public function new():Void unsupported();

	static function unsupported():Dynamic throw "sys.net.Socket is not supported by the JS build of haxe-in-haxe";

	public function close():Void unsupported();

	public function read():String return unsupported();

	public function write(content:String):Void unsupported();

	public function connect(host:Host, port:Int):Void unsupported();

	public function listen(connections:Int):Void unsupported();

	public function shutdown(read:Bool, write:Bool):Void unsupported();

	public function bind(host:Host, port:Int):Void unsupported();

	public function accept():Socket return unsupported();

	public function peer():{host:Host, port:Int} return unsupported();

	public function host():{host:Host, port:Int} return unsupported();

	public function setTimeout(timeout:Float):Void unsupported();

	public function waitForRead():Void unsupported();

	public function setBlocking(b:Bool):Void unsupported();

	public function setFastSend(b:Bool):Void unsupported();

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} return unsupported();
}
