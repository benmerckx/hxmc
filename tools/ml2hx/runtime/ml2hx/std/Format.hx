package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Format without boxes: a formatter writes its text through. (The
// compiler only prints strings to formatters; pretty-printing boxes and
// break hints are not provided.)
class FormatFormatter {
	public final out:String->Void;
	public final flush:Void->Void;
	public function new(out:String->Void, flush:Void->Void) {
		this.out = out;
		this.flush = flush;
	}
}

class Format {
	public static final stdFormatter = new FormatFormatter(s -> Stdlib.printString(s), () -> Stdlib.flush(Stdlib.stdout));
	public static final errFormatter = new FormatFormatter(s -> Stdlib.prerrString(s), () -> Stdlib.flush(Stdlib.stderr));
	public static function formatterOfBuffer(b:Buffer.BufferT):FormatFormatter return new FormatFormatter(s -> Buffer.addString(b, s), () -> {});
	public static function formatterOfOutChannel(oc:Stdlib.StdlibOutChannel):FormatFormatter
		return new FormatFormatter(s -> Stdlib.outputString(oc, s), () -> Stdlib.flush(oc));
	public static function ppPrintString(f:FormatFormatter, s:String):Unit { f.out(s); return Unit.value; }
	public static function ppPrintChar(f:FormatFormatter, c:Int):Unit { f.out(std.String.fromCharCode(c)); return Unit.value; }
	public static function ppPrintInt(f:FormatFormatter, n:Int63):Unit { f.out(n.toString()); return Unit.value; }
	public static function ppPrintNewline(f:FormatFormatter, _:Unit):Unit { f.out("\n"); f.flush(); return Unit.value; }
	public static function ppPrintFlush(f:FormatFormatter, _:Unit):Unit { f.flush(); return Unit.value; }
	public static function printString(s:String):Unit return ppPrintString(stdFormatter, s);
	public static function printNewline(_:Unit):Unit return ppPrintNewline(stdFormatter, Unit.value);
	public static function printFlush(_:Unit):Unit return ppPrintFlush(stdFormatter, Unit.value);
}
