package hxmc.simd;

// The 128 bits of a vector (docs/plans/simd.md): four little-endian 32-bit
// words, w0 the lowest. On hxmc a @:hxmc.struct value (16 bytes, which the
// compiler keeps in a vector register: FnLower.simdCall); the lane types
// (F32x4, I16x8, ...) are abstracts over it. Elsewhere (the interpreter,
// Eval, JavaScript, ...) the same words, worked on lane by lane (Ref).
@:hxmc.struct class V128 {
	public var w0:Int;
	public var w1:Int;
	public var w2:Int;
	public var w3:Int;

	public inline function new(w0:Int, w1:Int, w2:Int, w3:Int) {
		this.w0 = w0;
		this.w1 = w1;
		this.w2 = w2;
		this.w3 = w3;
	}
}
