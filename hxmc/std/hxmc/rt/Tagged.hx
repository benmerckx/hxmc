package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Values of type parameters as tagged 64-bit words (docs/hxmc.md, "Values
// of type parameters"; JavaScriptCore's encoding). A word is
//
//   0x0000_pppp_pppp_pppp  a reference (Dynamic): null is 0; every address
//                          of the heap, of static data and of the C heap is
//                          below 2^48
//   0x0002_0000_0000_0000  a Float: its bits plus 2^49 (DOUBLE_OFFSET); NaN
//   ... 0xFFF2_0000_0000_0000  is made canonical (0x7FF8_0000_0000_0000)
//                          first, so no double's word reaches 0xFFFF
//   0xFFFF_0000_xxxx_xxxx  an Int: its 32 bits under the 0xFFFF prefix
//
// So every scalar's word is at or above 2^49, outside every heap range: the
// collector's forwarding tests addresses against its regions (Gc.inYoung,
// inFrom; wasm/Gc.hx's granule table, bounded), and skips such a word as it
// skips the static boxes. A Bool is its static box, an Int64 a box: both
// references. A reference is also any value Dynamic holds, a box of a
// number included: decoding goes by the tag first, then through the box.
//
// The inline functions are the encoding; MemLower expands the same inline
// (Tag, Untag) and calls the exports here on its slow paths.
@:access(hxmc.rt.Boxes) @:access(hxmc.rt.Dyn)
class Tagged {
	// a word at or above this is a scalar (Int or Float), below it a reference
	public static inline var SCALAR_BITS = 49;

	public static inline function intTag():I64
		return (0xFFFF : I64) << 48;

	public static inline function doubleOffset():I64
		return (1 : I64) << 49;

	// NaN's word: 0x7FF8_0000_0000_0000 + 2^49
	public static inline function nanWord():I64
		return (0x7FFA : I64) << 48;

	public static inline function isScalar(w:I64):Bool
		return (w >>> SCALAR_BITS) != (0 : I64);

	public static inline function isInt(w:I64):Bool
		return (w >>> 48) == (0xFFFF : I64);

	// a Float's word: unsigned, w - 2^49 below 0xFFFF << 48 - 2^49
	public static inline function isDouble(w:I64):Bool
		return Mem.ult(w - doubleOffset(), intTag() - doubleOffset());

	public static inline function isRef(w:I64):Bool
		return !isScalar(w);

	public static inline function ofInt(v:Int):I64
		return intTag() | (((v : I64) << 32) >>> 32);

	public static inline function ofFloat(v:Float):I64
		return v != v ? nanWord() : Mem.f64Bits(v) + doubleOffset();

	// (w a word of the kind)
	public static inline function intOf(w:I64):Int
		return w.toInt();

	public static inline function floatOf(w:I64):Float
		return Mem.bitsF64(w - doubleOffset());

	// whether w is a word of the encoding: a reference (any word below 2^48),
	// an Int (nothing between the prefix and the 32 bits) or a Float (a
	// canonical NaN only); what RT_VERIFY checks in reference slots
	public static inline function valid(w:I64):Bool
		return (w >>> 48) == (0 : I64) || (isInt(w) ? (w >>> 32) == ((0xFFFF : I64) << 16) : isDouble(w) && validDouble(w));

	static inline function validDouble(w:I64):Bool {
		var b = w - doubleOffset();
		// (NaNs: exponent all ones, a mantissa; only the canonical one)
		var nan = ((b >>> 52) & 0x7FF) == (0x7FF : I64) && (b & (((1 : I64) << 52) - 1)) != (0 : I64);
		return !nan || w == nanWord();
	}

	// ---- the slow paths of MemLower's Untag: a word of another kind, or a
	// reference (null, a box: Dynamic's conversions)

	@:hxmc.export("hx_tag_int") @:hxmc.unsafe static function toInt(w:I64):Int {
		if (isInt(w)) return intOf(w);
		if (isScalar(w)) return Boxes.f2i(floatOf(w));
		return Boxes.unboxInt(Mem.obj(new Ptr(w)));
	}

	@:hxmc.export("hx_tag_float") @:hxmc.unsafe static function toFloat(w:I64):Float {
		if (isInt(w)) return intOf(w);
		if (isScalar(w)) return floatOf(w);
		return Boxes.unboxFloat(Mem.obj(new Ptr(w)));
	}

	@:hxmc.export("hx_tag_bool") @:hxmc.unsafe static function toBool(w:I64):Int {
		if (isInt(w)) return intOf(w) != 0 ? 1 : 0;
		if (isScalar(w)) return floatOf(w) != 0 ? 1 : 0;
		return Boxes.unboxBool(Mem.obj(new Ptr(w)));
	}

	@:hxmc.export("hx_tag_i64") @:hxmc.unsafe static function toI64(w:I64):I64 {
		if (isInt(w)) return (intOf(w) : I64);
		if (isScalar(w)) return Boxes.f2l(floatOf(w));
		return Boxes.unboxI64(Mem.obj(new Ptr(w)));
	}

	// the word as Dynamic: a scalar boxed (Boxes: small Ints static), a
	// reference as it is
	@:hxmc.export("hx_tag_box") static function box(w:I64):Dynamic {
		if (!isScalar(w)) return Mem.obj(new Ptr(w));
		if (isInt(w)) return Boxes.boxInt(intOf(w));
		return Boxes.boxFloat(floatOf(w));
	}

	// the value of a word read from a field of kind 't' (a type parameter's:
	// Dyn.boxSlot), as Dynamic
	public static inline function dyn(w:I64):Dynamic
		return isScalar(w) ? box(w) : Mem.obj(new Ptr(w));

	// a == b of two type parameters' words, as Dynamic's == has them
	// (hx_dyn_eq) but without boxing: MirBuild.tagEq's slow path (the words
	// differ, and are not two Ints'), Dyn.enumEq's for such arguments. Equal
	// words are equal values but a NaN's; a number's word equals a number
	// of the other kind, or a box of one, of its value (an Int's an Int64
	// box of it); references compare as Dynamic's
	@:hxmc.export("hx_tag_eq_slow") @:hxmc.unsafe public static function eq(a:I64, b:I64):Bool {
		if (a == b) return a != nanWord();
		if (isRef(a) && isRef(b)) return Dyn.dynEq(Mem.obj(new Ptr(a)), Mem.obj(new Ptr(b)));
		var s = isRef(a) ? b : a, r = isRef(a) ? a : b;
		if (isScalar(r)) return numOf(s) == numOf(r);
		// (a scalar's word and a reference: null, a box, anything else)
		if (r == (0 : I64)) return false;
		var o:Dynamic = Mem.obj(new Ptr(r));
		return switch Types.tindex(o) {
			case Types.T_BOXINT: numOf(s) == Mem.getI32(Mem.addr(o), 0);
			case Types.T_BOXFLOAT: numOf(s) == Mem.getF64(Mem.addr(o), 0);
			case Types.T_BOXI64: isInt(s) && (intOf(s) : I64) == Mem.getI64(Mem.addr(o), 0);
			case _: false;
		}
	}

	// Std.isOfType(w, type) of a type parameter's word (FnLower: no box made
	// for a number's): a reference's as Dyn.isOf tests it, a number's as it
	// tests the number's box
	@:hxmc.host("hx_tag_is") @:hxmc.unsafe static function isOf(w:I64, type:Dynamic):Bool {
		if (isRef(w)) return Dyn.isOf(Mem.obj(new Ptr(w)), type);
		if (Str.isNull(type)) return false;
		return switch Types.described(type) {
			case Types.T_NONE | Types.T_BOXFLOAT: true;
			case Types.T_BOXINT if (isInt(w)): true;
			case Types.T_BOXINT:
				var f = floatOf(w);
				f == Math.ffloor(f) && Math.abs(f) < 2147483648.0;
			case _: false;
		}
	}

	// (w a scalar's word)
	static inline function numOf(w:I64):Float
		return isInt(w) ? intOf(w) : floatOf(w);

	// -D hxmc.verify-tags: a scalar's word reached code that reads it as a
	// reference (MemLower's operations on objects, Mem.addr in the runtime)
	@:hxmc.export("rt_tagged_access") @:hxmc.unsafe static function access():Void {
		#if (hxmc.target == "wasm32-wasi")
		hxmc.rt.wasm.Wasi.writeLit(2, MSG);
		hxmc.rt.wasm.Wasi.exit(2);
		#else
		var r = new Os.Report(Mem.stack(Os.Report.BYTES));
		r.str(MSG);
		r.flush();
		Os.exit(2);
		#end
	}

	static inline var MSG = "hxmc: a tagged word (the value of a type parameter) was read as a reference (-D hxmc.verify-tags)\n";
}
