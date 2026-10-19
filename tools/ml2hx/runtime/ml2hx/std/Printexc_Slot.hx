package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;
import ml2hx.std.Printexc;

// Printexc.Slot
typedef PrintexcSlotT = PrintexcBacktraceSlot;

class Printexc_Slot {
	public static function isRaise(s:PrintexcSlotT):Bool return false;
	public static function isInline(s:PrintexcSlotT):Bool return false;
	public static function location(s:PrintexcSlotT):MlOption<PrintexcLocation> return None;
	public static function name(s:PrintexcSlotT):MlOption<String> return None;
	public static function format(i:Int63, s:PrintexcSlotT):MlOption<String> return None;
}
