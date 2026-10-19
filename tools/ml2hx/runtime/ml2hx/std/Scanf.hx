package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.std.Scanf_Scanning;
import ml2hx.rt.Fmt;

class ScanfScanFailure extends MlException {
	public final v0:String;
	public function new(v0:String) {
		super();
		this.v0 = v0;
	}
	override public function exnName():String return "Stdlib.Scanf.Scan_failure";
	override public function exnArity():Int return 1;
	override public function exnArg(i:Int):Dynamic return v0;
}

// Stdlib.Scanf for the conversions the compiler's code uses: integers
// (%d %i %u %x %X %o), strings (%s up to a space), %c, floats (%f %e %g),
// %b, literal characters and spaces (a space matches any amount of white
// space). The consumer function is applied to the values one at a time.
class Scanf {
	static function isSpace(c:Int) return c == " ".code || c == "\t".code || c == "\n".code || c == "\r".code;
	static function fail(msg:String):Dynamic throw new ScanfScanFailure("scanf: " + msg);
	static function scanToken(ib:ScanfScanningInChannel, ok:Int->Bool, width:Int):String {
		var b = new StringBuf(), n = 0;
		while ((width < 0 || n < width) && ib.peek() >= 0 && ok(ib.peek())) { b.addChar(ib.take()); n++; }
		return b.toString();
	}
	static function skipSpaces(ib:ScanfScanningInChannel) while (ib.peek() >= 0 && isSpace(ib.peek())) ib.take();
	static function scanValues(ib:ScanfScanningInChannel, fmt:Fmt):HArray<Dynamic> {
		var values:HArray<Dynamic> = [];
		for (it in fmt.items) {
			if (it.kind == ml2hx.rt.Fmt.FmtItem.LITERAL) {
				for (i in 0...it.literal.length) {
					var c = StringTools.fastCodeAt(it.literal, i);
					if (c == " ".code) skipSpaces(ib);
					else if (ib.peek() == c) ib.take();
					else fail('looking for ${std.String.fromCharCode(c)}, found ${ib.peek() < 0 ? "end of input" : std.String.fromCharCode(ib.peek())}');
				}
				continue;
			}
			if (it.kind != ml2hx.rt.Fmt.FmtItem.CONV) continue;
			var w = it.width >= 0 ? it.width : -1;
			switch it.conv {
				case "d".code | "i".code | "u".code:
					skipSpaces(ib);
					var sign = (ib.peek() == "-".code || ib.peek() == "+".code) ? std.String.fromCharCode(ib.take()) : "";
					var digits = scanToken(ib, c -> (c >= "0".code && c <= "9".code) || c == "_".code, w);
					if (digits == "") fail("character is not a decimal digit");
					values.push(Stdlib.intOfString(sign + digits));
				case "x".code | "X".code | "o".code:
					skipSpaces(ib);
					var hex = it.conv != "o".code;
					var digits = scanToken(ib, c -> (c >= "0".code && c <= (hex ? "9".code : "7".code)) || (hex && ((c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code))), w);
					if (digits == "") fail("character is not a digit");
					values.push(Stdlib.intOfString((hex ? "0x" : "0o") + digits));
				case "s".code:
					skipSpaces(ib);
					values.push(scanToken(ib, c -> !isSpace(c), w));
				case "c".code:
					var c = ib.take();
					if (c < 0) throw EndOfFile.instance;
					values.push(c);
				case "f".code | "e".code | "E".code | "g".code | "G".code | "F".code:
					skipSpaces(ib);
					var t = scanToken(ib, c -> (c >= "0".code && c <= "9".code) || c == ".".code || c == "e".code || c == "E".code || c == "-".code || c == "+".code || c == "_".code, w);
					values.push(Stdlib.floatOfString(t));
				case "b".code | "B".code:
					skipSpaces(ib);
					var t = scanToken(ib, c -> c >= "a".code && c <= "z".code, 5);
					values.push(t == "true" ? true : t == "false" ? false : fail("bad boolean"));
				case c:
					fail("unsupported conversion %" + std.String.fromCharCode(c));
			}
		}
		return values;
	}
	static function apply(f:Dynamic, values:HArray<Dynamic>):Dynamic {
		var r:Dynamic = f;
		for (v in values) r = r(v);
		return r;
	}
	// The signatures' arities: kscanf ib ef : ('a, ...) scanner (a format
	// to a function of the consumer), sscanf s : scanner.
	public static function kscanf<R>(ib:ScanfScanningInChannel, ef:(ScanfScanningInChannel, MlException) -> R):Dynamic {
		return function(fmt:Fmt):Dynamic return function(f:Dynamic):Dynamic {
			var values = try scanValues(ib, fmt) catch (e:MlException) return ef(ib, e);
			return apply(f, values);
		};
	}
	public static function bscanf(ib:ScanfScanningInChannel):Dynamic
		return function(fmt:Fmt):Dynamic return function(f:Dynamic):Dynamic return apply(f, scanValues(ib, fmt));
	public static function sscanf(s:String):Dynamic return bscanf(Scanf_Scanning.fromString(s));
	public static function ksscanf<R>(s:String, ef:(ScanfScanningInChannel, MlException) -> R):Dynamic
		return kscanf(Scanf_Scanning.fromString(s), ef);
}
