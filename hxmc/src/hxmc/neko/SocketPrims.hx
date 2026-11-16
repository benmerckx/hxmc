package hxmc.neko;

import haxe.io.Bytes;
import hxmc.NativeNet;
import hxmc.neko.Prims.Register;
import hxmc.neko.StdPrims.NBuf;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

class NSocket {
	public var fd:Int;

	public function new(fd)
		this.fd = fd;
}

// libs/std/socket.c over hxmc.NativeNet (file descriptors). Neko's IPv4
// address is the network-order bytes read as a little-endian Int; NativeNet's
// is the host-order value.
class SocketPrims {
	static inline function swap(v:Int):Int
		return ((v >>> 24) & 0xFF) | ((v >> 8) & 0xFF00) | ((v & 0xFF00) << 8) | (v << 24);

	public static function sock(v:NValue):NSocket
		return v.abs("socket");

	// block_error: "Blocking" when the call would block, else the failure
	static function check(r:Int):Int {
		if (r < 0) {
			if (NativeNet.blocked()) throw new NekoError(NStr.of("Blocking"));
			throw Builtins.failure;
		}
		return r;
	}

	public static function register(add:Register) {
		var r = (n:String, k:Int, f:Prim) -> add("std@" + n, k, f);
		r("socket_init", 0, (vm, a) -> null);
		r("socket_new", 1, (vm, a) -> {
			if (a[0] == true) throw VM.error("UDP sockets are not supported");
			return new NAbs("socket", new NSocket(check(NativeNet.socket())));
		});
		r("socket_close", 1, (vm, a) -> {
			var s = sock(a[0]);
			if (s.fd >= 0) NativeNet.close(s.fd);
			s.fd = -1;
			return null;
		});
		r("socket_connect", 3, (vm, a) -> {
			var s = sock(a[0]);
			check(NativeNet.connect(s.fd, swap(a[1].int()), a[2].int()));
			return true;
		});
		r("socket_send", 4, (vm, a) -> {
			var s = sock(a[0]), b = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > b.length) throw Builtins.failure;
			return check(NativeNet.send(s.fd, b, p, l));
		});
		r("socket_send_char", 2, (vm, a) -> {
			var s = sock(a[0]), c = a[1].int();
			if (c < 0 || c > 255) throw Builtins.failure;
			var b = Bytes.alloc(1);
			b.set(0, c);
			check(NativeNet.send(s.fd, b, 0, 1));
			return true;
		});
		r("socket_recv", 4, (vm, a) -> {
			var s = sock(a[0]), b = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > b.length) throw Builtins.failure;
			return check(NativeNet.recv(s.fd, b, p, l));
		});
		r("socket_recv_char", 1, (vm, a) -> {
			var s = sock(a[0]);
			var b = Bytes.alloc(1);
			if (check(NativeNet.recv(s.fd, b, 0, 1)) == 0) throw Builtins.failure;
			return b.get(0);
		});
		r("socket_write", 2, (vm, a) -> {
			var s = sock(a[0]), b = a[1].str().b;
			var p = 0;
			while (p < b.length)
				p += check(NativeNet.send(s.fd, b, p, b.length - p));
			return true;
		});
		r("socket_read", 1, (vm, a) -> {
			var s = sock(a[0]);
			var out = new NBuf();
			var b = Bytes.alloc(1024);
			while (true) {
				var n = check(NativeNet.recv(s.fd, b, 0, b.length));
				if (n == 0) break;
				out.addBytes(b, 0, n);
			}
			return new NStr(out.bytes());
		});
		r("socket_listen", 2, (vm, a) -> {
			check(NativeNet.listen(sock(a[0]).fd, a[1].int()));
			return true;
		});
		r("socket_bind", 3, (vm, a) -> {
			var s = sock(a[0]);
			NativeNet.setReuseAddr(s.fd, true);
			check(NativeNet.bind(s.fd, swap(a[1].int()), a[2].int()));
			return true;
		});
		r("socket_accept", 1, (vm, a) -> new NAbs("socket", new NSocket(check(NativeNet.accept(sock(a[0]).fd)))));
		function addr(s:NSocket, peer:Bool):NValue {
			var r = NativeNet.sockName(s.fd, peer);
			if (r == null) throw Builtins.failure;
			return Arr.pair(swap(r[0]), r[1]);
		}
		r("socket_peer", 1, (vm, a) -> addr(sock(a[0]), true));
		r("socket_host", 1, (vm, a) -> addr(sock(a[0]), false));
		r("socket_set_timeout", 2, (vm, a) -> {
			check(NativeNet.setTimeout(sock(a[0]).fd, a[1] == null ? 0 : a[1].number()));
			return true;
		});
		r("socket_shutdown", 3, (vm, a) -> {
			var rd = a[1] == true, wr = a[2] == true;
			if (rd || wr) check(NativeNet.shutdown(sock(a[0]).fd, rd && wr ? 2 : rd ? 0 : 1));
			return true;
		});
		r("socket_set_blocking", 2, (vm, a) -> {
			check(NativeNet.setBlocking(sock(a[0]).fd, a[1] == true));
			return true;
		});
		r("socket_set_fast_send", 2, (vm, a) -> {
			check(NativeNet.setNoDelay(sock(a[0]).fd, a[1] == true));
			return true;
		});
		r("socket_set_broadcast", 2, (vm, a) -> {
			check(NativeNet.setBroadcast(sock(a[0]).fd, a[1] == true));
			return true;
		});
		r("socket_select", 4, (vm, a) -> {
			function socks(v:NValue):NArr
				return v == null ? Arr.make(0) : v.arr();
			var rs = socks(a[0]), ws = socks(a[1]), os = socks(a[2]);
			var rf = [for (s in rs) sock(s).fd], wf = [for (s in ws) sock(s).fd], of = [for (s in os) sock(s).fd];
			var n = NativeNet.select(rf, wf, of, a[3] == null ? -1.0 : a[3].number());
			if (n < 0) throw Builtins.failure;
			// (NativeNet.select sets the descriptors that are not ready to -1)
			function keep(all:NArr, fds:Array<Int>):NValue {
				var n = 0;
				for (fd in fds)
					if (fd >= 0) n++;
				var r = Arr.make(n);
				n = 0;
				for (i in 0...all.length)
					if (fds[i] >= 0) r[n++] = all[i];
				return r;
			}
			return Arr.triple(keep(rs, rf), keep(ws, wf), keep(os, of));
		});
		r("host_resolve", 1, (vm, a) -> {
			var name = a[0].str().toString();
			var ip = NativeNet.resolve(name);
			if (ip == null) throw Builtins.failure;
			return swap(ip[0]);
		});
		r("host_to_string", 1, (vm, a) -> {
			var ip = a[0].int();
			return NStr.of([ip & 0xFF, (ip >>> 8) & 0xFF, (ip >>> 16) & 0xFF, (ip >>> 24) & 0xFF].join("."));
		});
		r("host_reverse", 1, (vm, a) -> {
			var r = NativeNet.reverse(swap(a[0].int()));
			if (r == null) throw Builtins.failure;
			return NStr.of(r);
		});
		r("host_local", 0, (vm, a) -> {
			var r = NativeNet.gethostname();
			if (r == null) throw Builtins.failure;
			return NStr.of(r);
		});
	}
}
