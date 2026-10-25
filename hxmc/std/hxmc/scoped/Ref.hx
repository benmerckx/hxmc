package hxmc.scoped;

import hxmc.unsafe.Ptr;

// A reference to one T in scoped memory (docs/plans/lowlevel.md, "Scoped
// memory"): its address. `r.value` reads it (a struct: in place, copied when
// kept), `r.value = v` and `r.value.x = 1` write it in place. Rooted at the
// memory it points into (a Grow's push: the Grow), which the root checker
// keeps it from outliving.
abstract Ref<T>(Ptr<T>) {
	public inline function new(p:Ptr<T>)
		this = p;

	public var value(get, set):T;

	inline function get_value():T
		return this.value;

	inline function set_value(v:T):T
		return this.value = v;

	public inline function ptr():Ptr<T>
		return this;
}
