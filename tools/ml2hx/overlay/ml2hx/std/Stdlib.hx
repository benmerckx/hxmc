package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import haxe.Int64;

// OCaml's Stdlib (the values of stdlib.mli the converted compiler uses, and
// their neighbours). Operators are named as tools/ml2hx/README.md lists them
// (( + ) is opAdd...). Channels: StdlibOutChannel, StdlibInChannel below.
class Stdlib {
	// ---- exceptions

	public static function raise<T>(e:MlException):T
		throw e;

	public static function raiseNotrace<T>(e:MlException):T
		throw e;

	public static function failwith<T>(s:String):T
		throw new Failure(s);

	public static function invalidArg<T>(s:String):T
		throw new InvalidArgument(s);

	// ---- comparisons

	public static inline function opEq<T>(a:T, b:T):Bool
		return Poly.equal(a, b);

	public static inline function opNe<T>(a:T, b:T):Bool
		return !Poly.equal(a, b);

	public static inline function opLt<T>(a:T, b:T):Bool
		return Poly.lessThan(a, b);

	public static inline function opGt<T>(a:T, b:T):Bool
		return Poly.greaterThan(a, b);

	public static inline function opLe<T>(a:T, b:T):Bool
		return Poly.lessEqual(a, b);

	public static inline function opGe<T>(a:T, b:T):Bool
		return Poly.greaterEqual(a, b);

	public static inline function compare<T>(a:T, b:T):Int63
		return Int63.ofInt(Poly.compare(a, b));

	public static function min<T>(a:T, b:T):T
		return Poly.lessEqual(a, b) ? a : b;

	public static function max<T>(a:T, b:T):T
		return Poly.greaterEqual(a, b) ? a : b;

	// physical equality: identity of heap values, equality of immediates
	public static function opPhysEq<T>(a:T, b:T):Bool {
		var x:Dynamic = a, y:Dynamic = b;
		if (Int64.isInt64(x) && Int64.isInt64(y)) return (x : Int64) == (y : Int64);
		if (Reflect.isEnumValue(x) && Reflect.isEnumValue(y) && Type.enumParameters(x).length == 0)
			return Type.enumEq(x, y);
		return x == y;
	}

	public static inline function opPhysNe<T>(a:T, b:T):Bool
		return !opPhysEq(a, b);

	// ---- boolean operators (as values; applications short-circuit in the converter)

	public static inline function not(b:Bool):Bool
		return !b;

	public static inline function opAnd(a:Bool, b:Bool):Bool
		return a && b;

	public static inline function opOr(a:Bool, b:Bool):Bool
		return a || b;

	// ---- integers

	public static inline function opNeg(a:Int63):Int63
		return Int63.neg(a);

	public static inline function opPos(a:Int63):Int63
		return a;

	public static inline function succ(a:Int63):Int63
		return Int63.succ(a);

	public static inline function pred(a:Int63):Int63
		return Int63.pred(a);

	public static inline function opAdd(a:Int63, b:Int63):Int63
		return Int63.add(a, b);

	public static inline function opSub(a:Int63, b:Int63):Int63
		return Int63.sub(a, b);

	public static inline function opMul(a:Int63, b:Int63):Int63
		return Int63.mul(a, b);

	public static inline function opDiv(a:Int63, b:Int63):Int63
		return Int63.div(a, b);

	public static inline function mod(a:Int63, b:Int63):Int63
		return Int63.mod(a, b);

	public static inline function abs(a:Int63):Int63
		return Int63.abs(a);

	public static var maxInt(get, never):Int63;
	public static var minInt(get, never):Int63;

	static inline function get_maxInt():Int63
		return Int63.maxInt;

	static inline function get_minInt():Int63
		return Int63.minInt;

	public static inline function land(a:Int63, b:Int63):Int63
		return Int63.logand(a, b);

	public static inline function lor(a:Int63, b:Int63):Int63
		return Int63.logor(a, b);

	public static inline function lxor(a:Int63, b:Int63):Int63
		return Int63.logxor(a, b);

	public static inline function lnot(a:Int63):Int63
		return Int63.lognot(a);

	public static inline function lsl(a:Int63, b:Int63):Int63
		return Int63.shiftLeft(a, b);

	public static inline function lsr(a:Int63, b:Int63):Int63
		return Int63.shiftRightLogical(a, b);

	public static inline function asr(a:Int63, b:Int63):Int63
		return Int63.shiftRight(a, b);

	// ---- floats

	public static inline function opNegF(a:Float):Float
		return -a;

	public static inline function opPosF(a:Float):Float
		return a;

	public static inline function opAddF(a:Float, b:Float):Float
		return a + b;

	public static inline function opSubF(a:Float, b:Float):Float
		return a - b;

	public static inline function opMulF(a:Float, b:Float):Float
		return a * b;

	public static inline function opDivF(a:Float, b:Float):Float
		return a / b;

	public static inline function opPow(a:Float, b:Float):Float
		return Math.pow(a, b);

	public static inline function sqrt(a:Float):Float
		return Math.sqrt(a);

	public static inline function exp(a:Float):Float
		return Math.exp(a);

	public static inline function log(a:Float):Float
		return Math.log(a);

	public static inline function log10(a:Float):Float
		return Math.log(a) / Math.log(10);

	public static inline function cos(a:Float):Float
		return Math.cos(a);

	public static inline function sin(a:Float):Float
		return Math.sin(a);

	public static inline function tan(a:Float):Float
		return Math.tan(a);

	public static inline function acos(a:Float):Float
		return Math.acos(a);

	public static inline function asin(a:Float):Float
		return Math.asin(a);

	public static inline function atan(a:Float):Float
		return Math.atan(a);

	public static inline function atan2(a:Float, b:Float):Float
		return Math.atan2(a, b);

	public static inline function ceil(a:Float):Float
		return Math.fceil(a);

	public static inline function floor(a:Float):Float
		return Math.ffloor(a);

	public static inline function absFloat(a:Float):Float
		return Math.abs(a);

	public static function modFloat(a:Float, b:Float):Float {
		// C fmod: the result has the sign of a
		if (b != b || a != a || b == 0 || !Math.isFinite(a)) return Math.NaN;
		if (!Math.isFinite(b)) return a;
		return a % b;
	}

	public static function frexp(f:Float):Tuple2<Float, Int63> {
		if (f == 0 || !Math.isFinite(f)) return new Tuple2(f, Int63.zero);
		var bits = Float64.bits(f);
		var e = (bits.high >>> 20) & 0x7FF;
		if (e == 0) {
			// subnormal: scale up first
			var r = frexp(f * 18014398509481984.0); // 2^54
			return new Tuple2(r.v0, Int63.sub(r.v1, Int63.ofInt(54)));
		}
		var m = Float64.ofBits(Int64.make((bits.high & 0x800FFFFF) | (1022 << 20), bits.low));
		return new Tuple2(m, Int63.ofInt(e - 1022));
	}

	public static function ldexp(f:Float, n:Int63):Float {
		var k = n.toInt();
		while (k > 1000) {
			f *= Math.pow(2, 1000);
			k -= 1000;
		}
		while (k < -1000) {
			f *= Math.pow(2, -1000);
			k += 1000;
		}
		return f * Math.pow(2, k);
	}

	public static function modf(f:Float):Tuple2<Float, Float> {
		if (!Math.isFinite(f)) return new Tuple2(f != f ? f : (f > 0 ? 0.0 : -0.0), f);
		var i = f < 0 ? Math.fceil(f) : Math.ffloor(f);
		return new Tuple2(f - i, i);
	}

	public static inline function float(a:Int63):Float
		return Int63.toFloat(a);

	public static inline function floatOfInt(a:Int63):Float
		return Int63.toFloat(a);

	public static inline function truncate(f:Float):Int63
		return Int63.ofFloat(f);

	public static inline function intOfFloat(f:Float):Int63
		return Int63.ofFloat(f);

	public static var infinity(get, never):Float;
	public static var negInfinity(get, never):Float;
	public static var nan(get, never):Float;
	public static var maxFloat(get, never):Float;
	public static var minFloat(get, never):Float;
	public static var epsilonFloat(get, never):Float;

	static inline function get_infinity():Float
		return Math.POSITIVE_INFINITY;

	static inline function get_negInfinity():Float
		return Math.NEGATIVE_INFINITY;

	// OCaml 5's nan: 0x7FF8_0000_0000_0001
	static inline function get_nan():Float
		return Float64.ofBits(Int64.make(0x7FF80000, 1));

	static inline function get_maxFloat():Float
		return 1.7976931348623157e308;

	static inline function get_minFloat():Float
		return 2.2250738585072014e-308;

	static inline function get_epsilonFloat():Float
		return 2.220446049250313e-16;

	public static function classifyFloat(f:Float):StdlibFpclass {
		if (f != f) return FP_nan;
		if (!Math.isFinite(f)) return FP_infinite;
		if (f == 0) return FP_zero;
		var e = (Float64.bits(f).high >>> 20) & 0x7FF;
		return e == 0 ? FP_subnormal : FP_normal;
	}

	// ---- strings and chars

	public static inline function opConcat(a:String, b:String):String
		return a + b;

	public static inline function intOfChar(c:Int):Int63
		return Int63.ofInt(c);

	public static function charOfInt(n:Int63):Int {
		if (Int63.lt(n, Int63.zero) || Int63.gt(n, Int63.ofInt(255))) throw new InvalidArgument("char_of_int");
		return n.toInt();
	}

	public static inline function ignore<T>(v:T):Unit
		return Unit.value;

	public static inline function stringOfBool(b:Bool):String
		return b ? "true" : "false";

	public static function boolOfString(s:String):Bool {
		return switch s {
			case "true": true;
			case "false": false;
			case _: throw new InvalidArgument("bool_of_string");
		}
	}

	public static function boolOfStringOpt(s:String):MlOption<Bool> {
		return switch s {
			case "true": Some(true);
			case "false": Some(false);
			case _: None;
		}
	}

	public static inline function stringOfInt(n:Int63):String
		return n.toString();

	// runtime/ints.c's parse_intnat: sign, 0x 0o 0b 0u prefixes, '_' after
	// the first digit; nbits 63 (int), 32 (int32) or 64 (int64)
	public static function parseIntnat(s:String, nbits:Int, err:String):Int64 {
		var p = 0, n = s.length;
		var sign = 1;
		if (p < n && StringTools.fastCodeAt(s, p) == "-".code) {
			sign = -1;
			p++;
		} else if (p < n && StringTools.fastCodeAt(s, p) == "+".code)
			p++;
		var base = 10, signed = true;
		if (p + 1 < n && StringTools.fastCodeAt(s, p) == "0".code) {
			switch StringTools.fastCodeAt(s, p + 1) {
				case "x".code | "X".code:
					base = 16;
					signed = false;
					p += 2;
				case "o".code | "O".code:
					base = 8;
					signed = false;
					p += 2;
				case "b".code | "B".code:
					base = 2;
					signed = false;
					p += 2;
				case "u".code | "U".code:
					signed = false;
					p += 2;
				case _:
			}
		}
		var b64 = Int64.ofInt(base);
		// (2^64 - 1) / base, unsigned
		var threshold = udiv(Int64.make(0xFFFFFFFF, 0xFFFFFFFF), base);
		var d = p < n ? digit(StringTools.fastCodeAt(s, p)) : -1;
		if (d < 0 || d >= base) throw new Failure(err);
		var res = Int64.ofInt(d);
		p++;
		while (p < n) {
			var c = StringTools.fastCodeAt(s, p);
			if (c == "_".code) {
				p++;
				continue;
			}
			d = digit(c);
			if (d < 0 || d >= base) break;
			if (Int64.ucompare(res, threshold) > 0) throw new Failure(err);
			res = res * b64 + d;
			if (Int64.ucompare(res, Int64.ofInt(d)) < 0) throw new Failure(err);
			p++;
		}
		if (p != n) throw new Failure(err);
		if (signed) {
			var lim = Int64.make(nbits == 64 ? 0x80000000 : (nbits == 63 ? 0x40000000 : 0), nbits == 32 ? 0x80000000 : 0);
			if (sign >= 0) {
				if (Int64.ucompare(res, lim) >= 0) throw new Failure(err);
			} else {
				if (Int64.ucompare(res, lim) > 0) throw new Failure(err);
			}
		} else if (nbits < 64) {
			var lim = Int64.make(nbits == 63 ? 0x80000000 : 1, 0);
			if (Int64.ucompare(res, lim) >= 0) throw new Failure(err);
		}
		return sign < 0 ? -res : res;
	}

	static function udiv(v:Int64, base:Int):Int64 {
		var b = Int64.ofInt(base);
		var q = Int64.div(v >>> 1, Int64.ofInt(base >> 1));
		if (base & 1 == 1) q = Int64.div(v >>> 1, b) << 1;
		var r = v - q * b;
		while (Int64.ucompare(r, b) >= 0) {
			q = q + 1;
			r = r - b;
		}
		return q;
	}

	static function digit(c:Int):Int {
		if (c >= "0".code && c <= "9".code) return c - "0".code;
		if (c >= "A".code && c <= "F".code) return c - "A".code + 10;
		if (c >= "a".code && c <= "f".code) return c - "a".code + 10;
		return -1;
	}

	public static function intOfString(s:String):Int63
		return Int63.ofInt64(parseIntnat(s, 63, "int_of_string"));

	public static function intOfStringOpt(s:String):MlOption<Int63> {
		try {
			return Some(intOfString(s));
		} catch (e:Failure) {
			return None;
		}
	}

	public static inline function stringOfFloat(f:Float):String
		return FloatFormat.stringOfFloat(f);

	public static function floatOfString(s:String):Float {
		var v = FloatFormat.parse(s);
		if (v == null) throw new Failure("float_of_string");
		return v;
	}

	public static function floatOfStringOpt(s:String):MlOption<Float> {
		var v = FloatFormat.parse(s);
		return v == null ? None : Some(v);
	}

	// ---- pairs

	public static inline function fst<A, B>(p:Tuple2<A, B>):A
		return p.v0;

	public static inline function snd<A, B>(p:Tuple2<A, B>):B
		return p.v1;

	// ---- lists

	public static function opAppend<T>(a:MlList<T>, b:MlList<T>):MlList<T>
		return List.append(a, b);

	// ---- references

	public static inline function ref<T>(v:T):Ref<T>
		return new Ref(v);

	public static inline function opDeref<T>(r:Ref<T>):T
		return r.value;

	public static inline function opAssign<T>(r:Ref<T>, v:T):Unit {
		r.value = v;
		return Unit.value;
	}

	public static inline function incr(r:Ref<Int63>):Unit {
		r.value = Int63.succ(r.value);
		return Unit.value;
	}

	public static inline function decr(r:Ref<Int63>):Unit {
		r.value = Int63.pred(r.value);
		return Unit.value;
	}

	// ---- functions

	public static inline function opPipe<A, B>(x:A, f:A->B):B
		return f(x);

	public static inline function opApply<A, B>(f:A->B, x:A):B
		return f(x);

	// ---- channels

	public static var stdin(default, null):StdlibInChannel = StdlibInChannel.ofInput(std.Sys.stdin());
	public static var stdout(default, null):StdlibOutChannel = StdlibOutChannel.ofOutput(std.Sys.stdout());
	public static var stderr(default, null):StdlibOutChannel = StdlibOutChannel.ofOutput(std.Sys.stderr(), true);

	public static function printString(s:String):Unit
		return outputString(stdout, s);

	public static function printEndline(s:String):Unit {
		outputString(stdout, s);
		outputChar(stdout, 10);
		return flush(stdout);
	}

	public static function printNewline(_:Unit):Unit {
		outputChar(stdout, 10);
		return flush(stdout);
	}

	public static function printChar(c:Int):Unit
		return outputChar(stdout, c);

	public static function printInt(n:Int63):Unit
		return outputString(stdout, n.toString());

	public static function printFloat(f:Float):Unit
		return outputString(stdout, stringOfFloat(f));

	public static function prerrString(s:String):Unit
		return outputString(stderr, s);

	public static function prerrEndline(s:String):Unit {
		outputString(stderr, s);
		outputChar(stderr, 10);
		return flush(stderr);
	}

	public static function prerrNewline(_:Unit):Unit {
		outputChar(stderr, 10);
		return flush(stderr);
	}

	public static function prerrChar(c:Int):Unit
		return outputChar(stderr, c);

	public static function prerrInt(n:Int63):Unit
		return outputString(stderr, n.toString());

	public static function readLine(_:Unit):String {
		flush(stdout);
		return inputLine(stdin);
	}

	public static function openOut(name:String):StdlibOutChannel
		return openOutGen(Cons(Open_wronly, Cons(Open_creat, Cons(Open_trunc, Cons(Open_text, Nil)))), Int63.ofInt(438), name);

	public static function openOutBin(name:String):StdlibOutChannel
		return openOutGen(Cons(Open_wronly, Cons(Open_creat, Cons(Open_trunc, Cons(Open_binary, Nil)))), Int63.ofInt(438), name);

	public static function openOutGen(mode:MlList<StdlibOpenFlag>, perm:Int63, name:String):StdlibOutChannel {
		var append = false, trunc = false, creat = false, excl = false;
		var l = mode;
		while (true) switch l {
			case Nil: break;
			case Cons(f, t):
				switch f {
					case Open_append: append = true;
					case Open_trunc: trunc = true;
					case Open_creat: creat = true;
					case Open_excl: excl = true;
					case _:
				}
				l = t;
		}
		var path = ByteString.toNative(name);
		var exists = sys.FileSystem.exists(path);
		if (excl && creat && exists) throw new SysError(name + ": File exists");
		if (!exists && !creat) throw new SysError(name + ": No such file or directory");
		try {
			var out:haxe.io.Output = append ? sys.io.File.append(path, true) : (trunc || !exists ? sys.io.File.write(path, true) : sys.io.File.update(path, true));
			return StdlibOutChannel.ofOutput(out);
		} catch (e:MlException) {
			throw e;
		} catch (e:Dynamic) {
			throw new SysError(name + ": " + Std.string(e));
		}
	}

	public static function flush(oc:StdlibOutChannel):Unit {
		oc.flush();
		return Unit.value;
	}

	public static function flushAll(_:Unit):Unit {
		for (c in StdlibOutChannel.all) c.flush();
		return Unit.value;
	}

	public static function outputChar(oc:StdlibOutChannel, c:Int):Unit {
		oc.addChar(c);
		return Unit.value;
	}

	public static function outputString(oc:StdlibOutChannel, s:String):Unit {
		oc.addString(s);
		return Unit.value;
	}

	public static function outputBytes(oc:StdlibOutChannel, b:haxe.io.Bytes):Unit {
		oc.addBytes(b, 0, b.length);
		return Unit.value;
	}

	public static function output(oc:StdlibOutChannel, b:haxe.io.Bytes, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > b.length - n) throw new InvalidArgument("output");
		oc.addBytes(b, o, n);
		return Unit.value;
	}

	public static function outputSubstring(oc:StdlibOutChannel, s:String, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > s.length - n) throw new InvalidArgument("output_substring");
		oc.addString(s.substr(o, n));
		return Unit.value;
	}

	public static function outputByte(oc:StdlibOutChannel, n:Int63):Unit {
		oc.addChar(n.toInt() & 0xFF);
		return Unit.value;
	}

	public static function closeOut(oc:StdlibOutChannel):Unit {
		oc.close();
		return Unit.value;
	}

	public static function closeOutNoerr(oc:StdlibOutChannel):Unit {
		try
			oc.close()
		catch (_:Dynamic) {}
		return Unit.value;
	}

	public static function posOut(oc:StdlibOutChannel):Int63
		return Int63.ofInt(oc.pos());

	public static function seekOut(oc:StdlibOutChannel, n:Int63):Unit {
		oc.seek(n.toInt());
		return Unit.value;
	}

	public static function outChannelLength(oc:StdlibOutChannel):Int63
		return Int63.ofInt(oc.length());

	public static function setBinaryModeOut(oc:StdlibOutChannel, b:Bool):Unit
		return Unit.value;

	public static function openIn(name:String):StdlibInChannel
		return openInGen(Cons(Open_rdonly, Cons(Open_text, Nil)), Int63.zero, name);

	public static function openInBin(name:String):StdlibInChannel
		return openInGen(Cons(Open_rdonly, Cons(Open_binary, Nil)), Int63.zero, name);

	public static function openInGen(mode:MlList<StdlibOpenFlag>, perm:Int63, name:String):StdlibInChannel {
		var path = ByteString.toNative(name);
		if (!sys.FileSystem.exists(path)) throw new SysError(name + ": No such file or directory");
		if (sys.FileSystem.isDirectory(path)) return StdlibInChannel.ofBytes(haxe.io.Bytes.alloc(0));
		try {
			return StdlibInChannel.ofBytes(sys.io.File.getBytes(path));
		} catch (e:Dynamic) {
			throw new SysError(name + ": " + Std.string(e));
		}
	}

	public static function inputChar(ic:StdlibInChannel):Int {
		var c = ic.readByte();
		if (c < 0) throw EndOfFile.instance;
		return c;
	}

	public static function inputByte(ic:StdlibInChannel):Int63
		return Int63.ofInt(inputChar(ic));

	public static function inputLine(ic:StdlibInChannel):String {
		var l = ic.readLine();
		if (l == null) throw EndOfFile.instance;
		return l;
	}

	public static function input(ic:StdlibInChannel, b:haxe.io.Bytes, ofs:Int63, len:Int63):Int63 {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > b.length - n) throw new InvalidArgument("input");
		return Int63.ofInt(ic.read(b, o, n));
	}

	public static function reallyInput(ic:StdlibInChannel, b:haxe.io.Bytes, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > b.length - n) throw new InvalidArgument("really_input");
		while (n > 0) {
			var r = ic.read(b, o, n);
			if (r == 0) throw EndOfFile.instance;
			o += r;
			n -= r;
		}
		return Unit.value;
	}

	public static function reallyInputString(ic:StdlibInChannel, len:Int63):String {
		var b = haxe.io.Bytes.alloc(len.toInt());
		reallyInput(ic, b, Int63.zero, len);
		return ByteString.ofBytes(b, 0, -1);
	}

	public static function closeIn(ic:StdlibInChannel):Unit {
		ic.close();
		return Unit.value;
	}

	public static function closeInNoerr(ic:StdlibInChannel):Unit {
		ic.close();
		return Unit.value;
	}

	public static function posIn(ic:StdlibInChannel):Int63
		return Int63.ofInt(ic.pos);

	public static function seekIn(ic:StdlibInChannel, n:Int63):Unit {
		ic.seek(n.toInt());
		return Unit.value;
	}

	public static function inChannelLength(ic:StdlibInChannel):Int63
		return Int63.ofInt(ic.length());

	public static function setBinaryModeIn(ic:StdlibInChannel, b:Bool):Unit
		return Unit.value;

	// ---- program termination

	static var exitFunctions:Array<Void->Void> = [];

	public static function atExit(f:Unit->Unit):Unit {
		exitFunctions.unshift(() -> f(Unit.value));
		return Unit.value;
	}

	public static function doAtExit() {
		var fs = exitFunctions;
		exitFunctions = [];
		for (f in fs) f();
		flushAll(Unit.value);
	}

	public static function exit<T>(code:Int63):T {
		doAtExit();
		std.Sys.exit(code.toInt());
		throw new haxe.Exception("unreachable");
	}
}

enum StdlibFpclass {
	FP_normal;
	FP_subnormal;
	FP_zero;
	FP_infinite;
	FP_nan;
}

enum StdlibOpenFlag {
	Open_rdonly;
	Open_wronly;
	Open_append;
	Open_creat;
	Open_trunc;
	Open_excl;
	Open_binary;
	Open_text;
	Open_nonblock;
}

enum StdlibResult<A, E> {
	Ok(v:A);
	Error(e:E);
}

// out_channel: a buffer of bytes (the units of the strings written) in front of a haxe.io.Output
class StdlibOutChannel {
	public static var all:Array<StdlibOutChannel> = [];

	var out:Null<haxe.io.Output>;
	var buf:haxe.io.Bytes;
	var len = 0;
	var written = 0;
	final unbuffered:Bool;
	public var closed(default, null) = false;

	function new(out:haxe.io.Output, unbuffered:Bool) {
		this.out = out;
		this.unbuffered = unbuffered;
		buf = haxe.io.Bytes.alloc(65536);
		all.push(this);
	}

	public static function ofOutput(out:haxe.io.Output, unbuffered = false):StdlibOutChannel
		return new StdlibOutChannel(out, unbuffered);

	inline function check() {
		if (closed) throw new SysError("Bad file descriptor");
	}

	public inline function addChar(c:Int) {
		if (len == buf.length) flushBuffer();
		buf.set(len++, c);
		if (unbuffered && c == 10) flush();
	}

	public function addString(s:String) {
		check();
		var n = s.length;
		for (i in 0...n) {
			if (len == buf.length) flushBuffer();
			buf.set(len++, StringTools.fastCodeAt(s, i));
		}
		if (unbuffered) flush();
	}

	public function addBytes(b:haxe.io.Bytes, ofs:Int, n:Int) {
		check();
		if (len + n > buf.length) flushBuffer();
		if (n > buf.length) {
			out.writeFullBytes(b, ofs, n);
			written += n;
		} else {
			buf.blit(len, b, ofs, n);
			len += n;
		}
		if (unbuffered) flush();
	}

	function flushBuffer() {
		check();
		if (len > 0) {
			out.writeFullBytes(buf, 0, len);
			written += len;
			len = 0;
		}
	}

	public function flush() {
		if (closed) return;
		flushBuffer();
		out.flush();
	}

	public function close() {
		if (closed) return;
		flush();
		out.close();
		closed = true;
		all.remove(this);
	}

	public function pos():Int
		return written + len;

	public function length():Int
		return written + len;

	public function seek(n:Int) {
		flushBuffer();
		var f = Std.downcast(out, sys.io.FileOutput);
		if (f == null) throw new SysError("Illegal seek");
		f.seek(n, SeekBegin);
		written = n;
	}
}

// in_channel: a file's bytes read at open, or a stream (stdin)
class StdlibInChannel {
	var bytes:Null<haxe.io.Bytes>;
	var input:Null<haxe.io.Input>;
	public var pos(default, null) = 0;
	var peeked = -2;

	function new() {}

	public static function ofBytes(b:haxe.io.Bytes):StdlibInChannel {
		var c = new StdlibInChannel();
		c.bytes = b;
		return c;
	}

	public static function ofInput(i:haxe.io.Input):StdlibInChannel {
		var c = new StdlibInChannel();
		c.input = i;
		return c;
	}

	// a byte, -1 at the end
	public function readByte():Int {
		if (bytes != null) return pos < bytes.length ? bytes.get(pos++) : -1;
		if (peeked != -2) {
			var c = peeked;
			peeked = -2;
			if (c >= 0) pos++;
			return c;
		}
		try {
			var c = input.readByte();
			pos++;
			return c;
		} catch (e:haxe.io.Eof) {
			return -1;
		}
	}

	public function readLine():Null<String> {
		var c = readByte();
		if (c < 0) return null;
		var b = new StringBuf();
		while (c >= 0 && c != 10) {
			b.addChar(c);
			c = readByte();
		}
		return b.toString();
	}

	public function read(b:haxe.io.Bytes, ofs:Int, n:Int):Int {
		if (n == 0) return 0;
		if (bytes != null) {
			var k = bytes.length - pos;
			if (k > n) k = n;
			if (k <= 0) return 0;
			b.blit(ofs, bytes, pos, k);
			pos += k;
			return k;
		}
		var c = readByte();
		if (c < 0) return 0;
		b.set(ofs, c);
		return 1;
	}

	public function seek(n:Int) {
		if (bytes == null) throw new SysError("Illegal seek");
		pos = n;
	}

	public function length():Int {
		if (bytes == null) throw new SysError("Illegal seek");
		return bytes.length;
	}

	public function close() {
		if (input != null) input.close();
	}
}
