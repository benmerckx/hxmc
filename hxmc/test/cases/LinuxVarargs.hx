import hxmc.I64;
import hxmc.unsafe.*;

// One C function declared variadic three ways in one program: syscall(2) by
// hxmc.unsafe.Posix (three arguments, fast), hxmc.unsafe.Linux (seven,
// @:hxmc.blocking) and the runtime's Math.random (seven, fast: its seed).
// Their fixed argument and result agree; each call passes its own variadic
// arguments (CInterop.sameSig).
@:hxmc.c @:hxmc.fast extern class Proc {
	static function getpid():Int;
}

class LinuxVarargs {
	static function main() {
		var SYS_getpid = Mem.arm() ? 172 : 39;
		var SYS_close = Mem.arm() ? 57 : 3;
		var pid = Proc.getpid();
		trace(Posix.syscall(SYS_getpid, 0, 0).toInt() == pid);
		trace(Linux.syscall(SYS_getpid, 0, 0, 0, 0, 0, 0).toInt() == pid);
		var r = Math.random();
		trace(r >= 0 && r < 1);
		// failures through both: -1 and EBADF
		trace(Std.string(Posix.syscall(SYS_close, -1, 0)), Linux.errno() == 9);
		trace(Std.string(Linux.syscall(SYS_close, -1, 0, 0, 0, 0, 0)), Linux.errno() == 9);
		var ok = true;
		for (i in 0...1000) {
			var x = Math.random();
			if (x < 0 || x >= 1 || Posix.syscall(SYS_getpid, 0, 0) != Linux.syscall(SYS_getpid, 0, 0, 0, 0, 0, 0)) ok = false;
		}
		trace(ok);
	}
}
