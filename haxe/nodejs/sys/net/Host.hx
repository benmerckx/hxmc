package sys.net;

// Stand-in for the Node.js compiler build: hxnodejs' Host resolves names
// synchronously through the `deasync` npm module, which would become a load-time
// dependency of the whole build. Host lookups from macros fail instead.
class Host {
	public var host(default, null):String;
	public var ip(default, null):Int;

	public function new(name:String) {
		throw "sys.net.Host is not supported by the JS build of haxe-in-haxe";
	}

	public function toString():String return host;

	public function reverse():String throw "sys.net.Host is not supported by the JS build of haxe-in-haxe";

	public static function localhost():String throw "sys.net.Host is not supported by the JS build of haxe-in-haxe";
}
