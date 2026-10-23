package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.Win32;
import hxmc.unsafe.Winsock;

// What the network layers (PosixNet, WinNet) do the same way, written once
// over the calls that differ: inline, with the system chosen by Mem.os,
// which folds while lowering, so each layer keeps only its own calls and
// compiles to what its own copy did.
@:access(hxmc.rt.PosixNet) @:access(hxmc.rt.WinNet)
extern class NetCore {
	// a Boolean socket option (an int)
	public static inline function setBool(fd:Int, level:Int, opt:Int, b:Bool):Int {
		var v = Mem.stack(8);
		Mem.setI32(v, 0, b ? 1 : 0);
		return Mem.os() == 2 ? WinNet.ret(Winsock.setsockopt(WinNet.sock(fd), level, opt, v, 4)) : PosixNet.ret(Posix.setsockopt(fd, level, opt, v, 4));
	}

	// select with other threads: they run until a descriptor is ready or
	// the timeout passes (rt_wait_fds polls them in a safe region), then
	// select looks without waiting. The entries: struct pollfd (int fd,
	// short events, short revents) or WSAPOLLFD (SOCKET, short, short).
	public static inline function waitFds(r:Array<Int>, nr:Int, w:Array<Int>, nw:Int, o:Array<Int>, no:Int, timeout:Float) {
		var p = Mem.os() == 2 ? LibC.malloc(16 * (nr + nw + no + 1)) : LibC.malloc(8 * (nr + nw + no + 1));
		var k = 0;
		inline function add(fd:Int, events:Int) {
			Mem.setI32(p, 8 * k, fd);
			Mem.setI16(p, 8 * k + 4, events);
			Mem.setI16(p, 8 * k + 6, 0);
			k++;
		}
		inline function addWin(fd:Int, events:Int) {
			Mem.setI64(p, 16 * k, WinNet.sock(fd));
			Mem.setI16(p, 16 * k + 8, events);
			Mem.setI16(p, 16 * k + 10, 0);
			k++;
		}
		for (i in 0...nr)
			if (Mem.os() == 2) addWin(r[i], 0x100) else add(r[i], 1); // POLLRDNORM, POLLIN
		for (i in 0...nw)
			if (Mem.os() == 2) addWin(w[i], 0x10) else add(w[i], 4); // POLLWRNORM, POLLOUT
		for (i in 0...no)
			if (Mem.os() == 2) addWin(o[i], 0x200) else add(o[i], 2); // POLLRDBAND, POLLPRI
		Rt.rt_wait_fds(p, k, timeout);
		LibC.free(p);
	}

	// gethostbyname/gethostbyaddr return static data: one lookup at a time
	// (a spin lock: Names.spin[0], Windows' Names.spin[4]), in a safe region
	// (they may block on the network), results copied out under the lock
	public static inline function lockResolver() {
		var l = Mem.os() == 2 ? Names.spin.add(16) : Names.spin;
		while (Atomic.cas32(l, 0, 1) != 0)
			if (Mem.os() == 2) Win32.Sleep(0) else Posix.sched_yield();
	}

	public static inline function unlockResolver()
		Atomic.store32(Mem.os() == 2 ? Names.spin.add(16) : Names.spin, 0);

	// the host-order IPv4 address of n, with 1 << 32 set when found (struct
	// hostent: h_name, h_aliases, h_addrtype and h_length, ints, Windows'
	// shorts, h_addr_list)
	public static inline function lookup(n:Ptr):I64 {
		var r:I64 = 0;
		Leaf.rt_blocking_enter();
		if (Mem.os() == 2) WinNet.lockResolver() else PosixNet.lockResolver();
		var h = Mem.os() == 2 ? Winsock.gethostbyname(n) : Posix.gethostbyname(n);
		if (!h.isNull() && (Mem.os() == 2 ? Mem.getI16(h, 16) : Mem.getI32(h, 16)) == 2) {
			var list = Mem.getPtr(h, 24);
			var a = Mem.getPtr(list, 0);
			if (!a.isNull()) {
				var ip = (Mem.getU8(a, 0) << 24) | (Mem.getU8(a, 1) << 16) | (Mem.getU8(a, 2) << 8) | Mem.getU8(a, 3);
				r = ((1 : I64) << 32) | ((ip : I64) & (((1 : I64) << 32) - 1));
			}
		}
		if (Mem.os() == 2) WinNet.unlockResolver() else PosixNet.unlockResolver();
		Leaf.rt_blocking_leave();
		return r;
	}

	// a malloc'ed copy of the name of ip (host order), or null
	public static inline function reverseLookup(ip:Int):Ptr {
		var a = Mem.stack(8);
		Mem.setI8(a, 0, ip >>> 24);
		Mem.setI8(a, 1, ip >> 16);
		Mem.setI8(a, 2, ip >> 8);
		Mem.setI8(a, 3, ip);
		var name = Ptr.nil();
		Leaf.rt_blocking_enter();
		if (Mem.os() == 2) WinNet.lockResolver() else PosixNet.lockResolver();
		var h = Mem.os() == 2 ? Winsock.gethostbyaddr(a, 4, 2) : Posix.gethostbyaddr(a, 4, 2);
		if (!h.isNull() && !Mem.getPtr(h, 0).isNull()) name = Mem.os() == 2 ? Winsock._strdup(Mem.getPtr(h, 0)) : Posix.strdup(Mem.getPtr(h, 0));
		if (Mem.os() == 2) WinNet.unlockResolver() else PosixNet.unlockResolver();
		Leaf.rt_blocking_leave();
		return name;
	}
}
