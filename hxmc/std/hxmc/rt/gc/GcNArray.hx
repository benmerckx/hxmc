package hxmc.rt.gc;

import hxmc.I64;
import hxmc.rt.Types.*;

// -D hxmc.wasm-gc: hxmc.NativeArray, as hxmc.rt.NArray. A NativeArray of a
// known element type is the bare WasmGC array of its kind (i32, f64, i64,
// eqref; Bool i8: GcModule.naType), made, read and written by the
// generated code (hxmc.wasmgc.FuncGen.narray); its empty array is one global
// per kind. A NativeArray seen as Dynamic (Dynamic, Any, an erased type
// parameter) goes through these functions and W.na*, by the kind of its
// storage.
//
// A NativeArray made for an erased type parameter (`new NativeArray<T>` in
// generic code) is a wrapper of reference storage, as NArray's: the first
// typed view to take it gets that storage, converted to the view's kind if
// it differs (once), and fixes the wrapper on it, so that the generic code
// and the typed code share it; a later view of another kind is an error.
@:keep @:hxmc.wasmgc
class GcNArray {
	@:hxmc.host("hx_narray_open") static function open(n:Int):Dynamic {
		if (n < 0 || n > 0x0FFFFFFD) badLength();
		if (n == 0) return W.naNew(AK_PTR, 0);
		return W.naWrap(W.naNew(AK_PTR, n));
	}

	@:hxmc.host("hxmc_NativeArray_copy") static function copy(a:Dynamic):Dynamic {
		var s = W.naStorage(a), n = W.naLen(s);
		if (n == 0) return a;
		var r = W.naNew(W.naKind(s), n);
		W.naCopy(r, 0, s, 0, n);
		// (an open wrapper's copy is open too)
		return W.naKind(a) == AK_OPEN ? W.naWrap(r) : r;
	}

	@:hxmc.export("hx_narray_bad_length") static function badLength():Void
		throw "Invalid NativeArray length";

	// the error of index i of an array of length n, at the position of the
	// access (FnLower.outOfBounds: -D hxmc.native-array-outofbounds=throws);
	// no file: unknown (Dynamic access)
	@:hxmc.host("hx_narray_oob") public static function outOfBounds(i:Int, n:Int, file:Null<String>, line:Int, cls:Null<String>, method:Null<String>):Dynamic {
		var pos:haxe.PosInfos = file == null ? null : {fileName: file, lineNumber: line, className: cls, methodName: method};
		return new haxe.exceptions.ArgumentException("index", 'Index $i out of bounds for length $n', null, pos);
	}

	// the default of a's elements, by its storage's kind, as a read out of
	// bounds gives it through a Dynamic-typed view (FnLower.nativeRead, GcDyn:
	// -D hxmc.native-array-outofbounds=silent)
	@:hxmc.host("hx_narray_default") public static function defaultOf(a:Dynamic):Dynamic {
		var zero:I64 = 0;
		return switch W.naKind(W.naStorage(a)) {
			case AK_BOOL: (false : Dynamic);
			case AK_I32: (0 : Dynamic);
			case AK_F64: (0.0 : Dynamic);
			case AK_I64: (zero : Dynamic);
			case _: null;
		}
	}

	// a (a NativeArray, or a Dynamic) taken by a typed view of kind k
	@:hxmc.host("hx_narray_view") static function view(a:Dynamic, k:Int):Dynamic {
		if (a == null) return null;
		var ak = W.naKind(a);
		if (ak < 0) throw "Invalid cast to NativeArray";
		if (ak == k) return a;
		var s = W.naStorage(a), n = W.naLen(s);
		if (n == 0) return W.naNew(k, 0);
		if (ak == AK_OPEN) {
			if (k != AK_PTR) {
				var d = W.naNew(k, n);
				for (i in 0...n)
					set(d, i, W.naGet(s, i));
				W.naSetStorage(a, d);
				s = d;
			}
			W.naFix(a);
			return s;
		}
		if (ak == AK_WRAP && W.naKind(s) == k) return s;
		throw "NativeArray storage type mismatch";
	}

	// the slow path of a write of a NativeArray seen as Dynamic (FuncGen.narray:
	// storage of references is written inline, reads are W.naGet's)
	@:hxmc.export("hx_narray_set_slow") static function setSlow(a:Dynamic, i:Int, value:Dynamic):Void
		set(a, i, value);

	public static function set(a:Dynamic, i:Int, value:Dynamic):Void {
		var s = W.naStorage(a);
		var kind = W.naKind(s);
		if (kind != AK_PTR) {
			// (null, Int and Bool into any kind, Float into Float, Int64 into Int64: W.kind)
			var t = W.kind(value);
			if (t != 0 && t != 1 && t != 3 && !(kind == AK_F64 && t == 2) && !(kind == AK_I64 && t == 9))
				throw "NativeArray element type mismatch";
		}
		W.naSet(s, i, value);
	}
}
