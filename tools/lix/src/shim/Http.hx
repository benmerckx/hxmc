package shim;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import shim.Error;

using StringTools;

typedef Response = {
	/** The URL that answered, after redirects. **/
	final url:String;
	final status:Int;
	final headers:Map<String, String>;
	final body:Bytes;
}

// port: what lix does with node's http/https modules (lix.client.Download):
// GET (and the POST of haxe remoting) over HTTP/1.1 with redirects, written
// over sys.net.Socket and sys.ssl.Socket instead of std's sys.Http, which
// cannot report progress, tunnel through an HTTPS proxy (CONNECT) or decode
// chunked responses of unknown length piecewise. Proxies: HTTPS_PROXY /
// HTTP_PROXY / NO_PROXY (node's https.get ignores them; lix behind a proxy
// relied on global-agent). Trusted: the system's CA certificates, Mozilla's
// (shim.CaBundle, generated at build time) and SSL_CERT_FILE.
class Http {
	static public var USER_AGENT = 'lix';

	static inline var MAX_REDIRECTS = 20;

	/**
		Requests `url`, following redirects. Statuses >= 400 throw an `Error`
		with that code. `progress` gets the bytes received and the expected
		length (-1 when unknown).
	**/
	static public function request(url:String, ?options:{?method:String, ?headers:Array<{name:String, value:String}>, ?body:Bytes},
			?progress:(loaded:Int, total:Int) -> Void):Response {
		var method = options != null && options.method != null ? options.method : 'GET';
		for (i in 0...MAX_REDIRECTS) {
			var res = requestOnce(url, method, options, progress);
			if (res.status >= 400)
				throw Error.withData(res.status, statusMessage(res.status), res);
			switch res.headers.get('location') {
				case null:
					return res;
				case location:
					url = Url.parse(url).resolve(Url.parse(location)).toString();
			}
		}
		throw new Error('Too many redirects for $url');
	}

	static public function bytes(url:String):Bytes
		return request(url).body;

	static public function text(url:String):String
		return bytes(url).toString();

	static function statusMessage(status:Int)
		return switch status {
			case 400: 'Bad Request';
			case 401: 'Unauthorized';
			case 403: 'Forbidden';
			case 404: 'Not Found';
			case 429: 'Too Many Requests';
			case 500: 'Internal Server Error';
			case 502: 'Bad Gateway';
			case 503: 'Service Unavailable';
			default: 'HTTP Error $status';
		}

	static function proxyFor(scheme:String, host:String):Null<Url> {
		var noProxy = env('NO_PROXY', 'no_proxy');
		if (noProxy != null)
			for (entry in noProxy.split(',')) {
				var e = entry.trim().toLowerCase();
				if (e == '*')
					return null;
				if (e.startsWith('*.'))
					e = e.substr(1);
				if (e != '' && (host == e || (e.startsWith('.') && host.endsWith(e)) || host.endsWith('.' + e)))
					return null;
			}
		var p = scheme == 'https' ? env('HTTPS_PROXY', 'https_proxy') : env('HTTP_PROXY', 'http_proxy');
		return p == null || p == '' ? null : Url.parse(p.indexOf('://') == -1 ? 'http://$p' : p);
	}

	static function env(a:String, b:String):Null<String> {
		var v = Sys.getEnv(a);
		return v != null && v != '' ? v : Sys.getEnv(b);
	}

	static function connect(host:String, port:Int):sys.net.Socket {
		var s = new sys.net.Socket();
		s.setTimeout(30);
		s.connect(new sys.net.Host(host), port);
		return s;
	}

	static var ca:Null<sys.ssl.Certificate>;

	static function caChain():Null<sys.ssl.Certificate> {
		if (ca == null) {
			ca = sys.ssl.Certificate.loadDefaults();
			// node's bundled roots (Mozilla's, see tools/make/Make.hx), as the npm package trusts
			ca.add(CaBundle.PEM);
			var extra = Sys.getEnv('SSL_CERT_FILE');
			if (extra != null && sys.FileSystem.exists(extra))
				ca.add(sys.io.File.getContent(extra));
		}
		return ca;
	}

	// TLS over the connected plain socket `plain` (taken over)
	// port: std has no way to start TLS on an established connection (as for a
	// proxy tunnel), hence the use of hxmc's sys.ssl.Socket internals
	static function startTls(plain:sys.net.Socket, hostname:String):sys.net.Socket {
		#if (target.name == "hxmc")
		var s = new sys.ssl.Socket();
		@:privateAccess {
			hxmc.NativeNet.close(s.fd);
			s.fd = plain.fd;
			plain.fd = -1;
			s.setCA(caChain());
			s.conf = s.buildConfig(false);
			s.ssl = hxmc.NativeSsl.sslInit();
			hxmc.NativeSsl.sslSetup(s.ssl, s.conf);
			hxmc.NativeSsl.sslSetBio(s.ssl, s.fd);
			s.handshakeDone = false;
			s.hostname = hostname;
			hxmc.NativeSsl.sslSetHostname(s.ssl, hostname);
		}
		s.handshake();
		return s;
		#else
		throw new Error(NotImplemented, 'TLS through a proxy is not supported on this target');
		#end
	}

	static function open(url:Url):{socket:sys.net.Socket, absoluteForm:Bool} {
		var scheme = url.scheme;
		var host = url.host.name;
		var port = url.host.port != null ? url.host.port : scheme == 'https' ? 443 : 80;
		var proxy = proxyFor(scheme, host);
		if (proxy == null) {
			if (scheme == 'https') {
				var s = new sys.ssl.Socket();
				s.setCA(caChain());
				s.setTimeout(30);
				s.setHostname(host);
				s.connect(new sys.net.Host(host), port);
				return {socket: s, absoluteForm: false};
			}
			return {socket: connect(host, port), absoluteForm: false};
		}
		var s = connect(proxy.host.name, proxy.host.port != null ? proxy.host.port : 80);
		if (scheme != 'https')
			return {socket: s, absoluteForm: true};
		var req = 'CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n';
		if (proxy.auth != null)
			req += 'Proxy-Authorization: Basic ' + haxe.crypto.Base64.encode(Bytes.ofString(proxy.auth.urlDecode())) + '\r\n';
		s.output.writeString(req + '\r\n');
		var status = readHead(s.input).status;
		if (status != 200) {
			s.close();
			throw new Error(status, 'Proxy refused to connect to $host:$port (status $status)');
		}
		return {socket: startTls(s, host), absoluteForm: false};
	}

	static function readLine(i:haxe.io.Input):String {
		var b = new BytesBuffer();
		while (true) {
			var c = i.readByte();
			if (c == '\n'.code)
				break;
			if (c != '\r'.code)
				b.addByte(c);
		}
		return b.getBytes().toString();
	}

	static function readHead(i:haxe.io.Input):{status:Int, headers:Map<String, String>} {
		var statusLine = readLine(i);
		var parts = statusLine.split(' ');
		var status = parts.length > 1 ? Std.parseInt(parts[1]) : null;
		if (status == null)
			throw new Error('Invalid HTTP response: $statusLine');
		var headers = new Map();
		while (true) {
			var line = readLine(i);
			if (line == '')
				break;
			var colon = line.indexOf(':');
			if (colon > 0)
				headers.set(line.substr(0, colon).trim().toLowerCase(), line.substr(colon + 1).trim());
		}
		return {status: status, headers: headers};
	}

	static function requestOnce(raw:String, method:String, options:Null<{?headers:Array<{name:String, value:String}>, ?body:Bytes}>,
			progress:Null<(Int, Int) -> Void>):Response {
		var url = Url.parse(raw);
		if (url.host == null || (url.scheme != 'http' && url.scheme != 'https'))
			throw new Error(BadRequest, 'Unsupported url $raw');
		var conn = try open(url) catch (e:Error) throw e catch (e:Dynamic) throw new Error('Failed to download $raw because $e');
		var socket = conn.socket;
		try {
			var target = (url.path == '' ? '/' : url.path) + (url.query == null ? '' : '?' + url.query);
			if (conn.absoluteForm)
				target = 'http://${url.host}$target';
			var req = new StringBuf();
			req.add('$method $target HTTP/1.1\r\n');
			req.add('Host: ${url.host}\r\n');
			req.add('User-Agent: $USER_AGENT\r\n');
			req.add('Accept: */*\r\n');
			req.add('Connection: close\r\n');
			if (url.auth != null)
				req.add('Authorization: Basic ' + haxe.crypto.Base64.encode(Bytes.ofString(url.auth.urlDecode())) + '\r\n');
			var body = options == null ? null : options.body;
			if (options != null && options.headers != null)
				for (h in options.headers)
					req.add('${h.name}: ${h.value}\r\n');
			if (body != null)
				req.add('Content-Length: ${body.length}\r\n');
			req.add('\r\n');
			socket.output.writeString(req.toString());
			if (body != null)
				socket.output.writeFullBytes(body, 0, body.length);
			socket.output.flush();

			var input = socket.input;
			var head = readHead(input);
			while (head.status == 100)
				head = readHead(input);
			var out = new BytesBuffer();
			var chunk = Bytes.alloc(65536);
			var loaded = 0;
			var length = switch head.headers.get('content-length') {
				case null: -1;
				case v: Std.parseInt(v);
			}
			function readExactly(n:Int) {
				while (n > 0) {
					var r = input.readBytes(chunk, 0, n < chunk.length ? n : chunk.length);
					out.addBytes(chunk, 0, r);
					n -= r;
					loaded += r;
					if (progress != null)
						progress(loaded, length);
				}
			}
			if (method == 'HEAD' || head.status == 204 || head.status == 304) {}
			else if (head.headers.get('transfer-encoding') == 'chunked') {
				while (true) {
					var size = Std.parseInt('0x' + readLine(input).split(';')[0].trim());
					if (size == null)
						throw new Error('Invalid chunked response from $raw');
					if (size == 0)
						break;
					readExactly(size);
					readLine(input);
				}
			} else if (length >= 0)
				readExactly(length);
			else
				try {
					while (true) {
						var r = input.readBytes(chunk, 0, chunk.length);
						if (r == 0)
							break;
						out.addBytes(chunk, 0, r);
						loaded += r;
						if (progress != null)
							progress(loaded, -1);
					}
				} catch (e:haxe.io.Eof) {}
			socket.close();
			return {url: raw, status: head.status, headers: head.headers, body: out.getBytes()};
		} catch (e:Dynamic) {
			try socket.close() catch (_:Dynamic) {}
			if (Std.isOfType(e, Error))
				throw e;
			throw new Error('Failed to download $raw because $e');
		}
	}
}
