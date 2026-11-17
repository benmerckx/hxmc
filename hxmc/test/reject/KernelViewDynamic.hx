// A view trusts its value's type (StrView reads a String's layout): a safe kernel passes it no Dynamic, nor a type parameter's value.
// expect: KernelViewDynamic.hx:13: KernelViewDynamic.length: a value of type Dynamic as a String (kernel: a view trusts its value's type: no Dynamic or type parameter where a typed GC value is expected)
// expect: KernelViewDynamic.hx:13: KernelViewDynamic.length: a value of type conv.T as a String (kernel: a view trusts its value's type: no Dynamic or type parameter where a typed GC value is expected)
// expect: KernelViewDynamic.hx:14: KernelViewDynamic.length: a value of type Dynamic as a StringBuf (kernel: a view trusts its value's type: no Dynamic or type parameter where a typed GC value is expected)
import hxmc.rt.StrBufView;
import hxmc.rt.StrView;

class KernelViewDynamic {
	@:hxmc.kernel static function conv<T>(x:Dynamic):T
		return x;

	@:hxmc.kernel static function length(d:Dynamic):Int {
		var n = StrView.length(d) + StrView.units1(conv(d))[0];
		return n + StrBufView.length(d);
	}

	static function main()
		trace(length("abc"));
}
