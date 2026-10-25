// A C function that keeps a pointer it is passed (@:hxmc.retains) takes no scoped memory.
// expect: scoped memory passed to LibCKeeps.setbuf, which keeps the pointer (@:hxmc.retains)
import hxmc.scoped.*;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

@:hxmc.c extern class LibCKeeps {
	@:hxmc.retains static function setbuf(stream:Ptr, buf:Ptr):Void;
}

@:hxmc.scoped class Keeper {
	public static function keep(stream:Ptr) {
		var b = Scope.slice(512);
		LibCKeeps.setbuf(stream, b.ptr());
	}
}

class ScopedCRetains {
	static function main()
		Keeper.keep(Ptr.nil());
}
