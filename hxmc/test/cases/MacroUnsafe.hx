// A class with a macro function is typed in the macro context too (Eval),
// every field of it. Probe's fields mention hxmc.unsafe (an import, fields'
// types, signatures, bodies a macro never runs), so Eval loaded hxmc.unsafe's
// modules and compiled their functions: Ptr's call Mem.ult, an extern Eval
// has no field for, and every build failed, natively too: "Field index for
// ult not found on prototype hxmc.unsafe.Mem". hxmc's externs now compile on
// Eval and throw if a macro runs them, naming the function
// (hxmc.TargetFlags.evalExtern); Arena and CString keep hxmc's runtime out
// of Eval. With -D hxmc.macros=mir the macro context is hxmc's, where they
// run as in the program.
import hxmc.I64;
import hxmc.unsafe.*;
import hxmc.unsafe.Callback;

class MacroUnsafe {
	static function main() {
		trace(Probe.atMacroTime());
		trace(Probe.sum(4));
		trace(Probe.text("héllo"));
		trace(!Callback.addr(Probe.tick).isNull());
	}
}

class Probe {
	public var p:Ptr<Int>;
	public var arena:Arena;
	public var atomic:Atomic;
	public var blocking:Blocking;
	public var bytesPtr:BytesPtr;
	public var cstring:CString;
	public var callback:Callback;
	public var f32:Float32;
	public var i8:Int8;
	public var i16:Int16;
	public var i32:Int32;
	public var i64:Int64;
	public var u8:UInt8;
	public var u16:UInt16;
	public var u32:UInt32;
	public var u64:UInt64;
	public var ioBuffer:IoBuffer;
	public var libc:LibC;
	public var mem:Mem;
	public var posix:Posix;
	public var slice:Slice<Int>;
	public var struct:Struct;
	public var win32:Win32;
	public var winsock:Winsock;

	// a call of hxmc.unsafe at macro time: on Eval it throws, naming the
	// function; on the Mir interpreter it runs
	public static macro function atMacroTime() {
		var said = try {
			LibC.free(LibC.malloc(16));
			"ran";
		} catch (e:Dynamic) Std.string(e);
		#if eval
		return macro $v{said == "hxmc.unsafe.LibC.malloc is implemented by hxmc's code generator or runtime: a macro on Eval cannot use it"};
		#else
		return macro $v{said == "ran"};
		#end
	}

	public static function sum(n:Int):Int {
		var p:Ptr<Int> = LibC.malloc((4 * n : I64));
		for (i in 0...n)
			p[i] = i + 1;
		var s = new Slice(p, n), t = 0;
		for (i in 0...s.length)
			t += s[i];
		LibC.free(p);
		return t;
	}

	public static function text(s:String):String
		return Arena.scopedValue(a -> a.cstring(s).toString() + " " + a.cstring(s).length());

	@:hxmc.callback public static function tick(n:Int):Int
		return n;
}
