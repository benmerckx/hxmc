// @:hxmc.safe vouches for typed parameters only: a raw pointer would let safe code reach any memory.
// expect: C function poke is @:hxmc.safe but its parameter p is raw memory or a GC value (hxmc.unsafe.Ptr<hxmc.unsafe.UInt8>: spans, handles, objects, scalars and structs of them)
import hxmc.unsafe.*;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function poke(p:Ptr<UInt8>, v:Int):Void;
}

class CBindingRawParam {
	static function main()
		C.poke(Ptr.nil(), 1);
}
