package hxmc.rt.wasm;

import hxmc.rt.C;

// hxmc.NativeSsl on WebAssembly (docs/hxmc.md, "WebAssembly"): mbedtls is not
// there, so every call throws. Typed only for the programs that use the API.
class NoSsl {
	static function noSsl():Void
		Rt.rt_throw("mbedtls is not supported on WebAssembly");

	public static function strerror(code:Int):String { noSsl(); return null; }
	public static function ctrDrbgInit():Dynamic { noSsl(); return null; }
	public static function ctrDrbgRandom(ctx:Dynamic, output:haxe.io.Bytes, len:Int):Int { noSsl(); return 0; }
	public static function ctrDrbgSeed(ctx:Dynamic, entropy:Dynamic):Int { noSsl(); return 0; }
	public static function entropyInit():Dynamic { noSsl(); return null; }
	public static function x509CrtInit():Dynamic { noSsl(); return null; }
	public static function x509Next(crt:Dynamic):Dynamic { noSsl(); return null; }
	public static function x509CrtParse(crt:Dynamic, b:haxe.io.Bytes):Int { noSsl(); return 0; }
	public static function x509CrtParseFile(crt:Dynamic, path:String):Int { noSsl(); return 0; }
	public static function x509CrtParsePath(crt:Dynamic, path:String):Int { noSsl(); return 0; }
	public static function certAltNames(crt:Dynamic):Array<String> { noSsl(); return null; }
	public static function certIssuer(crt:Dynamic, field:String):Null<String> { noSsl(); return null; }
	public static function certSubject(crt:Dynamic, field:String):Null<String> { noSsl(); return null; }
	public static function certNotAfter(crt:Dynamic):Float { noSsl(); return 0.0; }
	public static function certNotBefore(crt:Dynamic):Float { noSsl(); return 0.0; }
	public static function certLoadDefaults(crt:Dynamic):Int { noSsl(); return 0; }
	public static function configInit():Dynamic { noSsl(); return null; }
	public static function confAuthmode(conf:Dynamic, authmode:Int):Void { noSsl(); }
	public static function confCaChain(conf:Dynamic, crt:Dynamic):Void { noSsl(); }
	public static function configDefaults(conf:Dynamic, endpoint:Int, transport:Int, preset:Int):Int { noSsl(); return 0; }
	public static function confRng(conf:Dynamic, ctrDrbg:Dynamic):Void { noSsl(); }
	public static function pkInit():Dynamic { noSsl(); return null; }
	public static function pkParseKey(pk:Dynamic, key:haxe.io.Bytes, password:Null<String>, rng:Dynamic):Int { noSsl(); return 0; }
	public static function pkParseKeyfile(pk:Dynamic, path:String, password:Null<String>, rng:Dynamic):Int { noSsl(); return 0; }
	public static function pkParsePublicKey(pk:Dynamic, key:haxe.io.Bytes):Int { noSsl(); return 0; }
	public static function pkParsePublicKeyfile(pk:Dynamic, path:String):Int { noSsl(); return 0; }
	public static function pkParse(pk:Dynamic, key:haxe.io.Bytes, isPublic:Bool, password:Null<String>, pem:Bool):Int { noSsl(); return 0; }
	public static function mdSize(alg:String):Int { noSsl(); return 0; }
	public static function md(alg:String, data:haxe.io.Bytes, out:haxe.io.Bytes):Int { noSsl(); return 0; }
	public static function pkSign(pk:Dynamic, alg:String, data:haxe.io.Bytes, out:haxe.io.Bytes, rng:Dynamic):Int { noSsl(); return 0; }
	public static function pkVerify(pk:Dynamic, alg:String, data:haxe.io.Bytes, sig:haxe.io.Bytes):Int { noSsl(); return 0; }
	public static function sslGetVerifyResult(ssl:Dynamic):Int { noSsl(); return 0; }
	public static function sslInit():Dynamic { noSsl(); return null; }
	public static function sslGetPeerCert(ssl:Dynamic):Dynamic { noSsl(); return null; }
	public static function sslHandshake(ssl:Dynamic):Int { noSsl(); return 0; }
	public static function sslRead(ssl:Dynamic, buf:haxe.io.Bytes, pos:Int, len:Int):Int { noSsl(); return 0; }
	public static function sslWrite(ssl:Dynamic, buf:haxe.io.Bytes, pos:Int, len:Int):Int { noSsl(); return 0; }
	public static function sslSetBio(ssl:Dynamic, fd:Int):Void { noSsl(); }
	public static function sslSetHostname(ssl:Dynamic, hostname:String):Int { noSsl(); return 0; }
	public static function sslSetup(ssl:Dynamic, conf:Dynamic):Int { noSsl(); return 0; }
	public static function bioError(ssl:Dynamic):Int { noSsl(); return 0; }
	public static function bioErrorSend(ssl:Dynamic):Bool { noSsl(); return false; }
}
