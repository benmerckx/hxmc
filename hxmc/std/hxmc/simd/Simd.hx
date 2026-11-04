package hxmc.simd;

import hxmc.unsafe.Ptr;

// The intrinsics of the vector types (docs/plans/simd.md), expanded inline
// by the compiler (FnLower.simdCall, MirBuild.simd): `op` names a
// WebAssembly SIMD instruction (hxmc.SimdOps), a literal; lanes and a
// constant's words are literals. Not a user API: F32x4, I32x4, ... are.
@:noCompletion extern class Simd {
	static function op1(op:String, a:V128):V128;
	static function op2(op:String, a:V128, b:V128):V128;
	static function op3(op:String, a:V128, b:V128, c:V128):V128;
	static function shift(op:String, a:V128, n:Int):V128;
	static function splatInt(op:String, x:Int):V128;
	static function splatI64(op:String, x:haxe.Int64):V128;
	static function splatFloat(op:String, x:Float):V128;
	static function extractInt(op:String, a:V128, lane:Int):Int;
	static function extractI64(op:String, a:V128, lane:Int):haxe.Int64;
	static function extractFloat(op:String, a:V128, lane:Int):Float;
	static function replaceInt(op:String, a:V128, lane:Int, x:Int):V128;
	static function replaceI64(op:String, a:V128, lane:Int, x:haxe.Int64):V128;
	static function replaceFloat(op:String, a:V128, lane:Int, x:Float):V128;
	static function test(op:String, a:V128):Int;
	static function shuffle(a:V128, b:V128, l0:Int, l1:Int, l2:Int, l3:Int, l4:Int, l5:Int, l6:Int, l7:Int, l8:Int, l9:Int, l10:Int, l11:Int, l12:Int,
		l13:Int, l14:Int, l15:Int):V128;
	static function const(w0:Int, w1:Int, w2:Int, w3:Int):V128;
	// at p + off (raw memory: the caller checked the range)
	static function load(op:String, p:Ptr, off:Int):V128;
	static function store(op:String, p:Ptr, off:Int, v:V128):Void;
}
