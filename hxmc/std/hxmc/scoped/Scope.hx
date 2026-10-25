package hxmc.scoped;

import hxmc.rt.DataStacks;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;

// Memory of the current scope (docs/plans/lowlevel.md, "Scoped memory"):
// fresh on the data stack, freed when the scope ends.
class Scope {
	// n zeroed elements
	public static inline function slice<T>(n:Int):Slice<T> {
		var bytes = (Ptr.nil() : Ptr<T>).offset(n).toI64().toInt();
		var p = DataStacks.alloc(bytes);
		LibC.memset(p, 0, (bytes : I64));
		return new Slice((p : Ptr<T>), n);
	}
}
