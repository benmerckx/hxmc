package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.LibC;

// One allocation: the header (Types: the type index, naType of the element
// kind; the words; the length), then the packed elements. Typed accesses are
// emitted by MirBuild; a NativeArray seen as Dynamic (Dynamic, Any, an
// erased type parameter) goes through these helpers, by the kind.
//
// A NativeArray made for an erased type parameter (`new NativeArray<T>` in
// generic code) cannot know its element kind: it is a wrapper (T_NATIVE_OPEN,
// kind AK_OPEN: a record of one slot, its length in its header where a
// record has its hash: Types) referring to storage of references. The first
// typed view to take it (view, from FnLower.coerce) gets that storage,
// converted to the view's kind if it differs (once), and fixes the wrapper
// (T_NATIVE_WRAP, kind AK_WRAP) on it: the generic code that holds the
// wrapper sees what the typed code writes, and the other way round. A later
// view of another kind is an error.
//
// An array of no elements cannot change: one made by typed code is the empty
// array of its kind (MirBuild.EMPTY_ARRAY, static data: empty), and any
// serves as a copy of itself, and as the view of any kind.
//
// An Array's storage is a NativeArray of the Array's kind, its length the
// Array's capacity (Boxes): an Array without room has the empty one.
@:keep
class NArray {
	static inline function kindOf(a:Dynamic):Int {
		var t = tindex(a);
		return t > T_NATIVE_WRAP ? naKind(t) : t == T_NATIVE_OPEN ? AK_OPEN : AK_WRAP;
	}

	// (a wrapper's: in its header too)
	static inline function lengthOf(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), -4);

	// the empty array of kind k (MirBuild.EMPTY_ARRAY, which DataGen defines
	// where it is referred to)
	public static inline function empty(k:Int):Dynamic
		return Mem.obj((switch k {
			case AK_I32: Mem.sym("hxmc$narray_empty$1");
			case AK_F64: Mem.sym("hxmc$narray_empty$2");
			case AK_I64: Mem.sym("hxmc$narray_empty$3");
			case AK_BOOL: Mem.sym("hxmc$narray_empty$4");
			case AK_BYTE: Mem.sym("hxmc$narray_empty$5");
			case _: Mem.sym("hxmc$narray_empty$0");
		}).add(8));

	// the storage of a: a itself, unless a wrapper
	static inline function storage(a:Dynamic):Dynamic {
		var k = kindOf(a);
		return k == AK_OPEN || k == AK_WRAP ? Mem.getRef(Mem.addr(a), 0) : a;
	}

	// new storage of n elements of kind k (zeroed: 0, false, null; none:
	// the empty one). A literal's storage too (MirBuild, hxmc_narray_lit: n
	// from 1 to the kind's most), and an Array's (Boxes, inline: make, n > 0)
	@:hxmc.export("hx_narray_new_n") public static function alloc(k:Int, n:Int):Dynamic
		return n == 0 ? empty(k) : make(k, n);

	public static inline function make(k:Int, n:Int):Dynamic
		return Mem.allocArray(naType(k), n, k >= AK_BOOL ? (n + 7) >> 3 : k == AK_I32 ? (n + 1) >> 1 : n);

	@:hxmc.host("hx_narray_open") static function open(n:Int):Dynamic {
		if (n < 0 || n > 0x0FFFFFFD) badLength();
		if (n == 0) return alloc(AK_PTR, 0);
		var s = alloc(AK_PTR, n);
		var w = Mem.alloc(1, T_NATIVE_OPEN, K_OBJ);
		Mem.setI32(Mem.addr(w), -4, n);
		Mem.setRefBarrier(w, 0, s);
		return w;
	}

	@:hxmc.host("hxmc_NativeArray_copy") static function copy(a:Dynamic):Dynamic {
		if (lengthOf(a) == 0) return a;
		if (kindOf(a) != AK_OPEN) return copyStorage(storage(a));
		// (an open wrapper's copy is open too)
		var w = open(lengthOf(a));
		var from = storage(a), to = storage(w);
		LibC.memcpy(Mem.addr(to), Mem.addr(from), (lengthOf(from) : I64) * 8);
		C.Leaf.rt_barrier_range(to, Mem.addr(to), lengthOf(to));
		return w;
	}

	static function copyStorage(a:Dynamic):Dynamic {
		var words = nslots(a);
		var result = Mem.allocArrayRaw(tindex(a), lengthOf(a), words);
		LibC.memcpy(Mem.addr(result), Mem.addr(a), (words : I64) * 8);
		if (kindOf(a) == AK_PTR) C.Leaf.rt_barrier_range(result, Mem.addr(result), lengthOf(result));
		return result;
	}

	// the storage of the Array a, which move takes as any NativeArray
	// (hxmc.NativeArray.fromArray, toArray)
	public static inline function ofArray(a:Dynamic):Dynamic
		return Mem.getRef(Mem.addr(a), 8);

	// hxmc.NativeArray.blit (haxe.ds.Vector.blit; fromArray and toArray, with
	// an Array's storage): d[di, di + n) = s[si, si +
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
		var es = k >= AK_BOOL ? 1 : k == AK_I32 ? 4 : 8;
		var to = Mem.addr(ds).add(es * di);
		LibC.memmove(to, Mem.addr(ss).add(es * si), (es * n : I64));
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
			case AK_I32 | AK_BYTE: (0 : Dynamic);
			case AK_F64: (0.0 : Dynamic);
			case AK_I64: (zero : Dynamic);
			case _: null;
		}
	}

	// a (a NativeArray, or a Dynamic) taken by a typed view of kind k
	@:hxmc.host("hx_narray_view") static function view(a:Dynamic, k:Int):Dynamic {
		if (a == null) return null;
		// (most often storage of the kind already: one comparison)
		var t = tindex(a);
		if (t == naType(k)) return a;
		if (!isNativeArray(t)) throw "Invalid cast to NativeArray";
		var ak = kindOf(a);
		if (lengthOf(a) == 0) return a;
		if (ak == AK_OPEN) {
			var s = storage(a);
			if (k != AK_PTR) {
				var n = lengthOf(s);
				var d = alloc(k, n);
				for (i in 0...n)
					set(d, i, get(s, i));
				Mem.setRefBarrier(a, 0, d);
				s = d;
			}
			// (the type index: a u16 at -8, Types)
			Mem.setI16(Mem.addr(a), -8, T_NATIVE_WRAP);
			return s;
		}
		if (ak == AK_WRAP) {
			var s = storage(a);
			if (kindOf(s) == k) return s;
		}
		throw "NativeArray storage type mismatch";
	}

	// the slow paths of an access of a NativeArray seen as Dynamic (MemLower.narrayDyn)
	@:hxmc.export("hx_narray_get_slow") static function getSlow(a:Dynamic, i:Int):Dynamic
		return get(a, i);

	@:hxmc.export("hx_narray_set_slow") static function setSlow(a:Dynamic, i:Int, value:Dynamic):Void
		set(a, i, value);

	@:hxmc.host("hx_narray_get") public static function get(a:Dynamic, i:Int):Dynamic {
		var s = storage(a);
		return switch kindOf(s) {
			case AK_BOOL: (Mem.getU8At(Mem.addr(s), 0, i) != 0 : Dynamic);
			case AK_BYTE: (Mem.getU8At(Mem.addr(s), 0, i) : Dynamic);
			case AK_I32: (Mem.getI32At(Mem.addr(s), 0, i) : Dynamic);
			case AK_F64: (Mem.getF64At(Mem.addr(s), 0, i) : Dynamic);
			case AK_I64: (Mem.getI64At(Mem.addr(s), 0, i) : Dynamic);
			case _: Mem.getRefAt(Mem.addr(s), 0, i);
		}
	}

	@:hxmc.host("hx_narray_set") public static function set(a:Dynamic, i:Int, value:Dynamic):Void {
		var s = storage(a);
		var kind = kindOf(s);
		if (kind == AK_PTR) {
			Mem.setRefBarrier(s, 8 * i, value);
			return;
		}
		var t = value == null ? T_BOXINT : tindex(value);
		if (t != T_BOXINT && t != T_BOXBOOL && !(kind == AK_F64 && t == T_BOXFLOAT) && !(kind == AK_I64 && t == T_BOXI64))
			throw "NativeArray element type mismatch";
		switch kind {
			case AK_BOOL: var v:Bool = value; Mem.setU8At(Mem.addr(s), 0, i, v ? 1 : 0);
			case AK_BYTE: var v:Int = value; Mem.setU8At(Mem.addr(s), 0, i, v);
			case AK_I32: var v:Int = value; Mem.setI32At(Mem.addr(s), 0, i, v);
			case AK_F64: var v:Float = value; Mem.setF64At(Mem.addr(s), 0, i, v);
			case _: var v:I64 = value; Mem.setI64At(Mem.addr(s), 0, i, v);
		}
	}
}
