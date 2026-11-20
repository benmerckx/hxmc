package hxmc.neko;

import haxe.io.Bytes;
import hxmc.NativeSsl;
import hxmc.neko.Prims.Register;
import hxmc.neko.StdPrims.NBuf;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

// libs/ssl over hxmc's mbedtls (hxmc.NativeSsl), the certificates as
// sys.ssl.Certificate
class SslPrims {
	static inline var ERR_SSL_WANT_READ = -0x6900;
	static inline var ERR_SSL_WANT_WRITE = -0x6880;
	static inline var ERR_SSL_PEER_CLOSE_NOTIFY = -0x7880;
	static inline var ERR_SSL_RECEIVED_NEW_SESSION_TICKET = -0x7B00;

	static function blocking():NekoError
		return new NekoError(NStr.of("Blocking"));

	// an mbedtls result: the BIO's system error, Blocking, or the error's text
	static function result(ssl:NValue, r:Int):Int {
		var err = NativeSsl.bioError(ssl);
		if (err != 0) {
			if (hxmc.NativeNet.blocked()) throw blocking();
			throw VM.error("ssl network error");
		}
		if (r == ERR_SSL_WANT_READ || r == ERR_SSL_WANT_WRITE) throw blocking();
		return r;
	}

	static function cert(v:NValue):sys.ssl.Certificate
		return v.abs("ssl_cert");

	public static function register(add:Register) {
		var r = (n:String, k:Int, f:Prim) -> add("ssl@" + n, k, f);
		r("conf_new", 1, (vm, a) -> {
			var conf = NativeSsl.configInit();
			NativeSsl.configDefaults(conf, a[0] == true ? 1 : 0, 0, 0);
			NativeSsl.confRng(conf, sys.ssl.Mbedtls.getDefaultCtrDrbg());
			return new NAbs("ssl_conf", conf);
		});
		r("conf_close", 1, (vm, a) -> null);
		r("conf_set_ca", 2, (vm, a) -> {
			var conf = a[0].abs("ssl_conf");
			if (a[1] != null) NativeSsl.confCaChain(conf, @:privateAccess cert(a[1]).native);
			return null;
		});
		r("conf_set_verify", 2, (vm, a) -> {
			var conf = a[0].abs("ssl_conf");
			NativeSsl.confAuthmode(conf, a[1] == true ? 2 : (a[1] == null ? 1 : 0));
			return null;
		});
		r("conf_set_cert", 3, (vm, a) -> throw VM.error("ssl: server certificates are not supported"));
		r("conf_set_servername_callback", 2, (vm, a) -> null);
		r("ssl_new", 1, (vm, a) -> {
			var ssl = NativeSsl.sslInit();
			var e = NativeSsl.sslSetup(ssl, a[0].abs("ssl_conf"));
			if (e != 0) throw VM.error(NativeSsl.strerror(e));
			return new NAbs("ssl", ssl);
		});
		r("ssl_close", 1, (vm, a) -> null);
		r("ssl_set_socket", 2, (vm, a) -> {
			NativeSsl.sslSetBio(a[0].abs("ssl"), SocketPrims.sock(a[1]).fd);
			return null;
		});
		r("ssl_set_hostname", 2, (vm, a) -> {
			var e = NativeSsl.sslSetHostname(a[0].abs("ssl"), a[1].str().toString());
			if (e != 0) throw VM.error(NativeSsl.strerror(e));
			return null;
		});
		r("ssl_handshake", 1, (vm, a) -> {
			var ssl = a[0].abs("ssl");
			var e = result(ssl, NativeSsl.sslHandshake(ssl));
			if (e != 0) throw VM.error(NativeSsl.strerror(e));
			return null;
		});
		r("ssl_get_peer_certificate", 1, (vm, a) -> {
			var c = NativeSsl.sslGetPeerCert(a[0].abs("ssl"));
			return c == null ? null : new NAbs("ssl_cert", @:privateAccess new sys.ssl.Certificate(c));
		});
		function send(ssl:NValue, b:Bytes, p:Int, l:Int):Int {
			var n = result(ssl, NativeSsl.sslWrite(ssl, b, p, l));
			if (n < 0) throw VM.error(NativeSsl.strerror(n));
			return n;
		}
		function recv(ssl:NValue, b:Bytes, p:Int, l:Int):Int {
			var n = NativeSsl.sslRead(ssl, b, p, l);
			if (n == ERR_SSL_PEER_CLOSE_NOTIFY || n == ERR_SSL_RECEIVED_NEW_SESSION_TICKET) return 0;
			n = result(ssl, n);
			if (n < 0) throw VM.error(NativeSsl.strerror(n));
			return n;
		}
		r("ssl_send", 4, (vm, a) -> {
			var b = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > b.length) throw Builtins.failure;
			return send(a[0].abs("ssl"), b, p, l);
		});
		r("ssl_send_char", 2, (vm, a) -> {
			var c = a[1].int();
			if (c < 0 || c > 255) throw Builtins.failure;
			var b = Bytes.alloc(1);
			b.set(0, c);
			send(a[0].abs("ssl"), b, 0, 1);
			return true;
		});
		r("ssl_recv", 4, (vm, a) -> {
			var b = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > b.length) throw Builtins.failure;
			return recv(a[0].abs("ssl"), b, p, l);
		});
		r("ssl_recv_char", 1, (vm, a) -> {
			var b = Bytes.alloc(1);
			if (recv(a[0].abs("ssl"), b, 0, 1) == 0) throw Builtins.failure;
			return b.get(0);
		});
		r("ssl_write", 2, (vm, a) -> {
			var ssl = a[0].abs("ssl"), b = a[1].str().b;
			var p = 0;
			while (p < b.length)
				p += send(ssl, b, p, b.length - p);
			return true;
		});
		r("ssl_read", 1, (vm, a) -> {
			var ssl = a[0].abs("ssl");
			var out = new NBuf();
			var b = Bytes.alloc(4096);
			while (true) {
				var n = recv(ssl, b, 0, b.length);
				if (n == 0) break;
				out.addBytes(b, 0, n);
			}
			return new NStr(out.bytes());
		});
		r("ssl_get_verify_result", 1, (vm, a) -> {
			var v = NativeSsl.sslGetVerifyResult(a[0].abs("ssl"));
			if (v == -1) throw VM.error("not available");
			return v == 0;
		});
		// keys and digests (Neko: an abstract of kind pkey; digests by name)
		function key(data:NStr, isPublic:Bool, pass:NValue, pem:Bool):NAbs {
			var pk = NativeSsl.pkInit();
			var e = NativeSsl.pkParse(pk, data.b, isPublic, pass == null ? null : pass.str().toString(), pem);
			if (e != 0) throw VM.error(NativeSsl.strerror(e));
			return new NAbs("pkey", pk);
		}
		r("key_from_der", 2, (vm, a) -> key(a[0].str(), a[1].bool(), null, false));
		r("key_from_pem", 3, (vm, a) -> key(a[0].str(), a[1].bool(), a[2], true));
		function alg(v:NValue):String {
			var name = v.str().toString();
			if (NativeSsl.mdSize(name) == 0) throw VM.error("Invalid hash algorithm");
			return name;
		}
		r("dgst_make", 2, (vm, a) -> {
			var data = a[0].str(), name = alg(a[1]);
			var out = haxe.io.Bytes.alloc(NativeSsl.mdSize(name));
			var e = NativeSsl.md(name, data.b, out);
			if (e != 0) throw VM.error(NativeSsl.strerror(e));
			return new NStr(out);
		});
		r("dgst_sign", 3, (vm, a) -> {
			var data = a[0].str(), pk = a[1].abs("pkey"), name = alg(a[2]);
			var out = haxe.io.Bytes.alloc(1024);
			var n = NativeSsl.pkSign(pk, name, data.b, out, sys.ssl.Mbedtls.getDefaultCtrDrbg());
			if (n < 0) throw VM.error(NativeSsl.strerror(n));
			return new NStr(out.sub(0, n));
		});
		r("dgst_verify", 4, (vm, a) -> {
			var data = a[0].str(), sig = a[1].str(), pk = a[2].abs("pkey"), name = alg(a[3]);
			return NativeSsl.pkVerify(pk, name, data.b, sig.b) == 0;
		});
		r("cert_load_defaults", 0, (vm, a) -> new NAbs("ssl_cert", sys.ssl.Certificate.loadDefaults()));
		r("cert_load_file", 1, (vm, a) -> new NAbs("ssl_cert", sys.ssl.Certificate.loadFile(a[0].str().toString())));
		r("cert_load_path", 1, (vm, a) -> new NAbs("ssl_cert", sys.ssl.Certificate.loadPath(a[0].str().toString())));
		r("cert_get_subject", 2, (vm, a) -> {
			var s = cert(a[0]).subject(a[1].str().toString());
			return s == null ? null : NStr.of(s);
		});
		r("cert_get_issuer", 2, (vm, a) -> {
			var s = cert(a[0]).issuer(a[1].str().toString());
			return s == null ? null : NStr.of(s);
		});
		// (a list of [name, next] pairs, null after the last)
		r("cert_get_altnames", 1, (vm, a) -> {
			var names = cert(a[0]).altNames;
			var l:NValue = null;
			var i = names.length;
			while (i-- > 0) {
				var cell = Arr.pair(NStr.of(names[i]), l);
				l = cell;
			}
			return l;
		});
		function date(d:Date):NValue {
			var r = Arr.make(6);
			r[0] = d.getUTCFullYear();
			r[1] = d.getUTCMonth() + 1;
			r[2] = d.getUTCDate();
			r[3] = d.getUTCHours();
			r[4] = d.getUTCMinutes();
			r[5] = d.getUTCSeconds();
			return r;
		}
		r("cert_get_notbefore", 1, (vm, a) -> date(cert(a[0]).notBefore));
		r("cert_get_notafter", 1, (vm, a) -> date(cert(a[0]).notAfter));
		r("cert_get_next", 1, (vm, a) -> {
			var n = cert(a[0]).next();
			return n == null ? null : new NAbs("ssl_cert", n);
		});
		r("cert_add_pem", 2, (vm, a) -> {
			var c = a[0] == null ? sys.ssl.Certificate.fromString(a[1].str().toString()) : cert(a[0]);
			if (a[0] != null) c.add(a[1].str().toString());
			return new NAbs("ssl_cert", c);
		});
		r("cert_add_der", 2, (vm, a) -> {
			var c = cert(a[0]);
			c.addDER(a[1].str().b);
			return new NAbs("ssl_cert", c);
		});
	}
}
