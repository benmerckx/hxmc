import H;
import p.M1;
import p.q.M2;
using p.Ext;
using StringTools;

abstract A5(Int) from Int to Int {
	public inline function new(i:Int)
		this = i;

	public function get():Int
		return this;

	public var twice(get, never):Int;

	function get_twice():Int
		return this * 2;

	@:op(A + B) public static function add(a:A5, b:A5):A5
		return new A5(a.get() + b.get());

	@:op(A * B) public static function mul(a:A5, b:A5):A5
		return new A5(a.get() * b.get());

	@:op(-A) public static function neg(a:A5):A5
		return new A5(-a.get());
}

enum abstract K6(Int) to Int {
	var K6A = 1;
	var K6B = 4;
	var K6C = 7;
	var K6D = 10;
}

class Main {
	public static inline function fn7(...r8:Int):Int {
		return (new Box<Int>(Reflect.compare(23, 8))).value;
	}
	public static function fn9():String {
		return (StringTools.trim(StringTools.hex((92) & 0xFFFF, 4))).replace("a", "b");
	}
	public static function fn10(a11:Box<String>, a12:Bool, a13:Bool):String {
		var v77:Int = 0x884E;
		return StringTools.lpad((switch (({x1: 286, x2: v77} : S0)) {
			case {x1: c87}: Std.string(126);
		}), "*", (Lambda.fold(([] : Array<Int>), (v88:Int, v89:Int) -> ("  pad  ").indexOf(""), 0) & 7));
	}
	public static function fn14(a15:Int, a16:Int, a17:Int):Int {
		return (a15 - a15);
	}
	public static function fn18(a19:String, a20:S0, a21:Null<Int>):Bool {
		var v103:Int = (-1077658044);
		switch (((new A5(v103)).get() + v103)) {
			case c123 if (c123 > 10): {
				H.out("o124 " + Std.string((a19).lastIndexOf(a19)));
			};
		}
		return false;
	}
	public static function fn22():String {
		return ((true ? StringTools.contains("  pad  ", "\\") : true) + StringTools.hex((("é").length) & 0xFFFF, 4));
	}
	public static function fn23(a24:Int, a25:Bool, a26:Bool):Void {
		var v135 = a24;
		var v137 = Main.fn18(Std.string(a26), ({x1: a24, x2: 288} : S0), v135);
	}
	public static function section0():Void {}
	public static function section1():Void {
		var v188:String = fn9();
		var v189:Int = (switch (("q").lastIndexOf(v188)) {
			case _: 44;
		});
		fn23(1, true, false);
	}
	public static function main():Void {
		H.out("start");
		section1();
	}
}
