package hxmc.rt;

// hxmc.NativeNet for WebAssembly (docs/hxmc.md, "WebAssembly"): WASI
// preview 1 has no sockets and no name resolution, so every operation fails
// with ENOSYS (sys.net.Socket throws "Function not implemented", Host
// resolution "Unknown host").
@:hxmc.wasm
class WasiNet {
	static inline var ENOSYS = 52; // (WASI's errno)

	public static function getErrno():Int
		return ENOSYS;

	public static function strerror(err:Int):String
		return err == ENOSYS ? "Function not implemented" : "Unknown error " + err;

	public static function socket():Int
		return -1;

	public static function close(fd:Int):Int
		return -1;

	public static function accept(fd:Int):Int
		return -1;

	public static function bind(fd:Int, ip:Int, port:Int):Int
		return -1;

	public static function connect(fd:Int, ip:Int, port:Int):Int
		return -1;

	public static function listen(fd:Int, backlog:Int):Int
		return -1;

	public static function sockName(fd:Int, peer:Bool):Null<Array<Int>>
		return null;

	public static function recv(fd:Int, b:Dynamic, pos:Int, len:Int):Int
		return -1;

	public static function send(fd:Int, b:Dynamic, pos:Int, len:Int):Int
		return -1;

	public static function select(read:Array<Int>, write:Array<Int>, others:Array<Int>, timeout:Float):Int
		return -1;

	public static function setNoDelay(fd:Int, b:Bool):Int
		return -1;

	public static function setBroadcast(fd:Int, b:Bool):Int
		return -1;

	public static function setReuseAddr(fd:Int, b:Bool):Int
		return -1;

	public static function setTimeout(fd:Int, seconds:Float):Int
		return -1;

	public static function shutdown(fd:Int, mode:Int):Int
		return -1;

	public static function setBlocking(fd:Int, b:Bool):Int
		return -1;

	public static function blocked():Bool
		return false;

	public static function gethostname():Null<String>
		return null;

	public static function resolve(name:String):Null<Array<Int>>
		return null;

	public static function reverse(ip:Int):Null<String>
		return null;
}
