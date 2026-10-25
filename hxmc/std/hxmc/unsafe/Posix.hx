package hxmc.unsafe;

import hxmc.I64;
import hxmc.scoped.Ref;
import hxmc.scoped.Slice;

// POSIX functions of the C library (musl on Linux, libSystem on macOS) the
// runtime's Haxe code calls (hxmc.rt.PosixSys, hxmc.rt.PosixNet), with the C ABI as
// LibC's. Structures are read at their offsets per target (the callers);
// macOS x86-64 names the 64-bit-inode stat and directory functions with a
// suffix (stat$INODE64), as its headers do. Variadic functions
// (@:hxmc.varargs) pass their variadic arguments as the platform requires
// (on the stack on Apple arm64).
// The system's calls take views of scoped memory (docs/plans/lowlevel.md,
// "The scoped C boundary"): a buffer and its length as a Slice, a C string,
// a structure or an int the call fills as a Ref; what C returns (a C string
// of its own, errno's location) as a Ref, rooted nowhere; a directory
// stream, a handle, as a Ptr.
@:hxmc.c @:hxmc.fast extern class Posix {
	static function write(fd:Int, buf:Slice<UInt8>):I64;
	static function read(fd:Int, buf:Slice<UInt8>):I64;
	@:hxmc.varargs(2) static function open(path:Ref<UInt8>, flags:Int, mode:Int):Int;
	static function close(fd:Int):Int;
	static function lseek(fd:Int, off:I64, whence:Int):I64;
	@:hxmc.varargs(2) static function fcntl(fd:Int, cmd:Int, arg:Int):Int;
	static function pipe(fds:Ref<Int>):Int;
	static function pipe2(fds:Ref<Int>, flags:Int):Int; // (not on macOS)
	static function dup2(a:Int, b:Int):Int;
	static function isatty(fd:Int):Int;
	static function tcgetattr(fd:Int, t:Ref<UInt8>):Int;
	static function tcsetattr(fd:Int, act:Int, t:Ref<UInt8>):Int;
	static function getenv(name:Ref<UInt8>):Ref<UInt8>;
	static function setenv(name:Ref<UInt8>, value:Ref<UInt8>, overwrite:Int):Int;
	static function unsetenv(name:Ref<UInt8>):Int;
	static function getcwd(buf:Slice<UInt8>):Ref<UInt8>;
	static function strnlen(s:Slice<UInt8>):I64;
	static function chdir(path:Ref<UInt8>):Int;
	static function nanosleep(req:Ref<UInt8>, rem:Ref<UInt8>):Int;
	static function gettimeofday(tv:Ref<UInt8>, tz:Ref<UInt8>):Int;
	static function clock():I64;
	static function readlink(path:Ref<UInt8>, buf:Slice<UInt8>):I64;
	static function realpath(path:Ref<UInt8>, buf:Ref<UInt8>):Ref<UInt8>;
	static function system(cmd:Ref<UInt8>):Int;
	static function fork():Int;
	static function execvp(file:Ptr, argv:Ptr):Int;
	static function _exit(code:Int):Void;
	static function exit(code:Int):Void;
	static function fflush(f:Ptr):Int;
	static function waitpid(pid:Int, status:Ref<Int>, options:Int):Int;
	static function kill(pid:Int, sig:Int):Int;
	static function mkdir(path:Ref<UInt8>, mode:Int):Int;
	static function unlink(path:Ref<UInt8>):Int;
	static function rmdir(path:Ref<UInt8>):Int;
	static function rename(a:Ref<UInt8>, b:Ref<UInt8>):Int;
	static function stat(path:Ref<UInt8>, st:Ref<UInt8>):Int;
	static function fstat(fd:Int, st:Ref<UInt8>):Int;
	static function opendir(path:Ref<UInt8>):Ptr;
	static function readdir(d:Ptr):Ref<UInt8>;
	static function closedir(d:Ptr):Int;
	@:native("stat$INODE64") static function statInode64(path:Ref<UInt8>, st:Ref<UInt8>):Int;
	@:native("fstat$INODE64") static function fstatInode64(fd:Int, st:Ref<UInt8>):Int;
	@:native("opendir$INODE64") static function opendirInode64(path:Ref<UInt8>):Ptr;
	@:native("readdir$INODE64") static function readdirInode64(d:Ptr):Ref<UInt8>;
	// errno: musl's location, libSystem's
	static function __errno_location():Ref<Int>;
	static function __errno():Ref<Int>; // (Bionic: Android)
	static function __error():Ref<Int>;
	static function _NSGetEnviron():Ptr;
	static function _NSGetExecutablePath(buf:Ref<UInt8>, size:Ref<Int>):Int;
	@:native("realpath$DARWIN_EXTSN") static function realpathExtsn(path:Ref<UInt8>, buf:Ref<UInt8>):Ref<UInt8>;
	// sockets (hxmc.rt.PosixNet)
	static function socket(domain:Int, type:Int, protocol:Int):Int;
	static function bind(fd:Int, addr:Ref<UInt8>, len:Int):Int;
	static function connect(fd:Int, addr:Ref<UInt8>, len:Int):Int;
	static function accept(fd:Int, addr:Ref<UInt8>, len:Ref<Int>):Int;
	static function accept4(fd:Int, addr:Ref<UInt8>, len:Ref<Int>, flags:Int):Int; // (not on macOS)
	static function listen(fd:Int, backlog:Int):Int;
	static function getsockname(fd:Int, addr:Ref<UInt8>, len:Ref<Int>):Int;
	static function getpeername(fd:Int, addr:Ref<UInt8>, len:Ref<Int>):Int;
	static function getsockopt(fd:Int, level:Int, opt:Int, v:Ref<UInt8>, len:Ref<Int>):Int;
	static function setsockopt(fd:Int, level:Int, opt:Int, v:Ref<UInt8>, len:Int):Int;
	static function recv(fd:Int, buf:Slice<UInt8>, flags:Int):I64;
	static function send(fd:Int, buf:Slice<UInt8>, flags:Int):I64;
	static function select(n:Int, r:Ref<UInt8>, w:Ref<UInt8>, e:Ref<UInt8>, tv:Ref<UInt8>):Int;
	@:native("select$1050") static function select1050(n:Int, r:Ref<UInt8>, w:Ref<UInt8>, e:Ref<UInt8>, tv:Ref<UInt8>):Int;
	static function shutdown(fd:Int, how:Int):Int;
	static function signal(sig:Int, handler:Ptr):Ptr;
	static function strerror(err:Int):Ref<UInt8>;
	static function gethostname(buf:Slice<UInt8>):Int;
	static function gethostbyname(name:Ref<UInt8>):Ptr;
	static function gethostbyaddr(addr:Ref<UInt8>, len:Int, type:Int):Ptr;
	static function strdup(s:Ptr):Ptr;
	static function sched_yield():Int;
	// loading shared libraries at run time (graphics drivers: libGL,
	// libvulkan): glibc's libdl.so.2 in the dynamic glibc mode (-D
	// hxmc.libc=glibc), libSystem's on macOS; none in the static musl mode
	// (a link error). flags: RTLD_LAZY 1,
	// RTLD_NOW 2 (RTLD_GLOBAL: 0x100 on Linux, 8 on macOS)
	static function dlopen(path:Ptr, flags:Int):Ptr;
	static function dlsym(handle:Ptr, name:Ptr):Ptr;
	static function dlclose(handle:Ptr):Int;
	static function dlerror():Ptr;
}
