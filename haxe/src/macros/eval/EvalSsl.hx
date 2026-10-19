package macros.eval;

import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalEncode;
import macros.eval.EvalDecode;
import macros.eval.EvalExceptions;

using macros.eval.EvalValue.EvalValueTools;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeNet;
import hxmc.NativeSsl;
#end

// port: upstream calls the OCaml mbedtls bindings (haxe/libs/mbedtls). On the hxmc
// host (hxmc/) they are `hxmc.NativeSsl` (hxmc/std/hxmc/rt/Ssl.hx); on other
// hosts the constructors and natives fail with "mbedtls (...) is not supported
// by haxe-in-haxe".
//
// Deviations:
// - `mbedtls_ssl_set_bio` takes the socket descriptor: the BIO calls send/recv
//   in C instead of calling back `Unix.send`/`Unix.recv`. A failing send/recv
//   makes the BIO return an mbedtls error and the native then raises the
//   `Unix_error` as `catch_unix_error` would format it (upstream lets the OCaml
//   exception escape through mbedtls).
// - Field lists are `{name, value}` pairs; `init_fields` is passed as a function.
class EvalSsl {
	static function asX509Crt(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: IMbedtlsX509Crt(i)}): i;
			case _: EvalExceptions.unexpectedValue(vthis, "X509Crt");
		}
	}

	static function asConfig(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: IMbedtlsConfig(i)}): i;
			case _: EvalExceptions.unexpectedValue(vthis, "Config");
		}
	}

	static function asSocket(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: ISocket(sock)}): sock.closed ? -1 : sock.fd;
			case _: EvalExceptions.unexpectedValue(vthis, "NativeSocket");
		}
	}

	static function asCtrDrbg(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: IMbedtlsCtrDrbg(i)}): i;
			case _: EvalExceptions.unexpectedValue(vthis, "CtrDrbg");
		}
	}

	static function asEntropy(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: IMbedtlsEntropy(i)}): i;
			case _: EvalExceptions.unexpectedValue(vthis, "Entropy");
		}
	}

	static function asPkContext(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: IMbedtlsPkContext(i)}): i;
			case _: EvalExceptions.unexpectedValue(vthis, "PkContext");
		}
	}

	static function asSsl(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: IMbedtlsSsl(ctx)}): ctx;
			case _: EvalExceptions.unexpectedValue(vthis, "Ssl");
		}
	}

	static function notSupported(what:String):Dynamic {
		return EvalContext.excString("mbedtls (" + what + ") is not supported by haxe-in-haxe");
	}

	public static function initConstructors(add:(Int, Array<Value>->Value) -> Void):Void {
		#if (target.name == "hxmc")
		add(EvalHash.key_mbedtls_Config, _ -> {
			var cfg = NativeSsl.configInit();
			EvalEncode.encodeInstance(EvalHash.key_mbedtls_Config, IMbedtlsConfig(cfg));
		});
		add(EvalHash.key_mbedtls_CtrDrbg, _ -> {
			var ctr = NativeSsl.ctrDrbgInit();
			EvalEncode.encodeInstance(EvalHash.key_mbedtls_CtrDrbg, IMbedtlsCtrDrbg(ctr));
		});
		add(EvalHash.key_mbedtls_Entropy, _ -> {
			var entropy = NativeSsl.entropyInit();
			EvalEncode.encodeInstance(EvalHash.key_mbedtls_Entropy, IMbedtlsEntropy(entropy));
		});
		add(EvalHash.key_mbedtls_PkContext, _ -> {
			var pk = NativeSsl.pkInit();
			EvalEncode.encodeInstance(EvalHash.key_mbedtls_PkContext, IMbedtlsPkContext(pk));
		});
		add(EvalHash.key_mbedtls_Ssl, _ -> {
			var ssl = NativeSsl.sslInit();
			EvalEncode.encodeInstance(EvalHash.key_mbedtls_Ssl, IMbedtlsSsl(ssl));
		});
		add(EvalHash.key_mbedtls_X509Crt, _ -> {
			var cert = NativeSsl.x509CrtInit();
			EvalEncode.encodeInstance(EvalHash.key_mbedtls_X509Crt, IMbedtlsX509Crt(cert));
		});
		#else
		for (key in [
			EvalHash.key_mbedtls_Config,
			EvalHash.key_mbedtls_CtrDrbg,
			EvalHash.key_mbedtls_Entropy,
			EvalHash.key_mbedtls_PkContext,
			EvalHash.key_mbedtls_Ssl,
			EvalHash.key_mbedtls_X509Crt
		]) {
			add(key, _ -> notSupported(EvalHash.revHash(key)));
		}
		#end
	}

	#if (target.name == "hxmc")
	// port: the `Unix_error` of a failed BIO send/recv (see the module comment).
	static function checkBio(ssl:Dynamic, r:Int):Int {
		var err = NativeSsl.bioError(ssl);
		if (err != 0)
			EvalContext.excString(NativeNet.strerror(err) + "(" + (NativeSsl.bioErrorSend(ssl) ? "send" : "recv") + ", )");
		return r;
	}
	#end

	public static function initFields(initFields:(GlobalTypePathArg, Array<{name:String, value:Value}>,
		Array<{name:String, value:Value}>) -> Void):Void {
		#if (target.name == "hxmc")
		function nativeCert(self:Value):Dynamic {
			return asX509Crt(EvalField.field(self, EvalHash.hash("native")));
		}
		initFields({pack: ["sys", "ssl"], name: "Certificate"}, [], [
			{
				name: "get_altNames",
				value: EvalEncode.vifun0(self -> {
					var x509Crt = nativeCert(self);
					var a = NativeSsl.certAltNames(x509Crt);
					VArray(EvalArray.create(a.map(EvalEncode.encodeString)));
				})
			},
			{
				name: "get_notAfter",
				value: EvalEncode.vifun0(self -> {
					var x509Crt = nativeCert(self);
					var f = NativeSsl.certNotAfter(x509Crt);
					EvalEncode.encodeInstance(EvalHash.key_Date, IDate(f));
				})
			},
			{
				name: "get_notBefore",
				value: EvalEncode.vifun0(self -> {
					var x509Crt = nativeCert(self);
					var f = NativeSsl.certNotBefore(x509Crt);
					EvalEncode.encodeInstance(EvalHash.key_Date, IDate(f));
				})
			},
			{
				name: "issuer",
				value: EvalEncode.vifun1((self, field) -> {
					var x509Crt = nativeCert(self);
					switch NativeSsl.certIssuer(x509Crt, EvalDecode.decodeString(field)) {
						case null: VNull;
						case s: EvalEncode.encodeString(s);
					}
				})
			},
			{
				name: "subject",
				value: EvalEncode.vifun1((self, field) -> {
					var x509Crt = nativeCert(self);
					switch NativeSsl.certSubject(x509Crt, EvalDecode.decodeString(field)) {
						case null: VNull;
						case s: EvalEncode.encodeString(s);
					}
				})
			},
		]);
		initFields({pack: ["sys", "ssl"], name: "Mbedtls"}, [
			{
				name: "loadDefaults",
				value: EvalEncode.vfun1(self -> {
					VInt32(NativeSsl.certLoadDefaults(asX509Crt(self)));
				})
			},
			{
				name: "setSocket",
				value: EvalEncode.vfun2((self, socket) -> {
					var ctx = asSsl(self);
					var socket:Int = asSocket(socket);
					NativeSsl.sslSetBio(ctx, socket);
					VNull;
				})
			},
		], []);
		initFields({pack: ["mbedtls"], name: "X509Crt"}, [], [
			{
				name: "next",
				value: EvalEncode.vifun0(self -> {
					switch NativeSsl.x509Next(asX509Crt(self)) {
						case null: VNull;
						case cert: EvalEncode.encodeInstance(EvalHash.key_mbedtls_X509Crt, IMbedtlsX509Crt(cert));
					}
				})
			},
			{
				name: "parse",
				value: EvalEncode.vifun1((self, bytes) -> {
					var crt = asX509Crt(self);
					VInt32(NativeSsl.x509CrtParse(crt, EvalDecode.decodeBytes(bytes)));
				})
			},
			{
				name: "parse_file",
				value: EvalEncode.vifun1((self, path) -> {
					var crt = asX509Crt(self);
					VInt32(NativeSsl.x509CrtParseFile(crt, EvalDecode.decodeString(path)));
				})
			},
			{
				name: "parse_path",
				value: EvalEncode.vifun1((self, path) -> {
					var crt = asX509Crt(self);
					VInt32(NativeSsl.x509CrtParsePath(crt, EvalDecode.decodeString(path)));
				})
			},
		]);
		initFields({pack: ["mbedtls"], name: "Config"}, [], [
			{
				name: "authmode",
				value: EvalEncode.vifun1((self, authmode) -> {
					var conf = asConfig(self);
					NativeSsl.confAuthmode(conf, EvalDecode.decodeInt(authmode));
					VNull;
				})
			},
			{
				name: "ca_chain",
				value: EvalEncode.vifun1((self, caChain) -> {
					var conf = asConfig(self);
					NativeSsl.confCaChain(conf, asX509Crt(caChain));
					VNull;
				})
			},
			{
				name: "defaults",
				value: EvalEncode.vifun3((self, endpoint, transport, preset) -> {
					var conf = asConfig(self);
					var endpoint = EvalDecode.decodeInt(endpoint);
					var transport = EvalDecode.decodeInt(transport);
					var preset = EvalDecode.decodeInt(preset);
					VInt32(NativeSsl.configDefaults(conf, endpoint, transport, preset));
				})
			},
			{
				name: "rng",
				value: EvalEncode.vifun1((self, pRng) -> {
					var conf = asConfig(self);
					NativeSsl.confRng(conf, asCtrDrbg(pRng));
					VNull;
				})
			},
		]);
		initFields({pack: ["mbedtls"], name: "CtrDrbg"}, [], [
			{
				name: "random",
				value: EvalEncode.vifun2((self, output, outputLen) -> {
					var ctr = asCtrDrbg(self);
					var output = EvalDecode.decodeBytes(output);
					var outputLen = EvalDecode.decodeInt(outputLen);
					VInt32(NativeSsl.ctrDrbgRandom(ctr, output, outputLen));
				})
			},
			{
				name: "seed",
				value: EvalEncode.vifun2((self, entropy, custom) -> {
					// port: the custom string is ignored by the bindings (mbedtls_stubs.c)
					var ctr = asCtrDrbg(self);
					VInt32(NativeSsl.ctrDrbgSeed(ctr, asEntropy(entropy)));
				})
			},
		]);
		initFields({pack: ["mbedtls"], name: "Error"}, [
			{
				name: "strerror",
				value: EvalEncode.vfun1(code -> EvalEncode.encodeString(NativeSsl.strerror(EvalDecode.decodeInt(code))))
			},
		], []);
		function decodePassword(password:Value):Null<String> {
			return switch password {
				case VNull: null;
				case _: EvalDecode.decodeString(password);
			}
		}
		initFields({pack: ["mbedtls"], name: "PkContext"}, [], [
			{
				name: "parse_key",
				value: EvalEncode.vifun3((self, key, password, rng) -> {
					var pk = asPkContext(self);
					var key = EvalDecode.decodeBytes(key);
					var password = decodePassword(password);
					VInt32(NativeSsl.pkParseKey(pk, key, password, asCtrDrbg(rng)));
				})
			},
			{
				name: "parse_keyfile",
				value: EvalEncode.vifun3((self, path, password, rng) -> {
					var pk = asPkContext(self);
					var path = EvalDecode.decodeString(path);
					var password = decodePassword(password);
					VInt32(NativeSsl.pkParseKeyfile(pk, path, password, asCtrDrbg(rng)));
				})
			},
			{
				name: "parse_public_key",
				value: EvalEncode.vifun1((self, key) -> {
					var pk = asPkContext(self);
					VInt32(NativeSsl.pkParsePublicKey(pk, EvalDecode.decodeBytes(key)));
				})
			},
			{
				name: "parse_public_keyfile",
				value: EvalEncode.vifun1((self, path) -> {
					var pk = asPkContext(self);
					VInt32(NativeSsl.pkParsePublicKeyfile(pk, EvalDecode.decodeString(path)));
				})
			},
		]);
		initFields({pack: ["mbedtls"], name: "Ssl"}, [], [
			{
				name: "get_peer_cert",
				value: EvalEncode.vifun0(self -> {
					switch NativeSsl.sslGetPeerCert(asSsl(self)) {
						case null: VNull;
						case cert: EvalEncode.encodeInstance(EvalHash.key_mbedtls_X509Crt, IMbedtlsX509Crt(cert));
					}
				})
			},
			{
				name: "handshake",
				value: EvalEncode.vifun0(self -> {
					var ssl = asSsl(self);
					VInt32(checkBio(ssl, NativeSsl.sslHandshake(ssl)));
				})
			},
			{
				name: "read",
				value: EvalEncode.vifun3((self, buf, pos, len) -> {
					var ssl = asSsl(self);
					var buf = EvalDecode.decodeBytes(buf);
					var pos = EvalDecode.decodeInt(pos);
					var len = EvalDecode.decodeInt(len);
					VInt32(checkBio(ssl, NativeSsl.sslRead(ssl, buf, pos, len)));
				})
			},
			{
				name: "set_hostname",
				value: EvalEncode.vifun1((self, hostname) -> {
					var ssl = asSsl(self);
					VInt32(NativeSsl.sslSetHostname(ssl, EvalDecode.decodeString(hostname)));
				})
			},
			{
				name: "setup",
				value: EvalEncode.vifun1((self, conf) -> {
					var ssl = asSsl(self);
					VInt32(NativeSsl.sslSetup(ssl, asConfig(conf)));
				})
			},
			{
				name: "write",
				value: EvalEncode.vifun3((self, buf, pos, len) -> {
					var ssl = asSsl(self);
					var buf = EvalDecode.decodeBytes(buf);
					var pos = EvalDecode.decodeInt(pos);
					var len = EvalDecode.decodeInt(len);
					VInt32(checkBio(ssl, NativeSsl.sslWrite(ssl, buf, pos, len)));
				})
			},
		]);
		#end
		// port: hx_get_ssl_*_flags (libs/mbedtls/mbedtls_stubs.c): the values of mbedtls/ssl.h.
		// They are plain data, registered on every host.
		function statics(a:Array<{name:String, value:Int}>) return [for (f in a) {name: f.name, value: f.value.vint()}];
		initFields({pack: ["mbedtls"], name: "SslAuthmode"}, statics([
			{name: "SSL_VERIFY_NONE", value: 0},
			{name: "SSL_VERIFY_OPTIONAL", value: 1},
			{name: "SSL_VERIFY_REQUIRED", value: 2}
		]), []);
		initFields({pack: ["mbedtls"], name: "SslEndpoint"},
			statics([{name: "SSL_IS_CLIENT", value: 0}, {name: "SSL_IS_SERVER", value: 1}]), []);
		initFields({pack: ["mbedtls"], name: "SslPreset"},
			statics([{name: "SSL_PRESET_DEFAULT", value: 0}, {name: "SSL_PRESET_SUITEB", value: 2}]), []);
		initFields({pack: ["mbedtls"], name: "SslTransport"}, statics([
			{name: "SSL_TRANSPORT_STREAM", value: 0},
			{name: "SSL_TRANSPORT_DATAGRAM", value: 1}
		]), []);
	}
}

typedef GlobalTypePathArg = {pack:Array<String>, name:String};
