package hxmc.unsafe;

import hxmc.I64;

// Windows functions the runtime's Haxe code calls (hxmc.rt.WinSys,
// hxmc.rt.WinNet): kernel32 and ws2_32, and the UCRT's descriptor and wide
// functions, with the C ABI as LibC's (the Win64 and arm64 conventions; no
// stdcall on 64-bit Windows). Wide strings are UTF-16 (Haxe's own units);
// structures are read at their 64-bit offsets (the callers).
@:hxmc.c @:hxmc.fast extern class Win32 {
	// UCRT
	static function _write(fd:Int, p:Ptr, n:Int):Int;
	static function _read(fd:Int, p:Ptr, n:Int):Int;
	static function _close(fd:Int):Int;
	@:hxmc.varargs(2) static function _wopen(path:Ptr, flags:Int, mode:Int):Int;
	static function _lseeki64(fd:Int, off:I64, whence:Int):I64;
	static function _telli64(fd:Int):I64;
	static function _fstat64(fd:Int, st:Ptr):Int;
	static function _wstat64(path:Ptr, st:Ptr):Int;
	static function _wgetenv(name:Ptr):Ptr;
	static function _wputenv_s(name:Ptr, value:Ptr):Int;
	static function _wgetcwd(buf:Ptr, n:Int):Ptr;
	static function _wchdir(path:Ptr):Int;
	static function _wsystem(cmd:Ptr):Int;
	static function _wmkdir(path:Ptr):Int;
	static function _wunlink(path:Ptr):Int;
	static function _wrmdir(path:Ptr):Int;
	static function _getch():Int;
	static function _getche():Int;
	static function _errno():Ptr;
	static function _open_osfhandle(h:Ptr, flags:Int):Int;
	static function _get_osfhandle(fd:Int):Ptr;
	static function fflush(f:Ptr):Int;
	static function exit(code:Int):Void;
	// kernel32
	// address space (a library's own allocator): type MEM_COMMIT 0x1000,
	// MEM_RESERVE 0x2000; VirtualFree's MEM_DECOMMIT 0x4000, MEM_RELEASE
	// 0x8000 (size 0); protect PAGE_NOACCESS 1, PAGE_READWRITE 4
	static function VirtualAlloc(p:Ptr, size:I64, type:Int, protect:Int):Ptr;
	static function VirtualFree(p:Ptr, size:I64, type:Int):Int;
	static function GetEnvironmentStringsW():Ptr;
	static function FreeEnvironmentStringsW(p:Ptr):Int;
	static function Sleep(ms:Int):Void;
	static function GetSystemTimePreciseAsFileTime(ft:Ptr):Void;
	static function GetProcessTimes(p:Ptr, c:Ptr, e:Ptr, k:Ptr, u:Ptr):Int;
	static function GetCurrentProcess():Ptr;
	static function GetModuleFileNameW(m:Ptr, buf:Ptr, n:Int):Int;
	static function GetStdHandle(which:Int):Ptr;
	static function GetFileType(h:Ptr):Int;
	static function GetFileAttributesW(path:Ptr):Int;
	static function SetFileAttributesW(path:Ptr, attrs:Int):Int;
	static function MoveFileExW(a:Ptr, b:Ptr, flags:Int):Int;
	static function RemoveDirectoryW(path:Ptr):Int;
	static function FindFirstFileW(pattern:Ptr, data:Ptr):Ptr;
	static function FindNextFileW(h:Ptr, data:Ptr):Int;
	static function FindClose(h:Ptr):Int;
	static function GetLastError():Int;
	static function GetFullPathNameW(path:Ptr, n:Int, buf:Ptr, file:Ptr):Int;
	static function DuplicateHandle(sp:Ptr, h:Ptr, tp:Ptr, out:Ptr, access:Int, inherit:Int, options:Int):Int;
	static function CloseHandle(h:Ptr):Int;
	static function SearchPathW(path:Ptr, name:Ptr, ext:Ptr, n:Int, buf:Ptr, file:Ptr):Int;
	static function CreateFileW(name:Ptr, access:Int, share:Int, sa:Ptr, disposition:Int, flags:Int, template:Ptr):Ptr;
	static function CreatePipe(r:Ptr, w:Ptr, sa:Ptr, size:Int):Int;
	static function CreateProcessW(app:Ptr, cmd:Ptr, pa:Ptr, ta:Ptr, inherit:Int, flags:Int, env:Ptr, dir:Ptr, si:Ptr, pi:Ptr):Int;
	static function WaitForSingleObject(h:Ptr, ms:Int):Int;
	static function GetExitCodeProcess(h:Ptr, code:Ptr):Int;
	static function TerminateProcess(h:Ptr, code:Int):Int;
}
