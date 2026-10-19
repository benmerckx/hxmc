package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Obj over the representations of ml2hx.rt.Poly: Obj.t is any value;
// tags and sizes are OCaml's for the value's representation.
abstract ObjT(Dynamic) from Dynamic to Dynamic {}

class Obj {
	public static final lazyTag:Int63 = Int63.ofInt(246);
	public static final closureTag:Int63 = Int63.ofInt(247);
	public static final objectTag:Int63 = Int63.ofInt(248);
	public static final infixTag:Int63 = Int63.ofInt(249);
	public static final forwardTag:Int63 = Int63.ofInt(250);
	public static final noScanTag:Int63 = Int63.ofInt(251);
	public static final abstractTag:Int63 = Int63.ofInt(251);
	public static final stringTag:Int63 = Int63.ofInt(252);
	public static final doubleTag:Int63 = Int63.ofInt(253);
	public static final doubleArrayTag:Int63 = Int63.ofInt(254);
	public static final customTag:Int63 = Int63.ofInt(255);
	public static final intTag:Int63 = Int63.ofInt(1000);
	public static final outOfHeapTag:Int63 = Int63.ofInt(1001);
	public static final unalignedTag:Int63 = Int63.ofInt(1002);

	public static inline function repr<T>(x:T):ObjT return (cast x : ObjT);
	public static inline function obj<T>(x:ObjT):T return cast x;
	public static inline function magic<A, B>(x:A):B return cast x;
	public static function isBlock(x:ObjT):Bool return Poly.kind(x) != @:privateAccess Poly.K_IMM;
	public static function isInt(x:ObjT):Bool return !isBlock(x);
	public static function tag(x:ObjT):Int63 {
		var k = Poly.kind(x);
		return k == @:privateAccess Poly.K_IMM ? intTag : Int63.ofInt(Poly.tag(x, k));
	}
	public static function size(x:ObjT):Int63 {
		var k = Poly.kind(x);
		if (k == @:privateAccess Poly.K_STRING) return Int63.ofInt(Std.int(((x : String).length + 8) / 8));
		if (k == @:privateAccess Poly.K_DOUBLE) return Int63.one;
		return Int63.ofInt(Poly.size(x, k));
	}
	public static function field(x:ObjT, i:Int63):ObjT return Poly.fields(x, Poly.kind(x))[i.toInt()];
	public static function doubleField(x:ObjT, i:Int63):Float return (Poly.fields(x, Poly.kind(x))[i.toInt()] : Float);
	// The words reachable from x (Obj.reachable_words), counted over the
	// OCaml representation: a header and the fields of each distinct block.
	public static function reachableWords(x:ObjT):Int63 {
		var seen = new haxe.ds.ObjectMap<Dynamic, Bool>();
		var n = 0, stack:Array<Dynamic> = [x];
		while (stack.length > 0) {
			var v = stack.pop();
			var k = Poly.kind(v);
			if (k == @:privateAccess Poly.K_IMM) continue;
			if (k == @:privateAccess Poly.K_STRING || k == @:privateAccess Poly.K_DOUBLE || k == @:privateAccess Poly.K_BYTES || k == @:privateAccess Poly.K_FUNC) {
				if (k == @:privateAccess Poly.K_STRING) n += 1 + Std.int(((v : String).length + 8) / 8);
				else n += 2;
				continue;
			}
			if (seen.exists(v)) continue;
			seen.set(v, true);
			var fs = Poly.fields(v, k);
			n += 1 + fs.length;
			for (f in fs) stack.push(f);
		}
		return Int63.ofInt(n);
	}
}
