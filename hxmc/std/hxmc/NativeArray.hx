package hxmc;

/**
	Fixed-size, GC-managed storage specialized for its element type.

	Bool uses 8-bit elements, Int uses 32 bits, Float and Int64 use 64 bits,
	and other types use references (including boxed nullable numbers). With
	`-D hxmc.wasm-gc`, it is the engine's array of that type.
	Elements start at zero, false or null. Out of bounds, `-D
	hxmc.native-array-outofbounds` decides: not tested when not defined,
	`throws`, `silent` (as haxe.ds.Vector). Casts between storage types are
	not checked.
	Seen as NativeArray<Dynamic> (or Any, or an erased type parameter), any
	storage is read and written by its kind. Taken as a typed NativeArray
	(from those, or from a Dynamic), the storage must be of that type: an
	error is thrown there otherwise. Made for an erased type parameter, its
	storage holds references until the first typed view converts it to its
	own type, shared with the generic code from then on.
	Arrays of no elements are shared, one per element type.
	Conversions to and from Array copy the elements.
**/
@:final extern class NativeArray<T> implements ArrayAccess<T> {
	public var length(default, never):Int;
	public function new(length:Int):Void;

	/**
		Element `i`, without the test of the index
		`-D hxmc.native-array-outofbounds` asks for: `i` must be in bounds.
	**/
	@:noCompletion public function unsafeGet(i:Int):T;

	/** Sets element `i` as unsafeGet reads it. **/
	@:noCompletion public function unsafeSet(i:Int, value:T):Void;

	/**
		A new NativeArray of the elements of `values`, which must be an array
		literal: allocated at its length and filled in order, as an Array
		literal is (no Array is made).
	**/
	@:noCompletion public static function literal<T>(values:Array<T>):NativeArray<T>;

	public inline function fill(value:T):Void {
		for (i in 0...length) unsafeSet(i, value);
	}

	// Preserve the runtime element layout even when T is erased.
	public function copy():NativeArray<T>;

	public inline function toArray():Array<T> {
		var result:Array<T> = [];
		result.resize(length);
		for (i in 0...length) result[i] = unsafeGet(i);
		return result;
	}

	public static inline function fromArray<T>(array:Array<T>):NativeArray<T> {
		var result = new NativeArray<T>(array.length);
		for (i in 0...array.length) result.unsafeSet(i, array[i]);
		return result;
	}

	/**
		Copies `length` elements, overlapping ranges too. Ranges out of
		bounds are copied element by element, each access as
		`-D hxmc.native-array-outofbounds` says.
	**/
	public static inline function blit<T>(src:NativeArray<T>, srcPos:Int, dest:NativeArray<T>, destPos:Int, length:Int):Void {
		#if !(hxmc.wasm_gc || hxmc.native_array_outofbounds)
		// (accesses out of bounds not tested: a few elements copied here,
		// typed, without the test of the range)
		if (length <= 4) {
			if (src == dest && srcPos < destPos) {
				var i = length;
				while (i > 0) {
					i--;
					dest.unsafeSet(destPos + i, src.unsafeGet(srcPos + i));
				}
			} else
				for (i in 0...length) dest.unsafeSet(destPos + i, src.unsafeGet(srcPos + i));
		} else
		#end
		blitRange(src, srcPos, dest, destPos, length);
	}

	static inline function blitRange<T>(src:NativeArray<T>, srcPos:Int, dest:NativeArray<T>, destPos:Int, length:Int):Void {
		var inBounds = (srcPos | destPos | length) >= 0 && length <= src.length - srcPos && length <= dest.length - destPos;
		#if hxmc.wasm_gc
		// (-D hxmc.wasm-gc: storage of one kind by array.copy, which overlapping ranges take too)
		if (inBounds && hxmc.rt.gc.W.naCopy(dest, destPos, src, srcPos, length)) {} else
		#else
		// (more than a few elements: one memmove by the runtime, the
		// collector's barrier for references; a few are copied below, typed,
		// cheaper than the call)
		if (inBounds && length > 4 && hxmc.rt.NArray.move(dest, destPos, src, srcPos, length)) {} else
		#end
		if (src == dest && srcPos < destPos) {
			var i = length;
			if (inBounds)
				while (i > 0) {
					i--;
					dest.unsafeSet(destPos + i, src.unsafeGet(srcPos + i));
				}
			else
				while (i > 0) {
					i--;
					dest[destPos + i] = src[srcPos + i];
				}
		} else if (inBounds) {
			for (i in 0...length) dest.unsafeSet(destPos + i, src.unsafeGet(srcPos + i));
		} else {
			for (i in 0...length) dest[destPos + i] = src[srcPos + i];
		}
	}

	public inline function iterator():NativeArrayIterator<T> return new NativeArrayIterator(this);
}

@:generic class NativeArrayIterator<T> {
	var array:NativeArray<T>;
	var index = 0;
	public inline function new(array:NativeArray<T>) this.array = array;
	public inline function hasNext():Bool return index < array.length;
	public inline function next():T return array.unsafeGet(index++);
}
