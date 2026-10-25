package hxmc.unsafe;

import hxmc.I64;
import hxmc.scoped.Ref;
import hxmc.scoped.Slice;

// Winsock (ws2_32) and the few other functions hxmc.rt.WinNet calls, with
// the C ABI as LibC's. A SOCKET is pointer-sized (I64 here). The calls take
// views of scoped memory (docs/plans/lowlevel.md, "The scoped C boundary"):
// a buffer and its length as a Slice, an address, an option, a descriptor
// set or a length the call fills as a Ref; what Winsock returns of its own
// (a hostent, a message) as a Ptr.
@:hxmc.c @:hxmc.fast extern class Winsock {
	static function socket(af:Int, type:Int, protocol:Int):I64;
	static function closesocket(s:I64):Int;
	static function accept(s:I64, addr:Ref<UInt8>, len:Ref<Int>):I64;
	static function bind(s:I64, addr:Ref<UInt8>, len:Int):Int;
	static function connect(s:I64, addr:Ref<UInt8>, len:Int):Int;
	static function listen(s:I64, backlog:Int):Int;
	static function getsockname(s:I64, addr:Ref<UInt8>, len:Ref<Int>):Int;
	static function getpeername(s:I64, addr:Ref<UInt8>, len:Ref<Int>):Int;
	static function getsockopt(s:I64, level:Int, opt:Int, v:Ref<UInt8>, len:Ref<Int>):Int;
	static function setsockopt(s:I64, level:Int, opt:Int, v:Ref<UInt8>, len:Int):Int;
	static function recv(s:I64, buf:Slice<UInt8>, flags:Int):Int;
	static function send(s:I64, buf:Slice<UInt8>, flags:Int):Int;
	static function select(n:Int, r:Ref<UInt8>, w:Ref<UInt8>, e:Ref<UInt8>, tv:Ref<UInt8>):Int;
	static function shutdown(s:I64, how:Int):Int;
	static function ioctlsocket(s:I64, cmd:Int, arg:Ref<Int>):Int;
	static function gethostname(buf:Slice<UInt8>):Int;
	static function gethostbyname(name:Ref<UInt8>):Ptr;
	static function gethostbyaddr(addr:Ref<UInt8>, len:Int, type:Int):Ptr;
	static function WSAGetLastError():Int;
	// kernel32, the UCRT
	static function SetHandleInformation(h:I64, mask:Int, flags:Int):Int;
	static function strerror(err:Int):Ptr;
	static function _strdup(s:Ptr):Ptr;
	// rt_win.c: Winsock's error as the errno OCaml's Unix library reports; WSAStartup once
	static function rt_win_sock_errno(wsa:Int):Int;
	static function rt_win_sockets_init():Void;
}
