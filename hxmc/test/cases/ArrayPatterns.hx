// Array patterns on values that are not arrays but that `for` loops access
// by index (HaxeFoundation/haxe#13070, issue #8012): haxe.ds.Vector (hxmc's,
// over hxmc.NativeArray), an abstract with a `length` getter and
// @:arrayAccess, one whose `length` is private (a static get_length
// returning Int is what counts, as for loops have it), Null<Vector> subjects
// with and without `case null`, nesting, an enum argument, or-patterns,
// extractors and guards; Array alongside, unchanged. The golden file is the
// reference's --interp output.
import haxe.ds.Vector;

private abstract Pair<T>(Array<T>) {
	public inline function new(a:T, b:T)
		this = [a, b];

	public var length(get, never):Int;

	inline function get_length()
		return this.length;

	@:arrayAccess inline function get(i:Int):T
		return this[i];
}

private abstract Hidden(Array<Int>) {
	public inline function new(a:Array<Int>)
		this = a;

	var length(get, never):Int;

	inline function get_length()
		return this.length;

	@:arrayAccess inline function get(i:Int):Int
		return this[i];
}

private enum Wrapper {
	Wrap(v:Vector<Int>);
}

class ArrayPatterns {
	static function vec(a:Array<Int>)
		return Vector.fromArrayCopy(a);

	static function describe(v:Vector<Int>) {
		return switch v {
			case []: "empty";
			case [x]: 'one $x';
			case [1, y]: 'one-then $y';
			case [x, y] if (x > y): 'desc $x $y';
			case [x, y]: 'two $x $y';
			case _: 'many ${v.length}';
		}
	}

	static function describeArray(a:Array<Int>) {
		return switch a {
			case []: "empty";
			case [x]: 'one $x';
			case [x, y]: 'two $x $y';
			case _: 'many ${a.length}';
		}
	}

	static function nullable(v:Null<Vector<Int>>) {
		return switch v {
			case null: "null";
			case [a, b]: 'pair $a $b';
			case _: "other";
		}
	}

	static function nullableNoNullCase(v:Null<Vector<Int>>) {
		return switch v {
			case [a, b]: 'pair $a $b';
			case _: "other";
		}
	}

	static function first<T>(v:Vector<T>):Null<T> {
		return switch v {
			case [a] | [a, _]: a;
			case _: null;
		}
	}

	static function strings(v:Vector<String>) {
		return switch v {
			case ["a", rest]: 'a then $rest';
			case [s, "z"]: '$s then z';
			case [_, _]: "two strings";
			case _: "other";
		}
	}

	static function main() {
		for (a in [[], [5], [1, 7], [9, 3], [3, 9], [3, 9, 4]])
			Sys.println(describe(vec(a)) + " | " + describeArray(a));
		Sys.println(nullable(null));
		Sys.println(nullable(vec([1, 2])));
		Sys.println(nullable(vec([1])));
		Sys.println(nullableNoNullCase(null));
		Sys.println(nullableNoNullCase(vec([1, 2])));
		var nested = Vector.fromArrayCopy([vec([1]), vec([2, 3])]);
		Sys.println(switch nested {
			case [[a], [b, c]]: a + b + c;
			case _: -1;
		});
		Sys.println(switch Wrap(vec([4, 5])) {
			case Wrap([a, b]): a * b;
			case _: -1;
		});
		Sys.println(first(Vector.fromArrayCopy(["x"])));
		Sys.println(first(Vector.fromArrayCopy(["x", "y"])));
		Sys.println(first(Vector.fromArrayCopy(["x", "y", "z"])));
		Sys.println(switch vec([2, 3]) {
			case _.length => 2: "length two";
			case _: "other";
		});
		Sys.println(switch vec([2, 3]) {
			case [_ * 2 => 4, b]: 2 + b;
			case _: -1;
		});
		for (s in [["a", "b"], ["y", "z"], ["p", "q"], ["a"]])
			Sys.println(strings(Vector.fromArrayCopy(s)));
		var p = new Pair("a", "b");
		Sys.println(switch p {
			case [a, b]: a + b;
			case _: "";
		});
		Sys.println(switch p {
			case [a]: a;
			case _: "not one";
		});
		var h = new Hidden([6, 7]);
		Sys.println(switch h {
			case [a, b]: a * b;
			case _: -1;
		});
		var sum = 0;
		for (x in h)
			sum += x;
		Sys.println(sum);
	}
}
