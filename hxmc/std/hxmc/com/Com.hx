package hxmc.com;

import hxmc.unsafe.*;

// COM (docs/interop.md, "COM"): apartments, objects made, interfaces
// queried. Values of @:hxmc.com interfaces hold a reference each: a foreign
// object's box, or a Haxe object implementing the interface. Windows only:
// elsewhere every operation throws a ComException (E_NOTIMPL), so code
// using COM compiles for every target and runs behind a test of the system.
//
// iidOf (a type expression's IID: its @:hxmc.com metadata) is the
// compiler's; the functions taking an interface `t` inline it.
extern class Com {
	// (COINIT_DISABLE_OLE1DDE, with the apartment's flag)
	static inline var COINIT_DISABLE_OLE1DDE = 4;
	// CoCreateInstance's contexts
	static inline var CLSCTX_INPROC_SERVER = 1;
	static inline var CLSCTX_LOCAL_SERVER = 4;
	static inline var CLSCTX_ALL = 23;
	// the thread message that tells an apartment's message loop to run the
	// releases put off for it (runDeferred)
	static inline var WM_DEFERRED = 0x8000 + 0x3C3;

	// the calling thread enters a COM apartment (CoInitializeEx): every
	// thread that calls COM does, before its first call, and leaves it with
	// uninit. A single-threaded apartment's objects are released on the
	// thread that made their values (the runtime puts their releases off to
	// it), so such a thread runs a message loop that calls runDeferred on
	// WM_DEFERRED, or allocates now and then. Throws a ComException when the
	// thread is in an apartment of the other kind already (RPC_E_CHANGED_MODE)
	static inline function init(apartment:Apartment = SingleThreaded):Void {
		if (Mem.os() == 2) {
			var hr = Ole.CoInitializeEx(Ptr.nil(), (apartment : Int) | COINIT_DISABLE_OLE1DDE);
			if (hr < 0) throw new ComException(hr);
			@:privateAccess hxmc.rt.ComKind.noteThread();
		} else unavailable();
	}

	// the calling thread leaves its apartment (CoUninitialize), after running
	// the releases put off for it: values of its apartment's objects must
	// not be used after this
	static inline function uninit():Void {
		if (Mem.os() == 2) {
			runDeferred();
			@:privateAccess hxmc.rt.ComKind.forgetThread();
			Ole.CoUninitialize();
		} else unavailable();
	}

	// the releases put off for this thread (or any): a message loop's, on WM_DEFERRED
	static inline function runDeferred():Void
		@:privateAccess hxmc.rt.Foreign.runDeferred();

	// an object of class clsid ("{...}") made (CoCreateInstance), as interface t
	static inline function create<T:IUnknown>(clsid:String, t:Class<T>, context:Int = CLSCTX_ALL):T
		return make(guid(clsid), t, context);

	// the same of a CLSID's address
	static inline function make<T:IUnknown>(clsid:Ptr, t:Class<T>, context:Int = CLSCTX_ALL):T
		return cast(Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.create(clsid, context, iidOf(t)) : unavailable());

	// QueryInterface: x as interface t, or null when it has none (E_NOINTERFACE)
	static inline function query<T:IUnknown>(x:IUnknown, t:Class<T>):Null<T>
		return cast(Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.queryIid(x, iidOf(t)) : unavailable());

	// QueryInterface: x as interface t; throws a ComException (E_NOINTERFACE)
	// when it has none
	static inline function as<T:IUnknown>(x:IUnknown, t:Class<T>):T
		return cast(Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.asIid(x, iidOf(t)) : unavailable());

	// the IID of interface t (16 bytes, never freed): the compiler's
	static function iidOf<T:IUnknown>(t:Class<T>):Ptr;

	// an interface pointer an [out] parameter gave (+1, the caller's), as a
	// value of interface t: the value takes the reference over
	static inline function adopt<T:IUnknown>(p:Ptr, t:Class<T>):Null<T>
		return cast(Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.adopt(p) : unavailable());

	// a borrowed interface pointer as a value of interface t (which holds a
	// reference of its own)
	static inline function wrap<T:IUnknown>(p:Ptr, t:Class<T>):Null<T>
		return cast(Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.wrap(p) : unavailable());

	// x's pointer of interface t, borrowed: valid while x lives (to pass to C)
	static inline function ptr<T:IUnknown>(x:IUnknown, t:Class<T>):Ptr
		return Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.ptrIid(x, iidOf(t)) : unavailable();

	// whether a and b are one COM object (their canonical IUnknowns), whatever
	// their interfaces (== compares the values: one per interface pointer)
	static inline function same(a:Null<IUnknown>, b:Null<IUnknown>):Bool
		return Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.same2(a, b) : unavailable();

	// the object's reference count after an AddRef and a Release: a
	// diagnostic (a Haxe object's counts the reference its pairing holds)
	static inline function refCount(x:IUnknown):Int
		return Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.refCount(x) : unavailable();

	// x (a foreign object's value) gives up its reference now, not once a
	// collection finds it dead; calls through it throw from then on
	static inline function detach(x:IUnknown):Void
		if (Mem.os() == 2) @:privateAccess hxmc.rt.ComKind.detach(x) else unavailable();

	// the GUID of "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}" (16 bytes, interned, never freed)
	static inline function guid(s:String):Ptr
		return Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.guid(s) : unavailable();

	// a BSTR of s (SysAllocStringLen), for C functions that take one: the
	// caller's to free (freeBstr); and a BSTR's string
	static inline function bstr(s:String):Ptr
		return Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.bstr(s) : unavailable();

	static inline function freeBstr(p:Ptr):Void
		if (Mem.os() == 2) @:privateAccess hxmc.rt.ComKind.bstrFree(p) else unavailable();

	static inline function ofBstr(p:Ptr):String
		return Mem.os() == 2 ? @:privateAccess hxmc.rt.ComKind.bstrString(p) : unavailable();

	// (other systems: E_NOTIMPL, thrown)
	static inline function unavailable<T>():T
		return @:privateAccess ComException.unavailable();
}

@:hxmc.c @:hxmc.lib("ole32") private extern class Ole {
	@:hxmc.blocking static function CoInitializeEx(reserved:Ptr, flags:Int):Int;
	@:hxmc.blocking static function CoUninitialize():Void;
}
