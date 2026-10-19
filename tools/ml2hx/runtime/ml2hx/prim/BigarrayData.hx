package ml2hx.prim;

import ml2hx.rt.*;

// A bigarray: elements in a Haxe array (shared by sub-arrays and slices)
// from `offset`, row-major (C layout) or column-major (Fortran layout,
// indices from 1). Elements are the values of the kind's OCaml type: Float,
// Int63 (small ints), haxe.Int32, haxe.Int64, Int (char), Complex.t.
class BigarrayData<A, B, C> {
	public final kind:Any;
	public var layout:Any;
	public final dims:Array<Int>;
	public final data:Array<Dynamic>;
	public final offset:Int;

	public function new(kind:Any, layout:Any, dims:Array<Int>, data:Array<Dynamic>, offset:Int) {
		this.kind = kind;
		this.layout = layout;
		this.dims = dims;
		this.data = data;
		this.offset = offset;
	}

	public var fortran(get, never):Bool;
	inline function get_fortran():Bool return Type.enumIndex(cast layout) == 1;

	public function size():Int {
		var n = 1;
		for (d in dims) n *= d;
		return n;
	}

	// the element index of OCaml indices (bounds checked)
	public function index(ix:Array<Int63>):Int {
		if (ix.length != dims.length) throw new InvalidArgument("Bigarray.get/set: wrong number of indices");
		var k = 0;
		if (!fortran) {
			for (d in 0...dims.length) {
				var i = ix[d].toInt();
				if (Int63.lt(ix[d], Int63.zero) || i >= dims[d]) throw new InvalidArgument("index out of bounds");
				k = k * dims[d] + i;
			}
		} else {
			var d = dims.length - 1;
			while (d >= 0) {
				var i = ix[d].toInt() - 1;
				if (Int63.lt(ix[d], Int63.one) || i >= dims[d]) throw new InvalidArgument("index out of bounds");
				k = k * dims[d] + i;
				d--;
			}
		}
		return offset + k;
	}

	// a value stored as the kind stores it (wrapping small ints, rounding floats)
	public function normalize(v:Dynamic):Dynamic {
		return switch Type.enumConstructor(cast kind) {
			case "Float32": haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(v));
			case "Int8_signed": Int63.ofInt(((v : Int63).toInt64().low << 24) >> 24);
			case "Int8_unsigned": Int63.ofInt((v : Int63).toInt64().low & 0xFF);
			case "Int16_signed": Int63.ofInt(((v : Int63).toInt64().low << 16) >> 16);
			case "Int16_unsigned": Int63.ofInt((v : Int63).toInt64().low & 0xFFFF);
			case "Char": (v : Int) & 0xFF;
			case _: v;
		}
	}

	public static function zero(kind:Any):Dynamic {
		return switch Type.enumConstructor(cast kind) {
			case "Float32" | "Float64" | "Float16": 0.0;
			case "Int32": (0 : haxe.Int32);
			case "Int64" | "Nativeint": haxe.Int64.ofInt(0);
			case "Char": 0;
			case "Complex32" | "Complex64": null;
			case _: Int63.zero;
		}
	}

	public static function get<A, B, C>(a:BigarrayData<A, B, C>, ix:Array<Int63>):A return a.data[a.index(ix)];
	public static function set<A, B, C>(a:BigarrayData<A, B, C>, ix:Array<Int63>, v:A):Unit {
		a.data[a.index(ix)] = a.normalize(v);
		return Unit.value;
	}
	public static function dim<A, B, C>(a:BigarrayData<A, B, C>, n:Int):Int63 {
		if (n < 0 || n >= a.dims.length) throw new InvalidArgument("Bigarray.dim");
		return Int63.ofInt(a.dims[n]);
	}

}
