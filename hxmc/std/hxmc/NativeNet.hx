package hxmc;

import hxmc.rt.PosixNet;
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.WasiNet;
#end
import hxmc.rt.WinNet;
import hxmc.unsafe.Mem;

// BSD sockets behind the Eval natives of `eval.vm.NativeSocket` and
// `sys.net.Host` (src/macros/eval/EvalStdLibB.hx StdSocket, EvalStdLibA.hx
// StdHost), standing for OCaml's Unix module: POSIX (hxmc.rt.PosixNet) or
// Winsock (hxmc.rt.WinNet), chosen by the target, or none for WebAssembly
// (hxmc.rt.WasiNet: every call fails, typed only for wasm32-wasi). Sockets are file
// descriptors. Functions returning Int give -1 on failure with the C errno in
// `errno()`; `strerror` is OCaml's `Unix.error_message`.
class NativeNet {
	public static inline function errno():Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.getErrno() #else Mem.os() == 2 ? WinNet.getErrno() : PosixNet.getErrno() #end;

	public static inline function strerror(err:Int):String
		return #if (hxmc.target == "wasm32-wasi") WasiNet.strerror(err) #else Mem.os() == 2 ? WinNet.strerror(err) : PosixNet.strerror(err) #end;

	// PF_INET, SOCK_STREAM
	public static inline function socket():Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.socket() #else Mem.os() == 2 ? WinNet.socket() : PosixNet.socket() #end;

	public static inline function close(fd:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.close(fd) #else Mem.os() == 2 ? WinNet.close(fd) : PosixNet.close(fd) #end;

	public static inline function accept(fd:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.accept(fd) #else Mem.os() == 2 ? WinNet.accept(fd) : PosixNet.accept(fd) #end;

	// ip: host-order IPv4
	public static inline function bind(fd:Int, ip:Int, port:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.bind(fd, ip, port) #else Mem.os() == 2 ? WinNet.bind(fd, ip, port) : PosixNet.bind(fd, ip, port) #end;

	public static inline function connect(fd:Int, ip:Int, port:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.connect(fd, ip, port) #else Mem.os() == 2 ? WinNet.connect(fd, ip, port) : PosixNet.connect(fd, ip, port) #end;

	public static inline function listen(fd:Int, backlog:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.listen(fd, backlog) #else Mem.os() == 2 ? WinNet.listen(fd, backlog) : PosixNet.listen(fd, backlog) #end;

	// getsockname (peer false) or getpeername: [ip, port], null on failure;
	// [0, -1] when the address is not ADDR_INET
	public static inline function sockName(fd:Int, peer:Bool):Null<Array<Int>>
		return #if (hxmc.target == "wasm32-wasi") WasiNet.sockName(fd, peer) #else Mem.os() == 2 ? WinNet.sockName(fd, peer) : PosixNet.sockName(fd, peer) #end;

	public static inline function recv(fd:Int, b:haxe.io.Bytes, pos:Int, len:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.recv(fd, b.getData(), pos, len) #else Mem.os() == 2 ? WinNet.recv(fd, b.getData(), pos, len) : PosixNet.recv(fd, b.getData(), pos, len) #end;

	public static inline function send(fd:Int, b:haxe.io.Bytes, pos:Int, len:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.send(fd, b.getData(), pos, len) #else Mem.os() == 2 ? WinNet.send(fd, b.getData(), pos, len) : PosixNet.send(fd, b.getData(), pos, len) #end;

	// Unix.select: sets the entries of descriptors that are not ready to -1
	public static inline function select(read:Array<Int>, write:Array<Int>, others:Array<Int>, timeout:Float):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.select(read, write, others, timeout) #else Mem.os() == 2 ? WinNet.select(read, write, others, timeout) : PosixNet.select(read, write, others, timeout) #end;

	public static inline function setNoDelay(fd:Int, b:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.setNoDelay(fd, b) #else Mem.os() == 2 ? WinNet.setNoDelay(fd, b) : PosixNet.setNoDelay(fd, b) #end;

	public static inline function setBroadcast(fd:Int, b:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.setBroadcast(fd, b) #else Mem.os() == 2 ? WinNet.setBroadcast(fd, b) : PosixNet.setBroadcast(fd, b) #end;

	// SO_REUSEADDR (sys.net.Socket.bind)
	public static inline function setReuseAddr(fd:Int, b:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.setReuseAddr(fd, b) #else Mem.os() == 2 ? WinNet.setReuseAddr(fd, b) : PosixNet.setReuseAddr(fd, b) #end;

	// SO_RCVTIMEO then SO_SNDTIMEO
	public static inline function setTimeout(fd:Int, seconds:Float):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.setTimeout(fd, seconds) #else Mem.os() == 2 ? WinNet.setTimeout(fd, seconds) : PosixNet.setTimeout(fd, seconds) #end;

	// 0 receive, 1 send, 2 all
	public static inline function shutdown(fd:Int, mode:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.shutdown(fd, mode) #else Mem.os() == 2 ? WinNet.shutdown(fd, mode) : PosixNet.shutdown(fd, mode) #end;

	// O_NONBLOCK (sys.net.Socket only)
	public static inline function setBlocking(fd:Int, b:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiNet.setBlocking(fd, b) #else Mem.os() == 2 ? WinNet.setBlocking(fd, b) : PosixNet.setBlocking(fd, b) #end;

	// the last failure was EAGAIN/EWOULDBLOCK
	public static inline function blocked():Bool
		return #if (hxmc.target == "wasm32-wasi") WasiNet.blocked() #else Mem.os() == 2 ? WinNet.blocked() : PosixNet.blocked() #end;

	// host names: null when the name is unknown (errno 0) or on failure
	public static inline function gethostname():Null<String>
		return #if (hxmc.target == "wasm32-wasi") WasiNet.gethostname() #else Mem.os() == 2 ? WinNet.gethostname() : PosixNet.gethostname() #end;

	// [host-order IPv4 of h_addr_list[0]]
	public static inline function resolve(name:String):Null<Array<Int>>
		return #if (hxmc.target == "wasm32-wasi") WasiNet.resolve(name) #else Mem.os() == 2 ? WinNet.resolve(name) : PosixNet.resolve(name) #end;

	public static inline function reverse(ip:Int):Null<String>
		return #if (hxmc.target == "wasm32-wasi") WasiNet.reverse(ip) #else Mem.os() == 2 ? WinNet.reverse(ip) : PosixNet.reverse(ip) #end;
}
