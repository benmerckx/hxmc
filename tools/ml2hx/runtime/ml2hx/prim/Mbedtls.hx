package ml2hx.prim;

import haxe.io.Bytes;
import ml2hx.rt.*;

// A context of mbedtls (an opaque native handle).
abstract Handle(Dynamic) {
	public inline function new(h:Dynamic) this = h;
	public inline function raw():Dynamic return this;
}

// The haxe compiler's mbedtls glue (libs/mbedtls/mbedtls.ml) over hxmc's
// mbedtls binding, hxmc.NativeSsl (the one today's port uses). Built with
// another Haxe, mbedtls is not available: each call raises Failure.
class Mbedtls {
	static inline function i(n:Int63):Int return n.toInt();
	static inline function r(n:Int):Int63 return Int63.ofInt(n);
	#if !hxmc
	static function na<T>():T throw new Failure("mbedtls is not available to this build (hxmc provides it)");
	#end

	// mbedtls' constants (ssl.h)
	public static function hxGetSslAuthmodeFlags(_:Unit):Array<Tuple2<String, Int63>>
		return [new Tuple2("SSL_VERIFY_NONE", r(0)), new Tuple2("SSL_VERIFY_OPTIONAL", r(1)), new Tuple2("SSL_VERIFY_REQUIRED", r(2))];
	public static function hxGetSslEndpointFlags(_:Unit):Array<Tuple2<String, Int63>>
		return [new Tuple2("SSL_IS_CLIENT", r(0)), new Tuple2("SSL_IS_SERVER", r(1))];
	public static function hxGetSslPresetFlags(_:Unit):Array<Tuple2<String, Int63>>
		return [new Tuple2("SSL_PRESET_DEFAULT", r(0)), new Tuple2("SSL_PRESET_SUITEB", r(2))];
	public static function hxGetSslTransportFlags(_:Unit):Array<Tuple2<String, Int63>>
		return [new Tuple2("SSL_TRANSPORT_STREAM", r(0)), new Tuple2("SSL_TRANSPORT_DATAGRAM", r(1))];

	public static function mlMbedtlsStrerror(code:Int63):String
		return #if hxmc hxmc.NativeSsl.strerror(i(code)) #else na() #end;
	public static function mlMbedtlsCtrDrbgInit(_:Unit):Handle
		return #if hxmc new Handle(hxmc.NativeSsl.ctrDrbgInit()) #else na() #end;
	public static function mlMbedtlsCtrDrbgRandom(ctx:Handle, b:Bytes, len:Int63):Int63
		return #if hxmc r(hxmc.NativeSsl.ctrDrbgRandom(ctx.raw(), b, i(len))) #else na() #end;
	public static function mlMbedtlsCtrDrbgSeed<A>(ctx:Handle, entropy:A, custom:MlOption<String>):Int63
		return #if hxmc r(hxmc.NativeSsl.ctrDrbgSeed(ctx.raw(), (cast entropy : Handle).raw())) #else na() #end;
	// (hxmc seeds a generator from its entropy natively: no entropy calls)
	public static function mlMbedtlsEntropyFunc(ctx:Handle, b:Bytes, len:Int63):Int63
		throw new Failure("mbedtls_entropy_func: not available (entropy is drawn by mbedtls_ctr_drbg_seed)");
	public static function mlMbedtlsEntropyInit(_:Unit):Handle
		return #if hxmc new Handle(hxmc.NativeSsl.entropyInit()) #else na() #end;
	public static function mlMbedtlsSslConfCaChain(conf:Handle, ca:Handle):Unit
		return #if hxmc { hxmc.NativeSsl.confCaChain(conf.raw(), ca.raw()); Unit.value; } #else na() #end;
	public static function mlMbedtlsSslConfAuthmode(conf:Handle, mode:Int63):Unit
		return #if hxmc { hxmc.NativeSsl.confAuthmode(conf.raw(), i(mode)); Unit.value; } #else na() #end;
	public static function mlMbedtlsSslConfigDefaults(conf:Handle, endpoint:Int63, transport:Int63, preset:Int63):Int63
		return #if hxmc r(hxmc.NativeSsl.configDefaults(conf.raw(), i(endpoint), i(transport), i(preset))) #else na() #end;
	public static function mlMbedtlsSslConfigInit(_:Unit):Handle
		return #if hxmc new Handle(hxmc.NativeSsl.configInit()) #else na() #end;
	public static function mlMbedtlsSslConfRng<A>(conf:Handle, rng:A):Unit
		return #if hxmc { hxmc.NativeSsl.confRng(conf.raw(), (cast rng : Handle).raw()); Unit.value; } #else na() #end;
	public static function mlMbedtlsSslInit(_:Unit):Handle
		return #if hxmc new Handle(hxmc.NativeSsl.sslInit()) #else na() #end;
	public static function mlMbedtlsSslGetPeerCert(ssl:Handle):MlOption<Handle>
		return #if hxmc { var c = hxmc.NativeSsl.sslGetPeerCert(ssl.raw()); c == null ? None : Some(new Handle(c)); } #else na() #end;
	public static function mlMbedtlsSslHandshake(ssl:Handle):Int63
		return #if hxmc r(hxmc.NativeSsl.sslHandshake(ssl.raw())) #else na() #end;
	public static function mlMbedtlsSslRead(ssl:Handle, b:Bytes, pos:Int63, len:Int63):Int63
		return #if hxmc r(hxmc.NativeSsl.sslRead(ssl.raw(), b, i(pos), i(len))) #else na() #end;
	public static function mlMbedtlsSslSetBio<A>(ssl:Handle, socket:A, send:A->Bytes->Int63, recv:A->Bytes->Int63):Unit
		return #if hxmc { hxmc.NativeSsl.sslSetBio(ssl.raw(), ml2hx.std.Unix.nativeFd(cast socket)); Unit.value; } #else na() #end;
	public static function mlMbedtlsSslSetHostname(ssl:Handle, host:String):Int63
		return #if hxmc r(hxmc.NativeSsl.sslSetHostname(ssl.raw(), host)) #else na() #end;
	public static function mlMbedtlsSslSetup(ssl:Handle, conf:Handle):Int63
		return #if hxmc r(hxmc.NativeSsl.sslSetup(ssl.raw(), conf.raw())) #else na() #end;
	public static function mlMbedtlsSslWrite(ssl:Handle, b:Bytes, pos:Int63, len:Int63):Int63
		return #if hxmc r(hxmc.NativeSsl.sslWrite(ssl.raw(), b, i(pos), i(len))) #else na() #end;
	public static function mlMbedtlsPkInit(_:Unit):Handle
		return #if hxmc new Handle(hxmc.NativeSsl.pkInit()) #else na() #end;
	public static function mlMbedtlsPkParseKey(ctx:Handle, key:Bytes, password:MlOption<String>, rng:Handle):Int63
		return #if hxmc r(hxmc.NativeSsl.pkParseKey(ctx.raw(), key, switch password { case Some(p): p; case None: null; }, rng.raw())) #else na() #end;
	public static function mlMbedtlsPkParseKeyfile(ctx:Handle, path:String, password:MlOption<String>, rng:Handle):Int63
		return #if hxmc r(hxmc.NativeSsl.pkParseKeyfile(ctx.raw(), path, switch password { case Some(p): p; case None: null; }, rng.raw())) #else na() #end;
	public static function mlMbedtlsPkParsePublicKeyfile(ctx:Handle, path:String):Int63
		return #if hxmc r(hxmc.NativeSsl.pkParsePublicKeyfile(ctx.raw(), path)) #else na() #end;
	public static function mlMbedtlsPkParsePublicKey(ctx:Handle, key:Bytes):Int63
		return #if hxmc r(hxmc.NativeSsl.pkParsePublicKey(ctx.raw(), key)) #else na() #end;
	public static function mlMbedtlsX509CrtInit(_:Unit):Handle
		return #if hxmc new Handle(hxmc.NativeSsl.x509CrtInit()) #else na() #end;
	public static function mlMbedtlsX509Next(c:Handle):MlOption<Handle>
		return #if hxmc { var n = hxmc.NativeSsl.x509Next(c.raw()); n == null ? None : Some(new Handle(n)); } #else na() #end;
	public static function mlMbedtlsX509CrtParse(c:Handle, b:Bytes):Int63
		return #if hxmc r(hxmc.NativeSsl.x509CrtParse(c.raw(), b)) #else na() #end;
	public static function mlMbedtlsX509CrtParseFile(c:Handle, path:String):Int63
		return #if hxmc r(hxmc.NativeSsl.x509CrtParseFile(c.raw(), path)) #else na() #end;
	public static function mlMbedtlsX509CrtParsePath(c:Handle, path:String):Int63
		return #if hxmc r(hxmc.NativeSsl.x509CrtParsePath(c.raw(), path)) #else na() #end;
	public static function hxCertGetAltNames(c:Handle):Array<String>
		return #if hxmc hxmc.NativeSsl.certAltNames(c.raw()) #else na() #end;
	public static function hxCertGetIssuer(c:Handle, field:String):MlOption<String>
		return #if hxmc { var v = hxmc.NativeSsl.certIssuer(c.raw(), field); v == null ? None : Some(v); } #else na() #end;
	public static function hxCertGetNotafter(c:Handle):Float
		return #if hxmc hxmc.NativeSsl.certNotAfter(c.raw()) #else na() #end;
	public static function hxCertGetNotbefore(c:Handle):Float
		return #if hxmc hxmc.NativeSsl.certNotBefore(c.raw()) #else na() #end;
	public static function hxCertGetSubject(c:Handle, field:String):MlOption<String>
		return #if hxmc { var v = hxmc.NativeSsl.certSubject(c.raw(), field); v == null ? None : Some(v); } #else na() #end;
	public static function hxCertLoadDefaults(c:Handle):Int63
		return #if hxmc r(hxmc.NativeSsl.certLoadDefaults(c.raw())) #else na() #end;
}
