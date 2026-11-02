package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.*;

// Objective-C exceptions (docs/interop.md, "Exceptions"): an exception
// libobjc throws (objc_exception_throw: the C++ ABI's two-phase unwinding)
// that reaches a Haxe frame becomes a Haxe throw there. The program's
// unwind tables name rt_objc_personality as the personality of its Haxe
// functions, and the stub hxmc_objc_landing as their language-specific
// data (LinkMachO: a program with Objective-C, DataGen.objcCaught; nothing
// here names the program's own symbols, which a program without
// Objective-C has not). Its search phase claims the first Haxe frame the
// exception reaches; its cleanup phase has the unwinder resume that frame
// in the stub, which continues in hxmc_objc_caught as though the call the
// exception left had called it (the call's return address where a call
// puts it; the frame's stack pointer and callee-saved registers are the
// unwinder's, as at that call's return). hxmc_objc_caught, generated,
// leaves the safe region the message was sent in and calls rt_objc_caught,
// which takes the exception (objc_begin_catch, libc++abi's
// __cxa_begin_catch: its result is what a C++ personality's search set,
// which this one does not, so the object is read where libobjc put it),
// boxes the object as any id becoming a value, ends the catch (which
// releases the exception) and throws the box as a Haxe throw does
// (rt_throw: the innermost try, which is this frame's or a caller's).
// Nothing runs in the personality but a few loads and stores, as in Faults.
//
// A frame is claimed when the thread is one of the runtime's, not
// collecting, and its innermost handler, when there is one, is a frame at
// or above this one; another exception (C++'s) and a forced unwind pass
// through, as before. Entries Objective-C calls (ObjC.entry) have no
// personality: an exception they raise (a Haxe exception leaving a method)
// goes on to Objective-C's frames.
@:hxmc.native @:keep @:allow(hxmc.rt)
class ObjCExceptions {
	// _Unwind_Action
	static inline var SEARCH_PHASE = 1;
	static inline var HANDLER_FRAME = 4;
	static inline var FORCE_UNWIND = 8;
	// _Unwind_Reason_Code
	static inline var FATAL_PHASE1_ERROR = 3;
	static inline var HANDLER_FOUND = 6;
	static inline var INSTALL_CONTEXT = 7;
	static inline var CONTINUE_UNWIND = 8;

	// libobjc throws with libc++abi (__cxa_throw): its exceptions are C++'s,
	// "CLNGC++\0", whose type (the std::type_info at -80 from the unwind
	// header, in the __cxa_exception before it: LP64) is libobjc's own
	// objc_typeinfo, in the thrown object after the id (+32 from the header:
	// libobjc's objc_exception {id obj; objc_typeinfo tinfo}), where a C++
	// exception's is its type's (typeid(T), in an image)
	@:hxmc.unsafe static inline function cxxClass():I64
		return ((0x434c4e47 : I64) << 32) | 0x432b2b00;

	@:hxmc.unsafe static inline function isObjC(cls:I64, ue:Ptr):Bool
		return cls == cxxClass() && Mem.getPtr(ue, -80) == ue.add(40);

	@:hxmc.export("rt_objc_personality") @:hxmc.unsafe static function personality(version:Int, actions:Int, cls:I64, ue:Ptr, ctx:Ptr):Int {
		// (Apple's systems only: one branch is lowered, Lower folds Mem.os())
		var r = CONTINUE_UNWIND;
		if (Mem.os() == 1) r = claim(version, actions, cls, ue, ctx) else {}
		return r;
	}

	@:hxmc.unsafe static function claim(version:Int, actions:Int, cls:I64, ue:Ptr, ctx:Ptr):Int {
		if (version != 1) return FATAL_PHASE1_ERROR;
		if (!isObjC(cls, ue) || actions & FORCE_UNWIND != 0) return CONTINUE_UNWIND;
		var landing = U._Unwind_GetLanguageSpecificData(ctx);
		if (landing.isNull()) return CONTINUE_UNWIND;
		// the frame's stack pointer (DWARF: arm64 sp 31, x86-64 rsp 7)
		var sp = U._Unwind_GetGR(ctx, Mem.arm() ? 31 : 7);
		var m = Threads.self;
		if (m.isNull() || Threads.collector == m) return CONTINUE_UNWIND;
		var h = Gc.hcur;
		if (!h.isNull() && h.ult(sp)) return CONTINUE_UNWIND;
		if (actions & SEARCH_PHASE != 0) return HANDLER_FOUND;
		if (actions & HANDLER_FRAME == 0) return CONTINUE_UNWIND;
		// the stub (ue, the return address): the first two arguments'
		// registers (DWARF: arm64 x0, x1; x86-64 rdi 5, rsi 4)
		U._Unwind_SetGR(ctx, Mem.arm() ? 0 : 5, ue);
		U._Unwind_SetGR(ctx, Mem.arm() ? 1 : 4, U._Unwind_GetIP(ctx));
		U._Unwind_SetIP(ctx, landing);
		return INSTALL_CONTEXT;
	}

	// the exception ue as a Haxe throw (hxmc_objc_caught, out of the safe
	// region): libobjc's functions come as addresses (the runtime does not
	// link libobjc), those of a box's too (Gc.idBox)
	@:hxmc.export("rt_objc_caught") static function caught(ue:Ptr, beginCatch:Ptr, endCatch:Ptr, retain:Ptr, release:Ptr, getClass:Ptr, getIvar:Ptr,
			ivarOffset:Ptr):Void {
		Ind.call1(beginCatch, ue);
		var id = Mem.getPtr(ue, 32);
		var v = Gc.idBox(id, retain, release, getClass, getIvar, ivarOffset);
		Ind.call0(endCatch);
		Rt.rt_throw(v);
	}

	// ---- a Haxe exception leaving a method or block Objective-C called
	// (ObjC.imps, ObjC.invoke) is raised as an Objective-C exception by the
	// entry once it took its caller's state back (ObjC.entry: rt_objc_raising,
	// then objc_exception_throw from its frame, which has no personality). An
	// Objective-C object (a box of an id, an object of a Haxe class extending
	// an Objective-C one) is raised itself; another value as an NSException
	// of the class HXMCException (registered here at the first), named
	// "HaxeException", Std.string of the value its reason, and paired with
	// the value as a Haxe class's object is with its id (Gc.pair): an
	// exception that comes back to a Haxe frame is the value again
	// (Gc.idBox). libobjc's functions are found by name (dlsym: the runtime
	// does not link libobjc).

	// the id the entry raises (retained, autoreleased), else nil
	@:hxmc.threadLocal static var raising:Ptr;

	// the exception v leaving a method: raised by its entry, else (no
	// NSException class: Foundation not loaded) reported as an uncaught one,
	// the end of the program
	@:hxmc.export("rt_objc_raise") static function raise(v:Dynamic):Void {
		var id = Gc.idOf(v);
		if (id.isNull()) id = wrap(v);
		if (id.isNull()) {
			Gc.uncaught("Uncaught exception in a method Objective-C called: ", v);
			Stacks.report();
			Os.exit(1);
		}
		Ind.call1(fn(Mem.cstr("objc_retain")), id);
		raising = Ind.call1(fn(Mem.cstr("objc_autorelease")), id);
	}

	@:hxmc.export("rt_objc_raising") @:hxmc.unsafe static function takeRaising():Ptr {
		var r = raising;
		raising = Ptr.nil();
		return r;
	}

	@:hxmc.unsafe static function fn(name:Ptr):Ptr {
		var r = Ptr.nil();
		if (Mem.os() == 1) r = S.dlsym(Ptr.ofI64(-2), name) else {} // (RTLD_DEFAULT)
		return r;
	}

	@:hxmc.unsafe static function sel(name:Ptr):Ptr
		return Ind.call1(fn(Mem.cstr("sel_registerName")), name);

	@:hxmc.unsafe static function nsString(s:Ptr):Ptr
		return Ind.call3(fn(Mem.cstr("objc_msgSend")), Ind.call1(fn(Mem.cstr("objc_getClass")), Mem.cstr("NSString")), sel(Mem.cstr("stringWithUTF8String:")), s);

	// Std.string of a native handle v (Dyn.str): an id's box's is the
	// object's description (an NSException's: its reason), another
	// handle's null
	static function description(v:Dynamic):Null<String> {
		var r:Null<String> = null;
		if (Mem.os() == 1) r = describe(v) else {}
		return r;
	}

	static function describe(v:Dynamic):Null<String> {
		var id = Gc.idOf(v);
		if (id.isNull()) return null;
		var send = fn(Mem.cstr("objc_msgSend"));
		var d = Ind.call2(send, id, sel(Mem.cstr("description")));
		var s = d.isNull() ? Ptr.nil() : Ind.call2(send, d, sel(Mem.cstr("UTF8String")));
		return s.isNull() ? null : Str.ofUtf8(s, LibC.strlen(s).toInt());
	}

	// a new NSException carrying v (nil: no NSException class)
	static function wrap(v:Dynamic):Ptr {
		var getClass = fn(Mem.cstr("objc_getClass")), send = fn(Mem.cstr("objc_msgSend"));
		var cls = Ind.call1(getClass, Mem.cstr("HXMCException"));
		if (cls.isNull()) {
			var sup = Ind.call1(getClass, Mem.cstr("NSException"));
			if (sup.isNull()) return Ptr.nil();
			// (nil: another thread registered it meanwhile)
			var c = Ind.call3(fn(Mem.cstr("objc_allocateClassPair")), sup, Mem.cstr("HXMCException"), Ptr.nil());
			if (!c.isNull()) {
				Ind.call5(fn(Mem.cstr("class_addIvar")), c, Mem.cstr("hxmc_peer"), Ptr.ofI64(4), Ptr.ofI64(2), Mem.cstr("i"));
				Ind.call1(fn(Mem.cstr("objc_registerClassPair")), c);
			}
			cls = Ind.call1(getClass, Mem.cstr("HXMCException"));
			// (nil: another thread's, not registered yet)
			if (cls.isNull()) return Ptr.nil();
		}
		var reason = Str.toUtf8(Std.string(v));
		var obj = Ind.call2(send, cls, sel(Mem.cstr("alloc")));
		obj = Ind.call5(send, obj, sel(Mem.cstr("initWithName:reason:userInfo:")), nsString(Mem.cstr("HaxeException")), nsString(reason), Ptr.nil());
		LibC.free(reason);
		var ivar = Ind.call2(fn(Mem.cstr("class_getInstanceVariable")), cls, Mem.cstr("hxmc_peer"));
		var at = Ind.call1(fn(Mem.cstr("ivar_getOffset")), ivar);
		// (null: thrown as nothing to pair, an NSException without a value)
		if (v != null) Mem.setI32(obj.addL(at.toI64()), 0, Gc.pair(v, obj, fn(Mem.cstr("_objc_rootRetainCount")), fn(Mem.cstr("objc_release")), false));
		return obj;
	}
}

@:hxmc.c @:hxmc.fast private extern class S {
	static function dlsym(handle:Ptr, name:Ptr):Ptr;
}

@:hxmc.c @:hxmc.fast private extern class U {
	static function _Unwind_GetGR(ctx:Ptr, reg:Int):Ptr;
	static function _Unwind_SetGR(ctx:Ptr, reg:Int, v:Ptr):Void;
	static function _Unwind_GetIP(ctx:Ptr):Ptr;
	static function _Unwind_SetIP(ctx:Ptr, v:Ptr):Void;
	static function _Unwind_GetLanguageSpecificData(ctx:Ptr):Ptr;
}

@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call0(f:Ptr):Void;
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
	@:hxmc.indirect static function call3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Ptr;
	@:hxmc.indirect static function call5(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr, e:Ptr):Ptr;
}
