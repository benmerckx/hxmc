// A COM method's parameters are what C passes: a Haxe function is none.
// target: windows-x86_64
// expect: COM method Run: the parameter f has no C type a call can pass
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A03}")
extern interface ICallback extends hxmc.com.IUnknown {
	function Run(f:Int->Int):Int;
}

class ComBadType {
	static function main() {
		var c:ICallback = null;
		trace(c.Run(x -> x));
	}
}
