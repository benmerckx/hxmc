// a + b + c...: joined at once (hx_str_concat3, 4); the operands evaluated
// and converted in the order a chain of binary + does it.
class StringChains {
	static var log = [];

	static function f(s:String):String {
		log.push(s);
		return s;
	}

	static function main() {
		var a = "a", b = "bb", c = "", d:String = null, i = 42, x = 1.5, t = true;
		Sys.println(a + b + c);
		Sys.println(a + b + c + a);
		Sys.println(a + b + c + a + b);
		Sys.println(a + b + a + b + a + b + a);
		Sys.println(a + b + a + b + a + b + a + b);
		Sys.println(a + d + b + d);
		Sys.println(c + c + c);
		Sys.println(i + a + x + t + i);
		Sys.println(1 + 2 + a + 1 + 2);
		Sys.println(a + (1 + 2) + (b + c) + i);
		Sys.println(f("1") + f("2") + f("3") + f("4") + f("5"));
		Sys.println(log.join(","));
		// a later operand assigning an earlier one's local
		var s = "x";
		Sys.println(s + s + (s = "y") + s);
		var n = 1;
		Sys.println(n + "|" + (n++) + "|" + n);
		// an object changed by a later operand
		var o = [1];
		Sys.println(o + grow(o, 2) + o + grow(o, 3) + o);
		var dyn:Dynamic = [1, 2];
		Sys.println("d" + dyn + null + "e");
		var acc = "";
		for (k in 0...3)
			acc = acc + k + ",";
		Sys.println(acc);
	}

	static function grow(o:Array<Int>, v:Int):String {
		o.push(v);
		return "-";
	}
}
