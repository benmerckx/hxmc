package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.scoped.Fixed;
import hxmc.scoped.LE;
import hxmc.scoped.Ref;
import hxmc.scoped.Scope;
import hxmc.scoped.Slice;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// BSD sockets of hxmc.NativeNet on Linux and macOS (formerly rt_net.c;
// Windows: WinNet), standing for the OCaml Unix
// functions of Eval's socket and host natives. The constants and the
// sockaddr_in layout differ between Linux and macOS (below; macOS x86-64
// names select select$1050, as its headers do). With several threads, a
// call on a blocking socket does not block the process: it is made without
// blocking and the thread waits for the descriptor in the scheduler
// (rt_wait_fd, rt_wait_fds). The C library's calls take views of scoped
// memory (hxmc.unsafe.Posix): addresses, options and descriptor sets in
// Fixed buffers of the frame, read and written little-endian (hxmc.scoped.LE).
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

	@:hxmc.scoped static function errno():Int
		return (mac() ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location()).value;

	@:hxmc.scoped static function setErrno(e:Int)
		(mac() ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location()).value = e;

	// the last failure's errno, per thread
	@:hxmc.threadLocal static var netErrno:Int;

	@:hxmc.scoped static function ret(r:Int):Int {
		if (r < 0) netErrno = errno();
		return r;
	}

	static inline function lastErrno():Int
		return netErrno;

	@:hxmc.scoped public static function getErrno():Int
		return lastErrno();

	// with other threads, a blocking socket's calls wait in the scheduler
	@:hxmc.scoped static function cooperative(fd:Int):Bool {
		if (threads() <= 1) return false;
		var flags = Posix.fcntl(fd, F_GETFL, 0);
		return flags >= 0 && (flags & O_NONBLOCK()) == 0;
	}

	// SO_RCVTIMEO/SO_SNDTIMEO (setTimeout): seconds, -1 when none
	@:hxmc.scoped static function sockTimeout(fd:Int, opt:Int):Float {
		var tv = new Fixed<UInt8, 16>(), n = new Fixed<Int, 1>();
		n[0] = 16;
		if (Posix.getsockopt(fd, SOL_SOCKET(), opt, tv.view().ref(0), n.view().ref(0)) < 0) return -1;
		var s = LE.i64(tv.view(), 0), us = LE.i32(tv.view(), 8);
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
		return SysCore.ofC(Posix.strerror(err));
	}

	// haxe/src/compiler/haxe.ml ignores SIGPIPE for the whole process; the
	// port's entry point does not, so the first socket does it
	static var sigpipeIgnored:Bool;

	@:hxmc.scoped public static function socket():Int {
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

	@:hxmc.scoped public static function close(fd:Int):Int {
		Leaf.rt_fd_closed(fd);
		return ret(Posix.close(fd));
	}

	public static function accept(fd:Int):Int {
		if (cooperative(fd) && !waitSock(fd, false)) return ret(-1);
		var a = new Fixed<UInt8, 128>(), n = new Fixed<Int, 1>();
		n[0] = 128;
		if (!mac()) return ret(Posix.accept4(fd, a.view().ref(0), n.view().ref(0), 0x80000)); // SOCK_CLOEXEC
		Threads.lockSafe(Gc.fdLock);
		var c = ret(PosixSys.cloexec(Posix.accept(fd, a.view().ref(0), n.view().ref(0))));
		Os.unlock(Gc.fdLock);
		return c;
	}

	// sockaddr_in of ip (host order) and port: Linux u16 family; macOS u8
	// length, u8 family; then the port and the address in network order
	@:hxmc.scoped static function inetAddr(a:Slice<UInt8>, ip:Int, port:Int) {
		if (mac()) {
			a[0] = 16;
			a[1] = 2;
		} else LE.put16(a, 0, 2);
		a[2] = port >> 8;
		a[3] = port;
		LE.put32(a, 4, ((ip >>> 24) & 0xff) | ((ip >> 8) & 0xff00) | ((ip << 8) & 0xff0000) | (ip << 24));
	}

	@:hxmc.scoped public static function bind(fd:Int, ip:Int, port:Int):Int {
		var a = new Fixed<UInt8, 16>();
		inetAddr(a.view(), ip, port);
		return ret(Posix.bind(fd, a.view().ref(0), 16));
	}

	public static function connect(fd:Int, ip:Int, port:Int):Int {
		if (cooperative(fd)) { // a non-blocking connect, then wait until it completes
			var flags = Posix.fcntl(fd, F_GETFL, 0);
			Posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK());
			var r = connectTo(fd, ip, port);
			if (r < 0 && errno() == EINPROGRESS()) {
				if (waitSock(fd, true)) {
					var e = new Fixed<UInt8, 4>(), n = new Fixed<Int, 1>();
					n[0] = 4;
					Posix.getsockopt(fd, SOL_SOCKET(), SO_ERROR(), e.view().ref(0), n.view().ref(0));
					var err = LE.i32(e.view(), 0);
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

	@:hxmc.scoped static function connectTo(fd:Int, ip:Int, port:Int):Int {
		var a = new Fixed<UInt8, 16>();
		inetAddr(a.view(), ip, port);
		return Posix.connect(fd, a.view().ref(0), 16);
	}

	@:hxmc.scoped public static function listen(fd:Int, n:Int):Int
		return ret(Posix.listen(fd, n));

	public static function sockName(fd:Int, peer:Bool):Array<Int> {
		var a = new Fixed<UInt8, 128>(), n = new Fixed<Int, 1>();
		n[0] = 128;
		var s = a.view();
		var r = peer ? Posix.getpeername(fd, s.ref(0), n.view().ref(0)) : Posix.getsockname(fd, s.ref(0), n.view().ref(0));
		if (r < 0) {
			ret(-1);
			return null;
		}
		var family = mac() ? s[1] : LE.u16(s, 0);
		if (family != 2) return [0, -1];
		var ip = (s[4] << 24) | (s[5] << 16) | (s[6] << 8) | s[7];
		return [ip, (s[2] << 8) | s[3]];
	}

	// the bytes [pos, pos + len) of the Bytes b, a view for a call that does
	// not block (nothing collects during it)
	static inline function bytesView(b:Dynamic, pos:Int, len:Int):Slice<UInt8>
		return Slice.raw(Bytes.bytes(b).add(pos), len);

	// OCaml's Unix.recv/send check the range (Invalid_argument "Unix.recv")
	public static function recv(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.recv");
		if (cooperative(fd)) {
			var r = 0;
			while (true) {
				r = Posix.recv(fd, bytesView(b, pos, len), MSG_DONTWAIT()).toInt();
				if (r >= 0) break;
				var e = errno();
				if (e != EAGAIN() && e != EINTR) break;
				if (e != EINTR && !waitSock(fd, false)) break;
			}
			return ret(r);
		}
		return ret(Posix.recv(fd, bytesView(b, pos, len), 0).toInt());
	}

	public static function send(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > Bytes.len(b) - len) Rt.rt_throw("Unix.send");
		if (cooperative(fd)) { // may send part of the buffer, as a signal-interrupted send does
			var r = 0;
			while (true) {
				r = Posix.send(fd, bytesView(b, pos, len), MSG_DONTWAIT()).toInt();
				if (r >= 0) break;
				var e = errno();
				if (e != EAGAIN() && e != EINTR) break;
				if (e != EINTR && !waitSock(fd, true)) break;
			}
			return ret(r);
		}
		return ret(Posix.send(fd, bytesView(b, pos, len), 0).toInt());
	}

	// an fd_set (1024 bits, the same bytes on Linux and macOS) of the
	// descriptors of a; false when one is out of range
	// (s zero)
	static function toFdset(a:Array<Int>, s:Slice<UInt8>, maxfd:Ref<Int>):Bool {
		if (Str.isNull(a)) return true;
		for (i in 0...a.length) {
			var fd = a[i];
			if (fd < 0 || fd >= 1024) return false;
			s[fd >> 3] = s[fd >> 3] | (1 << (fd & 7));
			if (fd > maxfd.value) maxfd.value = fd;
		}
		return true;
	}

	static function fromFdset(a:Array<Int>, s:Slice<UInt8>) {
		if (Str.isNull(a)) return;
		for (i in 0...a.length) {
			var fd = a[i];
			if ((s[fd >> 3] >> (fd & 7)) & 1 == 0) a[i] = -1;
		}
	}

	// Unix.select (otherlib/unix/select_unix.c): a negative timeout waits forever
	public static function select(r:Array<Int>, w:Array<Int>, o:Array<Int>, timeout:Float):Int {
		var sets = new Fixed<UInt8, 384>(), top = new Fixed<Int, 1>();
		var rs = sets.view().sub(0, 128), ws = sets.view().sub(128, 128), os = sets.view().sub(256, 128), maxfd = top.view().ref(0);
		maxfd.value = -1;
		if (!toFdset(r, rs, maxfd) || !toFdset(w, ws, maxfd) || !toFdset(o, os, maxfd)) {
			netErrno = EINVAL;
			return -1;
		}
		if (threads() > 1 && timeout != 0) {
			// other threads run until a descriptor is ready or the timeout
			// passes, then select looks without waiting
			var nr = Str.isNull(r) ? 0 : r.length, nw = Str.isNull(w) ? 0 : w.length, no = Str.isNull(o) ? 0 : o.length;
			NetCore.waitFds(r, nr, w, nw, o, no, timeout);
			sets = new Fixed<UInt8, 384>();
			maxfd.value = -1;
			if (!toFdset(r, rs, maxfd) || !toFdset(w, ws, maxfd) || !toFdset(o, os, maxfd)) {
				netErrno = EBADF;
				return -1;
			}
			timeout = 0;
		}
		var tv:Fixed<UInt8, 16> = Fixed.scratch();
		var tvp:Ref<UInt8> = Ref.nil();
		if (timeout >= 0) {
			var s:I64 = cast timeout;
			LE.put64(tv.view(), 0, s);
			LE.put64(tv.view(), 8, cast(1e6 * (timeout - (cast s : Float))));
			tvp = tv.view().ref(0);
		}
		var n = doSelect(maxfd.value + 1, rs.ref(0), ws.ref(0), os.ref(0), tvp);
		if (n < 0) {
			ret(-1);
			return -1;
		}
		fromFdset(r, rs);
		fromFdset(w, ws);
		fromFdset(o, os);
		return n;
	}

	@:hxmc.scoped static function doSelect(n:Int, r:Ref<UInt8>, w:Ref<UInt8>, o:Ref<UInt8>, tv:Ref<UInt8>):Int
		return Mem.target() == 2 ? Posix.select1050(n, r, w, o, tv) : Posix.select(n, r, w, o, tv);

	@:hxmc.scoped static function setBool(fd:Int, level:Int, opt:Int, b:Bool):Int
		return NetCore.setBool(fd, level, opt, b);

	@:hxmc.scoped public static function setNoDelay(fd:Int, b:Bool):Int
		return setBool(fd, 6, 1, b); // IPPROTO_TCP, TCP_NODELAY

	@:hxmc.scoped public static function setBroadcast(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET(), SO_BROADCAST(), b);

	@:hxmc.scoped public static function setReuseAddr(fd:Int, b:Bool):Int
		return setBool(fd, SOL_SOCKET(), SO_REUSEADDR(), b);

	// Unix.setsockopt_float SO_RCVTIMEO, then SO_SNDTIMEO (struct timeval:
	// 64-bit seconds, then microseconds: a long on Linux, an int on macOS)
	@:hxmc.scoped public static function setTimeout(fd:Int, t:Float):Int {
		var tv = new Fixed<UInt8, 16>();
		var s:I64 = cast t;
		LE.put64(tv.view(), 0, s);
		LE.put32(tv.view(), 8, Std.int((t - (cast s : Float)) * 1e6));
		if (Posix.setsockopt(fd, SOL_SOCKET(), SO_RCVTIMEO(), tv.view().ref(0), 16) < 0) return ret(-1);
		return ret(Posix.setsockopt(fd, SOL_SOCKET(), SO_SNDTIMEO(), tv.view().ref(0), 16));
	}

	@:hxmc.scoped public static function shutdown(fd:Int, mode:Int):Int
		return ret(Posix.shutdown(fd, mode == 0 ? 0 : mode == 1 ? 1 : 2));

	// for sys.net.Socket.setBlocking (hxmc std; the Eval socket natives are blocking)
	@:hxmc.scoped public static function setBlocking(fd:Int, b:Bool):Int {
		var flags = Posix.fcntl(fd, F_GETFL, 0);
		if (flags < 0) return ret(-1);
		return ret(Posix.fcntl(fd, F_SETFL, b ? flags & ~O_NONBLOCK() : flags | O_NONBLOCK()));
	}

	// whether the last failure was EAGAIN/EWOULDBLOCK (a non-blocking socket not ready)
	@:hxmc.scoped public static function blocked():Bool
		return lastErrno() == EAGAIN();

	public static function gethostname():String {
		var buf:Slice<UInt8> = Scope.slice(4096);
		if (Posix.gethostname(buf.sub(0, 4095)) < 0) {
			ret(-1);
			return null;
		}
		buf[4095] = 0;
		return SysCore.ofC(buf.ref(0));
	}

	// gethostbyname/gethostbyaddr return static data: one thread at a time
	// (a spin lock: Names.spin[0]), in a safe region (they may block
	// on the network), results copied out under the lock
	@:hxmc.unsafe static function lockResolver()
		NetCore.lockResolver();

	@:hxmc.unsafe static function unlockResolver()
		NetCore.unlockResolver();

	public static function resolve(name:String):Array<Int> {
		var ip = lookup(SysCore.cstr(name));
		netErrno = 0;
		if ((ip >>> 32).toInt() == 0) return null;
		return [ip.toInt()];
	}

	// the host-order IPv4 address of n, with 1 << 32 set when found
	@:hxmc.unsafe static function lookup(n:Ptr):I64
		return NetCore.lookup(n);

	public static function reverse(ip:Int):String {
		var name = reverseLookup(ip);
		netErrno = 0;
		if (name.isNull()) return null;
		var s = Str.ofUtf8(name, LibC.strlen(name).toInt());
		LibC.free(name);
		return s;
	}

	// a malloc'ed copy of the name of ip (host order), or null
	@:hxmc.unsafe static function reverseLookup(ip:Int):Ptr
		return NetCore.reverseLookup(ip);
}
