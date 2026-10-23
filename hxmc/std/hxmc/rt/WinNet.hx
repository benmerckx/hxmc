package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.Win32;
import hxmc.unsafe.Winsock;

// Winsock of hxmc.NativeNet on Windows (formerly rt_net_win.c), as PosixNet
// does with BSD sockets elsewhere, standing for OCaml's Unix library on
// Windows. A socket is its SOCKET handle as an Int. Errors are Winsock's,
// mapped to the errno values OCaml's Unix library reports for them
// (WinRt.sockErrno); strerror is the C runtime's message for
// those. Sockets are not inherited by child processes. Winsock has no way
// to ask whether a socket blocks, so the sockets the program made
// non-blocking (setBlocking) are remembered here (a malloc'ed table under
// a spin lock, Names.spin[3]).
class WinNet {
	static inline function threads():Int
		return Mem.getI32(Mem.sym("rt_nthreads"), 0);

	static inline var SOL_SOCKET = 0xffff;
	static inline var SO_REUSEADDR = 4;
	static inline var SO_BROADCAST = 0x20;
	static inline var SO_RCVTIMEO = 0x1006;
	static inline var SO_SNDTIMEO = 0x1005;
	static inline var SO_ERROR = 0x1007;
	static inline var FIONBIO = 0x8004667E;
	static inline var WSAEWOULDBLOCK = 10035;
	// the UCRT's errno values
	static inline var EAGAIN = 11;
	static inline var EWOULDBLOCK = 140;
	static inline var EBADF = 9;
	static inline var EINVAL = 22;

	// the last failure's errno, per thread
	@:hxmc.threadLocal static var netErrno:Int;

	static inline function setLast(e:Int)
		netErrno = e;

	static inline function lastErrno():Int
		return netErrno;

	@:hxmc.noGc static function fail():Int {
		setLast(Winsock.rt_win_sock_errno(Winsock.WSAGetLastError()));
		return -1;
	}

	@:hxmc.noGc static function ret(r:Int):Int
		return r == -1 ? fail() : r; // SOCKET_ERROR

	static inline function sock(fd:Int):I64
		return fd;

	@:hxmc.noGc public static function getErrno():Int
		return lastErrno();

	public static function strerror(err:Int):String {
		var s = Winsock.strerror(err);
		return Str.ofUtf8(s, LibC.strlen(s).toInt());
	}

	// ---- the sockets in non-blocking mode

	static var nonblocking:Ptr;
	static var nNonblocking:Int;
	static var capNonblocking:Int;

	@:hxmc.noGc static function lock() {
		var l = Names.spin.add(12);
		while (Atomic.cas32(l, 0, 1) != 0)
			Win32.Sleep(0);
	}

	@:hxmc.noGc static function unlock()
		Atomic.store32(Names.spin.add(12), 0);

	@:hxmc.noGc static function isNonblocking(s:I64):Bool {
		var r = false;
		lock();
		for (i in 0...nNonblocking)
			if (Mem.getI64At(nonblocking, 0, i) == s) r = true;
		unlock();
		return r;
	}

	@:hxmc.noGc static function setNonblocking(s:I64, on:Bool) {
		lock();
		var i = 0;
		while (i < nNonblocking) {
			if (Mem.getI64At(nonblocking, 0, i) == s) {
				nNonblocking--;
				Mem.setI64At(nonblocking, 0, i, Mem.getI64At(nonblocking, 0, nNonblocking));
			} else i++;
		}
		if (on) {
			if (nNonblocking == capNonblocking) {
				capNonblocking = capNonblocking > 0 ? capNonblocking * 2 : 16;
				nonblocking = LibC.realloc(nonblocking, 8 * capNonblocking);
			}
			Mem.setI64At(nonblocking, 0, nNonblocking++, s);
		}
		unlock();
	}

	// With other threads, a blocking call waits for the socket in a safe
	// region first (WSAPoll), so a collection can run meanwhile
	@:hxmc.noGc static function cooperative(s:I64):Bool
		return threads() > 1 && !isNonblocking(s);

	// SO_RCVTIMEO/SO_SNDTIMEO (milliseconds on Windows): seconds, -1 when none
	@:hxmc.noGc static function sockTimeout(s:I64, opt:Int):Float {
		var ms = Mem.stack(8), n = Mem.stack(8);
		Mem.setI32(ms, 0, 0);
		Mem.setI32(n, 0, 4);
		if (Winsock.getsockopt(s, SOL_SOCKET, opt, ms, n) != 0 || Mem.getI32(ms, 0) == 0) return -1;
		var v:I64 = Mem.getI32(ms, 0);
		var f:Float = cast(v & (((1 : I64) << 32) - 1));
		return f / 1000.0;
	}

	// waits for s as a blocking call would (with the socket's timeout):
	// false when the wait failed, the errno set as the call would have (EAGAIN: timeout)
	static function waitSock(s:I64, write:Bool):Bool {
		var r = Rt.rt_wait_fd(s.toInt(), write ? 1 : 0, sockTimeout(s, write ? SO_SNDTIMEO : SO_RCVTIMEO));
		if (r > 0) return true;
		setLast(r == 0 ? EAGAIN : EBADF);
		return false;
	}

	@:hxmc.noGc public static function socket():Int {
		Winsock.rt_win_sockets_init();
		var s = Winsock.socket(2, 1, 0); // AF_INET, SOCK_STREAM
		if (s == -1) return fail(); // INVALID_SOCKET
		Winsock.SetHandleInformation(s, 1, 0); // HANDLE_FLAG_INHERIT
		return s.toInt();
	}

	@:hxmc.noGc public static function close(fd:Int):Int {
		Leaf.rt_fd_closed(fd);
		setNonblocking(sock(fd), false);
		return ret(Winsock.closesocket(sock(fd)));
	}

	public static function accept(fd:Int):Int {
		var s = sock(fd);
		if (cooperative(s) && !waitSock(s, false)) return -1;
		var a = Mem.stack(128), n = Mem.stack(8);
		Mem.setI32(n, 0, 128);
		var c = Winsock.accept(s, a, n);
		if (c == -1) return fail();
		Winsock.SetHandleInformation(c, 1, 0);
		return c.toInt();
	}

	// sockaddr_in: u16 family, the port and the address in network order
	@:hxmc.noGc static function inetAddr(a:Ptr, ip:Int, port:Int) {
		LibC.memset(a, 0, 16);
		Mem.setI16(a, 0, 2);
		Mem.setI8(a, 2, port >> 8);
		Mem.setI8(a, 3, port);
		Mem.setI8(a, 4, ip >>> 24);
		Mem.setI8(a, 5, ip >> 16);
		Mem.setI8(a, 6, ip >> 8);
		Mem.setI8(a, 7, ip);
	}

	@:hxmc.noGc public static function bind(fd:Int, ip:Int, port:Int):Int {
		var a = Mem.stack(16);
		inetAddr(a, ip, port);
		return ret(Winsock.bind(sock(fd), a, 16));
	}

	public static function connect(fd:Int, ip:Int, port:Int):Int {
		var s = sock(fd);
		if (cooperative(s)) { // a non-blocking connect, then wait until it completes
			var arg = Mem.stack(8);
			Mem.setI32(arg, 0, 1);
			Winsock.ioctlsocket(s, FIONBIO, arg);
			var r = connectTo(s, ip, port);
			var e = r == -1 ? Winsock.WSAGetLastError() : 0;
			if (e == WSAEWOULDBLOCK) {
				if (waitSock(s, true)) {
					var err = Mem.stack(8), n = Mem.stack(8);
					Mem.setI32(err, 0, 0);
					Mem.setI32(n, 0, 4);
					Winsock.getsockopt(s, SOL_SOCKET, SO_ERROR, err, n);
					var x = Mem.getI32(err, 0);
					r = x != 0 ? -1 : 0;
					if (x != 0) setLast(Winsock.rt_win_sock_errno(x));
				} else r = -1;
			} else if (e != 0) setLast(Winsock.rt_win_sock_errno(e));
			Mem.setI32(arg, 0, 0);
			Winsock.ioctlsocket(s, FIONBIO, arg);
			return r;
		}
		return ret(connectTo(s, ip, port));
	}

	@:hxmc.noGc static function connectTo(s:I64, ip:Int, port:Int):Int {
		var a = Mem.stack(16);
		inetAddr(a, ip, port);
		return Winsock.connect(s, a, 16);
	}

	@:hxmc.noGc public static function listen(fd:Int, n:Int):Int
		return ret(Winsock.listen(sock(fd), n));

	public static function sockName(fd:Int, peer:Bool):Array<Int> {
		var s = Mem.stack(128), n = Mem.stack(8);
		Mem.setI32(n, 0, 128);
		var r = peer ? Winsock.getpeername(sock(fd), s, n) : Winsock.getsockname(sock(fd), s, n);
		if (r != 0) {
			fail();
			return null;
		}
		if (Mem.getU16(s, 0) != 2) return [0, -1];
		var ip = (Mem.getU8(s, 4) << 24) | (Mem.getU8(s, 5) << 16) | (Mem.getU8(s, 6) << 8) | Mem.getU8(s, 7);
		return [ip, (Mem.getU8(s, 2) << 8) | Mem.getU8(s, 3)];
	}

	// OCaml's Unix.recv/send check the range (Invalid_argument "Unix.recv")
	public static function recv(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.recv");
		var s = sock(fd);
		if (cooperative(s) && !waitSock(s, false)) return -1;
		return ret(recvHeap(s, b, pos, len));
	}

	public static function send(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.send");
		var s = sock(fd);
		if (cooperative(s) && !waitSock(s, true)) return -1;
		return ret(sendHeap(s, b, pos, len));
	}

	// (the buffer's pages committed first: WinSys.touch)
	@:hxmc.noGc static function recvHeap(s:I64, b:Dynamic, pos:Int, len:Int):Int {
		var p = Bytes.bytes(b).add(pos);
		WinSys.touch(p, len);
		return Winsock.recv(s, p, len, 0);
	}

	@:hxmc.noGc static function sendHeap(s:I64, b:Dynamic, pos:Int, len:Int):Int {
		var p = Bytes.bytes(b).add(pos);
		WinSys.touch(p, len);
		return Winsock.send(s, p, len, 0);
	}

	// Winsock's fd_set: u32 fd_count, then the SOCKETs (FD_SETSIZE 64)
	static inline var FD_SETSIZE = 64;

	static function toFdset(a:Array<Int>, s:Ptr) {
		Mem.setI32(s, 0, 0);
		if (Str.isNull(a)) return;
		for (i in 0...a.length) {
			var fd = sock(a[i]);
			var n = Mem.getI32(s, 0);
			var found = false;
			for (k in 0...n)
				if (Mem.getI64(s, 8 + 8 * k) == fd) found = true;
			if (!found && n < FD_SETSIZE) {
				Mem.setI64(s, 8 + 8 * n, fd);
				Mem.setI32(s, 0, n + 1);
			}
		}
	}

	static function fromFdset(a:Array<Int>, s:Ptr) {
		if (Str.isNull(a)) return;
		for (i in 0...a.length) {
			var fd = sock(a[i]);
			var found = false;
			for (k in 0...Mem.getI32(s, 0))
				if (Mem.getI64(s, 8 + 8 * k) == fd) found = true;
			if (!found) a[i] = -1;
		}
	}

	// Unix.select: a negative timeout waits forever; Winsock's select fails
	// without sockets, then the timeout is slept as select would
	public static function select(r:Array<Int>, w:Array<Int>, o:Array<Int>, timeout:Float):Int {
		var nr = Str.isNull(r) ? 0 : r.length, nw = Str.isNull(w) ? 0 : w.length, no = Str.isNull(o) ? 0 : o.length;
		if (nr > FD_SETSIZE || nw > FD_SETSIZE || no > FD_SETSIZE) {
			setLast(EINVAL);
			return -1;
		}
		if (nr + nw + no == 0) {
			if (timeout > 0) Rt.rt_sleep(timeout) else if (timeout < 0) Rt.rt_throw("select: no descriptor and no timeout");
			return 0;
		}
		if (threads() > 1 && timeout != 0) {
			// other threads run until a socket is ready or the timeout passes,
			// then select looks without waiting
			NetCore.waitFds(r, nr, w, nw, o, no, timeout);
			timeout = 0;
		}
		var rs = Mem.stack(528), ws = Mem.stack(528), os = Mem.stack(528);
		toFdset(r, rs);
		toFdset(w, ws);
		toFdset(o, os);
		var tv = Mem.stack(16);
		var tvp = Ptr.nil();
		if (timeout >= 0) {
			// struct timeval: two longs (32 bits on Windows)
			var s = Std.int(timeout);
			Mem.setI32(tv, 0, s);
			Mem.setI32(tv, 4, Std.int(1e6 * (timeout - s)));
			tvp = tv;
		}
		var n = Winsock.select(0, rs, ws, os, tvp);
		if (n == -1) return fail();
		fromFdset(r, rs);
		fromFdset(w, ws);
		fromFdset(o, os);
		return n;
	}

	@:hxmc.noGc static function setBool(fd:Int, level:Int, opt:Int, b:Bool):Int
		return NetCore.setBool(fd, level, opt, b);

	@:hxmc.noGc public static function setNoDelay(fd:Int, b:Bool):Int
		return setBool(fd, 6, 1, b); // IPPROTO_TCP, TCP_NODELAY

	@:hxmc.noGc public static function setBroadcast(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET, SO_BROADCAST, b);

	@:hxmc.noGc public static function setReuseAddr(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET, SO_REUSEADDR, b);

	// Unix.setsockopt_float SO_RCVTIMEO, then SO_SNDTIMEO (milliseconds)
	@:hxmc.noGc public static function setTimeout(fd:Int, t:Float):Int {
		var ms = Mem.stack(8);
		var v:I64 = cast(t * 1000.0);
		Mem.setI32(ms, 0, v.toInt());
		if (Winsock.setsockopt(sock(fd), SOL_SOCKET, SO_RCVTIMEO, ms, 4) != 0) return fail();
		return ret(Winsock.setsockopt(sock(fd), SOL_SOCKET, SO_SNDTIMEO, ms, 4));
	}

	@:hxmc.noGc public static function shutdown(fd:Int, mode:Int):Int
		return ret(Winsock.shutdown(sock(fd), mode == 0 ? 0 : mode == 1 ? 1 : 2));

	@:hxmc.noGc public static function setBlocking(fd:Int, b:Bool):Int {
		var nb = Mem.stack(8);
		Mem.setI32(nb, 0, b ? 0 : 1);
		if (Winsock.ioctlsocket(sock(fd), FIONBIO, nb) != 0) return fail();
		setNonblocking(sock(fd), !b);
		return 0;
	}

	@:hxmc.noGc public static function blocked():Bool
		return lastErrno() == EAGAIN || lastErrno() == EWOULDBLOCK;

	public static function gethostname():String {
		Winsock.rt_win_sockets_init();
		var buf = Mem.stack(4096);
		if (Winsock.gethostname(buf, 4095) != 0) {
			fail();
			return null;
		}
		Mem.setI8(buf, 4095, 0);
		return Str.ofUtf8(buf, LibC.strlen(buf).toInt());
	}

	// one lookup at a time (Names.spin[4]), in a safe region (it may block on the network)
	@:hxmc.noGc static function lockResolver()
		NetCore.lockResolver();

	@:hxmc.noGc static function unlockResolver()
		NetCore.unlockResolver();

	public static function resolve(name:String):Array<Int> {
		Winsock.rt_win_sockets_init();
		var n = Str.toUtf8(name);
		var ip = lookup(n);
		LibC.free(n);
		setLast(0);
		if ((ip >>> 32).toInt() == 0) return null;
		return [ip.toInt()];
	}

	// the host-order IPv4 address of n, with 1 << 32 set when found
	// (struct hostent: h_name, h_aliases, short h_addrtype, short h_length, h_addr_list)
	@:hxmc.noGc static function lookup(n:Ptr):I64
		return NetCore.lookup(n);

	public static function reverse(ip:Int):String {
		Winsock.rt_win_sockets_init();
		var name = reverseLookup(ip);
		setLast(0);
		if (name.isNull()) return null;
		var s = Str.ofUtf8(name, LibC.strlen(name).toInt());
		LibC.free(name);
		return s;
	}

	@:hxmc.noGc static function reverseLookup(ip:Int):Ptr
		return NetCore.reverseLookup(ip);
}
