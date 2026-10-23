package hxmc.rt;

import haxe.io.Bytes;
import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.*;

// mbedtls behind hxmc.NativeSsl (the Eval natives of mbedtls.* and sys.ssl.*,
// src/macros/eval/EvalSsl.hx), mirroring the OCaml bindings
// haxe/libs/mbedtls/mbedtls_stubs.c used by haxe/src/macro/eval/evalSsl.ml;
// once C (rt_ssl.c), now Haxe calling mbedtls directly (docs/plans/lowlevel.md).
// mbedtls itself stays the prebuilt ssl.o, linked when a program uses it.
//
// Contexts are T_NATIVE objects whose slot 0 holds the malloc'ed mbedtls
// context (Rt.rt_native_new_refs): the collector frees them once
// unreachable, with the context's free callback (upstream frees them from
// OCaml custom-block finalizers, which call mbedtls_*_free but not free()).
// Deviations, for memory safety:
// - a context's reference slots keep alive what mbedtls keeps pointers to: a
//   configuration its CtrDrbg and CA chain, a CtrDrbg its entropy, an Ssl its
//   configuration (upstream relies on the Haxe side keeping them reachable);
// - X509Crt.next and Ssl.get_peer_cert return borrowed certificates, which
//   are not freed but keep their owner alive (upstream gives them the
//   owning finalizer, which would free a chain's tail or the session's peer
//   certificate).
// Deviation: upstream's BIO callbacks call OCaml's Unix.send/Unix.recv, whose
// Unix_error escapes through mbedtls. Here the BIO is C send/recv on the
// socket descriptor; on failure it records errno and returns
// MBEDTLS_ERR_NET_SEND_FAILED/RECV_FAILED, and the port raises the Unix error
// after the call (bioError, bioErrorSend).
//
// The handshake, reads and writes are C calls in a safe region (they block
// on the socket): mbedtls works on malloc'ed memory only meanwhile, and the
// BIO callbacks are no-GC functions that call send/recv directly.
class Ssl {
	// the layouts of mbedtls 2.28 (hxmc/deps/deps.sh), the same on the six
	// targets: context sizes, and the fields of mbedtls_x509_crt read here
	static inline var CTR_DRBG_SIZE = 344;
	static inline var ENTROPY_SIZE = 1032;
	static inline var X509_CRT_SIZE = 616;
	static inline var SSL_CONFIG_SIZE = 400;
	static inline var PK_SIZE = 16;
	static inline var SSL_SIZE = 472;
	static inline var CRT_ISSUER = 160;
	static inline var CRT_SUBJECT = 224;
	static inline var CRT_VALID_FROM = 288;
	static inline var CRT_VALID_TO = 312;
	static inline var CRT_ALT_NAMES = 448;
	static inline var CRT_EXT_TYPES = 512;
	static inline var CRT_NEXT = 608;
	static inline var CRT_RAW = 8; // an asn1_buf
	static inline var EXT_SUBJECT_ALT_NAME = 32;
	static inline var BADCERT_CN_MISMATCH = 4;
	static inline var BADCERT_OTHER = 256;
	static inline var ERR_NET_SEND_FAILED = -0x4E;
	static inline var ERR_NET_RECV_FAILED = -0x4C;
	static inline var ERR_X509_FATAL_ERROR = -0x3000;
	// an Ssl's state after its mbedtls_ssl_context (hx_ssl): the socket, the
	// BIO's errno (0: no failure), whether the failure was in send
	static inline var SSL_FD = SSL_SIZE;
	static inline var SSL_BIO_ERRNO = SSL_SIZE + 4;
	static inline var SSL_BIO_SEND = SSL_SIZE + 8;
	static inline var HX_SSL_SIZE = SSL_SIZE + 16;
	// the reference slots of each context (after slot 0)
	static inline var CTR_REF_ENTROPY = 1;
	static inline var CONF_REF_RNG = 1;
	static inline var CONF_REF_CA = 2;
	static inline var SSL_REF_CONF = 1;
	static inline var T_NATIVE = Types.T_NATIVE;

	static inline function ptr(o:Dynamic):Ptr
		return Mem.getPtr(Mem.addr(o), 0);

	static inline function setRef(o:Dynamic, slot:Int, v:Dynamic)
		Mem.setRefBarrier(o, 8 * slot, v);

	static inline function bytes(b:Bytes):Ptr
		return Mem.addr(b.getData());

	static inline function os():Int
		return Mem.os();

	// a context of `size` bytes, malloc'ed (the caller initializes it)
	static inline function alloc(size:Int):Ptr
		return LibC.malloc((size : I64));

	// a borrowed pointer into owner's resource: slot 1 keeps owner alive
	static function borrow(p:Ptr, owner:Dynamic):Dynamic {
		var o = Mem.alloc(2, Types.T_NATIVE_REFS, Types.K_PARR);
		Mem.setPtr(Mem.addr(o), 0, p);
		Mem.setRef(Mem.addr(o), 8, owner); // (young)
		return o;
	}

	// the collector's free callbacks (no-GC: it runs them while the world is stopped)
	@:hxmc.callback @:hxmc.noGc static function freeCtrDrbg(p:Ptr):Void {
		M.mbedtls_ctr_drbg_free(p);
		LibC.free(p);
	}

	@:hxmc.callback @:hxmc.noGc static function freeEntropy(p:Ptr):Void {
		M.mbedtls_entropy_free(p);
		LibC.free(p);
	}

	@:hxmc.callback @:hxmc.noGc static function freeX509Crt(p:Ptr):Void {
		M.mbedtls_x509_crt_free(p);
		LibC.free(p);
	}

	@:hxmc.callback @:hxmc.noGc static function freeSslConfig(p:Ptr):Void {
		M.mbedtls_ssl_config_free(p);
		LibC.free(p);
	}

	@:hxmc.callback @:hxmc.noGc static function freePk(p:Ptr):Void {
		M.mbedtls_pk_free(p);
		LibC.free(p);
	}

	@:hxmc.callback @:hxmc.noGc static function freeSsl(p:Ptr):Void {
		M.mbedtls_ssl_free(p);
		LibC.free(p);
	}

	// a NUL-terminated copy of a Bytes (OCaml strings carry a NUL after their length)
	static function bytesZ(a:Arena, b:Bytes):Ptr<UInt8> {
		var n = b.length;
		var p:Ptr<UInt8> = a.alloc(n + 1, 1);
		LibC.memcpy(p, bytes(b), (n : I64));
		return p;
	}

	static inline function str(p:Ptr, n:Int):String
		return Str.ofUtf8(p, n);

	public static function strerror(code:Int):String {
		var buf = Mem.stack(128);
		M.mbedtls_strerror(code, buf, 128);
		return str(buf, LibC.strlen(buf).toInt());
	}

	// ---- CtrDrbg

	public static function ctrDrbgInit():Dynamic {
		var p = alloc(CTR_DRBG_SIZE);
		M.mbedtls_ctr_drbg_init(p);
		return Rt.rt_native_new_refs(p, Callback.addr(freeCtrDrbg), 1);
	}

	public static function ctrDrbgRandom(ctx:Dynamic, output:Bytes, len:Int):Int
		return M.mbedtls_ctr_drbg_random(ptr(ctx), bytes(output), (len : I64));

	public static function ctrDrbgSeed(ctx:Dynamic, entropy:Dynamic):Int {
		setRef(ctx, CTR_REF_ENTROPY, entropy);
		return M.mbedtls_ctr_drbg_seed(ptr(ctx), Mem.sym("mbedtls_entropy_func"), ptr(entropy), Ptr.nil(), 0);
	}

	// ---- Entropy

	public static function entropyInit():Dynamic {
		var p = alloc(ENTROPY_SIZE);
		M.mbedtls_entropy_init(p);
		return Rt.rt_native_new_refs(p, Callback.addr(freeEntropy), 0);
	}

	// ---- Certificate

	public static function x509CrtInit():Dynamic {
		var p = alloc(X509_CRT_SIZE);
		M.mbedtls_x509_crt_init(p);
		return Rt.rt_native_new_refs(p, Callback.addr(freeX509Crt), 0);
	}

	// null: none
	public static function x509Next(chain:Dynamic):Dynamic {
		var next = Mem.getPtr(ptr(chain), CRT_NEXT);
		return next.isNull() ? null : borrow(next, chain);
	}

	public static function x509CrtParse(chain:Dynamic, b:Bytes):Int
		return Arena.scopedValue(a -> M.mbedtls_x509_crt_parse(ptr(chain), bytesZ(a, b), (b.length + 1 : I64)));

	public static function x509CrtParseFile(chain:Dynamic, path:String):Int
		return Arena.scopedValue(a -> M.mbedtls_x509_crt_parse_file(ptr(chain), a.cstring(path)));

	public static function x509CrtParsePath(chain:Dynamic, path:String):Int
		return Arena.scopedValue(a -> M.mbedtls_x509_crt_parse_path(ptr(chain), a.cstring(path)));

	// ---- Certificate Haxe API

	public static function certAltNames(chain:Dynamic):Array<String> {
		var r:Array<String> = [];
		if (Mem.getI32(ptr(chain), CRT_EXT_TYPES) & EXT_SUBJECT_ALT_NAME == 0) return r;
		var cur:Ptr<Asn1Sequence> = ptr(chain).add(CRT_ALT_NAMES);
		while (!cur.isNull()) {
			// (the certificate is C memory: its pointers stay valid across allocations)
			r.push(str(cur.value.buf.p, cur.value.buf.len.toInt()));
			cur = cur.value.next;
		}
		return r;
	}

	static function findName(name:Ptr<X509Name>, field:String):Null<String> {
		var f = Arena.scopedValue(a -> {
			var want = a.cstring(field);
			var found:Ptr<X509Name> = Ptr.nil();
			var oname:Ptr<CString> = a.alloc(8);
			var obj = name;
			while (!obj.isNull()) {
				if (M.mbedtls_oid_get_attr_short_name(obj, oname) == 0 && LibC.strcmp(oname.value, want) == 0) {
					found = obj;
					break;
				}
				obj = obj.value.next;
			}
			found;
		});
		return f.isNull() ? null : str(f.value.val.p, f.value.val.len.toInt());
	}

	public static function certSubject(chain:Dynamic, field:String):Null<String>
		return findName(ptr(chain).add(CRT_SUBJECT), field);

	public static function certIssuer(chain:Dynamic, field:String):Null<String>
		return findName(ptr(chain).add(CRT_ISSUER), field);

	// upstream leaves the other fields of `info` (tm_isdst) uninitialized
	static function timeToTimeT(t:Ptr<X509Time>):Float {
		var tm:Ptr<Int32> = Mem.stack(64);
		LibC.memset(tm, 0, 64);
		tm[5] = t.value.year - 1900;
		tm[4] = t.value.mon - 1;
		tm[3] = t.value.day;
		tm[2] = t.value.hour;
		tm[1] = t.value.min;
		tm[0] = t.value.sec;
		var t:Float = cast (os() == 2 ? LibC._mktime64(tm) : LibC.mktime(tm));
		return t;
	}

	public static function certNotAfter(chain:Dynamic):Float
		return timeToTimeT(ptr(chain).add(CRT_VALID_TO));

	public static function certNotBefore(chain:Dynamic):Float
		return timeToTimeT(ptr(chain).add(CRT_VALID_FROM));

	// 0 when the system store was loaded; otherwise
	// sys.ssl.Mbedtls.loadDefaultCertificates reads the CA files of
	// Sys.systemName(). Upstream's Windows (system "Root" store) and macOS
	// (Security framework) branches; Linux has neither (1, as upstream on
	// Linux and the BSDs).
	public static function certLoadDefaults(certificate:Dynamic):Int {
		if (os() == 2) return loadWindowsRoots(ptr(certificate));
		if (os() == 1) return loadMacosRoots(ptr(certificate));
		return 1;
	}

	// upstream's Windows branch: the system's "Root" store
	static function loadWindowsRoots(chain:Ptr):Int {
		var r = 1;
		var store = Arena.scopedValue(a -> Crypt32.CertOpenSystemStoreW(Ptr.nil(), a.wstring("Root")));
		if (!store.isNull()) {
			var cert = Ptr.nil();
			while (!(cert = Crypt32.CertEnumCertificatesInStore(store, cert)).isNull()) {
				// CERT_CONTEXT: dwCertEncodingType, pbCertEncoded (8), cbCertEncoded (16)
				r = M.mbedtls_x509_crt_parse_der(chain, Mem.getPtr(cert, 8), (Mem.getI32(cert, 16) : I64));
				if (r != 0) return r; // as upstream (which leaves the store open)
			}
			Crypt32.CertCloseStore(store, 0);
		}
		return r;
	}

	// upstream's Windows verify callback (ml_mbedtls_ssl_config_init): a chain
	// mbedtls rejects (other than for its name) is checked by the system, which
	// may know intermediate or root certificates the CA chain lacks
	@:hxmc.callback @:hxmc.noGc static function verifyCallback(param:Ptr, crt:Ptr, depth:Int, flags:Ptr):Int {
		var f = Mem.getI32(flags, 0);
		if (f == 0 || f & BADCERT_CN_MISMATCH != 0) return 0;
		// CERT_STORE_PROV_MEMORY, CERT_STORE_DEFER_CLOSE_UNTIL_LAST_FREE_FLAG
		var store = Crypt32.CertOpenStore(Ptr.ofI64(2), 0, Ptr.nil(), 4, Ptr.nil());
		if (store.isNull()) return ERR_X509_FATAL_ERROR;
		var primary:Ptr<Ptr> = Mem.stack(16);
		primary.value = Ptr.nil();
		// X509_ASN_ENCODING, CERT_STORE_ADD_REPLACE_EXISTING; crt->raw: len at 8, p at 16
		if (Crypt32.CertAddEncodedCertificateToStore(store, 1, Mem.getPtr(crt, CRT_RAW + 16), Mem.getI32(crt, CRT_RAW + 8), 3, primary) == 0) {
			Crypt32.CertCloseStore(store, 0);
			return ERR_X509_FATAL_ERROR;
		}
		// (zeroed: CERT_CHAIN_PARA, CERT_CHAIN_POLICY_PARA, CERT_CHAIN_POLICY_STATUS, as upstream's memsets)
		var parameters:Ptr = Mem.stack(64);
		var policyParameters:Ptr = Mem.stack(64);
		var policyStatus:Ptr = Mem.stack(64);
		LibC.memset(parameters, 0, 64);
		LibC.memset(policyParameters, 0, 64);
		LibC.memset(policyStatus, 0, 64);
		var chain:Ptr<Ptr> = Mem.stack(16);
		chain.value = Ptr.nil();
		if (Crypt32.CertGetCertificateChain(Ptr.nil(), primary.value, Ptr.nil(), store, parameters, 0, Ptr.nil(), chain) == 0) {
			Crypt32.CertFreeCertificateContext(primary.value);
			Crypt32.CertCloseStore(store, 0);
			return ERR_X509_FATAL_ERROR;
		}
		// CERT_CHAIN_POLICY_SSL
		if (Crypt32.CertVerifyCertificateChainPolicy(Ptr.ofI64(4), chain.value, policyParameters, policyStatus) == 0) {
			Crypt32.CertFreeCertificateChain(chain.value);
			Crypt32.CertFreeCertificateContext(primary.value);
			Crypt32.CertCloseStore(store, 0);
			return ERR_X509_FATAL_ERROR;
		}
		// CERT_CHAIN_POLICY_STATUS.dwError (4)
		if (Mem.getI32(policyStatus, 4) == 0) Mem.setI32(flags, 0, 0) else Mem.setI32(flags, 0, f | BADCERT_OTHER);
		Crypt32.CertFreeCertificateChain(chain.value);
		Crypt32.CertFreeCertificateContext(primary.value);
		Crypt32.CertCloseStore(store, 0);
		return 0;
	}

	// upstream's macOS branch (SecTrustCopyAnchorCertificates), with the
	// Security and CoreFoundation functions looked up at run time (dlopen,
	// called through their addresses): a program that never loads the
	// defaults loads neither framework
	static function loadMacosRoots(chain:Ptr):Int {
		return Arena.scopedValue(a -> {
			var r = 1;
			var sec = Dl.dlopen(a.cstring("/System/Library/Frameworks/Security.framework/Security"), 1); // RTLD_LAZY
			var cf = Dl.dlopen(a.cstring("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"), 1);
			if (sec.isNull() || cf.isNull()) return r;
			var copyAnchors = Dl.dlsym(sec, a.cstring("SecTrustCopyAnchorCertificates"));
			var copyData = Dl.dlsym(sec, a.cstring("SecCertificateCopyData"));
			var arrayCount = Dl.dlsym(cf, a.cstring("CFArrayGetCount"));
			var arrayGet = Dl.dlsym(cf, a.cstring("CFArrayGetValueAtIndex"));
			var dataPtr = Dl.dlsym(cf, a.cstring("CFDataGetBytePtr"));
			var dataLen = Dl.dlsym(cf, a.cstring("CFDataGetLength"));
			var release = Dl.dlsym(cf, a.cstring("CFRelease"));
			if (copyAnchors.isNull() || copyData.isNull() || arrayCount.isNull() || arrayGet.isNull() || dataPtr.isNull() || dataLen.isNull()
				|| release.isNull()) return r;
			var certs:Ptr<Ptr> = a.alloc(8);
			if (Dl.call1i(copyAnchors, certs) == 0) { // errSecSuccess
				var count = Dl.call1l(arrayCount, certs.value);
				var i:I64 = 0;
				while (i < count) {
					var data = Dl.call1p(copyData, Dl.call2p(arrayGet, certs.value, i));
					if (!data.isNull()) {
						r = M.mbedtls_x509_crt_parse_der(chain, Dl.call1p(dataPtr, data), Dl.call1l(dataLen, data));
						Dl.call1v(release, data);
						if (r != 0) return r; // as upstream (which keeps the array)
					}
					i = i + 1;
				}
				Dl.call1v(release, certs.value);
			}
			return r;
		});
	}

	// ---- Config

	public static function configInit():Dynamic {
		var p = alloc(SSL_CONFIG_SIZE);
		M.mbedtls_ssl_config_init(p);
		if (os() == 2) M.mbedtls_ssl_conf_verify(p, Callback.addr(verifyCallback), Ptr.nil());
		return Rt.rt_native_new_refs(p, Callback.addr(freeSslConfig), 2);
	}

	public static function confAuthmode(conf:Dynamic, authmode:Int):Void
		M.mbedtls_ssl_conf_authmode(ptr(conf), authmode);

	public static function confCaChain(conf:Dynamic, caChain:Dynamic):Void {
		setRef(conf, CONF_REF_CA, caChain);
		M.mbedtls_ssl_conf_ca_chain(ptr(conf), ptr(caChain), Ptr.nil());
	}

	public static function configDefaults(conf:Dynamic, endpoint:Int, transport:Int, preset:Int):Int
		return M.mbedtls_ssl_config_defaults(ptr(conf), endpoint, transport, preset);

	public static function confRng(conf:Dynamic, rng:Dynamic):Void {
		setRef(conf, CONF_REF_RNG, rng);
		M.mbedtls_ssl_conf_rng(ptr(conf), Mem.sym("mbedtls_ctr_drbg_random"), ptr(rng));
	}

	// ---- Pk: ml_mbedtls_pk_parse_* return the C int without Val_int, so OCaml
	// reads the result as an immediate (r asr 1); the error codes Eval sees are halved

	static inline function camlRawInt(r:Int):Int
		return r >> 1;

	public static function pkInit():Dynamic {
		var p = alloc(PK_SIZE);
		M.mbedtls_pk_init(p);
		return Rt.rt_native_new_refs(p, Callback.addr(freePk), 0);
	}

	public static function pkParseKey(ctx:Dynamic, key:Bytes, password:Null<String>, rng:Dynamic):Int {
		return Arena.scopedValue(a -> {
			var pwd = a.cstring(password);
			var pwdlen:I64 = pwd.isNull() ? 0 : (pwd.length() : I64);
			camlRawInt(M.mbedtls_pk_parse_key(ptr(ctx), bytesZ(a, key), (key.length + 1 : I64), pwd, pwdlen));
		});
	}

	public static function pkParseKeyfile(ctx:Dynamic, path:String, password:Null<String>, rng:Dynamic):Int
		return Arena.scopedValue(a -> camlRawInt(M.mbedtls_pk_parse_keyfile(ptr(ctx), a.cstring(path), a.cstring(password))));

	public static function pkParsePublicKey(ctx:Dynamic, key:Bytes):Int
		return Arena.scopedValue(a -> camlRawInt(M.mbedtls_pk_parse_public_key(ptr(ctx), bytesZ(a, key), (key.length + 1 : I64))));

	public static function pkParsePublicKeyfile(ctx:Dynamic, path:String):Int
		return Arena.scopedValue(a -> camlRawInt(M.mbedtls_pk_parse_public_keyfile(ptr(ctx), a.cstring(path))));

	// ---- Ssl: the context and its BIO state (hx_ssl)

	public static function sslInit():Dynamic {
		var s = LibC.malloc((HX_SSL_SIZE : I64));
		LibC.memset(s, 0, (HX_SSL_SIZE : I64));
		M.mbedtls_ssl_init(s);
		Mem.setI32(s, SSL_FD, -1);
		return Rt.rt_native_new_refs(s, Callback.addr(freeSsl), 1);
	}

	// null: none
	public static function sslGetPeerCert(ssl:Dynamic):Dynamic {
		var crt = M.mbedtls_ssl_get_peer_cert(ptr(ssl));
		return crt.isNull() ? null : borrow(crt, ssl);
	}

	public static function sslHandshake(ssl:Dynamic):Int {
		var s = ptr(ssl);
		Mem.setI32(s, SSL_BIO_ERRNO, 0);
		return MBlocking.mbedtls_ssl_handshake(s);
	}

	// mbedtls reads and writes a malloc'ed copy (the call is in a safe region:
	// a collection may move `buf` meanwhile)
	public static function sslRead(ssl:Dynamic, buf:Bytes, pos:Int, len:Int):Int {
		var s = ptr(ssl);
		Mem.setI32(s, SSL_BIO_ERRNO, 0);
		var tmp = LibC.malloc((len > 0 ? len : 1 : I64));
		var r = MBlocking.mbedtls_ssl_read(s, tmp, (len : I64));
		if (r > 0) LibC.memcpy(bytes(buf).add(pos), tmp, (r : I64));
		LibC.free(tmp);
		return r;
	}

	public static function sslWrite(ssl:Dynamic, buf:Bytes, pos:Int, len:Int):Int {
		var s = ptr(ssl);
		Mem.setI32(s, SSL_BIO_ERRNO, 0);
		var tmp = LibC.malloc((len > 0 ? len : 1 : I64));
		if (len > 0) LibC.memcpy(tmp, bytes(buf).add(pos), (len : I64));
		var r = MBlocking.mbedtls_ssl_write(s, tmp, (len : I64));
		LibC.free(tmp);
		return r;
	}

	// the BIO: Unix.send / Unix.recv socket bytes 0 (Bytes.length bytes) []
	// (called by mbedtls inside the handshake, read or write: in their safe region)
	@:hxmc.noGc static function bioFailed(s:Ptr, send:Bool):Int {
		var e = os() == 2 ? Winsock.rt_win_sock_errno(Winsock.WSAGetLastError()) : Mem.getI32(os() == 1 ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location(), 0);
		Mem.setI32(s, SSL_BIO_ERRNO, e);
		Mem.setI32(s, SSL_BIO_SEND, send ? 1 : 0);
		return send ? ERR_NET_SEND_FAILED : ERR_NET_RECV_FAILED;
	}

	@:hxmc.callback @:hxmc.noGc static function bioWrite(s:Ptr, buf:Ptr, len:I64):Int {
		var fd = Mem.getI32(s, SSL_FD);
		var r:I64 = os() == 2 ? (Winsock.send((fd : I64), buf, len.toInt(), 0) : I64) : Posix.send(fd, buf, len, 0);
		return r < 0 ? bioFailed(s, true) : r.toInt();
	}

	@:hxmc.callback @:hxmc.noGc static function bioRead(s:Ptr, buf:Ptr, len:I64):Int {
		var fd = Mem.getI32(s, SSL_FD);
		var r:I64 = os() == 2 ? (Winsock.recv((fd : I64), buf, len.toInt(), 0) : I64) : Posix.recv(fd, buf, len, 0);
		return r < 0 ? bioFailed(s, false) : r.toInt();
	}

	// send/recv on the socket
	public static function sslSetBio(ssl:Dynamic, fd:Int):Void {
		var s = ptr(ssl);
		Mem.setI32(s, SSL_FD, fd);
		M.mbedtls_ssl_set_bio(s, s, Callback.addr(bioWrite), Callback.addr(bioRead), Ptr.nil());
	}

	public static function sslSetHostname(ssl:Dynamic, hostname:String):Int
		return Arena.scopedValue(a -> M.mbedtls_ssl_set_hostname(ptr(ssl), a.cstring(hostname)));

	public static function sslSetup(ssl:Dynamic, conf:Dynamic):Int {
		setRef(ssl, SSL_REF_CONF, conf);
		return M.mbedtls_ssl_setup(ptr(ssl), ptr(conf));
	}

	// errno of the BIO's failed send/recv during the last handshake/read/write (0: none)
	public static function bioError(ssl:Dynamic):Int
		return Mem.getI32(ptr(ssl), SSL_BIO_ERRNO);

	public static function bioErrorSend(ssl:Dynamic):Bool
		return Mem.getI32(ptr(ssl), SSL_BIO_SEND) != 0;
}

// mbedtls_asn1_buf, mbedtls_asn1_sequence, mbedtls_x509_name, mbedtls_x509_time
@:hxmc.struct @:publicFields private class Asn1Buf {
	var tag:Int32;
	var len:UInt64;
	var p:Ptr<UInt8>;
}

@:hxmc.struct @:publicFields private class Asn1Sequence {
	var buf:Asn1Buf;
	var next:Ptr<Asn1Sequence>;
}

@:hxmc.struct @:publicFields private class X509Name {
	var oid:Asn1Buf;
	var val:Asn1Buf;
	var next:Ptr<X509Name>;
	var nextMerged:UInt8;
}

@:hxmc.struct @:publicFields private class X509Time {
	var year:Int32;
	var mon:Int32;
	var day:Int32;
	var hour:Int32;
	var min:Int32;
	var sec:Int32;
}

// the mbedtls functions (ssl.o): the handshake, reads and writes block on
// the socket (a safe region), the rest is quick
@:hxmc.c @:hxmc.fast private extern class M {
	static function mbedtls_strerror(code:Int, buf:Ptr, len:I64):Void;
	static function mbedtls_ctr_drbg_init(ctx:Ptr):Void;
	static function mbedtls_ctr_drbg_free(ctx:Ptr):Void;
	static function mbedtls_ctr_drbg_random(ctx:Ptr, out:Ptr, len:I64):Int;
	static function mbedtls_ctr_drbg_seed(ctx:Ptr, f:Ptr, entropy:Ptr, custom:Ptr, len:I64):Int;
	static function mbedtls_entropy_init(ctx:Ptr):Void;
	static function mbedtls_entropy_free(ctx:Ptr):Void;
	static function mbedtls_x509_crt_init(crt:Ptr):Void;
	static function mbedtls_x509_crt_free(crt:Ptr):Void;
	static function mbedtls_x509_crt_parse(crt:Ptr, buf:Ptr, len:I64):Int;
	static function mbedtls_x509_crt_parse_der(crt:Ptr, buf:Ptr, len:I64):Int;
	static function mbedtls_x509_crt_parse_file(crt:Ptr, path:CString):Int;
	static function mbedtls_x509_crt_parse_path(crt:Ptr, path:CString):Int;
	static function mbedtls_oid_get_attr_short_name(oid:Ptr, name:Ptr<CString>):Int;
	static function mbedtls_ssl_config_init(conf:Ptr):Void;
	static function mbedtls_ssl_config_free(conf:Ptr):Void;
	static function mbedtls_ssl_conf_verify(conf:Ptr, f:Ptr, param:Ptr):Void;
	static function mbedtls_ssl_conf_authmode(conf:Ptr, mode:Int):Void;
	static function mbedtls_ssl_conf_ca_chain(conf:Ptr, ca:Ptr, crl:Ptr):Void;
	static function mbedtls_ssl_config_defaults(conf:Ptr, endpoint:Int, transport:Int, preset:Int):Int;
	static function mbedtls_ssl_conf_rng(conf:Ptr, f:Ptr, rng:Ptr):Void;
	static function mbedtls_pk_init(pk:Ptr):Void;
	static function mbedtls_pk_free(pk:Ptr):Void;
	static function mbedtls_pk_parse_key(pk:Ptr, key:Ptr, keylen:I64, pwd:Ptr, pwdlen:I64):Int;
	static function mbedtls_pk_parse_keyfile(pk:Ptr, path:CString, pwd:CString):Int;
	static function mbedtls_pk_parse_public_key(pk:Ptr, key:Ptr, keylen:I64):Int;
	static function mbedtls_pk_parse_public_keyfile(pk:Ptr, path:CString):Int;
	static function mbedtls_ssl_init(ssl:Ptr):Void;
	static function mbedtls_ssl_free(ssl:Ptr):Void;
	static function mbedtls_ssl_get_peer_cert(ssl:Ptr):Ptr;
	static function mbedtls_ssl_set_bio(ssl:Ptr, ctx:Ptr, send:Ptr, recv:Ptr, recvTimeout:Ptr):Void;
	static function mbedtls_ssl_set_hostname(ssl:Ptr, host:CString):Int;
	static function mbedtls_ssl_setup(ssl:Ptr, conf:Ptr):Int;
}

@:hxmc.c private extern class MBlocking {
	static function mbedtls_ssl_handshake(ssl:Ptr):Int;
	static function mbedtls_ssl_read(ssl:Ptr, buf:Ptr, len:I64):Int;
	static function mbedtls_ssl_write(ssl:Ptr, buf:Ptr, len:I64):Int;
}

// Windows' certificate store (crypt32.dll)
@:hxmc.c @:hxmc.fast @:hxmc.lib("crypt32") private extern class Crypt32 {
	static function CertOpenSystemStoreW(prov:Ptr, name:Ptr<UInt16>):Ptr;
	static function CertEnumCertificatesInStore(store:Ptr, prev:Ptr):Ptr;
	static function CertCloseStore(store:Ptr, flags:Int):Int;
	static function CertOpenStore(provider:Ptr, encoding:Int, prov:Ptr, flags:Int, para:Ptr):Ptr;
	static function CertAddEncodedCertificateToStore(store:Ptr, encoding:Int, data:Ptr, len:Int, disposition:Int, out:Ptr<Ptr>):Int;
	static function CertGetCertificateChain(engine:Ptr, cert:Ptr, time:Ptr, store:Ptr, para:Ptr, flags:Int, reserved:Ptr, out:Ptr<Ptr>):Int;
	static function CertVerifyCertificateChainPolicy(policy:Ptr, chain:Ptr, para:Ptr, status:Ptr):Int;
	static function CertFreeCertificateChain(chain:Ptr):Void;
	static function CertFreeCertificateContext(cert:Ptr):Int;
}

// macOS: frameworks looked up at run time (libSystem's dlopen, dlsym), their
// functions called through the addresses
@:hxmc.c @:hxmc.fast private extern class Dl {
	static function dlopen(path:CString, mode:Int):Ptr;
	static function dlsym(handle:Ptr, name:CString):Ptr;
	@:hxmc.indirect static function call1i(f:Ptr, a:Ptr):Int;
	@:hxmc.indirect static function call1l(f:Ptr, a:Ptr):I64;
	@:hxmc.indirect static function call1p(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call1v(f:Ptr, a:Ptr):Void;
	@:hxmc.indirect static function call2p(f:Ptr, a:Ptr, b:I64):Ptr;
}
