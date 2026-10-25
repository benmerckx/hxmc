package hxmc.unsafe;

import hxmc.I64;
import hxmc.scoped.Ref;
import hxmc.scoped.Slice;

// Windows functions the runtime's Haxe code calls (hxmc.rt.WinSys,
// hxmc.rt.WinNet): kernel32 and the UCRT's descriptor and wide functions,
// with the C ABI as LibC's (the Win64 and arm64 conventions; no stdcall on
// 64-bit Windows). Structures are read at their 64-bit offsets (the
// callers). The calls take views of scoped memory (docs/plans/lowlevel.md,
// "The scoped C boundary"): a buffer and its length as a Slice, a wide
// string (UTF-16, Haxe's own units, NUL-terminated), a structure or a value
// the call fills as a Ref; what the system returns of its own (an
// environment variable, errno's location) as a Ref, rooted nowhere; a
// handle, and memory the system allocates, as a Ptr.
@:hxmc.c @:hxmc.fast extern class Win32 {
	// UCRT
	static function _write(fd:Int, buf:Slice<UInt8>):Int;
	static function _read(fd:Int, buf:Slice<UInt8>):Int;
	static function _close(fd:Int):Int;
	@:hxmc.varargs(2) static function _wopen(path:Ref<UInt16>, flags:Int, mode:Int):Int;
	static function _lseeki64(fd:Int, off:I64, whence:Int):I64;
	static function _telli64(fd:Int):I64;
	static function _fstat64(fd:Int, st:Ref<UInt8>):Int;
	static function _wstat64(path:Ref<UInt16>, st:Ref<UInt8>):Int;
	static function _wgetenv(name:Ref<UInt16>):Ref<UInt16>;
	static function _wputenv_s(name:Ref<UInt16>, value:Ref<UInt16>):Int;
	static function _wgetcwd(buf:Ptr, n:Int):Ptr;
	static function _wchdir(path:Ref<UInt16>):Int;
	static function _wsystem(cmd:Ref<UInt16>):Int;
	static function _wmkdir(path:Ref<UInt16>):Int;
	static function _wunlink(path:Ref<UInt16>):Int;
	static function _wrmdir(path:Ref<UInt16>):Int;
	static function wcslen(s:Ref<UInt16>):I64;
	static function _getch():Int;
	static function _getche():Int;
	static function _errno():Ref<Int>;
	static function _open_osfhandle(h:Ptr, flags:Int):Int;
	static function _get_osfhandle(fd:Int):Ptr;
	static function fflush(f:Ptr):Int;
	static function exit(code:Int):Void;
	// kernel32
	static function GetEnvironmentStringsW():Ptr;
	static function FreeEnvironmentStringsW(p:Ptr):Int;
	static function Sleep(ms:Int):Void;
	static function GetSystemTimePreciseAsFileTime(ft:Ref<I64>):Void;
	static function GetProcessTimes(p:Ptr, c:Ref<I64>, e:Ref<I64>, k:Ref<I64>, u:Ref<I64>):Int;
	static function GetCurrentProcess():Ptr;
	static function GetModuleFileNameW(m:Ptr, buf:Slice<UInt16>):Int;
	static function GetStdHandle(which:Int):Ptr;
	static function GetFileType(h:Ptr):Int;
	static function GetFileAttributesW(path:Ref<UInt16>):Int;
	static function SetFileAttributesW(path:Ref<UInt16>, attrs:Int):Int;
	static function MoveFileExW(a:Ref<UInt16>, b:Ref<UInt16>, flags:Int):Int;
	static function RemoveDirectoryW(path:Ref<UInt16>):Int;
	static function FindFirstFileW(pattern:Ref<UInt16>, data:Ref<UInt8>):Ptr;
	static function FindNextFileW(h:Ptr, data:Ref<UInt8>):Int;
	static function FindClose(h:Ptr):Int;
	static function GetLastError():Int;
	static function GetFullPathNameW(path:Ref<UInt16>, n:Int, buf:Ref<UInt16>, file:Ptr):Int;
	static function DuplicateHandle(sp:Ptr, h:Ptr, tp:Ptr, out:Ref<I64>, access:Int, inherit:Int, options:Int):Int;
	static function CloseHandle(h:Ptr):Int;
	static function SearchPathW(path:Ptr, name:Ref<UInt16>, ext:Ref<UInt16>, n:Int, buf:Ref<UInt16>, file:Ptr):Int;
	static function CreateFileW(name:Ref<UInt16>, access:Int, share:Int, sa:Ptr, disposition:Int, flags:Int, template:Ptr):Ptr;
	static function CreatePipe(r:Ref<I64>, w:Ref<I64>, sa:Ref<UInt8>, size:Int):Int;
	static function CreateProcessW(app:Ref<UInt16>, cmd:Ref<UInt16>, pa:Ptr, ta:Ptr, inherit:Int, flags:Int, env:Ptr, dir:Ptr, si:Ref<UInt8>,
		pi:Ref<UInt8>):Int;
	static function WaitForSingleObject(h:Ptr, ms:Int):Int;
	static function GetExitCodeProcess(h:Ptr, code:Ref<Int>):Int;
	static function TerminateProcess(h:Ptr, code:Int):Int;
}
