package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;

// BSD sockets of hxmc.NativeNet on Linux and macOS (formerly rt_net.c;
// Windows: WinNet), standing for the OCaml Unix
// functions of Eval's socket and host natives. The constants and the
// sockaddr_in layout differ between Linux and macOS (below; macOS x86-64
// names select select$1050, as its headers do). With several threads, a
// call on a blocking socket does not block the process: it is made without
// blocking and the thread waits for the descriptor in the scheduler
// (rt_wait_fd, rt_wait_fds).
class PosixNet {
	static inline function mac():Bool
		return Mem.os() == 1;

	static inline function threads():Int
		return Mem.getI32(Mem.sym("rt_nthreads"), 0);

	// the C library's constants: Linux / macOS
	static inline function SOL_SOCKET():Int
		return mac() ? 0xffff : 1;

	static inline function SO_REUSEADDR():Int
		return mac() ? 4 : 2;

	static inline function SO_BROADCAST():Int
		return mac() ? 0x20 : 6;

	static inline function SO_RCVTIMEO():Int
		return mac() ? 0x1006 : 20;

	static inline function SO_SNDTIMEO():Int
		return mac() ? 0x1005 : 21;

	static inline function SO_ERROR():Int
		return mac() ? 0x1007 : 4;

	static inline function MSG_DONTWAIT():Int
		return mac() ? 0x80 : 0x40;

	static inline function EAGAIN():Int
		return mac() ? 35 : 11;

	static inline function EINPROGRESS():Int
		return mac() ? 36 : 115;

	static inline function O_NONBLOCK():Int
		return mac() ? 4 : 0x800;

	static inline var EINTR = 4;
	static inline var EBADF = 9;
	static inline var EINVAL = 22;
	static inline var F_GETFL = 3;
	static inline var F_SETFL = 4;

	@:hxmc.noGc static function errno():Int
		return Mem.getI32(mac() ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location(), 0);

	@:hxmc.noGc static function setErrno(e:Int)
		Mem.setI32(mac() ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location(), 0, e);

	// the last failure's errno, per thread
	@:hxmc.threadLocal static var netErrno:Int;

	@:hxmc.noGc static function ret(r:Int):Int {
		if (r < 0) netErrno = errno();
		return r;
	}

	static inline function lastErrno():Int
		return netErrno;

	@:hxmc.noGc public static function getErrno():Int
		return lastErrno();

	// with other threads, a blocking socket's calls wait in the scheduler
	@:hxmc.noGc static function cooperative(fd:Int):Bool {
		if (threads() <= 1) return false;
		var flags = Posix.fcntl(fd, F_GETFL, 0);
		return flags >= 0 && (flags & O_NONBLOCK()) == 0;
	}

	// SO_RCVTIMEO/SO_SNDTIMEO (setTimeout): seconds, -1 when none
	@:hxmc.noGc static function sockTimeout(fd:Int, opt:Int):Float {
		var tv = Mem.stack(16), n = Mem.stack(8);
		Mem.setI32(n, 0, 16);
		if (Posix.getsockopt(fd, SOL_SOCKET(), opt, tv, n) < 0) return -1;
		var s = Mem.getI64(tv, 0), us = Mem.getI32(tv, 8);
		if (s == 0 && us == 0) return -1;
		var sf:Float = cast s;
		return sf + us * 1e-6;
	}

	// waits for fd as a blocking call would (with the socket's timeout):
	// false when the wait failed, errno set as the call would have (EAGAIN: timeout)
	static function waitSock(fd:Int, write:Bool):Bool {
		var r = Rt.rt_wait_fd(fd, write ? 1 : 0, sockTimeout(fd, write ? SO_SNDTIMEO() : SO_RCVTIMEO()));
		if (r > 0) return true;
		setErrno(r == 0 ? EAGAIN() : EBADF);
		return false;
	}

	public static function strerror(err:Int):String {
		var s = Posix.strerror(err);
		return Str.ofUtf8(s, LibC.strlen(s).toInt());
	}

	// haxe/src/compiler/haxe.ml ignores SIGPIPE for the whole process; the
	// port's entry point does not, so the first socket does it
	static var sigpipeIgnored:Bool;

	@:hxmc.noGc public static function socket():Int {
		if (!sigpipeIgnored) {
			Posix.signal(13, Ptr.ofI64(1)); // SIGPIPE, SIG_IGN
			sigpipeIgnored = true;
		}
		// close-on-exec from the start (PosixSys.pipes): SOCK_CLOEXEC on Linux,
		// FD_CLOEXEC under the descriptor lock on macOS
		if (!mac()) return ret(Posix.socket(2, 1 | 0x80000, 0)); // PF_INET, SOCK_STREAM | SOCK_CLOEXEC
		Threads.lockSafe(Gc.fdLock);
		var fd = ret(PosixSys.cloexec(Posix.socket(2, 1, 0)));
		Os.unlock(Gc.fdLock);
		return fd;
	}

	@:hxmc.noGc public static function close(fd:Int):Int {
		Leaf.rt_fd_closed(fd);
		return ret(Posix.close(fd));
	}

	public static function accept(fd:Int):Int {
		if (cooperative(fd) && !waitSock(fd, false)) return ret(-1);
		var a = Mem.stack(128), n = Mem.stack(8);
		Mem.setI32(n, 0, 128);
		if (!mac()) return ret(Posix.accept4(fd, a, n, 0x80000)); // SOCK_CLOEXEC
		Threads.lockSafe(Gc.fdLock);
		var c = ret(PosixSys.cloexec(Posix.accept(fd, a, n)));
		Os.unlock(Gc.fdLock);
		return c;
	}

	// sockaddr_in of ip (host order) and port: Linux u16 family; macOS u8
	// length, u8 family; then the port and the address in network order
	@:hxmc.noGc static function inetAddr(a:Ptr, ip:Int, port:Int) {
		LibC.memset(a, 0, 16);
		if (mac()) {
			Mem.setI8(a, 0, 16);
			Mem.setI8(a, 1, 2);
		} else Mem.setI16(a, 0, 2);
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
		return ret(Posix.bind(fd, a, 16));
	}

	public static function connect(fd:Int, ip:Int, port:Int):Int {
		if (cooperative(fd)) { // a non-blocking connect, then wait until it completes
			var flags = Posix.fcntl(fd, F_GETFL, 0);
			Posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK());
			var r = connectTo(fd, ip, port);
			if (r < 0 && errno() == EINPROGRESS()) {
				if (waitSock(fd, true)) {
					var e = Mem.stack(8), n = Mem.stack(8);
					Mem.setI32(e, 0, 0);
					Mem.setI32(n, 0, 4);
					Posix.getsockopt(fd, SOL_SOCKET(), SO_ERROR(), e, n);
					var err = Mem.getI32(e, 0);
					r = err != 0 ? -1 : 0;
					setErrno(err);
				} else r = -1;
			}
			var e = errno();
			Posix.fcntl(fd, F_SETFL, flags);
			setErrno(e);
			return ret(r);
		}
		return ret(connectTo(fd, ip, port));
	}

	@:hxmc.noGc static function connectTo(fd:Int, ip:Int, port:Int):Int {
		var a = Mem.stack(16);
		inetAddr(a, ip, port);
		return Posix.connect(fd, a, 16);
	}

	@:hxmc.noGc public static function listen(fd:Int, n:Int):Int
		return ret(Posix.listen(fd, n));

	public static function sockName(fd:Int, peer:Bool):Array<Int> {
		var s = Mem.stack(128), n = Mem.stack(8);
		Mem.setI32(n, 0, 128);
		var r = peer ? Posix.getpeername(fd, s, n) : Posix.getsockname(fd, s, n);
		if (r < 0) {
			ret(-1);
			return null;
		}
		var family = mac() ? Mem.getU8(s, 1) : Mem.getU16(s, 0);
		if (family != 2) return [0, -1];
		var ip = (Mem.getU8(s, 4) << 24) | (Mem.getU8(s, 5) << 16) | (Mem.getU8(s, 6) << 8) | Mem.getU8(s, 7);
		return [ip, (Mem.getU8(s, 2) << 8) | Mem.getU8(s, 3)];
	}

	// OCaml's Unix.recv/send check the range (Invalid_argument "Unix.recv")
	public static function recv(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.recv");
		if (cooperative(fd)) {
			var r = 0;
			while (true) {
				r = Posix.recv(fd, Bytes.bytes(b).add(pos), len, MSG_DONTWAIT()).toInt();
				if (r >= 0) break;
				var e = errno();
				if (e != EAGAIN() && e != EINTR) break;
				if (e != EINTR && !waitSock(fd, false)) break;
			}
			return ret(r);
		}
		return ret(Posix.recv(fd, Bytes.bytes(b).add(pos), len, 0).toInt());
	}

	public static function send(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.send");
		if (cooperative(fd)) { // may send part of the buffer, as a signal-interrupted send does
			var r = 0;
			while (true) {
				r = Posix.send(fd, Bytes.bytes(b).add(pos), len, MSG_DONTWAIT()).toInt();
				if (r >= 0) break;
				var e = errno();
				if (e != EAGAIN() && e != EINTR) break;
				if (e != EINTR && !waitSock(fd, true)) break;
			}
			return ret(r);
		}
		return ret(Posix.send(fd, Bytes.bytes(b).add(pos), len, 0).toInt());
	}

	// an fd_set (1024 bits, the same bytes on Linux and macOS) of the
	// descriptors of a; false when one is out of range
	static function toFdset(a:Array<Int>, s:Ptr, maxfd:Ptr):Bool {
		LibC.memset(s, 0, 128);
		if (Str.isNull(a)) return true;
		for (i in 0...a.length) {
			var fd = a[i];
			if (fd < 0 || fd >= 1024) return false;
			Mem.setI8(s, fd >> 3, Mem.getU8(s, fd >> 3) | (1 << (fd & 7)));
			if (fd > Mem.getI32(maxfd, 0)) Mem.setI32(maxfd, 0, fd);
		}
		return true;
	}

	static function fromFdset(a:Array<Int>, s:Ptr) {
		if (Str.isNull(a)) return;
		for (i in 0...a.length) {
			var fd = a[i];
			if ((Mem.getU8(s, fd >> 3) >> (fd & 7)) & 1 == 0) a[i] = -1;
		}
	}

	// Unix.select (otherlib/unix/select_unix.c): a negative timeout waits forever
	public static function select(r:Array<Int>, w:Array<Int>, o:Array<Int>, timeout:Float):Int {
		var rs = Mem.stack(128), ws = Mem.stack(128), os = Mem.stack(128), maxfd = Mem.stack(8);
		Mem.setI32(maxfd, 0, -1);
		if (!toFdset(r, rs, maxfd) || !toFdset(w, ws, maxfd) || !toFdset(o, os, maxfd)) {
			netErrno = EINVAL;
			return -1;
		}
		if (threads() > 1 && timeout != 0) {
			// other threads run until a descriptor is ready or the timeout
			// passes, then select looks without waiting
			var nr = Str.isNull(r) ? 0 : r.length, nw = Str.isNull(w) ? 0 : w.length, no = Str.isNull(o) ? 0 : o.length;
			var p = LibC.malloc(8 * (nr + nw + no + 1));
			var k = 0;
			inline function add(fd:Int, events:Int) {
				Mem.setI32(p, 8 * k, fd);
				Mem.setI16(p, 8 * k + 4, events);
				Mem.setI16(p, 8 * k + 6, 0);
				k++;
			}
			for (i in 0...nr)
				add(r[i], 1); // POLLIN
			for (i in 0...nw)
				add(w[i], 4); // POLLOUT
			for (i in 0...no)
				add(o[i], 2); // POLLPRI
			Rt.rt_wait_fds(p, k, timeout);
			LibC.free(p);
			Mem.setI32(maxfd, 0, -1);
			if (!toFdset(r, rs, maxfd) || !toFdset(w, ws, maxfd) || !toFdset(o, os, maxfd)) {
				netErrno = EBADF;
				return -1;
			}
			timeout = 0;
		}
		var tv = Mem.stack(16);
		var tvp = Ptr.nil();
		if (timeout >= 0) {
			var s:I64 = cast timeout;
			Mem.setI64(tv, 0, s);
			var us:I64 = cast(1e6 * (timeout - (cast s : Float)));
			Mem.setI64(tv, 8, us);
			tvp = tv;
		}
		var n = doSelect(Mem.getI32(maxfd, 0) + 1, rs, ws, os, tvp);
		if (n < 0) {
			ret(-1);
			return -1;
		}
		fromFdset(r, rs);
		fromFdset(w, ws);
		fromFdset(o, os);
		return n;
	}

	@:hxmc.noGc static function doSelect(n:Int, r:Ptr, w:Ptr, o:Ptr, tv:Ptr):Int
		return Mem.target() == 2 ? Posix.select1050(n, r, w, o, tv) : Posix.select(n, r, w, o, tv);

	@:hxmc.noGc static function setBool(fd:Int, level:Int, opt:Int, b:Bool):Int {
		var v = Mem.stack(8);
		Mem.setI32(v, 0, b ? 1 : 0);
		return ret(Posix.setsockopt(fd, level, opt, v, 4));
	}

	@:hxmc.noGc public static function setNoDelay(fd:Int, b:Bool):Int
		return setBool(fd, 6, 1, b); // IPPROTO_TCP, TCP_NODELAY

	@:hxmc.noGc public static function setBroadcast(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET(), SO_BROADCAST(), b);

	@:hxmc.noGc public static function setReuseAddr(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET(), SO_REUSEADDR(), b);

	// Unix.setsockopt_float SO_RCVTIMEO, then SO_SNDTIMEO (struct timeval:
	// 64-bit seconds, then microseconds: a long on Linux, an int on macOS)
	@:hxmc.noGc public static function setTimeout(fd:Int, t:Float):Int {
		var tv = Mem.stack(16);
		LibC.memset(tv, 0, 16);
		var s:I64 = cast t;
		Mem.setI64(tv, 0, s);
		Mem.setI32(tv, 8, Std.int((t - (cast s : Float)) * 1e6));
		if (Posix.setsockopt(fd, SOL_SOCKET(), SO_RCVTIMEO(), tv, 16) < 0) return ret(-1);
		return ret(Posix.setsockopt(fd, SOL_SOCKET(), SO_SNDTIMEO(), tv, 16));
	}

	@:hxmc.noGc public static function shutdown(fd:Int, mode:Int):Int
		return ret(Posix.shutdown(fd, mode == 0 ? 0 : mode == 1 ? 1 : 2));

	// for sys.net.Socket.setBlocking (hxmc std; the Eval socket natives are blocking)
	@:hxmc.noGc public static function setBlocking(fd:Int, b:Bool):Int {
		var flags = Posix.fcntl(fd, F_GETFL, 0);
		if (flags < 0) return ret(-1);
		return ret(Posix.fcntl(fd, F_SETFL, b ? flags & ~O_NONBLOCK() : flags | O_NONBLOCK()));
	}

	// whether the last failure was EAGAIN/EWOULDBLOCK (a non-blocking socket not ready)
	@:hxmc.noGc public static function blocked():Bool
		return lastErrno() == EAGAIN();

	public static function gethostname():String {
		var buf = Mem.stack(4096);
		if (Posix.gethostname(buf, 4095) < 0) {
			ret(-1);
			return null;
		}
		Mem.setI8(buf, 4095, 0);
		return Str.ofUtf8(buf, LibC.strlen(buf).toInt());
	}

	// gethostbyname/gethostbyaddr return static data: one thread at a time
	// (a spin lock: Names.spin[0]), in a safe region (they may block
	// on the network), results copied out under the lock
	@:hxmc.noGc static function lockResolver() {
		var l = Names.spin;
		while (Atomic.cas32(l, 0, 1) != 0)
			Posix.sched_yield();
	}

	@:hxmc.noGc static function unlockResolver()
		Atomic.store32(Names.spin, 0);

	public static function resolve(name:String):Array<Int> {
		var n = Str.toUtf8(name);
		var ip = lookup(n);
		LibC.free(n);
		netErrno = 0;
		if ((ip >>> 32).toInt() == 0) return null;
		return [ip.toInt()];
	}

	// the host-order IPv4 address of n, with 1 << 32 set when found
	@:hxmc.noGc static function lookup(n:Ptr):I64 {
		var r:I64 = 0;
		Leaf.rt_blocking_enter();
		lockResolver();
		var h = Posix.gethostbyname(n);
		// struct hostent: h_name, h_aliases, int h_addrtype, int h_length, h_addr_list
		if (!h.isNull() && Mem.getI32(h, 16) == 2) {
			var list = Mem.getPtr(h, 24);
			var a = Mem.getPtr(list, 0);
			if (!a.isNull()) {
				var ip = (Mem.getU8(a, 0) << 24) | (Mem.getU8(a, 1) << 16) | (Mem.getU8(a, 2) << 8) | Mem.getU8(a, 3);
				r = ((1 : I64) << 32) | ((ip : I64) & (((1 : I64) << 32) - 1));
			}
		}
		unlockResolver();
		Leaf.rt_blocking_leave();
		return r;
	}

	public static function reverse(ip:Int):String {
		var name = reverseLookup(ip);
		netErrno = 0;
		if (name.isNull()) return null;
		var s = Str.ofUtf8(name, LibC.strlen(name).toInt());
		LibC.free(name);
		return s;
	}

	// a malloc'ed copy of the name of ip (host order), or null
	@:hxmc.noGc static function reverseLookup(ip:Int):Ptr {
		var a = Mem.stack(8);
		Mem.setI8(a, 0, ip >>> 24);
		Mem.setI8(a, 1, ip >> 16);
		Mem.setI8(a, 2, ip >> 8);
		Mem.setI8(a, 3, ip);
		var name = Ptr.nil();
		Leaf.rt_blocking_enter();
		lockResolver();
		var h = Posix.gethostbyaddr(a, 4, 2);
		if (!h.isNull() && !Mem.getPtr(h, 0).isNull()) name = Posix.strdup(Mem.getPtr(h, 0));
		unlockResolver();
		Leaf.rt_blocking_leave();
		return name;
	}
}
