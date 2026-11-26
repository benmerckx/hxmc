// not-live: Unmade.poke
// A type test makes no instance of its class. Std.isOfType's class, and the
// tests a dispatched call missing an argument makes of its receiver (each
// implementation's default: FnLower.receiverDefault), are read for their
// type index only, so a class no live code makes keeps its methods out even
// with Type.createEmptyInstance live (which makes those whose class value
// live code has): helder's canvas linked its web back end's wasm imports
// into native programs through such a test.
interface Drawer {
	function draw(n:Int = 1):String;
}

class Made implements Drawer {
	public function new() {}

	public function draw(n = 1):String
		return "made " + n;
}

class Unmade implements Drawer {
	public function new() {}

	public function draw(n = 2):String
		return poke() + n;

	public function poke():String
		return "never";
}

class Empty {
	public var x:Int;
}

class TypeTestReach {
	static function main() {
		var d:Drawer = new Made();
		Sys.println(d.draw());
		Sys.println(Std.isOfType(d, Unmade));
		Sys.println(Type.createEmptyInstance(Empty) != null);
	}
}
