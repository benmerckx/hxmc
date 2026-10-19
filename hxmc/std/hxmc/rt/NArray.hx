package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.LibC;

// One allocation: length/kind in its first word, followed by packed elements.
// GC scans reference elements, excluding that word. Typed accesses are
// emitted by MirBuild; a NativeArray seen as Dynamic (Dynamic, Any, an erased
// type parameter) goes through these helpers, by the stored kind.
//
// A NativeArray made for an erased type parameter (`new NativeArray<T>` in
// generic code) cannot know its element kind: it is a wrapper, a NativeArray
// of kind AK_OPEN holding its length and one reference, to storage of
// references. The first typed view to take it (view, from FnLower.coerce)
// gets that storage, converted to the view's kind if it differs (once), and
// fixes the wrapper (AK_WRAP) on it: the generic code that holds the wrapper
// sees what the typed code writes, and the other way round. A later view of
// another kind is an error.
//
// An array of no elements cannot change: one made by typed code is the empty
// array of its kind (MirBuild.EMPTY_ARRAY, static data; not referred to here,
// so that a tool that does not define it can build the runtime), and any
// serves as a copy of itself, and as the view of any kind.
@:keep
class NArray {
	static inline function kindOf(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 4);

	static inline function lengthOf(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 0);

	// the storage of a: a itself, unless a wrapper
	static inline function storage(a:Dynamic):Dynamic {
		var k = kindOf(a);
		return k == AK_OPEN || k == AK_WRAP ? Mem.getRef(Mem.addr(a), 8) : a;
	}

	// new storage of n elements of kind k (zeroed: 0, false, null); the
	// header counts 8-byte slots, the length/kind word first
	static function alloc(k:Int, n:Int):Dynamic {
		var words = k == AK_BOOL ? (n + 7) >> 3 : k == AK_I32 ? (n + 1) >> 1 : n;
		var a = Mem.alloc(words + 1, T_NATIVE_ARRAY, k == AK_PTR ? K_PARR : K_RAW);
		Mem.setI32(Mem.addr(a), 0, n);
		Mem.setI32(Mem.addr(a), 4, k);
		return a;
	}

	@:hxmc.host("hx_narray_open") static function open(n:Int):Dynamic {
		if (n < 0 || n > 0x0FFFFFFD) badLength();
		if (n == 0) return alloc(AK_PTR, 0);
		var s = alloc(AK_PTR, n);
		var w = alloc(AK_PTR, 1);
		Mem.setI32(Mem.addr(w), 0, n);
		Mem.setI32(Mem.addr(w), 4, AK_OPEN);
		Mem.setRefBarrier(w, 8, s);
		return w;
	}

	@:hxmc.host("hxmc_NativeArray_copy") static function copy(a:Dynamic):Dynamic {
		if (lengthOf(a) == 0) return a;
		if (kindOf(a) != AK_OPEN) return copyStorage(storage(a));
		// (an open wrapper's copy is open too)
		var w = open(lengthOf(a));
		var from = storage(a), to = storage(w);
		LibC.memcpy(Mem.addr(to).add(8), Mem.addr(from).add(8), (lengthOf(from) : I64) * 8);
		C.Leaf.rt_barrier_range(to, Mem.addr(to).add(8), lengthOf(to));
		return w;
	}

	static function copyStorage(a:Dynamic):Dynamic {
		var words = Mem.getI32(Mem.addr(a), -8) & 0x0FFFFFFF;
		var kind = kindOf(a);
		var result = Mem.alloc(words, T_NATIVE_ARRAY, kind == AK_PTR ? K_PARR : K_RAW);
		LibC.memcpy(Mem.addr(result), Mem.addr(a), (words : I64) * 8);
		if (kind == AK_PTR) C.Leaf.rt_barrier_range(result, Mem.addr(result).add(8), Mem.getI32(Mem.addr(result), 0));
		return result;
	}

	// hxmc.NativeArray.blit (haxe.ds.Vector.blit): d[di, di + n) = s[si, si +
	// n), the ranges inside both (the caller tested them), possibly
	// overlapping (one storage), as one memmove, with the collector's barrier
	// for references; true. False when the storages are of other kinds
	// (generic code's views of another type), nothing done: the caller's
	// loop. A leaf: no frame for the collector.
	@:hxmc.noGc public static function move(d:Dynamic, di:Int, s:Dynamic, si:Int, n:Int):Bool {
		if (n <= 0) return true;
		var ds = storage(d), ss = storage(s);
		var k = kindOf(ds);
		if (k != kindOf(ss)) return false;
		var es = k == AK_BOOL ? 1 : k == AK_I32 ? 4 : 8;
		var to = Mem.addr(ds).add(8 + es * di);
		LibC.memmove(to, Mem.addr(ss).add(8 + es * si), (es * n : I64));
		if (k == AK_PTR) C.Leaf.rt_barrier_range(ds, to, n);
		return true;
	}

	@:hxmc.export("hx_narray_bad_length") static function badLength():Void
		throw "Invalid NativeArray length";

	// the error of index i of an array of length n, at the position of the
	// access (FnLower.outOfBounds: -D hxmc.native-array-outofbounds=throws);
	// no file: unknown (Dynamic access)
	@:hxmc.host("hx_narray_oob") public static function outOfBounds(i:Int, n:Int, file:Null<String>, line:Int, cls:Null<String>, method:Null<String>):Dynamic {
		var pos:haxe.PosInfos = file == null ? null : {fileName: file, lineNumber: line, className: cls, methodName: method};
		return new haxe.exceptions.ArgumentException("index", 'Index $i out of bounds for length $n', null, pos);
	}

	// the default of a's elements, by its storage's kind, as a read out of
	// bounds gives it through a Dynamic-typed view (FnLower.nativeRead, Dyn:
	// -D hxmc.native-array-outofbounds=silent; HL's nullValue)
	@:hxmc.host("hx_narray_default") public static function defaultOf(a:Dynamic):Dynamic {
		var zero:I64 = 0;
		return switch kindOf(storage(a)) {
			case AK_BOOL: (false : Dynamic);
			case AK_I32: (0 : Dynamic);
			case AK_F64: (0.0 : Dynamic);
			case AK_I64: (zero : Dynamic);
			case _: null;
		}
	}

	// a (a NativeArray, or a Dynamic) taken by a typed view of kind k
	@:hxmc.host("hx_narray_view") static function view(a:Dynamic, k:Int):Dynamic {
		if (a == null) return null;
		if (tindex(a) != T_NATIVE_ARRAY) throw "Invalid cast to NativeArray";
		var ak = kindOf(a);
		if (ak == k) return a;
		if (lengthOf(a) == 0) return alloc(k, 0);
		if (ak == AK_OPEN) {
			var s = storage(a);
			if (k != AK_PTR) {
				var n = lengthOf(s);
				var d = alloc(k, n);
				for (i in 0...n)
					set(d, i, get(s, i));
				Mem.setRefBarrier(a, 8, d);
				s = d;
			}
			Mem.setI32(Mem.addr(a), 4, AK_WRAP);
			return s;
		}
		if (ak == AK_WRAP) {
			var s = storage(a);
			if (kindOf(s) == k) return s;
		}
		throw "NativeArray storage type mismatch";
	}

	// the slow paths of an access of a NativeArray seen as Dynamic (MirBuild.narrayDyn)
	@:hxmc.export("hx_narray_get_slow") static function getSlow(a:Dynamic, i:Int):Dynamic
		return get(a, i);

	@:hxmc.export("hx_narray_set_slow") static function setSlow(a:Dynamic, i:Int, value:Dynamic):Void
		set(a, i, value);

	@:hxmc.host("hx_narray_get") public static function get(a:Dynamic, i:Int):Dynamic {
		var s = storage(a);
		return switch kindOf(s) {
			case AK_BOOL: (Mem.getU8At(Mem.addr(s), 8, i) != 0 : Dynamic);
			case AK_I32: (Mem.getI32At(Mem.addr(s), 8, i) : Dynamic);
			case AK_F64: (Mem.getF64At(Mem.addr(s), 8, i) : Dynamic);
			case AK_I64: (Mem.getI64At(Mem.addr(s), 8, i) : Dynamic);
			case _: Mem.getRefAt(Mem.addr(s), 8, i);
		}
	}

	@:hxmc.host("hx_narray_set") public static function set(a:Dynamic, i:Int, value:Dynamic):Void {
		var s = storage(a);
		var kind = kindOf(s);
		if (kind == AK_PTR) {
			Mem.setRefBarrier(s, 8 + 8 * i, value);
			return;
		}
		var t = value == null ? T_BOXINT : tindex(value);
		if (t != T_BOXINT && t != T_BOXBOOL && !(kind == AK_F64 && t == T_BOXFLOAT) && !(kind == AK_I64 && t == T_BOXI64))
			throw "NativeArray element type mismatch";
		switch kind {
			case AK_BOOL: var v:Bool = value; Mem.setU8At(Mem.addr(s), 8, i, v ? 1 : 0);
			case AK_I32: var v:Int = value; Mem.setI32At(Mem.addr(s), 8, i, v);
			case AK_F64: var v:Float = value; Mem.setF64At(Mem.addr(s), 8, i, v);
			case _: var v:I64 = value; Mem.setI64At(Mem.addr(s), 8, i, v);
		}
	}
}
