package macros.eval;

import core.Globals;
import haxe.Int64;
import macros.eval.EvalValue;
import macros.eval.EvalEncode.vfun1;
import macros.eval.EvalEncode.vfun2;
import macros.eval.EvalExceptions.EvalExceptions.unexpectedValue;
import macros.eval.EvalDecode.decodeI32;
import macros.eval.EvalDecode.decodeInt;
import macros.eval.EvalDecode.decodeString;
import macros.eval.EvalMisc.throwString;

// port: Int64 is `haxe.Int64`; UInt64 values are `haxe.Int64` bit patterns and the
// unsigned operations of the `integers` library (Unsigned.UInt64) are
// implemented explicitly below. `Size_t` is 64 bits wide.
class EvalIntegers {
	// port: Unsigned.UInt64
	public static final uint64MaxInt:Int64 = Int64.make(-1, -1);

	// port: UInt64.div; raises Division_by_zero.
	public static function uint64Div(a:Int64, b:Int64):Int64 return uint64DivRem(a, b).q;

	// port: UInt64.rem; raises Division_by_zero.
	public static function uint64Rem(a:Int64, b:Int64):Int64 return uint64DivRem(a, b).r;

	static function uint64DivRem(a:Int64, b:Int64):{q:Int64, r:Int64} {
		if (Int64.isZero(b)) throw new DivisionByZero();
		if (Int64.ucompare(a, b) < 0) return {q: Int64.ofInt(0), r: a};
		if (b.high < 0) {
			// port: b >= 2^63 and a >= b: the quotient is 1
			return {q: Int64.ofInt(1), r: Int64.sub(a, b)};
		}
		if (a.high >= 0) {
			var d = Int64.divMod(a, b);
			return {q: d.quotient, r: d.modulus};
		}
		// port: a >= 2^63, b < 2^63: long division by bits
		var q = Int64.ofInt(0), r = Int64.ofInt(0);
		var i = 63;
		while (i >= 0) {
			r = Int64.or(Int64.shl(r, 1), Int64.and(Int64.ushr(a, i), Int64.ofInt(1)));
			if (Int64.ucompare(r, b) >= 0) {
				r = Int64.sub(r, b);
				q = Int64.or(q, Int64.shl(Int64.ofInt(1), i));
			}
			i--;
		}
		return {q: q, r: r};
	}

	// port: UInt64.to_string (unsigned decimal).
	public static function uint64ToString(u:Int64):String {
		if (u.high >= 0) return Int64.toStr(u);
		var q = Int64.div(Int64.ushr(u, 1), Int64.ofInt(5));
		var r = Int64.sub(u, Int64.mul(q, Int64.ofInt(10)));
		return Int64.toStr(q) + Std.string(r.low);
	}

	// port: UInt64.of_string: integers' C parser (sign, 0x/0o/0b/0u prefixes, '_'); raises Failure.
	public static function uint64OfString(s:String):Int64 {
		inline function fail():Dynamic throw new core.ds.Failure("UInt64.of_string");
		var i = 0, sign = 1, base = 10;
		if (i < s.length && s.charAt(i) == "-") {
			sign = -1;
			i++;
		} else if (i < s.length && s.charAt(i) == "+") i++;
		if (i + 1 < s.length && s.charAt(i) == "0") switch s.charAt(i + 1) {
			case "x" | "X":
				base = 16;
				i += 2;
			case "o" | "O":
				base = 8;
				i += 2;
			case "b" | "B":
				base = 2;
				i += 2;
			case "u" | "U":
				i += 2;
			case _:
		}
		inline function digit(c:Int):Int {
			return if (c >= "0".code && c <= "9".code) c - "0".code else if (c >= "A".code && c <= "F".code) c - "A".code + 10 else
				if (c >= "a".code
				&& c <= "f".code) c
				- "a".code + 10 else -1;
		}
		var maxPrefix = uint64Div(uint64MaxInt, Int64.ofInt(base));
		var d = i < s.length ? digit(StringTools.fastCodeAt(s, i)) : -1;
		if (d < 0 || d >= base) fail();
		var r = Int64.ofInt(d);
		i++;
		while (i < s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c == "_".code) {
				i++;
				continue;
			}
			d = digit(c);
			if (d < 0 || d >= base) break;
			if (Int64.ucompare(r, maxPrefix) > 0) fail();
			r = Int64.add(Int64.ofInt(d), Int64.mul(Int64.ofInt(base), r));
			if (Int64.ucompare(r, Int64.ofInt(d)) < 0) fail();
			i++;
		}
		if (i != s.length) fail();
		return sign < 0 ? Int64.neg(r) : r;
	}

	// port: signed Int64 division (OCaml: min_int / -1 = min_int, rem = 0; Division_by_zero)

	static function int64Div(a:Int64, b:Int64):Int64 {
		if (Int64.isZero(b)) throw new DivisionByZero();
		if (b == Int64.ofInt(-1)) return Int64.neg(a);
		return Int64.divMod(a, b).quotient;
	}

	static function int64Rem(a:Int64, b:Int64):Int64 {
		if (Int64.isZero(b)) throw new DivisionByZero();
		if (b == Int64.ofInt(-1)) return Int64.ofInt(0);
		return Int64.divMod(a, b).modulus;
	}

	static function printexcToString(e:Dynamic):String {
		if (Std.isOfType(e, DivisionByZero)) return "Division_by_zero";
		if (Std.isOfType(e, haxe.Exception)) return (e : haxe.Exception).message;
		return Std.string(e);
	}

	public static function decodeU64(v:Value):Int64 {
		return switch v {
			case VUInt64(u): u;
			case v: unexpectedValue(v, "eval.integers.UInt64");
		}
	}

	public static function decodeI64(v:Value):Int64 {
		return switch v {
			case VInt64(i): i;
			case v: unexpectedValue(v, "eval.integers.Int64");
		}
	}

	public static function encodeSizeT(t:Int64):Value return VUInt64(t);

	public static function decodeSizeT(v:Value):Int64 {
		return switch v {
			case VUInt64(u): u;
			case v: unexpectedValue(v, "eval.integers.UInt64");
		}
	}

	public static final uint64Fields:Array<{name:String, value:Value}> = [
		{name: "MAX", value: VUInt64(uint64MaxInt)},
		{name: "ZERO", value: VUInt64(Int64.ofInt(0))},
		{name: "ONE", value: VUInt64(Int64.ofInt(1))},
		{
			name: "ofInt",
			value: vfun1(v -> {
				var i32 = decodeI32(v);
				VUInt64(Int64.ofInt(i32));
			})
		},
		{
			name: "ofString",
			value: vfun1(v -> {
				var s = decodeString(v);
				try
					VUInt64(uint64OfString(s))
				catch (_:core.ds.Failure)
					throwString("The string is not a valid UInt64 representation", Globals.nullPos);
			})
		},
		{
			name: "max",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.ucompare(a, b) >= 0 ? a : b);
			})
		},
		{
			name: "min",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.ucompare(a, b) <= 0 ? a : b);
			})
		},
		{
			name: "compare",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				var c = Int64.ucompare(a, b);
				VInt(c < 0 ? -1 : c > 0 ? 1 : 0);
			})
		},
		{
			name: "toInt",
			value: vfun1(v -> {
				var u = decodeU64(v);
				VInt(u.low);
			})
		},
		{
			name: "toInt64",
			value: vfun1(v -> {
				var u = decodeU64(v);
				VInt64(u);
			})
		},
		{
			name: "toString",
			value: vfun1(v -> {
				var u = decodeU64(v);
				VString(EvalString.createAscii(uint64ToString(u)));
			})
		},
		{
			name: "successor",
			value: vfun1(v -> {
				var u = decodeU64(v);
				VUInt64(Int64.add(u, Int64.ofInt(1)));
			})
		},
		{
			name: "predecessor",
			value: vfun1(v -> {
				var u = decodeU64(v);
				VUInt64(Int64.sub(u, Int64.ofInt(1)));
			})
		},
		{
			name: "remainder",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				try
					VUInt64(uint64Rem(a, b))
				catch (e:Dynamic)
					throwString(printexcToString(e), Globals.nullPos);
			})
		},
		{
			name: "add",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.add(a, b));
			})
		},
		{
			name: "sub",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.sub(a, b));
			})
		},
		{
			name: "mul",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.mul(a, b));
			})
		},
		{
			name: "div",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				try
					VUInt64(uint64Div(a, b))
				catch (e:Dynamic)
					throwString(printexcToString(e), Globals.nullPos);
			})
		},
		{
			name: "logand",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.and(a, b));
			})
		},
		{
			name: "logor",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.or(a, b));
			})
		},
		{
			name: "logxor",
			value: vfun2((v1, v2) -> {
				var a = decodeU64(v1);
				var b = decodeU64(v2);
				VUInt64(Int64.xor(a, b));
			})
		},
		{
			name: "shift_left",
			value: vfun2((v1, v2) -> {
				var u = decodeU64(v1);
				var i = decodeInt(v2);
				VUInt64(Int64.shl(u, i));
			})
		},
		{
			name: "shift_right",
			value: vfun2((v1, v2) -> {
				var u = decodeU64(v1);
				var i = decodeInt(v2);
				VUInt64(Int64.ushr(u, i));
			})
		},
		{
			name: "lognot",
			value: vfun1(v -> {
				var u = decodeU64(v);
				VUInt64(Int64.xor(u, Int64.make(-1, -1)));
			})
		},
	];

	public static function makeInt64(high:Int, low:Int):Int64 {
		var high = Int64.ofInt(high);
		var high = Int64.shl(high, 32);
		var low = Int64.ofInt(low);
		var low = Int64.and(low, Int64.make(0, 0xFFFFFFFF));
		return Int64.or(high, low);
	}

	static function ocamlInt64OfString(s:String):Int64 {
		try
			return core.ds.OcamlInt64.ofString(s)
		catch (_:core.ds.OcamlInt.IntParseFailure)
			throw new core.ds.Failure("Int64.of_string");
	}

	public static final int64Fields:Array<{name:String, value:Value}> = [
		{name: "MAX", value: VInt64(Int64.make(0x7FFFFFFF, -1))},
		{name: "MIN", value: VInt64(Int64.make(1 << 31, 0))},
		{name: "ZERO", value: VInt64(Int64.ofInt(0))},
		{name: "ONE", value: VInt64(Int64.ofInt(1))},
		{
			name: "ofInt",
			value: vfun1(v -> {
				var i32 = decodeI32(v);
				VInt64(Int64.ofInt(i32));
			})
		},
		{
			name: "ofString",
			value: vfun1(v -> {
				var s = decodeString(v);
				try
					VInt64(ocamlInt64OfString(s))
				catch (_:core.ds.Failure)
					throwString("The string is not a valid Int64 representation", Globals.nullPos);
			})
		},
		{
			name: "max",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.compare(a, b) >= 0 ? a : b);
			})
		},
		{
			name: "min",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.compare(a, b) <= 0 ? a : b);
			})
		},
		{
			name: "compare",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				var c = Int64.compare(a, b);
				VInt(c < 0 ? -1 : c > 0 ? 1 : 0);
			})
		},
		{
			name: "make",
			value: vfun2((vhigh, vlow) -> {
				var high = decodeI32(vhigh);
				var low = decodeI32(vlow);
				var i = makeInt64(high, low);
				VInt64(i);
			})
		},
		{
			name: "toInt",
			value: vfun1(v -> {
				var i = decodeI64(v);
				VInt(i.low);
			})
		},
		{
			name: "toInt32",
			value: vfun1(v -> VInt(decodeI64(v).low))
		},
		{
			name: "toUInt64",
			value: vfun1(v -> {
				var i = decodeI64(v);
				VUInt64(i);
			})
		},
		{
			name: "toString",
			value: vfun1(v -> {
				var i = decodeI64(v);
				VString(EvalString.createAscii(Int64.toStr(i)));
			})
		},
		{
			name: "successor",
			value: vfun1(v -> {
				var i = decodeI64(v);
				VInt64(Int64.add(i, Int64.ofInt(1)));
			})
		},
		{
			name: "predecessor",
			value: vfun1(v -> {
				var i = decodeI64(v);
				VInt64(Int64.sub(i, Int64.ofInt(1)));
			})
		},
		{
			name: "remainder",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				try
					VInt64(int64Rem(a, b))
				catch (e:Dynamic)
					throwString(printexcToString(e), Globals.nullPos);
			})
		},
		{
			name: "add",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.add(a, b));
			})
		},
		{
			name: "sub",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.sub(a, b));
			})
		},
		{
			name: "mul",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.mul(a, b));
			})
		},
		{
			name: "div",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				try
					VInt64(int64Div(a, b))
				catch (e:Dynamic)
					throwString(printexcToString(e), Globals.nullPos);
			})
		},
		{
			name: "logand",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.and(a, b));
			})
		},
		{
			name: "logor",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.or(a, b));
			})
		},
		{
			name: "logxor",
			value: vfun2((v1, v2) -> {
				var a = decodeI64(v1);
				var b = decodeI64(v2);
				VInt64(Int64.xor(a, b));
			})
		},
		{
			name: "shift_left",
			value: vfun2((v1, v2) -> {
				var i64 = decodeI64(v1);
				var i = decodeInt(v2);
				VInt64(Int64.shl(i64, i));
			})
		},
		{
			name: "shift_right",
			value: vfun2((v1, v2) -> {
				var i64 = decodeI64(v1);
				var i = decodeInt(v2);
				VInt64(Int64.shr(i64, i));
			})
		},
		{
			name: "shift_right_logical",
			value: vfun2((v1, v2) -> {
				var i64 = decodeI64(v1);
				var i = decodeInt(v2);
				VInt64(Int64.ushr(i64, i));
			})
		},
		{
			name: "lognot",
			value: vfun1(v -> {
				var i = decodeI64(v);
				VInt64(Int64.xor(i, Int64.make(-1, -1)));
			})
		},
	];
}

// port: OCaml's Division_by_zero.
class DivisionByZero extends haxe.Exception {
	public function new() super("Division_by_zero");
}
