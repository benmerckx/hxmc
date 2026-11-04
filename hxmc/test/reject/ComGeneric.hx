// A generic class cannot implement a COM interface: its vtables are one class's.
// target: windows-x86_64
// expect: ComGeneric implements a COM interface: a generic class cannot
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A03}")
extern interface ICallback extends hxmc.com.IUnknown {
	function Run(x:Int):Int;
}

class ComGeneric<T> implements ICallback {
	public function new() {}

	public function Run(x:Int):Int
		return x;

	static function main() {
		var c:ICallback = new ComGeneric<Int>();
		trace(c.Run(1));
	}
}
