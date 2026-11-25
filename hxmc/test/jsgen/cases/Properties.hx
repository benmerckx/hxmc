// properties (their accessors are methods, docs/js.md): read-only and read-write ones, a setter whose result differs
// from its argument, overrides of one accessor, calls through `super`, statics, interfaces, structures, closures of
// accessors, reflection (Reflect.getProperty, $hx.properties), compound assignment
interface Named {
	var name(get, never):String;
}

typedef HasLabel = {
	var label(get, never):String;
}

class Box implements Named {
	var stored = 0;

	public var name(get, never):String;
	public var size(get, set):Int;
	public var label(get, never):String;

	public function new() {}

	function get_name() return "box";

	function get_size() return stored;

	// (clamped: `a = box.size = 200` is 100)
	function set_size(v:Int) {
		stored = v > 100 ? 100 : v;
		return stored;
	}

	function get_label() return "box of " + size;
}

class BigBox extends Box {
	override function get_name() return "big " + super.get_name();

	// (only the getter: the setter is Box's)
	override function get_size() return super.get_size() * 2;
}

class Counter implements Named {
	public var name(get, never):String;
	public var count(get, set):Int;

	var n = 0;

	public function new() {}

	function get_name() return "counter";

	public function get_count() return n;

	public function set_count(v:Int) return n = v;
}

class Settings {
	static var level = 1;

	public static var mode(get, set):String;

	static function get_mode() return "mode" + level;

	static function set_mode(v:String) {
		level = v.length;
		return v;
	}
}

class Properties {
	static function names(l:Array<Named>) return [for (n in l) n.name].join(",");

	static function labelOf(o:HasLabel) return o.label;

	static function main() {
		var box = new Box();
		box.size = 5;
		trace(box.size, box.name, box.label);
		var a = box.size = 200;
		trace(a, box.size);
		box.size += 3;
		trace(box.size);

		var big = new BigBox();
		big.size = 7;
		trace(big.size, big.name);
		big.size++;
		trace(big.size);

		var c = new Counter();
		c.count = 3;
		var get = c.get_count;
		trace(get(), c.count);

		trace(names([box, big, c]));
		trace(labelOf(box));

		Settings.mode = "abc";
		trace(Settings.mode);

		trace(Reflect.getProperty(box, "size"));
		Reflect.setProperty(box, "size", 42);
		trace(box.size);
	}
}
