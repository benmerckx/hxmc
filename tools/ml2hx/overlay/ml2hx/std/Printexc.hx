package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Printexc. Backtraces: none are recorded (empty).
class Printexc {
	static var printers:Array<Dynamic->MlOption<String>> = [];

	// Printexc.field: an immediate as %d, a string as %S, a float, else _
	static function field(v:Dynamic):String {
		var i = Poly.immediateOf(v);
		if (i != null) return haxe.Int64.toStr(i);
		if (Std.isOfType(v, String)) return "\"" + ml2hx.std.String.escaped(v) + "\"";
		if (Std.isOfType(v, Float)) return FloatFormat.stringOfFloat(v);
		return "_";
	}

	static function locfmt(file:String, line:Int63, char:Int63, char2:Int63, msg:String):String
		return Printf.sprintf(Fmt.of("File \"%s\", line %d, characters %d-%d: %s"), [file, line, char, char2, msg]);

	public static function toStringDefault(e:Dynamic):String {
		if (!Std.isOfType(e, MlException)) return Std.string(e);
		var x:MlException = e;
		if (Std.isOfType(x, OutOfMemory)) return "Out of memory";
		if (Std.isOfType(x, StackOverflow)) return "Stack overflow";
		if (Std.isOfType(x, MatchFailure)) {
			var m:MatchFailure = cast x;
			return locfmt(m.v0, m.v1, m.v2, Int63.add(m.v2, Int63.ofInt(5)), "Pattern matching failed");
		}
		if (Std.isOfType(x, AssertFailure)) {
			var m:AssertFailure = cast x;
			return locfmt(m.v0, m.v1, m.v2, Int63.add(m.v2, Int63.ofInt(6)), "Assertion failed");
		}
		if (Std.isOfType(x, UndefinedRecursiveModule)) {
			var m:UndefinedRecursiveModule = cast x;
			return locfmt(m.v0, m.v1, m.v2, Int63.add(m.v2, Int63.ofInt(6)), "Undefined recursive module");
		}
		var n = x.exnArity();
		if (n == 0) return x.exnName();
		var args:Array<Dynamic> = [for (i in 0...n) x.exnArg(i)];
		return x.exnName() + "(" + [for (a in args) field(a)].join(", ") + ")";
	}

	public static function toString(e:Dynamic):String {
		for (p in printers) switch p(e) {
			case Some(s): return s;
			case None:
		}
		return toStringDefault(e);
	}

	public static function toStringDefaultExn(e:MlException):String
		return toStringDefault(e);

	public static function registerPrinter(f:MlException->MlOption<String>):Unit {
		printers.unshift(e -> Std.isOfType(e, MlException) ? f(e) : None);
		return Unit.value;
	}

	public static function print<A, B>(f:A->B, x:A):B {
		try
			return f(x)
		catch (e:MlException) {
			Stdlib.prerrEndline("Uncaught exception: " + toString(e));
			throw e;
		}
	}

	public static function getBacktrace(_:Unit):String
		return "";

	public static function recordBacktrace(b:Bool):Unit
		return Unit.value;

	public static function backtraceStatus(_:Unit):Bool
		return false;

	public static function getRawBacktrace(_:Unit):PrintexcRawBacktrace
		return new PrintexcRawBacktrace();

	public static function getCallstack(n:Int63):PrintexcRawBacktrace
		return new PrintexcRawBacktrace();

	public static function rawBacktraceToString(b:PrintexcRawBacktrace):String
		return "";

	public static function rawBacktraceLength(b:PrintexcRawBacktrace):Int63
		return Int63.zero;

	public static function backtraceSlots(b:PrintexcRawBacktrace):MlOption<Array<PrintexcBacktraceSlot>>
		return None;

	public static function getRawBacktraceSlot(b:PrintexcRawBacktrace, i:Int63):PrintexcRawBacktraceSlot
		throw new InvalidArgument("Printexc.get_raw_backtrace_slot: index out of bounds");

	public static function convertRawBacktraceSlot(s:PrintexcRawBacktraceSlot):PrintexcBacktraceSlot
		return new PrintexcBacktraceSlot();

	public static function printBacktrace(oc:Stdlib.StdlibOutChannel):Unit
		return Unit.value;

	public static function exnSlotName(e:MlException):String
		return e.exnName();
}

// raw_backtrace: no frames are recorded
class PrintexcRawBacktrace {
	public function new() {}
}

// A frame of a backtrace (none are recorded: no values of these exist).
class PrintexcRawBacktraceSlot {
	public function new() {}
}

class PrintexcBacktraceSlot {
	public function new() {}
}

// Printexc.location
class PrintexcLocation implements Block {
	public final filename:String;
	public final lineNumber:Int63;
	public final startChar:Int63;
	public final endChar:Int63;
	public function new(filename:String, lineNumber:Int63, startChar:Int63, endChar:Int63) {
		this.filename = filename;
		this.lineNumber = lineNumber;
		this.startChar = startChar;
		this.endChar = endChar;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 4;
	public function blockField(i:Int):Dynamic return switch i { case 0: filename; case 1: lineNumber; case 2: startChar; case _: endChar; };
}
