// Null access (docs/hxmc.md, "Null access"): reading or writing through a
// null reference throws "Null Access" (the native targets: their fault
// handler, hxmc.rt.Faults; WebAssembly: explicit tests), which try/catch
// catches as any exception: fields, arrays, strings, enums, structures,
// closures, interfaces, Dynamic, Vector, Bytes, maps; in the function of the
// try with no call in its body, and deep below it, with collections right
// after (a 64 KB nursery: the handler's references must have been rooted);
// then one nothing catches (exit 1, the message on stderr).
// The reference's --interp prints the same but where Eval words it
// otherwise: "field access on null" for the field reads of class instances
// and structures and String's length, "Cannot call null" for a null
// function (and a method of null as a value); a Dynamic field read of null
// is null there, and a method of null that does not read `this` throws.
interface Shape {
	function area():Int;
	var sides(get, never):Int;
}

class Square implements Shape {
	public var side:Int;
	public var sides(get, never):Int;

	public function new(s:Int)
		side = s;

	function get_sides()
		return 4;

	public function area()
		return side * side;
}

class Node {
	public var value:Int;
	public var weight:Float;
	public var name:String;
	public var next:Node;

	public function new(v:Int) {
		value = v;
		weight = v / 2;
		name = "n" + v;
	}

	public function describe()
		return name + "=" + value;

	public function constant()
		return 7;

	public dynamic function dyn()
		return value;
}

class Child extends Node {
	override public function describe()
		return "child " + super.describe();
}

enum Tree {
	Leaf;
	Branch(l:Tree, v:Int, r:Tree);
}

typedef Point = {x:Int, y:Int, ?label:String}

class NullAccess {
	static var sink:Dynamic;

	// null, which no optimizer sees through (the program has no arguments)
	static function nul<T>(v:T):T
		return Sys.args().length > 99 ? v : null;

	static function check(what:String, f:Void->Dynamic) {
		try {
			var v:Dynamic = f();
			Sys.println(what + ": " + v);
		} catch (e:String) {
			Sys.println(what + ": caught " + e);
		}
	}

	static function arrays() {
		Sys.println("-- arrays");
		var a:Array<Int> = nul([1, 2]);
		check("a[0]", () -> a[0]);
		check("a[1] = 5", () -> a[1] = 5);
		check("a.length", () -> a.length);
		check("a.push(3)", () -> a.push(3));
		check("a.pop()", () -> a.pop());
		check("a.indexOf(2)", () -> a.indexOf(2));
		check("a.copy()", () -> a.copy());
		check("a.join", () -> a.join(","));
		check("a[0] += 1", () -> a[0] += 1);
		check("for in", () -> {
			var t = 0;
			for (x in a)
				t += x;
			t;
		});
		var s:Array<String> = nul(["x"]);
		check("s[0].length", () -> s[0].length);
		var ok = [nul("y")];
		check("[null][0].length", () -> ok[0].length);
	}

	static function strings() {
		Sys.println("-- strings");
		var s:String = nul("abc");
		check("s.length", () -> s.length);
		check("s.charCodeAt(0)", () -> s.charCodeAt(0));
		check("fastCodeAt", () -> StringTools.fastCodeAt(s, 0));
		check("s.charAt(1)", () -> s.charAt(1));
		check("s.substr(1)", () -> s.substr(1));
		check("s.indexOf", () -> s.indexOf("b"));
		check("s.split", () -> s.split(","));
		check("s.toUpperCase()", () -> s.toUpperCase());
		// (no access: null is printed)
		check("s + x", () -> s + "x");
		check("Std.string(s)", () -> Std.string(s));
		check("s == null", () -> s == null);
	}

	static function objects() {
		Sys.println("-- objects");
		var n:Node = nul(new Node(1));
		check("n.value", () -> n.value);
		check("n.weight", () -> n.weight);
		check("n.name", () -> n.name);
		check("n.next", () -> n.next);
		check("n.value = 2", () -> n.value = 2);
		check("n.name = x", () -> n.name = "x");
		check("n.describe()", () -> n.describe());
		check("n.dyn()", () -> n.dyn());
		var c:Node = nul(new Child(2));
		check("c.describe()", () -> c.describe());
		var m = new Node(3);
		check("m.next.value", () -> m.next.value);
		check("m.next.next", () -> m.next.next);
		m.next = new Node(4);
		check("m.next.next.name", () -> m.next.next.name);
		check("m.next.value", () -> m.next.value);
		// (a method that does not read `this`: it runs, on every hxmc target)
		check("n.constant()", () -> n.constant());
	}

	static function interfaces() {
		Sys.println("-- interfaces");
		var sh:Shape = nul(new Square(2));
		check("sh.area()", () -> sh.area());
		check("sh.sides", () -> sh.sides);
		var ok:Shape = new Square(3);
		check("ok.area()", () -> ok.area());
	}

	static function enums() {
		Sys.println("-- enums");
		var t:Tree = nul(Leaf);
		check("switch", () -> switch t {
			case Leaf: 0;
			case Branch(_, v, _): v;
		});
		check("t.match(Leaf)", () -> t.match(Leaf));
		check("Type.enumIndex", () -> Type.enumIndex(t));
		check("Type.enumParameters", () -> Type.enumParameters(t));
		check("t == Leaf", () -> t == Leaf);
		var b = Branch(nul(Leaf), 1, Leaf);
		check("nested", () -> switch b {
			case Branch(l, _, _): switch l {
					case Leaf: "leaf";
					case Branch(_, v, _): "branch " + v;
				}
			case Leaf: "none";
		});
	}

	static function structures() {
		Sys.println("-- structures");
		var p:Point = nul({x: 1, y: 2});
		check("p.x", () -> p.x);
		check("p.y = 3", () -> p.y = 3);
		check("p.label", () -> p.label);
		var q:{value:Int} = nul(new Node(5));
		check("q.value", () -> q.value);
	}

	static function functions() {
		Sys.println("-- functions");
		var f:Void->Int = nul(() -> 1);
		check("f()", () -> f());
		var g:Int->Int = nul(x -> x + 1);
		check("g(1)", () -> g(1));
		var o:{f:Void->Int} = {f: nul(() -> 2)};
		check("o.f()", () -> o.f());
	}

	static function dynamics() {
		Sys.println("-- dynamic");
		var d:Dynamic = nul({x: 1});
		check("d.x", () -> d.x);
		check("d.x = 1", () -> d.x = 1);
		check("d[0]", () -> d[0]);
		check("d[0] = 1", () -> d[0] = 1);
		check("d.f()", () -> d.f());
		check("d()", () -> d());
		check("d.length", () -> d.length);
		check("Reflect.field", () -> Reflect.field(d, "x"));
		check("Reflect.setField", () -> {
			Reflect.setField(d, "x", 1);
			"set";
		});
	}

	static function library() {
		Sys.println("-- library");
		var v:haxe.ds.Vector<Int> = nul(new haxe.ds.Vector(2));
		check("v[0]", () -> v[0]);
		check("v[1] = 1", () -> v[1] = 1);
		check("v.length", () -> v.length);
		var b:haxe.io.Bytes = nul(haxe.io.Bytes.alloc(2));
		check("b.get(0)", () -> b.get(0));
		check("b.length", () -> b.length);
		var m:Map<String, Int> = nul(["a" => 1]);
		check("m.get(a)", () -> m.get("a"));
		check("m[a] = 2", () -> m["a"] = 2);
		check("m.exists(a)", () -> m.exists("a"));
		var sb:StringBuf = nul(new StringBuf());
		check("sb.add", () -> {
			sb.add("x");
			"added";
		});
		check("sb.toString()", () -> sb.toString());
	}

	// a closure reading through null, called from deeper down
	static function call(f:Void->Int):Int
		return f() + 1;

	static function closures() {
		Sys.println("-- closures");
		var n:Node = nul(new Node(6));
		var read = () -> n.value * 2;
		check("in a closure", () -> call(read));
		var nested = () -> call(() -> call(() -> n.next.value));
		check("nested", () -> nested());
	}

	// what the handler reads must survive the collections after the throw: the
	// try body makes no call (no GC point), the fault is its only way out
	static function direct() {
		Sys.println("-- direct");
		var keep = [for (i in 0...50) new Node(i)];
		var a:Array<Int> = nul([1]);
		var caught = 0, bad = 0;
		for (round in 0...300) {
			var fresh = new Node(round);
			var label = "r" + round;
			try {
				sink = a.length;
				label = "not thrown";
			} catch (e:String) {
				caught++;
				// garbage: collections move what is live here
				var junk = [for (j in 0...60) new Node(j)];
				sink = junk;
			}
			if (fresh.value != round || fresh.name != "n" + round || label != "r" + round || keep[round % 50].name != "n" + (round % 50)) bad++;
		}
		Sys.println("caught " + caught + ", bad " + bad + ", keep " + keep.length + " " + keep[49].describe());
	}

	static function deep(k:Int, n:Node):Int {
		if (k == 0) return n.value;
		var local = [new Node(k)];
		return deep(k - 1, n) + local[0].value;
	}

	static function deeper() {
		Sys.println("-- deep");
		var survivors = [];
		var total = 0;
		for (k in 0...120) {
			var mine = new Node(k);
			try {
				total += deep(12, k % 3 == 0 ? new Node(k) : nul(new Node(k)));
				survivors.push(mine);
			} catch (e:String) {
				// more work after the catch: allocations, a second throw caught here
				var junk = [for (j in 0...40) "j" + j + mine.name];
				sink = junk;
				try {
					var again:Array<Node> = nul([mine]);
					total += again[0].value;
				} catch (e2:String) {
					total -= 1;
				}
				survivors.push(new Node(-k));
			}
		}
		var sum = 0;
		for (s in survivors)
			sum += s.value;
		Sys.println("total " + total + ", survivors " + survivors.length + ", sum " + sum + ", last " + survivors[survivors.length - 1].describe());
	}

	static function main() {
		arrays();
		strings();
		objects();
		interfaces();
		enums();
		structures();
		functions();
		dynamics();
		library();
		closures();
		direct();
		deeper();
		Sys.println("-- uncaught");
		var n:Node = nul(new Node(9));
		Sys.println(n.value);
		Sys.println("not reached");
	}
}
