package ml2hx.rt;

import ml2hx.rt.Int63;

// A Printf format string, parsed once (Fmt.of caches by text), and the
// printing of its conversions as CamlinternalFormat.make_printf does it. The
// arguments come as an array, in order, one per conversion that takes one
// (and one more before it for each `*` width or precision):
//   %d %i %u %x %X %o      int (Int63)        %ld... int32 (Int)   %Ld... %nd... int64 (Int64)
//   %s %S                  string             %c %C  char (Int)    %B %b  bool
//   %f %F %e %E %g %G      float              %a     printer, value     %t printer
// A printer (%a: the output, then the value; %t: the output) is an uncurried
// Haxe function: for sprintf/ksprintf its output is Unit and it returns the
// string, for bprintf a Buffer.T, for fprintf an OutChannel (returning Unit).
class Fmt {
	public final text:String;
	public final items:Array<FmtItem>;
	// arguments taken
	public final arity:Int;

	static var cache = new haxe.ds.StringMap<Fmt>();

	public static function of(text:String):Fmt {
		var f = cache.get(text);
		if (f == null) {
			f = new Fmt(text);
			cache.set(text, f);
		}
		return f;
	}

	function new(text:String) {
		this.text = text;
		items = parse(text);
		var n = 0;
		for (it in items) n += it.arity();
		arity = n;
	}

	static function parse(s:String):Array<FmtItem> {
		var items = [];
		var lit = new StringBuf();
		var litLen = 0;
		var i = 0, n = s.length;
		inline function flush() {
			if (litLen > 0) {
				items.push(new FmtItem(FmtItem.LITERAL, lit.toString()));
				lit = new StringBuf();
				litLen = 0;
			}
		}
		while (i < n) {
			var c = StringTools.fastCodeAt(s, i++);
			if (c != "%".code) {
				lit.addChar(c);
				litLen++;
				continue;
			}
			if (i >= n) throw new InvalidArgument("Printf: bad format " + s);
			var it = new FmtItem(FmtItem.CONV, null);
			// flags
			while (i < n) {
				var f = StringTools.fastCodeAt(s, i);
				switch f {
					case "-".code: it.minus = true;
					case "0".code: it.zero = true;
					case "+".code: it.plus = true;
					case " ".code: it.space = true;
					case "#".code: it.hash = true;
					case _: break;
				}
				i++;
			}
			// width
			if (i < n && StringTools.fastCodeAt(s, i) == "*".code) {
				it.width = FmtItem.STAR;
				i++;
			} else {
				var w = -1;
				while (i < n && isDigit(StringTools.fastCodeAt(s, i))) {
					w = (w < 0 ? 0 : w * 10) + StringTools.fastCodeAt(s, i) - 48;
					i++;
				}
				it.width = w;
			}
			// precision
			if (i < n && StringTools.fastCodeAt(s, i) == ".".code) {
				i++;
				if (i < n && StringTools.fastCodeAt(s, i) == "*".code) {
					it.prec = FmtItem.STAR;
					i++;
				} else {
					var p = 0;
					while (i < n && isDigit(StringTools.fastCodeAt(s, i))) {
						p = p * 10 + StringTools.fastCodeAt(s, i) - 48;
						i++;
					}
					it.prec = p;
				}
			}
			if (i >= n) throw new InvalidArgument("Printf: bad format " + s);
			var conv = StringTools.fastCodeAt(s, i++);
			if ((conv == "l".code || conv == "n".code || conv == "L".code) && i < n) {
				var next = StringTools.fastCodeAt(s, i);
				if (next == "d".code || next == "i".code || next == "u".code || next == "x".code || next == "X".code || next == "o".code) {
					it.size = conv;
					conv = next;
					i++;
				} else {
					// %l %n %L alone: the counter, printed as %u
					it.size = 0;
					conv = "u".code;
				}
			}
			switch conv {
				case "%".code | "@".code:
					lit.addChar(conv);
					litLen++;
					continue;
				case ",".code:
					continue;
				case "!".code:
					flush();
					items.push(new FmtItem(FmtItem.FLUSH, null));
					continue;
				case _:
			}
			it.conv = conv;
			flush();
			items.push(it);
		}
		flush();
		return items;
	}

	static inline function isDigit(c:Int):Bool
		return c >= 48 && c <= 57;

	// ---- the conversions (CamlinternalFormat's printing tools)

	public static function fixPadding(zeros:Bool, left:Bool, width:Int, str:String):String {
		var len = str.length;
		if (width < 0) {
			width = -width;
			left = true;
			zeros = false;
		}
		if (width <= len) return str;
		var pad = width - len;
		if (left) return str + StringTools.lpad("", " ", pad);
		if (!zeros) return StringTools.lpad("", " ", pad) + str;
		var zs = StringTools.lpad("", "0", pad);
		if (len > 0) {
			var c0 = StringTools.fastCodeAt(str, 0);
			if (c0 == "+".code || c0 == "-".code || c0 == " ".code) return str.charAt(0) + zs + str.substr(1);
			if (len > 1 && c0 == "0".code) {
				var c1 = StringTools.fastCodeAt(str, 1);
				if (c1 == "x".code || c1 == "X".code) return str.substr(0, 2) + zs + str.substr(2);
			}
		}
		return zs + str;
	}

	public static function fixIntPrecision(prec:Int, str:String):String {
		if (prec < 0) prec = -prec;
		var len = str.length;
		var c = StringTools.fastCodeAt(str, 0);
		if ((c == "+".code || c == "-".code || c == " ".code) && prec + 1 > len)
			return str.charAt(0) + StringTools.lpad("", "0", prec + 1 - len) + str.substr(1);
		if (c == "0".code && prec + 2 > len && len > 1 && (StringTools.fastCodeAt(str, 1) == "x".code || StringTools.fastCodeAt(str, 1) == "X".code))
			return str.substr(0, 2) + StringTools.lpad("", "0", prec + 2 - len) + str.substr(2);
		if (((c >= "0".code && c <= "9".code) || (c >= "a".code && c <= "f".code) || (c >= "A".code && c <= "F".code)) && prec > len)
			return StringTools.lpad("", "0", prec - len) + str;
		return str;
	}

	// an unsigned 64-bit value in base 8, 10 or 16
	static function unsigned64(v:haxe.Int64, base:Int, upper:Bool):String {
		if (v == 0) return "0";
		var digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
		var buf = [];
		var b = haxe.Int64.ofInt(base);
		while (v != 0) {
			// unsigned divmod
			var q = haxe.Int64.divMod(v >>> 1, b >> 1).quotient;
			// q approximates v / base from below; fix up
			var r = v - q * b;
			while (haxe.Int64.ucompare(r, b) >= 0) {
				q = q + 1;
				r = r - b;
			}
			buf.push(digits.charAt(r.low));
			v = q;
		}
		buf.reverse();
		return buf.join("");
	}

	// C printf's %d %+d % d %x %#x %X %#X %o %#o %u of a word of `bits` bits
	public static function formatInt(conv:Int, plus:Bool, space:Bool, hash:Bool, v:haxe.Int64, bits:Int):String {
		switch conv {
			case "d".code | "i".code:
				var s = haxe.Int64.toStr(v);
				if (v >= 0) s = (plus ? "+" : (space ? " " : "")) + s;
				return hash ? groupDigits(s) : s;
			case _:
		}
		if (bits == 32) v = haxe.Int64.make(0, v.low);
		var s = switch conv {
			case "x".code: unsigned64(v, 16, false);
			case "X".code: unsigned64(v, 16, true);
			case "o".code: unsigned64(v, 8, false);
			case _: unsigned64(v, 10, false);
		}
		if (hash && v != 0) {
			switch conv {
				case "x".code: s = "0x" + s;
				case "X".code: s = "0X" + s;
				case "o".code: s = "0" + s;
				case _:
			}
		}
		if (hash && conv == "u".code) s = groupDigits(s);
		return s;
	}

	// transform_int_alt: '_' between groups of three digits
	static function groupDigits(s:String):String {
		var digits = 0;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c >= 48 && c <= 57) digits++;
		}
		var buf = new StringBuf();
		var left = (digits - 1) % 3 + 1;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c >= 48 && c <= 57) {
				if (left == 0) {
					buf.addChar("_".code);
					left = 3;
				}
				left--;
			}
			buf.addChar(c);
		}
		return buf.toString();
	}

	public static function convertFloat(it:FmtItem, prec:Int, x:Float):String {
		var conv = it.conv;
		if (prec < 0) prec = -prec;
		switch conv {
			case "F".code:
				if (it.hash) throw new InvalidArgument("Printf: %#F is not supported by ml2hx");
				var str = FloatFormat.format("g".code, prec, it.plus, it.space, false, x);
				if (x != x) return "nan";
				if (x == Math.POSITIVE_INFINITY) return "infinity";
				if (x == Math.NEGATIVE_INFINITY) return "neg_infinity";
				for (i in 0...str.length) {
					var c = StringTools.fastCodeAt(str, i);
					if (c == ".".code || c == "e".code || c == "E".code) return str;
				}
				return str + ".";
			case "h".code | "H".code:
				throw new InvalidArgument("Printf: %h is not supported by ml2hx");
			case _:
				return FloatFormat.format(conv, prec, it.plus, it.space, it.hash, x);
		}
	}

	// One conversion of a literal format, by its specification ("%5d"): the
	// emitter compiles format literals to concatenations of these.
	public static function one(spec:String, a:Dynamic):String {
		var f = of(spec);
		for (it in f.items) if (it.kind == FmtItem.CONV) return convert(it, it.width, it.prec, a);
		throw new InvalidArgument("Printf: no conversion in " + spec);
	}

	// the string of one conversion (output-independent ones)
	public static function convert(it:FmtItem, width:Int, prec:Int, a:Dynamic):String {
		var zeros = it.zero && !it.minus;
		var left = it.minus;
		switch it.conv {
			case "d".code | "i".code | "u".code | "x".code | "X".code | "o".code:
				var str = switch it.size {
					case "l".code: formatInt(it.conv, it.plus, it.space, it.hash, haxe.Int64.ofInt((a : Int)), 32);
					case "n".code: formatInt(it.conv, it.plus, it.space, it.hash, haxe.Int64.ofInt((a : Int)), 32);
					case "L".code: formatInt(it.conv, it.plus, it.space, it.hash, (a : haxe.Int64), 64);
					case _: formatInt(it.conv, it.plus, it.space, it.hash, (a : Int63).toInt64(), 64);
				}
				if (prec != FmtItem.NONE) str = fixIntPrecision(prec, str);
				return width != FmtItem.NONE ? fixPadding(zeros, left, width, str) : str;
			case "s".code:
				return width != FmtItem.NONE ? fixPadding(zeros, left, width, a) : a;
			case "S".code:
				var str = "\"" + ml2hx.std.String.escaped(a) + "\"";
				return width != FmtItem.NONE ? fixPadding(zeros, left, width, str) : str;
			case "c".code:
				return std.String.fromCharCode(a);
			case "C".code:
				return "'" + ml2hx.std.Char.escaped(a) + "'";
			case "B".code | "b".code:
				var str = (a : Bool) ? "true" : "false";
				return width != FmtItem.NONE ? fixPadding(zeros, left, width, str) : str;
			case "f".code | "F".code | "e".code | "E".code | "g".code | "G".code | "h".code | "H".code:
				var p = prec != FmtItem.NONE ? prec : (it.conv == "F".code ? 12 : 6);
				var str = convertFloat(it, p, a);
				return width != FmtItem.NONE ? fixPadding(zeros, left, width, str) : str;
			case c:
				throw new InvalidArgument("Printf: unsupported conversion %" + std.String.fromCharCode(c));
		}
	}

	// Formats `args` into `out`: `add` takes the text pieces, `alpha`
	// calls a %a/%t printer on the output, `flush` the %! flushes.
	public inline function run(args:Array<Dynamic>, add:std.String->Void, alpha:(Dynamic, Dynamic, Bool) -> Void, flush:Void->Void) {
		var k = 0;
		for (it in items) {
			switch it.kind {
				case FmtItem.LITERAL:
					add(it.literal);
				case FmtItem.FLUSH:
					flush();
				case _:
					var width = it.width, prec = it.prec;
					if (width == FmtItem.STAR) width = (args[k++] : Int63).toInt();
					if (prec == FmtItem.STAR) prec = (args[k++] : Int63).toInt();
					switch it.conv {
						case "a".code:
							var f = args[k++];
							alpha(f, args[k++], true);
						case "t".code:
							alpha(args[k++], null, false);
						default:
							add(convert(it, width, prec, args[k++]));
					}
			}
		}
		if (k != args.length) throw new InvalidArgument("Printf: " + args.length + " arguments for " + arity + " in " + text);
	}
}

class FmtItem {
	public static inline var LITERAL = 0;
	public static inline var CONV = 1;
	public static inline var FLUSH = 2;
	public static inline var NONE = -1;
	public static inline var STAR = -2;

	public final kind:Int;
	public final literal:Null<String>;
	public var conv = 0;
	public var size = 0;
	public var minus = false;
	public var zero = false;
	public var plus = false;
	public var space = false;
	public var hash = false;
	public var width = NONE;
	public var prec = NONE;

	public function new(kind:Int, literal:Null<String>) {
		this.kind = kind;
		this.literal = literal;
	}

	public function arity():Int {
		if (kind != CONV) return 0;
		var n = conv == "a".code ? 2 : 1;
		if (width == STAR) n++;
		if (prec == STAR) n++;
		return n;
	}
}
