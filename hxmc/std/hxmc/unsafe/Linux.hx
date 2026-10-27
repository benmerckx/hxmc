package hxmc.unsafe;

// (no hxmc.target: typed for every native target at once, as the corpus'
// archives are; elsewhere the link fails on `syscall`)
#if (hxmc.target && hxmc.target != "linux-x86_64" && hxmc.target != "linux-arm64" && hxmc.target != "android-x86_64" && hxmc.target != "android-arm64")
#error "hxmc.unsafe.Linux is for the Linux targets only (linux-x86_64, linux-arm64, android-*)"
#end
import hxmc.I64;

// Linux's system calls that have no C library function (docs/interop.md,
// "System calls"): io_uring_setup, io_uring_enter, io_uring_register. It
// calls the C library's syscall(2): musl's, linked statically into every
// executable (bin/hxmc/rt/linux-*/rt.o), or glibc's in the dynamic mode
// (-D hxmc.libc=glibc), Bionic's on Android. The call runs in a safe region
// (@:hxmc.blocking): it may block (io_uring_enter waiting for completions)
// while other threads collect. On failure it returns -1 and errno() is the
// error, as the C library's wrappers do.
//
//   var fd = Linux.syscall(Linux.SYS_io_uring_setup, 8, params.toI64(), 0, 0, 0, 0);
//   if (fd < 0) trace(Linux.errno()); // ENOSYS: an old kernel
class Linux {
	// the numbers of the system calls added since Linux 5.1, the same on
	// every architecture (asm-generic/unistd.h); older ones differ per
	// architecture (Mem.arm())
	public static inline var SYS_io_uring_setup = 425;
	public static inline var SYS_io_uring_enter = 426;
	public static inline var SYS_io_uring_register = 427;

	// errno values
	public static inline var EINTR = 4;
	public static inline var EAGAIN = 11;
	public static inline var EFAULT = 14;
	public static inline var EINVAL = 22;
	public static inline var ENOSYS = 38;

	// system call nr with six arguments (the ones it does not take: 0)
	public static inline function syscall(nr:Int, a:I64, b:I64, c:I64, d:I64, e:I64, f:I64):I64
		return LinuxC.syscall((nr : I64), a, b, c, d, e, f);

	// the calling thread's errno (kept across the safe region's end)
	public static inline function errno():Int
		return Mem.getI32(Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location(), 0);
}

@:hxmc.c private extern class LinuxC {
	@:hxmc.blocking @:hxmc.varargs(1) static function syscall(nr:I64, a:I64, b:I64, c:I64, d:I64, e:I64, f:I64):I64;
}
