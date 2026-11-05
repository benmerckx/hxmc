package hxmc.com;

import hxmc.unsafe.*;
import hxmc.com.Variant;

// VARENUM: the types Variants knows
// (the Variants' types)
enum abstract VarType(Int) to Int {
	var VT_EMPTY = 0;
	var VT_NULL = 1;
	var VT_I4 = 3;
	var VT_R8 = 5;
	var VT_BSTR = 8;
	var VT_DISPATCH = 9;
	var VT_BOOL = 11;
	var VT_UNKNOWN = 13;
}

class Variants {
	public static function empty():Variant
		return new Variant();

	public static function ofInt(i:Int):Variant {
		var v = new Variant();
		v.vt = (VT_I4 : Int);
		v.value = (i : I64) & 0xFFFFFFFF;
		return v;
	}

	public static function ofFloat(f:Float):Variant {
		var v = new Variant();
		v.vt = (VT_R8 : Int);
		v.value = Mem.f64Bits(f);
		return v;
	}

	// VARIANT_BOOL: -1 true, 0 false
	public static function ofBool(b:Bool):Variant {
		var v = new Variant();
		v.vt = (VT_BOOL : Int);
		v.value = b ? 0xFFFF : 0;
		return v;
	}

	// a BSTR of s, which the variant owns
	public static function ofString(s:String):Variant {
		var v = new Variant();
		v.vt = (VT_BSTR : Int);
		v.value = Com.bstr(s).toI64();
		return v;
	}

	// x's IUnknown (VT_UNKNOWN), with a reference the variant owns; null: VT_EMPTY
	public static function ofUnknown(x:Null<IUnknown>):Variant {
		var v = new Variant();
		if (x == null) return v;
		v.vt = (VT_UNKNOWN : Int);
		v.value = @:privateAccess hxmc.rt.ComKind.ownedUnknown(x).toI64();
		return v;
	}

	// the value: an Int (VT_I4), a Float (VT_R8), a Bool (VT_BOOL), a String
	// (VT_BSTR, copied), an IUnknown (VT_UNKNOWN, VT_DISPATCH: a value of its
	// own), null (VT_EMPTY, VT_NULL); a ComException (E_NOTIMPL) for another type
	public static function toDynamic(v:Variant):Dynamic {
		var t:Int = v.vt;
		if (t == VT_EMPTY || t == VT_NULL) return null;
		if (t == VT_I4) return v.value.toInt();
		if (t == VT_R8) return Mem.bitsF64(v.value);
		if (t == VT_BOOL) return v.value.toInt() & 0xFFFF != 0;
		if (t == VT_BSTR) return Com.ofBstr(Ptr.ofI64(v.value));
		if (t == VT_UNKNOWN || t == VT_DISPATCH) return Com.wrap(Ptr.ofI64(v.value), IUnknown);
		throw new ComException(ComException.E_NOTIMPL, "VARIANT of type " + t);
	}

	// what v owns given back (VariantClear: a BSTR freed, an interface
	// released): v and its copies must not be read after this
	public static function clear(v:Variant):Void {
		var p:Ptr<Variant> = Mem.stack(24);
		p.value = v;
		clearAt(p);
	}

	// the same of a VARIANT in memory, left VT_EMPTY
	public static function clearAt(p:Ptr<Variant>):Void
		if (Mem.os() == 2) @:privateAccess hxmc.rt.ComKind.variantClear(p) else @:privateAccess ComException.unavailable();
}
