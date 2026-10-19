package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.PrintexcModule.PrintexcBacktraceSlot;

// A frame of a raw backtrace. The generated code records none (Haxe's call
// stacks do not map to OCaml source locations): backtraces are empty, as in
// an OCaml program compiled without debugging information.
class Slot {
	function new() {}
}

class Backtrace {
	static var recording = false;
	public static function camlRecordBacktrace(b:Bool):Unit {
		recording = b;
		return Unit.value;
	}
	public static function camlBacktraceStatus(_:Unit):Bool return recording;
	public static function camlGetExceptionRawBacktrace(_:Unit):Array<Int63> return [];
	public static function camlGetCurrentCallstack(n:Int63):Array<Int63> return [];
	public static function camlConvertRawBacktrace(bt:Array<Int63>):Array<PrintexcBacktraceSlot> {
		if (bt.length > 0) throw new Failure("no debug information");
		return [];
	}
	public static function camlConvertRawBacktraceSlot(s:Slot):PrintexcBacktraceSlot throw new Failure("no debug information");
	public static function camlRawBacktraceSlot(bt:Array<Int63>, i:Int63):Slot throw new InvalidArgument("Printexc.get_raw_backtrace_slot: index out of bounds");
	public static function camlRawBacktraceNextSlot(s:Slot):MlOption<Slot> return None;
	// 0: no debugging information (FILE_NOT_FOUND would be -1)
	public static function camlMlDebugInfoStatus(_:Unit):Int63 return Int63.zero;
}
