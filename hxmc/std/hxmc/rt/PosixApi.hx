package hxmc.rt;

import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// The C library's POSIX calls typed for checked kernels (docs/interop.md,
// "Typed bindings"): buffers as spans, out-parameters as spans of their
// bytes, no raw memory, so the safe kernels of PosixSys and PosixNet call
// them. Lengths are bytes: a C length in bytes takes a span of UInt8. The
// same symbols as hxmc.unsafe.Posix's, and fast as those; make
// header-check compiles the declarations against each target's headers.
@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("unistd.h", "fcntl.h", "signal.h", "sys/types.h", "sys/stat.h", "sys/socket.h", "time.h")
extern class PosixApi {
	static function read(fd:Int, buf:Span<UInt8>):I64;
	static function write(fd:Int, buf:ReadOnlySpan<UInt8>):I64;
	static function close(fd:Int):Int;
	static function lseek(fd:Int, off:I64, whence:Int):I64;
	static function clock():I64;
	// (struct timespec: tv_sec, tv_nsec, two longs)
	@:hxmc.len(ts, 2) static function clock_gettime(clock:Int, ts:Span<I64>):Int;
	// (struct timeval: tv_sec, tv_usec, two longs; struct timezone, two ints,
	// in a word: a span of its own, never a raw pointer)
	@:hxmc.len(tv, 2) @:hxmc.len(tz, 1) @:hxmc.header("sys/time.h") static function gettimeofday(tv:Span<I64>, tz:Span<I64>):Int;
	static function kill(pid:Int, sig:Int):Int;
	// (struct stat: at most 256 bytes on every target, the header check says)
	@:hxmc.len(st, 256) static function fstat(fd:Int, st:Span<UInt8>):Int;
	@:hxmc.len(st, 256) @:native("fstat$INODE64") static function fstatInode64(fd:Int, st:Span<UInt8>):Int;
	// sockets: an address's bytes, n of them (a socklen_t)
	@:hxmc.len(a, n) static function bind(fd:Int, a:ReadOnlySpan<UInt8>, n:Int):Int;
	@:hxmc.len(a, n) static function connect(fd:Int, a:ReadOnlySpan<UInt8>, n:Int):Int;
	static function listen(fd:Int, backlog:Int):Int;
	@:hxmc.len(v, n) static function setsockopt(fd:Int, level:Int, opt:Int, v:ReadOnlySpan<UInt8>, n:Int):Int;
	static function recv(fd:Int, buf:Span<UInt8>, flags:Int):I64;
	static function send(fd:Int, buf:ReadOnlySpan<UInt8>, flags:Int):I64;
	static function shutdown(fd:Int, how:Int):Int;
}

// The calls whose arguments a declaration cannot constrain, as checked
// kernels over the raw ones: fcntl's third argument is an int or a pointer
// by its command, getsockopt's length is a count of bytes C writes.
@:hxmc.kernel @:hxmc.unsafe class PosixCalls {
	// F_GETFL 3, F_SETFL 4
	public static function getFl(fd:Int):Int
		return Posix.fcntl(fd, 3, 0);

	public static function setFl(fd:Int, flags:Int):Int
		return Posix.fcntl(fd, 4, flags);

	// an option's bytes into v, its length v's: the bytes C wrote, or -1
	public static function getsockopt(fd:Int, level:Int, opt:Int, v:Span<UInt8>):Int {
		var n = Mem.stack(8);
		Mem.setI32(n, 0, v.length);
		return PosixRaw.getsockopt(fd, level, opt, v, n) < 0 ? -1 : Mem.getI32(n, 0);
	}
}

// (getsockopt's length: in, the room in v; out, the bytes written)
@:hxmc.c @:hxmc.fast @:hxmc.header("sys/socket.h") private extern class PosixRaw {
	@:hxmc.len(v, 0) static function getsockopt(fd:Int, level:Int, opt:Int, v:Span<UInt8>, len:Ptr):Int;
}

// The C library's calls of strings for GC code: each String a NUL-terminated
// UTF-8 copy for the call, getenv's result copied (docs/interop.md, "Typed
// bindings"). The same symbols as hxmc.unsafe.Posix's, and fast as those.
@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("stdlib.h", "unistd.h", "stdio.h")
extern class PosixStrings {
	static function getenv(name:String):String;
	static function setenv(name:String, value:String, overwrite:Int):Int;
	static function unsetenv(name:String):Int;
	static function chdir(path:String):Int;
	static function unlink(path:String):Int;
	static function rmdir(path:String):Int;
	static function rename(from:String, to:String):Int;
}
