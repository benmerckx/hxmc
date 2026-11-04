package hxmc.java;

import hxmc.unsafe.*;

// A weak reference to a Java object (docs/interop.md, "Java (JNI)"): a weak
// global reference (NewWeakGlobalRef), which does not keep the object;
// get() is the object while Java has it, null once Java collected it. Held
// outside the heap, deleted with the Weak (Foreign's weak cells: the cell's
// field registered at the offset the layout gave it).
class Weak<T> {
	var cell:Ptr;

	public function new(v:T) {
		if (!@:privateAccess JavaException.available()) {
			@:privateAccess JavaException.unavailable();
			return;
		}
		cell = @:privateAccess hxmc.rt.JniKind.weakNew(v);
		if (cell.isNull()) return;
		@:privateAccess hxmc.rt.Foreign.ownWeak(@:privateAccess hxmc.rt.JniKind.k(), this, Struct.fieldOffset(this, "cell"));
	}

	public function get():Null<T> {
		if (!@:privateAccess JavaException.available()) return null;
		return @:privateAccess hxmc.rt.JniKind.weakGet(cell);
	}
}
