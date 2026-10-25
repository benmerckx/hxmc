package hxmc.scoped;

import hxmc.NativeArray;
import hxmc.scoped.Slice.SliceIterator;

// N elements of T inline in the value holding them (docs/plans/lowlevel.md,
// "Types"): a local's in the frame, a struct's field in the struct, a Grow's
// element in the Grow; a struct value (copying one copies the elements). N
// is a constant (`Fixed<Int, 16>`: Haxe's const type parameter), which the
// lowering reads from the type. T is a scalar or a struct value holding no
// reference (scalars, root-free scoped classes): a Fixed's memory is its
// holder's, which the root checker sees as one area. `new Fixed<T, N>()`
// is zeroed; elements are reached through view(), a Slice of the same
// memory (`f[i] = v`, `f[i].x = 1` in place). Linear memory: the elements
// are the value's bytes (a struct of N * sizeof(T)); WasmGC: an array of
// the engine, copied where a struct value is copied.
// (N's name: a parameter named Rest takes a constant, and is the abstract's
// own in its constructor, which a @:const one is not: Haxe's typer refuses
// the abstract's own @:const parameter where a constant is expected)
@:hxmc.fixed
abstract Fixed<T, Rest>(NativeArray<T>) {
	// (the lowering's: zeroed elements, N of them; never compiled as written)
	public function new()
		this = null;

	// elements not zeroed (WasmGC's are), of numbers only: for the std's
	// cores, which write every element before reading it, where zeroing would
	// cost (`var b:Fixed<Int, 257> = Fixed.scratch();`: N from the type; a
	// compiler that does not know the metadata zeroes them)
	@:noCompletion public static inline function scratch<T, N>():Fixed<T, N>
		return @:hxmc.scratch new Fixed<T, N>();

	public var length(get, never):Int;

	@:arrayAccess public inline function get(i:Int):T
		return view()[i];

	@:arrayAccess public inline function set(i:Int, v:T):T
		return view()[i] = v;

	public inline function iterator():SliceIterator<T>
		return view().iterator();

	#if hxmc.wasm_gc
	inline function get_length():Int
		return this.length;

	public inline function view():Slice<T>
		return new Slice(this, 0, this.length);

	// a's elements made (the lowering's, for a new Fixed of struct values:
	// zeroed objects of class cl)
	@:noCompletion public static function filled(a:Dynamic, cl:Dynamic):Dynamic {
		for (i in 0...hxmc.rt.gc.W.naLen(a))
			hxmc.rt.gc.W.naSet(a, i, hxmc.rt.gc.W.createEmpty(cl));
		return a;
	}

	// a copy (the lowering's, where a struct value is copied: CInterop.valueCopies)
	@:noCompletion public static function copyOf(a:Dynamic):Dynamic {
		var n = hxmc.rt.gc.W.naLen(a), k = hxmc.rt.gc.W.naKind(a);
		var r = hxmc.rt.gc.W.naNew(k, n);
		// (struct values: each copied, as an object)
		if (k == hxmc.rt.Types.AK_PTR)
			for (i in 0...n)
				hxmc.rt.gc.W.naSet(r, i, hxmc.rt.gc.W.objCopy(hxmc.rt.gc.W.naGet(a, i)))
		else
			hxmc.rt.gc.W.naCopy(r, 0, a, 0, n);
		return r;
	}
	#else
	// (the lowering's, FnLower.fixedCall: N; never compiled as written)
	@:noCompletion public function get_length():Int
		return 0;

	// (the lowering's: the elements' address in the place holding them, and N)
	public function view():Slice<T>
		return cast null;
	#end
}
