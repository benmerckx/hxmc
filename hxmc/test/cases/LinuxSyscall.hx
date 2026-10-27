import hxmc.I64;
import hxmc.unsafe.*;

// hxmc.unsafe.Linux.syscall (docs/interop.md, "System calls"): the C
// library's syscall(2), musl's in the static mode, glibc's with
// -D hxmc.libc=glibc, with six 64-bit arguments as a variadic call.
// io_uring_setup with bad arguments fails at once, wherever it runs: EFAULT
// for its parameters at address 0, ENOSYS where the kernel (or qemu) has no
// io_uring, EPERM where it is turned off.
@:hxmc.c @:hxmc.fast extern class Proc {
	static function getpid():Int;
	static function getppid():Int;
}

class LinuxSyscall {
	static function main() {
		// (the numbers of the older calls differ per architecture)
		var SYS_write = Mem.arm() ? 64 : 1;
		var SYS_getpid = Mem.arm() ? 172 : 39;
		var SYS_getppid = Mem.arm() ? 173 : 110;
		var SYS_close = Mem.arm() ? 57 : 3;
		var pid = Linux.syscall(SYS_getpid, 0, 0, 0, 0, 0, 0);
		trace(pid.toInt() == Proc.getpid(), pid.toInt() > 0);
		trace(Linux.syscall(SYS_getppid, 0, 0, 0, 0, 0, 0).toInt() == Proc.getppid());
		// a write: arguments in order, the result the count
		Sys.stdout().flush();
		var n = Arena.scopedValue(a -> {
			var s = a.cstring("written by syscall(SYS_write)\n");
			Linux.syscall(SYS_write, 1, (s : Ptr<UInt8>).toI64(), 30, 0, 0, 0);
		});
		trace(Std.string(n));
		// failures: -1 and errno
		var r = Linux.syscall(SYS_close, -1, 0, 0, 0, 0, 0);
		trace(Std.string(r), Linux.errno() == 9); // EBADF
		var r = Linux.syscall(Linux.SYS_io_uring_setup, 0, 0, 0, 0, 0, 0);
		var e = Linux.errno();
		trace(Std.string(r), e == Linux.EFAULT || e == Linux.ENOSYS || e == 1 || e == Linux.EINVAL);
		// many calls, with collections in between (each call is a safe region)
		var keep = [];
		var ok = true;
		for (i in 0...20000) {
			keep.push("s" + i);
			if (keep.length > 500) keep = [];
			if (Linux.syscall(SYS_getpid, 0, 0, 0, 0, 0, 0) != pid) ok = false;
		}
		trace(ok);
	}
}
