// Appends to a string in a loop (`s += x`, `s = s + x + y`) that nothing
// else in the loop reads: FnLower.appendLoop gives them a StringBuf (made at
// the second append) and s its string after the loop. Each loop's result
// against what the appends make one at a time: operands of every type and
// their conversions in order, a null start, no iteration, one, break,
// continue, return, nested loops, do-while, units above 0xFF, a try in the
// loop catching an exception between the operands of a chain; and the loops
// that keep concatenating (s read in the loop, captured by a closure, in a
// try). The loops run to `n`, a static the typer cannot unroll them by.
// The output is the reference's (--interp).
class Shown {
	public static var log:Array<String> = [];

	var n:Int;

	public function new(n)
		this.n = n;

	public function toString() {
		log.push("toString " + n);
		return "<" + n + ">";
	}
}

class StrAppendLoop {
	static var calls:Array<String> = [];
	static var n3 = 3;
	static var n4 = 4;
	static var n10 = 10;

	static function f(tag:String, v:Dynamic, boom = false):Dynamic {
		calls.push(tag);
		if (boom) throw "boom";
		return v;
	}

	static function words(n:Int):String {
		var s = "";
		for (i in 0...n)
			s += i % 7 == 0 ? "lorem " : "ipsum ";
		return s;
	}

	static function kinds():String {
		var s = "k:";
		var o:Dynamic = {a: 1};
		for (i in 0...n3) {
			s += i;
			s += 0.5 + i;
			s += i == 1;
			s += null;
			s += [i];
			s += new Shown(i);
			s += 'x$i';
		}
		return s;
	}

	static function nullStart(n:Int):String {
		var s:String = null;
		for (i in 0...n)
			s += "a";
		return s;
	}

	static function chains():String {
		var s = "c";
		var i = 0;
		while (i < 4) {
			s = s + i + "-" + (i * 2) + ";";
			i++;
		}
		return s;
	}

	static function control():String {
		var s = "";
		for (i in 0...20) {
			if (i == 15) break;
			if (i % 3 == 0) continue;
			s += i + ",";
		}
		return s;
	}

	static function early(stop:Int):String {
		var s = "e";
		for (i in 0...n10) {
			if (i == stop) return "returned at " + i;
			s += i;
		}
		return s;
	}

	static function nested():String {
		var s = "";
		for (i in 0...n3) {
			s += "[";
			for (j in 0...i + 1)
				s += j;
			s += "]";
		}
		var t = "";
		for (i in 0...n3) {
			var u = "";
			for (j in 0...n3)
				u += i * j;
			t += u + "/";
		}
		return s + " " + t;
	}

	static function doWhile():String {
		var s = "d";
		var i = 0;
		do {
			s += i++;
		} while (i < 5);
		return s;
	}

	static function wide():String {
		var s = "é";
		for (i in 0...n4)
			s += i % 2 == 0 ? "ab" : "€";
		var t = "";
		for (i in 0...n3)
			t += String.fromCharCode(0x41 + i) + String.fromCharCode(0x3B1 + i);
		return s + " " + s.length + " " + t + " " + t.length + " " + t.charCodeAt(1);
	}

	static function caught():String {
		var s = "t";
		for (i in 0...n4) {
			try {
				s = s + f("a" + i, i) + f("b" + i, i, i == 2);
			} catch (e:String) {
				s += "!";
			}
		}
		return s + " " + calls.join(",");
	}

	static function readInLoop():String {
		var s = "";
		while (s.length < 10)
			s += "ab";
		return s;
	}

	static function captured():String {
		var s = "";
		var get = () -> s;
		for (i in 0...n3)
			s += i;
		return s + " " + get();
	}

	static function inTry():String {
		var s = "";
		try {
			for (i in 0...n10) {
				if (i == 3) throw "stop";
				s += i;
			}
		} catch (e:String) {
			s += e;
		}
		return s;
	}

	static function reassigned():String {
		var s = "";
		for (i in 0...n10) {
			if (i == 3) s = "reset";
			s += i;
		}
		return s;
	}

	static function main() {
		var w = words(30000);
		var n = 0;
		for (x in w.split(" "))
			if (x.length > 0) n++;
		trace(w.length + " " + n + " " + w.substr(0, 18) + " " + StringTools.fastCodeAt(w, w.length - 2));
		trace(kinds());
		trace(Shown.log.join(","));
		trace(nullStart(0) + " " + nullStart(1) + " " + nullStart(3));
		trace(chains());
		trace(control());
		trace(early(4) + " " + early(20) + " " + early(0));
		trace(nested());
		trace(doWhile());
		trace(wide());
		trace(caught());
		trace(readInLoop());
		trace(captured());
		trace(inTry());
		trace(reassigned());
		trace(words(0) == "" ? "empty" : "not empty");
	}
}
