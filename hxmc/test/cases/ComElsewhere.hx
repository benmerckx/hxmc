import hxmc.com.*;

// COM on other systems than Windows (docs/interop.md, "COM"): code using
// it compiles for every target (its archive is one for every native
// target), and each operation throws a ComException (E_NOTIMPL) there: a
// call through an interface, a query, an IID, Com's functions; a Haxe class
// implementing an interface is a Haxe class only.
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A03}")
extern interface ICallback extends IUnknown {
	function Run(x:Int):Int;
	function Corner():Pt;
	@:hxmc.com.direct function Size():Pt;
	function Name():BStr;
}

@:hxmc.struct class Pt {
	public var x:Int;
	public var y:Int;

	public function new() {}
}

class Impl implements ICallback {
	public function new() {}

	public function Run(x:Int):Int
		return x + 1;

	public function Corner():Pt
		return new Pt();

	public function Size():Pt
		return new Pt();

	public function Name():BStr
		return "impl";
}

class ComElsewhere {
	static function attempt(what:String, f:() -> Void)
		try {
			f();
			trace(what, "no exception");
		} catch (e:ComException) {
			trace(what, ComException.hex(e.hresult), e.message);
		}

	static function main() {
		attempt("init", () -> Com.init());
		var i = new Impl();
		trace("a Haxe class", i.Run(1));
		var c:ICallback = i;
		attempt("call", () -> c.Run(2));
		attempt("struct", () -> c.Corner());
		attempt("direct struct", () -> c.Size());
		attempt("bstr", () -> c.Name());
		attempt("query", () -> Com.query(c, ICallback));
		attempt("cast", () -> cast(c, ICallback));
		attempt("iid", () -> Com.iidOf(ICallback));
		attempt("variant", () -> Variants.ofString("x"));
	}
}
