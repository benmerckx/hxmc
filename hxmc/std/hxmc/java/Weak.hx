package hxmc.java;

import hxmc.unsafe.*;

// A weak reference to a Java object (docs/interop.md, "Java (JNI)"): a weak
// global reference (NewWeakGlobalRef), which does not keep the object;
// get() is the object while Java has it, null once Java collected it. Held
// outside the heap, deleted with the Weak (Foreign's weak cells).
class Weak<T> {
	var cell:Ptr;

	static var offset = -1;

	public function new(v:T) {
		if (!@:privateAccess JavaException.available()) {
			@:privateAccess JavaException.unavailable();
			return;
		}
		cell = @:privateAccess hxmc.rt.JniKind.weakNew(v);
		if (cell.isNull()) return;
		if (offset < 0) offset = offsetOf(this, cell);
		@:privateAccess hxmc.rt.Foreign.ownWeak(@:privateAccess hxmc.rt.JniKind.k(), this, offset);
	}

	public function get():Null<T> {
		if (!@:privateAccess JavaException.available()) return null;
		return @:privateAccess hxmc.rt.JniKind.weakGet(cell);
	}

	@:hxmc.unsafe static function offsetOf(o:Dynamic, p:Ptr):Int {
		var a = Mem.addr(o);
		for (i in 0...4)
			if (Mem.getPtr(a, 8 * i) == p) return 8 * i;
		return 0;
	}
}
