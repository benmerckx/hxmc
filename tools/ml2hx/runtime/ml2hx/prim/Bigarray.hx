package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.BigarrayModule.BigarrayKind;
import ocaml.stdlib.BigarrayModule.BigarrayLayout;

// OCaml's bigarray.c over BigarrayData.
class Bigarray {
	public static function camlBaCreate<A, B, C>(kind:BigarrayKind<A, B>, layout:BigarrayLayout<C>, dims:Array<Int63>):BigarrayData<A, B, C> {
		var ds = [];
		for (d in dims) {
			if (Int63.lt(d, Int63.zero) || Int63.gt(d, Int63.ofInt(0x7FFFFFFF))) throw new InvalidArgument("Bigarray.create: negative dimension");
			ds.push(d.toInt());
		}
		var n = 1;
		for (d in ds) n *= d;
		var z = BigarrayData.zero(kind);
		return new BigarrayData(kind, layout, ds, [for (_ in 0...n) z], 0);
	}
	public static function camlBaDim<A, B, C>(a:BigarrayData<A, B, C>, n:Int63):Int63 return BigarrayData.dim(a, n.toInt());
	public static function camlBaNumDims<A, B, C>(a:BigarrayData<A, B, C>):Int63 return Int63.ofInt(a.dims.length);
	public static function camlBaKind<A, B, C>(a:BigarrayData<A, B, C>):BigarrayKind<A, B> return cast a.kind;
	public static function camlBaLayout<A, B, C>(a:BigarrayData<A, B, C>):BigarrayLayout<C> return cast a.layout;
	public static function camlBaChangeLayout<A, B, C, D>(a:BigarrayData<A, B, C>, l:BigarrayLayout<D>):BigarrayData<A, B, D> {
		if (Type.enumIndex(l) == Type.enumIndex(cast a.layout)) return cast a;
		var ds = a.dims.copy();
		ds.reverse();
		return new BigarrayData(a.kind, l, ds, a.data, a.offset);
	}
	public static function camlBaFill<A, B, C>(a:BigarrayData<A, B, C>, v:A):Unit {
		var x = a.normalize(v);
		for (k in 0...a.size()) a.data[a.offset + k] = x;
		return Unit.value;
	}
	public static function camlBaBlit<A, B, C>(src:BigarrayData<A, B, C>, dst:BigarrayData<A, B, C>):Unit {
		if (src.dims.join(",") != dst.dims.join(",")) throw new InvalidArgument("Bigarray.blit: dimension mismatch");
		var n = src.size();
		var tmp = src.data.slice(src.offset, src.offset + n);
		for (k in 0...n) dst.data[dst.offset + k] = tmp[k];
		return Unit.value;
	}
	// sub on the first dimension (C) or the last (Fortran)
	public static function camlBaSub<A, B, C>(a:BigarrayData<A, B, C>, ofs:Int63, len:Int63):BigarrayData<A, B, C> {
		var o = ofs.toInt(), l = len.toInt();
		var ds = a.dims.copy();
		if (!a.fortran) {
			if (o < 0 || l < 0 || o + l > ds[0]) throw new InvalidArgument("Bigarray.sub: bad sub-array");
			var inner = 1;
			for (d in 1...ds.length) inner *= ds[d];
			ds[0] = l;
			return new BigarrayData(a.kind, a.layout, ds, a.data, a.offset + o * inner);
		}
		var last = ds.length - 1;
		o -= 1;
		if (o < 0 || l < 0 || o + l > ds[last]) throw new InvalidArgument("Bigarray.sub: bad sub-array");
		var inner = 1;
		for (d in 0...last) inner *= ds[d];
		ds[last] = l;
		return new BigarrayData(a.kind, a.layout, ds, a.data, a.offset + o * inner);
	}
	// slice: fix the leading (C) or trailing (Fortran) indices
	public static function camlBaSlice<A, B, C>(a:BigarrayData<A, B, C>, ix:Array<Int63>):BigarrayData<A, B, C> {
		var n = ix.length;
		if (n > a.dims.length) throw new InvalidArgument("Bigarray.slice: too many indices");
		if (!a.fortran) {
			var full = ix.concat([for (_ in n...a.dims.length) Int63.zero]);
			return new BigarrayData(a.kind, a.layout, a.dims.slice(n), a.data, a.index(full));
		}
		var full = [for (_ in 0...a.dims.length - n) Int63.one].concat(ix);
		return new BigarrayData(a.kind, a.layout, a.dims.slice(0, a.dims.length - n), a.data, a.index(full));
	}
	public static function camlBaGetGeneric<A, B, C>(a:BigarrayData<A, B, C>, ix:Array<Int63>):A return BigarrayData.get(a, ix);
	public static function camlBaSetGeneric<A, B, C>(a:BigarrayData<A, B, C>, ix:Array<Int63>, v:A):Unit return BigarrayData.set(a, ix, v);
	public static function camlBaReshape<A, B, C>(a:BigarrayData<A, B, C>, dims:Array<Int63>):BigarrayData<A, B, C> {
		var ds = [for (d in dims) d.toInt()];
		var n = 1;
		for (d in ds) n *= d;
		if (n != a.size()) throw new InvalidArgument("Bigarray.reshape: size mismatch");
		return new BigarrayData(a.kind, a.layout, ds, a.data, a.offset);
	}
	// symbols bigarray.ml mentions only to keep them linked (never called)
	public static function camlBaGet_1(_:Unit):Unit return Unit.value;
	public static function camlBaGet_2(_:Unit):Unit return Unit.value;
	public static function camlBaGet_3(_:Unit):Unit return Unit.value;
	public static function camlBaSet_1(_:Unit):Unit return Unit.value;
	public static function camlBaSet_2(_:Unit):Unit return Unit.value;
	public static function camlBaSet_3(_:Unit):Unit return Unit.value;
}
