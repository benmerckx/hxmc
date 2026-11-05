// A COM interface extends one COM interface: its vtable extends one.
// target: windows-x86_64
// expect: COM interface IBoth extends I
// expect: a COM interface has one base (its vtable extends one)
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A0A}")
extern interface IA extends hxmc.com.IUnknown {
	function A():Void;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A0B}")
extern interface IB extends hxmc.com.IUnknown {
	function B():Void;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A0C}")
extern interface IBoth extends IA extends IB {}

class ComTwoBases {
	static function main() {
		var c:IBoth = null;
		c.A();
	}
}
