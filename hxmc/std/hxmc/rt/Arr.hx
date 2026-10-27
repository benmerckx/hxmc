package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Repr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;

// The Array natives (formerly in rt_std.c): generic natives over arrays of
// any element kind, written over hxmc.rt.Repr: the arguments' meaning
// here, the elements' storage there (Boxes': slot 0 the length and the
// element kind, slot 1 the storage, a NativeArray of that kind as long as
// the capacity; the element access, growth and kind conversion themselves
// stay with the collector, hx_arr_*). The rest are the language's own
// array operations on Array<Dynamic>, which go through them.
@:keep @:allow(hxmc.rt)
class Arr {
	static inline function len(a:Dynamic):Int
		return Repr.arrLen(a);

	static inline function kindOf(a:Dynamic):Int
		return Repr.arrKind(a);

	// a new array of this kind and length (elements zero)
	static function make(kind:Int, n:Int):Dynamic
		return Repr.arrMake(kind, n);

	@:hxmc.host("Array_copy") static function copy(a:Dynamic):Dynamic {
		var n = len(a);
		var r = make(kindOf(a), n);
		Repr.arrCopy(r, a, n);
		return r;
	}

	@:hxmc.host("Array_concat") static function concat(a:Dynamic, b:Dynamic):Dynamic {
		if (kindOf(a) == kindOf(b)) {
			// same element kind: one allocation, two copies
			var na = len(a), nb = len(b);
			var r = make(kindOf(a), na + nb);
			Repr.arrCopy2(r, a, na, b, nb);
			return r;
		}
		var r:Array<Dynamic> = copy(a);
		var bb:Array<Dynamic> = b;
		var i = 0;
		while (i < bb.length) {
			r.push(bb[i]);
			i++;
		}
		return r;
	}

	static function indexFrom(a:Dynamic, x:Dynamic, from:Int):Int {
		var n = len(a);
		if (from < 0) {
			from += n;
			if (from < 0) from = 0;
		}
		switch kindOf(a) {
			case Repr.AK_I32:
				if (Repr.isNull(x)) return -1;
				if (Repr.isBoxedFloat(x)) {
					var f = Repr.unboxedFloat(x);
					if (f != Math.ffloor(f)) return -1;
				}
				var v:Int = x;
				var d = Repr.elems(a);
				for (i in from...n)
					if (d.getInt(i) == v) return i;
				return -1;
			case Repr.AK_BOOL:
				if (Repr.isNull(x) || !Repr.isBoxedBool(x)) return -1;
				var v = Repr.unboxedBool(x);
				var d = Repr.elems(a);
				for (i in from...n)
					if (d.getBool(i) == v) return i;
				return -1;
			case Repr.AK_F64:
				if (Repr.isNull(x)) return -1;
				var v:Float = x;
				var d = Repr.elems(a);
				for (i in from...n)
					if (d.getFloat(i) == v) return i;
				return -1;
			case Repr.AK_PTR if (Repr.identityEq(x)):
				// (== is this needle's identity: the words compared, no call)
				var d = Repr.elems(a);
				for (i in from...n)
					if (Repr.same(d.getRef(i), x)) return i;
				return -1;
			case _:
				for (i in from...n) {
					var e = Repr.elems(a).getRef(i);
					if (Repr.same(e, x) || Repr.dynEq(e, x)) return i;
				}
				return -1;
		}
	}

	@:hxmc.host("Array_indexOf") static function indexOf(a:Dynamic, x:Dynamic, from:Null<Int>):Int
		return indexFrom(a, x, from == null ? 0 : from);

	@:hxmc.host("Array_lastIndexOf") static function lastIndexOf(a:Dynamic, x:Dynamic, from:Null<Int>):Int {
		var n = len(a);
		var f:Int = from == null ? n - 1 : from;
		if (f < 0) f += n;
		if (f >= n) f = n - 1;
		var i = f;
		var k = kindOf(a);
		if (k == Repr.AK_PTR && Repr.identityEq(x)) {
			// (as indexFrom's)
			var d = Repr.elems(a);
			while (i >= 0) {
				if (Repr.same(d.getRef(i), x)) return i;
				i--;
			}
			return -1;
		}
		while (i >= 0) {
			if (k == Repr.AK_PTR) {
				var e = Repr.elems(a).getRef(i);
				if (Repr.same(e, x) || Repr.dynEq(e, x)) return i;
			} else if (k == Repr.AK_BOOL) {
				if (!Repr.isNull(x) && Repr.isBoxedBool(x) && Repr.elems(a).getBool(i) == Repr.unboxedBool(x)) return i;
			} else if (!Repr.isNull(x)) {
				var v:Float = x;
				var e = k == Repr.AK_I32 ? (Repr.elems(a).getInt(i) : Float) : k == Repr.AK_F64 ? Repr.elems(a).getFloat(i) : {
					var l:Float = cast Repr.elems(a).getI64(i);
					l;
				};
				if (e == v) return i;
			}
			i--;
		}
		return -1;
	}

	@:hxmc.host("Array_contains") static function contains(a:Dynamic, x:Dynamic):Bool
		return indexFrom(a, x, 0) >= 0;

	// removes element i, shifting the rest down
	static function removeAt(a:Dynamic, i:Int)
		Repr.arrRemoveAt(a, i);

	@:hxmc.host("Array_remove") static function remove(a:Dynamic, x:Dynamic):Bool {
		var i = indexFrom(a, x, 0);
		if (i < 0) return false;
		removeAt(a, i);
		return true;
	}

	@:hxmc.host("Array_pop") static function pop(a:Dynamic):Dynamic {
		var n = len(a);
		if (n == 0) return null;
		return Repr.arrPop(a, n);
	}

	@:hxmc.host("Array_shift") static function shift(a:Dynamic):Dynamic {
		if (len(a) == 0) return null;
		var v = (a : Array<Dynamic>)[0];
		removeAt(a, 0);
		return v;
	}

	@:hxmc.host("Array_insert") static function insert(a:Dynamic, pos:Int, x:Dynamic):Void {
		var n = len(a);
		if (pos < 0) {
			pos += n;
			if (pos < 0) pos = 0;
		}
		// grows (and converts the kind if needed); the length may have changed
		// meanwhile (another thread at the allocation)
		var arr:Array<Dynamic> = a;
		arr.push(x);
		n = len(a) - 1;
		if (pos > n) pos = n;
		// the last element (x) moved to pos, those from pos one up
		Repr.arrRotate(a, pos, n);
	}

	@:hxmc.host("Array_unshift") static function unshift(a:Dynamic, x:Dynamic):Void
		insert(a, 0, x);

	// iterator and keyValueIterator as values (their calls are inline)
	@:hxmc.host("Array_iterator") static function iterator(a:Dynamic):Dynamic {
		return Dyn.arrayIterator(a);
	}

	@:hxmc.host("Array_keyValueIterator") static function keyValueIterator(a:Dynamic):Dynamic
		return new haxe.iterators.ArrayKeyValueIterator<Dynamic>(a);

	// push as a value (a call is lowered inline: SArrPush)
	@:hxmc.host("Array_push") static function push(a:Dynamic, x:Dynamic):Int {
		var arr:Array<Dynamic> = a;
		return arr.push(x);
	}

	// (no allocation but in grow: the array needs no root here)
	@:hxmc.host("Array_resize") @:access(hxmc.rt.Boxes) static function resize(a:Dynamic, n:Int):Void {
		var m = len(a);
		if (n < m) {
			Repr.arrCut(a, n, m);
			return;
		}
		if (n == m) return;
		// within the capacity: the slots past the length are zero (shrinking
		// clears them)
		if (n <= Boxes.arrCap(a)) {
			MemRepr.arrSetLen(a, n);
			return;
		}
		grow(a, n);
	}

	@:access(hxmc.rt.Boxes) static function grow(a:Dynamic, n:Int):Void {
		// past the capacity, the storage allocated at twice the capacity, or
		// at the new length when that is more (from empty: the length), as a
		// push grows it (growing by one at a time stays amortised); the
		// elements copied once (the new ones zero, the kind kept), unless
		// another thread changed the array meanwhile
		var kind = kindOf(a);
		var cap = Boxes.arrCap(a);
		// (longer than the longest storage: arrGrow's error, below; the
		// doubled capacity stops at it)
		if (n > cap && n <= Boxes.MAX_CAP) {
			var ncap = cap * 2;
			if (ncap < n) ncap = n;
			if (ncap > Boxes.MAX_CAP) ncap = Boxes.MAX_CAP;
			// (a reference: the allocation's collection may move the storage, Boxes.arrGrow)
			var d0:Dynamic = Mem.getRef(Mem.addr(a), 8);
			var nd:Dynamic = Boxes.dataAlloc(kind, Boxes.roomFor(kind, ncap));
			var k = len(a);
			if (MemRepr.arrStore(a) == Mem.addr(d0) && kindOf(a) == kind && k <= n) {
				if (k > 0) {
					LibC.memcpy(Mem.addr(nd), MemRepr.arrData(a), (MemRepr.elemSize(a) * k : I64));
					if (kind == Repr.AK_PTR && !Boxes.inYoungObj(nd)) Boxes.Gc_barrierRange(nd, k);
				}
				Mem.setRefBarrier(a, 8, nd);
				MemRepr.arrSetLen(a, n);
				return;
			}
		}
		// a store past the end grows the array (zeros in between, the kind kept)
		var arr:Array<Dynamic> = a;
		arr[n - 1] = null;
	}

	@:hxmc.host("Array_reverse") @:hxmc.unsafe static function reverse(a:Dynamic):Void {
		var n = len(a);
		if (n < 2) return;
		Repr.arrReverse(a, n);
	}

	@:hxmc.host("Array_slice") static function slice(a:Dynamic, pos:Int, endp:Null<Int>):Dynamic {
		var n = len(a);
		var end:Int = endp == null ? n : endp;
		if (pos < 0) {
			pos += n;
			if (pos < 0) pos = 0;
		}
		if (end < 0) end += n;
		if (end > n) end = n;
		var l = end > pos ? end - pos : 0;
		var r = make(kindOf(a), l);
		Repr.arrCopyFrom(r, a, pos, l);
		return r;
	}

	@:hxmc.host("Array_splice") static function splice(a:Dynamic, pos:Int, l:Int):Dynamic {
		var n = len(a);
		if (pos < 0) {
			pos += n;
			if (pos < 0) pos = 0;
		}
		if (pos > n) pos = n;
		if (l < 0) l = 0;
		if (pos + l > n) l = n - pos;
		var r = make(kindOf(a), l);
		Repr.arrSplice(a, r, pos, l, n);
		return r;
	}

	@:hxmc.host("Array_join") static function join(a:Dynamic, sep:String):String {
		var arr:Array<Dynamic> = a;
		var b = new StringBuf();
		var i = 0;
		while (i < arr.length) {
			if (i > 0) b.add(sep);
			b.add(arr[i]);
			i++;
		}
		return b.toString();
	}

	@:hxmc.host("Array_toString") static function toString(a:Dynamic):String
		return Repr.stdString(a);

	// A stable sort, the same order for every consistent comparator: up to
	// SMALL elements a binary insertion sort in place (no allocation; each
	// insertion one move of memory), larger arrays runs of RUN sorted so, then
	// merged bottom-up between the array and one buffer. Generic: an
	// Array<Int> or Array<Float> with a comparator of its own type (FnLower:
	// Array_sortInt, Array_sortFloat) is sorted without boxing its elements;
	// any other array as Array<Dynamic>, through the array's own loads and
	// stores (its kind kept).
	static inline var SMALL = 128;
	static inline var RUN = 32;

	@:generic static function sortWith<T>(arr:Array<T>, f:T->T->Int):Void {
		var n = arr.length;
		if (n < 2) return;
		var run = n <= SMALL ? n : RUN;
		var lo = 0;
		while (lo < n) {
			var hi = lo + run < n ? lo + run : n;
			for (i in lo + 1...hi) {
				var x = arr[i];
				// (in order already: one comparison)
				if (f(x, arr[i - 1]) >= 0) continue;
				// after the last element not greater than x (stable)
				var a = lo, b = i - 1;
				while (a < b) {
					var m = (a + b) >> 1;
					if (f(x, arr[m]) < 0) b = m else a = m + 1;
				}
				// (x moved to a, those from a one up: one move of memory, the
				// elements as stored whatever the array's kind)
				Repr.arrRotate(arr, a, i);
			}
			lo = hi;
		}
		if (n <= SMALL) return;
		var buf:Array<T> = [];
		buf.resize(n);
		var src = arr, dst = buf;
		var width = RUN;
		while (width < n) {
			var start = 0;
			while (start < n) {
				var mid = start + width < n ? start + width : n;
				var hi = start + 2 * width < n ? start + 2 * width : n;
				var i = start, j = mid, k = start;
				while (i < mid && j < hi) {
					if (f(src[j], src[i]) < 0) dst[k++] = src[j++] else dst[k++] = src[i++];
				}
				while (i < mid)
					dst[k++] = src[i++];
				while (j < hi)
					dst[k++] = src[j++];
				start += 2 * width;
			}
			var t = src;
			src = dst;
			dst = t;
			width *= 2;
		}
		if (src != arr)
			for (i in 0...n)
				arr[i] = src[i];
	}

	@:hxmc.host("Array_sort") static function sort(a:Dynamic, f:Dynamic->Dynamic->Int):Void
		sortWith((a : Array<Dynamic>), f);

	@:hxmc.host("Array_sortInt") static function sortInt(a:Dynamic, f:Int->Int->Int):Void
		sortWith((a : Array<Int>), f);

	@:hxmc.host("Array_sortFloat") static function sortFloat(a:Dynamic, f:Float->Float->Int):Void
		sortWith((a : Array<Float>), f);

	@:hxmc.host("Array_filter") static function filter(a:Dynamic, f:Dynamic->Bool):Dynamic {
		var arr:Array<Dynamic> = a;
		var r:Array<Dynamic> = make(kindOf(a), 0);
		var i = 0;
		while (i < arr.length) {
			var v = arr[i];
			if (f(v)) r.push(v);
			i++;
		}
		return r;
	}

	@:hxmc.host("Array_map") static function map(a:Dynamic, f:Dynamic->Dynamic):Dynamic {
		var arr:Array<Dynamic> = a;
		var r:Array<Dynamic> = [];
		var i = 0;
		while (i < arr.length) {
			r.push(f(arr[i]));
			i++;
		}
		return r;
	}
}
