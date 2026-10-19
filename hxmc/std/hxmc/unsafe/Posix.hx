package hxmc.unsafe;

import hxmc.I64;

// POSIX functions of the C library (musl on Linux, libSystem on macOS) the
// runtime's Haxe code calls (hxmc.rt.PosixSys, hxmc.rt.PosixNet), with the C ABI as
// LibC's. Structures are read at their offsets per target (the callers);
// macOS x86-64 names the 64-bit-inode stat and directory functions with a
// suffix (stat$INODE64), as its headers do. Variadic functions
// (@:hxmc.varargs) pass their variadic arguments as the platform requires
// (on the stack on Apple arm64).
@:hxmc.c @:hxmc.fast extern class Posix {
	static function write(fd:Int, p:Ptr, n:I64):I64;
	static function read(fd:Int, p:Ptr, n:I64):I64;
	@:hxmc.varargs(2) static function open(path:Ptr, flags:Int, mode:Int):Int;
	static function close(fd:Int):Int;
	static function lseek(fd:Int, off:I64, whence:Int):I64;
	@:hxmc.varargs(2) static function fcntl(fd:Int, cmd:Int, arg:Int):Int;
	static function pipe(fds:Ptr):Int;
	static function pipe2(fds:Ptr, flags:Int):Int; // (not on macOS)
	static function dup2(a:Int, b:Int):Int;
	static function isatty(fd:Int):Int;
	static function tcgetattr(fd:Int, t:Ptr):Int;
	static function tcsetattr(fd:Int, act:Int, t:Ptr):Int;
	static function getenv(name:Ptr):Ptr;
	static function setenv(name:Ptr, value:Ptr, overwrite:Int):Int;
	static function unsetenv(name:Ptr):Int;
	static function getcwd(buf:Ptr, n:I64):Ptr;
	static function chdir(path:Ptr):Int;
	static function nanosleep(req:Ptr, rem:Ptr):Int;
	static function gettimeofday(tv:Ptr, tz:Ptr):Int;
	static function clock():I64;
	static function readlink(path:Ptr, buf:Ptr, n:I64):I64;
	static function realpath(path:Ptr, buf:Ptr):Ptr;
	static function system(cmd:Ptr):Int;
	static function fork():Int;
	static function execvp(file:Ptr, argv:Ptr):Int;
	static function _exit(code:Int):Void;
	static function exit(code:Int):Void;
	static function fflush(f:Ptr):Int;
	static function waitpid(pid:Int, status:Ptr, options:Int):Int;
	static function kill(pid:Int, sig:Int):Int;
	static function mkdir(path:Ptr, mode:Int):Int;
	static function unlink(path:Ptr):Int;
	static function rmdir(path:Ptr):Int;
	static function rename(a:Ptr, b:Ptr):Int;
	static function stat(path:Ptr, st:Ptr):Int;
	static function fstat(fd:Int, st:Ptr):Int;
	static function opendir(path:Ptr):Ptr;
	static function readdir(d:Ptr):Ptr;
	static function closedir(d:Ptr):Int;
	@:native("stat$INODE64") static function statInode64(path:Ptr, st:Ptr):Int;
	@:native("fstat$INODE64") static function fstatInode64(fd:Int, st:Ptr):Int;
	@:native("opendir$INODE64") static function opendirInode64(path:Ptr):Ptr;
	@:native("readdir$INODE64") static function readdirInode64(d:Ptr):Ptr;
	// errno: musl's location, libSystem's
	static function __errno_location():Ptr;
	static function __errno():Ptr; // (Bionic: Android)
	static function __error():Ptr;
	static function _NSGetEnviron():Ptr;
	static function _NSGetExecutablePath(buf:Ptr, size:Ptr):Int;
	@:native("realpath$DARWIN_EXTSN") static function realpathExtsn(path:Ptr, buf:Ptr):Ptr;
	// sockets (hxmc.rt.PosixNet)
	static function socket(domain:Int, type:Int, protocol:Int):Int;
	static function bind(fd:Int, addr:Ptr, len:Int):Int;
	static function connect(fd:Int, addr:Ptr, len:Int):Int;
	static function accept(fd:Int, addr:Ptr, len:Ptr):Int;
	static function accept4(fd:Int, addr:Ptr, len:Ptr, flags:Int):Int; // (not on macOS)
	static function listen(fd:Int, backlog:Int):Int;
	static function getsockname(fd:Int, addr:Ptr, len:Ptr):Int;
	static function getpeername(fd:Int, addr:Ptr, len:Ptr):Int;
	static function getsockopt(fd:Int, level:Int, opt:Int, v:Ptr, len:Ptr):Int;
	static function setsockopt(fd:Int, level:Int, opt:Int, v:Ptr, len:Int):Int;
	static function recv(fd:Int, p:Ptr, n:I64, flags:Int):I64;
	static function send(fd:Int, p:Ptr, n:I64, flags:Int):I64;
	static function select(n:Int, r:Ptr, w:Ptr, e:Ptr, tv:Ptr):Int;
	@:native("select$1050") static function select1050(n:Int, r:Ptr, w:Ptr, e:Ptr, tv:Ptr):Int;
	static function shutdown(fd:Int, how:Int):Int;
	static function signal(sig:Int, handler:Ptr):Ptr;
	static function strerror(err:Int):Ptr;
	static function gethostname(buf:Ptr, n:I64):Int;
	static function gethostbyname(name:Ptr):Ptr;
	static function gethostbyaddr(addr:Ptr, len:Int, type:Int):Ptr;
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
