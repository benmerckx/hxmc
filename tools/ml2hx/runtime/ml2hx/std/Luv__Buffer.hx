package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Buffer (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvBufferT {
	function new() {}
}

class Luv__Buffer {
	public static function blit(source:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, destination:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function blitFromBytes(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:haxe.io.Bytes, sourceOffset:ml2hx.rt.Int63):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function blitFromString(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:String, sourceOffset:ml2hx.rt.Int63):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function blitToBytes(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:haxe.io.Bytes, destinationOffset:ml2hx.rt.Int63):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function create(a0:ml2hx.rt.Int63):ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout> { throw new Failure("luv: not available in the generated compiler"); }
	public static function drop(a0:ml2hx.rt.MlList<ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>>, a1:ml2hx.rt.Int63):ml2hx.rt.MlList<ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>> { throw new Failure("luv: not available in the generated compiler"); }
	public static function fill(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:Int):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function fromBytes(a0:haxe.io.Bytes):ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout> { throw new Failure("luv: not available in the generated compiler"); }
	public static function fromString(a0:String):ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout> { throw new Failure("luv: not available in the generated compiler"); }
	public static function get(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:ml2hx.rt.Int63):Int { throw new Failure("luv: not available in the generated compiler"); }
	public static function set(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:ml2hx.rt.Int63, a2:Int):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function size(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>):ml2hx.rt.Int63 { throw new Failure("luv: not available in the generated compiler"); }
	public static function sub(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, offset:ml2hx.rt.Int63, length:ml2hx.rt.Int63):ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout> { throw new Failure("luv: not available in the generated compiler"); }
	public static function toBytes(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>):haxe.io.Bytes { throw new Failure("luv: not available in the generated compiler"); }
	public static function toString(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>):String { throw new Failure("luv: not available in the generated compiler"); }
	public static function totalSize(a0:ml2hx.rt.MlList<ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>>):ml2hx.rt.Int63 { throw new Failure("luv: not available in the generated compiler"); }
	public static function unsafeGet(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:ml2hx.rt.Int63):Int { throw new Failure("luv: not available in the generated compiler"); }
	public static function unsafeSet(a0:ml2hx.prim.BigarrayData<Int, ocaml.stdlib.BigarrayModule.BigarrayInt8UnsignedElt, ocaml.stdlib.BigarrayModule.BigarrayCLayout>, a1:ml2hx.rt.Int63, a2:Int):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
}
