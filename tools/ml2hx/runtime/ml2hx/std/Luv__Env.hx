package ml2hx.std;

import ml2hx.rt.*;
import ocaml.stdlib.StdlibModule.StdlibResult;

// luv's Env (uv_os_getenv and friends) over Haxe's Sys.
class Luv__Env {
	static inline function native(s:String):String return ByteString.toNative(s);
	static inline function ocaml(s:String):String return ByteString.ofNative(s);
	static function enoent<T>():StdlibResult<T, PolyVariant> return Error(PolyVariant.constant(877502405, "ENOENT"));
	public static function getenv(name:String):StdlibResult<String, PolyVariant> {
		var v = std.Sys.getEnv(native(name));
		return v == null ? enoent() : Ok(ocaml(v));
	}
	public static function setenv(name:String, value:String):StdlibResult<Unit, PolyVariant> {
		std.Sys.putEnv(native(name), native(value));
		return Ok(Unit.value);
	}
	public static function unsetenv(name:String):StdlibResult<Unit, PolyVariant> {
		std.Sys.putEnv(native(name), null);
		return Ok(Unit.value);
	}
	public static function environ(_:Unit):StdlibResult<MlList<Tuple2<String, String>>, PolyVariant> {
		var l = MlList.Nil;
		for (k => v in std.Sys.environment()) l = MlList.Cons(new Tuple2(ocaml(k), ocaml(v)), l);
		return Ok(l);
	}
}
