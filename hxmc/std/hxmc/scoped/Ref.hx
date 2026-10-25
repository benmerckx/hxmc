package hxmc.scoped;

import hxmc.unsafe.Ptr;

// A reference to one T in scoped memory (docs/plans/lowlevel.md, "Scoped
// memory"). `r.value` reads it (a struct: in place, copied when kept),
// `r.value = v` and `r.value.x = 1` write it in place. Rooted at the memory
// it points into (a Grow's push: the Grow), which the root checker keeps it
// from outliving. Linear memory: its address; WasmGC ("Two representations,
// one core"): the storage that holds it (a Grow's header, whose array may be
// reallocated, or a holder of a Slice's array) and its index.
abstract Ref<T>(#if hxmc.wasm_gc RefData<T> #else Ptr<T> #end) {
	#if hxmc.wasm_gc
	public inline function new(h:Holder<T>, i:Int)
		this = new RefData(h, i);

	// no element (an absent entry's reference)
	public static inline function nil<T>():Ref<T>
		return cast null;

	public inline function isNull():Bool
		return this == null;

	public var value(get, set):T;

	inline function get_value():T
		return this.h.a.unsafeGet(this.i);

	@:hxmc.noScope inline function set_value(v:T):T {
		this.h.a.unsafeSet(this.i, v);
		return v;
	}
	#else
	public inline function new(p:Ptr<T>)
		this = p;

	// no element (an absent entry's reference)
	public static inline function nil<T>():Ref<T>
		return new Ref(Ptr.nil());

	public inline function isNull():Bool
		return this.isNull();

	public var value(get, set):T;

	inline function get_value():T
		return this.value;

	@:hxmc.noScope inline function set_value(v:T):T
		return this.value = v;

	public inline function ptr():Ptr<T>
		return this;
	#end
}

#if hxmc.wasm_gc
// what holds the elements a Ref reaches: a Grow's header (hxmc.scoped.Grow),
// or a Slice's array
@:hxmc.repr @:noCompletion class Holder<T> {
	public var a:NativeArray<T>;

	public inline function new(a:NativeArray<T>)
		this.a = a;
}

@:hxmc.repr @:noCompletion class RefData<T> {
	public final h:Holder<T>;
	public final i:Int;

	public inline function new(h:Holder<T>, i:Int) {
		this.h = h;
		this.i = i;
	}
}
#end
