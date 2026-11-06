// Typing changes of the pin's move to 74c5b464e, executed: Std.string, string
// concatenation, interpolation and trace on abstracts with a toString
// (c19e08aa5, e077da883: an explicit Null<T> underlying type, the argument
// evaluated once, a @:multiType abstract), quoted field names in structures
// (27d1fbc58), properties redefined in a subclass (a843e700e) and compound
// assignment through @:arrayAccess functions without bodies (166a035d1).
abstract Named(String) from String {
	@:to public function toString():String return 'Named(' + this + ')';
}

abstract MaybeNamed(Null<String>) from Null<String> {
	@:to public function toString():String return this == null ? "nobody" : 'MaybeNamed(' + this + ')';
}

@:coreType abstract Slots from Array<Int> to Array<Int> {
	@:arrayAccess function get(i:Int):Int;
	@:arrayAccess function set(i:Int, v:Int):Int;
}

@:multiType(K) abstract Table<K, V>(haxe.Constraints.IMap<K, V>) {
	public function new();
	public inline function set(k:K, v:V) this.set(k, v);
	@:to static inline function toStringMap<K:String, V>(t:haxe.Constraints.IMap<K, V>):haxe.ds.StringMap<V> return new haxe.ds.StringMap<V>();
	@:to static inline function toIntMap<K:Int, V>(t:haxe.Constraints.IMap<K, V>):haxe.ds.IntMap<V> return new haxe.ds.IntMap<V>();
}

class Base {
	public var a(get, never):Int;
	public var b(default, null):Int = 2;
	function get_a() return 1;
	public function new() {}
}

class Child extends Base {
	override function get_a() return 10;
	public function new() super();
}

class Typing {
	static var calls = 0;
	static function named():Named {
		calls++;
		return "x";
	}
	static function maybe(s:Null<String>):MaybeNamed {
		calls++;
		return s;
	}

	static function main() {
		Sys.println(Std.string(named()) + " " + calls);
		Sys.println(Std.string(maybe(null)) + " " + calls);
		Sys.println(Std.string(maybe("y")) + " " + calls);
		var m:MaybeNamed = null;
		Sys.println("concat " + m);
		Sys.println('interpolated $m');
		var n:Null<Named> = null;
		Sys.println(Std.string(n));
		Sys.println("concat " + n);
		var t = new Table<String, Int>();
		t.set("a", 1);
		Sys.println(Std.string(t) != null);

		var o:{?"inline":Int, "class":String} = {"class": "c", "inline": 3};
		Sys.println(o."class" + " " + o."inline");
		var p:{var ?"default":Bool; final "override":Int;} = {"override": 1};
		Sys.println(p."default" + " " + p."override");
		o."inline" = 4;
		Sys.println(o."inline");
		var fields = Reflect.fields(o);
		fields.sort(Reflect.compare);
		Sys.println(fields);

		var c:Base = new Child();
		Sys.println(c.a + " " + c.b);

		var s:Slots = [1, 2, 3];
		s[1] += 5;
		s[2] *= 2;
		Sys.println((s : Array<Int>));
	}
}
