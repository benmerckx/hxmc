package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.scoped.Fixed;
import hxmc.scoped.LE;
import hxmc.scoped.Ref;
import hxmc.scoped.Slice;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;
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
// a spin lock, Names.spin[3]). Over hxmc.unsafe.Winsock, whose calls take
// views of scoped memory (docs/plans/lowlevel.md, "The scoped C boundary"):
// the addresses, options and descriptor sets in Fixed buffers of the frame,
// read and written little-endian (hxmc.scoped.LE).
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

	@:hxmc.scoped static function fail():Int {
		setLast(Winsock.rt_win_sock_errno(Winsock.WSAGetLastError()));
		return -1;
	}

	@:hxmc.scoped static function ret(r:Int):Int
		return r == -1 ? fail() : r; // SOCKET_ERROR

	static inline function sock(fd:Int):I64
		return fd;

	@:hxmc.scoped public static function getErrno():Int
		return lastErrno();

	public static function strerror(err:Int):String {
		var s = Winsock.strerror(err);
		return Str.ofUtf8(s, LibC.strlen(s).toInt());
	}

	// ---- the sockets in non-blocking mode

	static var nonblocking:Ptr;
	static var nNonblocking:Int;
	static var capNonblocking:Int;

	@:hxmc.unsafe static function lock() {
		var l = Names.spin.add(12);
		while (Atomic.cas32(l, 0, 1) != 0)
			Win32.Sleep(0);
	}

	@:hxmc.unsafe static function unlock()
		Atomic.store32(Names.spin.add(12), 0);

	@:hxmc.unsafe static function isNonblocking(s:I64):Bool {
		var r = false;
		lock();
		for (i in 0...nNonblocking)
			if (Mem.getI64At(nonblocking, 0, i) == s) r = true;
		unlock();
		return r;
	}

	@:hxmc.unsafe static function setNonblocking(s:I64, on:Bool) {
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
	@:hxmc.unsafe static function cooperative(s:I64):Bool
		return threads() > 1 && !isNonblocking(s);

	// an int option
	@:hxmc.scoped static function intOption(s:I64, opt:Int):Int {
		var v = new Fixed<UInt8, 4>(), n = new Fixed<Int, 1>();
		n[0] = 4;
		if (Winsock.getsockopt(s, SOL_SOCKET, opt, v.view().ref(0), n.view().ref(0)) != 0) return 0;
		return LE.i32(v.view(), 0);
	}

	// SO_RCVTIMEO/SO_SNDTIMEO (milliseconds on Windows): seconds, -1 when none
	@:hxmc.scoped static function sockTimeout(s:I64, opt:Int):Float {
		var ms = intOption(s, opt);
		if (ms == 0) return -1;
		var f:Float = cast((ms : I64) & (((1 : I64) << 32) - 1));
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

	@:hxmc.scoped public static function socket():Int {
		Winsock.rt_win_sockets_init();
		var s = Winsock.socket(2, 1, 0); // AF_INET, SOCK_STREAM
		if (s == -1) return fail(); // INVALID_SOCKET
		Winsock.SetHandleInformation(s, 1, 0); // HANDLE_FLAG_INHERIT
		return s.toInt();
	}

	@:hxmc.unsafe public static function close(fd:Int):Int {
		Leaf.rt_fd_closed(fd);
		setNonblocking(sock(fd), false);
		return ret(Winsock.closesocket(sock(fd)));
	}

	public static function accept(fd:Int):Int {
		var s = sock(fd);
		if (cooperative(s) && !waitSock(s, false)) return -1;
		var a = new Fixed<UInt8, 128>(), n = new Fixed<Int, 1>();
		n[0] = 128;
		var c = Winsock.accept(s, a.view().ref(0), n.view().ref(0));
		if (c == -1) return fail();
		Winsock.SetHandleInformation(c, 1, 0);
		return c.toInt();
	}

	// sockaddr_in: u16 family, the port and the address in network order
	@:hxmc.scoped static function inetAddr(a:Slice<UInt8>, ip:Int, port:Int) {
		LE.put16(a, 0, 2);
		a[2] = port >> 8;
		a[3] = port;
		LE.put32(a, 4, ((ip >>> 24) & 0xff) | ((ip >> 8) & 0xff00) | ((ip << 8) & 0xff0000) | (ip << 24));
	}

	@:hxmc.scoped public static function bind(fd:Int, ip:Int, port:Int):Int {
		var a = new Fixed<UInt8, 16>();
		inetAddr(a.view(), ip, port);
		return ret(Winsock.bind(sock(fd), a.view().ref(0), 16));
	}

	// FIONBIO: non-blocking (1) or blocking (0)
	@:hxmc.scoped static function nonblock(s:I64, on:Bool):Int {
		var arg = new Fixed<Int, 1>();
		arg[0] = on ? 1 : 0;
		return Winsock.ioctlsocket(s, FIONBIO, arg.view().ref(0));
	}

	public static function connect(fd:Int, ip:Int, port:Int):Int {
		var s = sock(fd);
		if (cooperative(s)) { // a non-blocking connect, then wait until it completes
			nonblock(s, true);
			var r = connectTo(s, ip, port);
			var e = r == -1 ? Winsock.WSAGetLastError() : 0;
			if (e == WSAEWOULDBLOCK) {
				if (waitSock(s, true)) {
					var x = intOption(s, SO_ERROR);
					r = x != 0 ? -1 : 0;
					if (x != 0) setLast(Winsock.rt_win_sock_errno(x));
				} else r = -1;
			} else if (e != 0) setLast(Winsock.rt_win_sock_errno(e));
			nonblock(s, false);
			return r;
		}
		return ret(connectTo(s, ip, port));
	}

	@:hxmc.scoped static function connectTo(s:I64, ip:Int, port:Int):Int {
		var a = new Fixed<UInt8, 16>();
		inetAddr(a.view(), ip, port);
		return Winsock.connect(s, a.view().ref(0), 16);
	}

	@:hxmc.scoped public static function listen(fd:Int, n:Int):Int
		return ret(Winsock.listen(sock(fd), n));

	public static function sockName(fd:Int, peer:Bool):Array<Int> {
		var a = new Fixed<UInt8, 128>(), n = new Fixed<Int, 1>();
		n[0] = 128;
		var s = a.view();
		var r = peer ? Winsock.getpeername(sock(fd), s.ref(0), n.view().ref(0)) : Winsock.getsockname(sock(fd), s.ref(0), n.view().ref(0));
		if (r != 0) {
			fail();
			return null;
		}
		if (LE.u16(s, 0) != 2) return [0, -1];
		var ip = (s[4] << 24) | (s[5] << 16) | (s[6] << 8) | s[7];
		return [ip, (s[2] << 8) | s[3]];
	}

	// the bytes [pos, pos + len) of the Bytes b, a view for a call that does
	// not block (nothing collects during it; its pages are touched first,
	// hx_view_touch)
	static inline function bytesView(b:Dynamic, pos:Int, len:Int):Slice<UInt8>
		return Slice.raw(Bytes.bytes(b).add(pos), len);

	// OCaml's Unix.recv/send check the range (Invalid_argument "Unix.recv")
	public static function recv(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.recv");
		var s = sock(fd);
		if (cooperative(s) && !waitSock(s, false)) return -1;
		return ret(Winsock.recv(s, bytesView(b, pos, len), 0));
	}

	public static function send(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.send");
		var s = sock(fd);
		if (cooperative(s) && !waitSock(s, true)) return -1;
		return ret(Winsock.send(s, bytesView(b, pos, len), 0));
	}

	// Winsock's fd_set: u32 fd_count, then the SOCKETs (FD_SETSIZE 64)
	static inline var FD_SETSIZE = 64;
	static inline var FD_SET = 8 + 8 * FD_SETSIZE;

	static function toFdset(a:Array<Int>, s:Slice<UInt8>) {
		LE.put32(s, 0, 0);
		if (Str.isNull(a)) return;
		for (i in 0...a.length) {
			var fd = sock(a[i]);
			var n = LE.i32(s, 0);
			var found = false;
			for (k in 0...n)
				if (LE.i64(s, 8 + 8 * k) == fd) found = true;
			if (!found && n < FD_SETSIZE) {
				LE.put64(s, 8 + 8 * n, fd);
				LE.put32(s, 0, n + 1);
			}
		}
	}

	static function fromFdset(a:Array<Int>, s:Slice<UInt8>) {
		if (Str.isNull(a)) return;
		for (i in 0...a.length) {
			var fd = sock(a[i]);
			var found = false;
			for (k in 0...LE.i32(s, 0))
				if (LE.i64(s, 8 + 8 * k) == fd) found = true;
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
		var sets:Fixed<UInt8, 1584> = Fixed.scratch(); // (each count written first)
		var rs = sets.view().sub(0, FD_SET), ws = sets.view().sub(FD_SET, FD_SET), os = sets.view().sub(2 * FD_SET, FD_SET);
		toFdset(r, rs);
		toFdset(w, ws);
		toFdset(o, os);
		// struct timeval: two longs (32 bits on Windows)
		var tv = new Fixed<UInt8, 8>();
		var tvp:Ref<UInt8> = Ref.nil();
		if (timeout >= 0) {
			var s = Std.int(timeout);
			LE.put32(tv.view(), 0, s);
			LE.put32(tv.view(), 4, Std.int(1e6 * (timeout - s)));
			tvp = tv.view().ref(0);
		}
		var n = Winsock.select(0, rs.ref(0), ws.ref(0), os.ref(0), tvp);
		if (n == -1) return fail();
		fromFdset(r, rs);
		fromFdset(w, ws);
		fromFdset(o, os);
		return n;
	}

	@:hxmc.scoped static function setBool(fd:Int, level:Int, opt:Int, b:Bool):Int
		return NetCore.setBool(fd, level, opt, b);

	@:hxmc.scoped public static function setNoDelay(fd:Int, b:Bool):Int
		return setBool(fd, 6, 1, b); // IPPROTO_TCP, TCP_NODELAY

	@:hxmc.scoped public static function setBroadcast(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET, SO_BROADCAST, b);

	@:hxmc.scoped public static function setReuseAddr(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET, SO_REUSEADDR, b);

	// Unix.setsockopt_float SO_RCVTIMEO, then SO_SNDTIMEO (milliseconds)
	@:hxmc.scoped public static function setTimeout(fd:Int, t:Float):Int {
		var ms = new Fixed<UInt8, 4>();
		var v:I64 = cast(t * 1000.0);
		LE.put32(ms.view(), 0, v.toInt());
		if (Winsock.setsockopt(sock(fd), SOL_SOCKET, SO_RCVTIMEO, ms.view().ref(0), 4) != 0) return fail();
		return ret(Winsock.setsockopt(sock(fd), SOL_SOCKET, SO_SNDTIMEO, ms.view().ref(0), 4));
	}

	@:hxmc.scoped public static function shutdown(fd:Int, mode:Int):Int
		return ret(Winsock.shutdown(sock(fd), mode == 0 ? 0 : mode == 1 ? 1 : 2));

	@:hxmc.unsafe public static function setBlocking(fd:Int, b:Bool):Int {
		if (nonblock(sock(fd), !b) != 0) return fail();
		setNonblocking(sock(fd), !b);
		return 0;
	}

	@:hxmc.scoped public static function blocked():Bool
		return lastErrno() == EAGAIN || lastErrno() == EWOULDBLOCK;

	public static function gethostname():String {
		Winsock.rt_win_sockets_init();
		var buf:Fixed<UInt8, 4096> = Fixed.scratch(); // (C fills it)
		var v = buf.view();
		if (Winsock.gethostname(v.sub(0, 4095)) != 0) {
			fail();
			return null;
		}
		v[4095] = 0;
		var n = 0;
		while (v[n] != 0)
			n++;
		return Str.ofUtf8(SysCore.viewAddr(v), n);
	}

	// one lookup at a time (Names.spin[4]), in a safe region (it may block on the network)
	@:hxmc.unsafe static function lockResolver()
		NetCore.lockResolver();

	@:hxmc.unsafe static function unlockResolver()
		NetCore.unlockResolver();

	public static function resolve(name:String):Array<Int> {
		Winsock.rt_win_sockets_init();
		var ip = lookup(SysCore.cstr(name));
		setLast(0);
		if ((ip >>> 32).toInt() == 0) return null;
		return [ip.toInt()];
	}

	// the host-order IPv4 address of n, with 1 << 32 set when found
	// (struct hostent: h_name, h_aliases, short h_addrtype, short h_length, h_addr_list)
	@:hxmc.unsafe static function lookup(n:Ptr):I64
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

	@:hxmc.unsafe static function reverseLookup(ip:Int):Ptr
		return NetCore.reverseLookup(ip);
}
