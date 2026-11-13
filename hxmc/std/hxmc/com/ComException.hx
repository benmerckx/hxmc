package hxmc.com;

import hxmc.Platform;
import hxmc.unsafe.*;

// A failed HRESULT (docs/interop.md, "COM"): what a COM method's call throws
// when the method returns one below zero (unless it is declared
// @:hxmc.com.hresult), and what a Haxe method COM calls throws to return
// one (any other exception returns E_FAIL). The message is the system's
// (FormatMessageW), or the code's when it has none.
class ComException extends haxe.Exception {
	public static inline var E_NOTIMPL = 0x80004001;
	public static inline var E_NOINTERFACE = 0x80004002;
	public static inline var E_POINTER = 0x80004003;
	public static inline var E_ABORT = 0x80004004;
	public static inline var E_FAIL = 0x80004005;
	public static inline var E_UNEXPECTED = 0x8000FFFF;
	public static inline var E_INVALIDARG = 0x80070057;
	public static inline var E_OUTOFMEMORY = 0x8007000E;

	public final hresult:Int;

	public function new(hresult:Int, ?message:String) {
		super(message != null ? message : describe(hresult));
		this.hresult = hresult;
	}

	// (Com on other systems than Windows)
	static function unavailable<T>():T
		throw new ComException(E_NOTIMPL, "COM (hxmc.com) is Windows only");

	// (a COM call, query or IID on another system than Windows: hxmc.ir.Com)
	@:keep @:hxmc.host("rt_com_unavailable") static function unavailableHost():Void
		unavailable();

	// the HRESULT as COM prints it (0x80004002)
	public static function hex(hr:Int):String
		return "0x" + StringTools.hex(hr, 8);

	// "0x80004002: No such interface supported": the code and the system's message
	public static function describe(hr:Int):String {
		var text = Platform.os() == 2 ? systemMessage(hr) : null;
		return text != null && text != "" ? hex(hr) + ": " + text : hex(hr);
	}

	// FormatMessageW's text of hr (FROM_SYSTEM, IGNORE_INSERTS), its line end dropped
	@:hxmc.unsafe(gc) static function systemMessage(hr:Int):Null<String> {
		var buf = Mem.stack(8);
		Mem.setPtr(buf, 0, Ptr.nil());
		// (ALLOCATE_BUFFER 0x100 | IGNORE_INSERTS 0x200 | FROM_SYSTEM 0x1000)
		var n = K.FormatMessageW(0x1300, Ptr.nil(), hr, 0, buf, 0, Ptr.nil());
		var p = Mem.getPtr(buf, 0);
		if (n <= 0 || p.isNull()) return null;
		var s = @:privateAccess hxmc.rt.ComKind.ofUnits(p, n);
		K.LocalFree(p);
		return StringTools.rtrim(s);
	}
}

@:hxmc.c @:hxmc.lib("kernel32") private extern class K {
	static function FormatMessageW(flags:Int, source:Ptr, id:Int, lang:Int, buf:Ptr, size:Int, args:Ptr):Int;
	@:hxmc.fast static function LocalFree(p:Ptr):Ptr;
}
