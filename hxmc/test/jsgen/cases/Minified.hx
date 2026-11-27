// what -D hxmc.js.minify must keep (bundled-min): untyped code that names a
// local or a type by its name, the tokens whose spaces and line breaks matter
// (in a split's file too)
class Named {
	public function new() {}

	public function hi() return "named";
}

// local functions as arrows, `_gthis` as `this` where only arrows use it
class Captures {
	var v = 10;

	public function new() {}

	public function run() {
		var later = [];
		function add(x:Int) return v + x;
		later.push(() -> trace("arrow " + add(1)));
		// (nested arrows, one that returns an object)
		later.push(() -> {
			var inner = () -> ({x: v} : {x:Int});
			trace("nested " + inner().x);
		});
		// (one that needs its own this: a function, so _gthis stays)
		later.push(function() {
			var self:Dynamic = js.Lib.nativeThis;
			trace("own this " + (self == null) + " " + v);
		});
		var f:Void->Int = null;
		var g = f != null ? f : () -> v * 2;
		trace("or " + g());
		trace("called " + (() -> v + 3)());
		trace("value " + {
			var k = v;
			(() -> k + v)();
		});
		trace(true + " " + (true : Dynamic).toString());
		for (l in later) l();
		return js.Bundle.split("captures", () -> v + 1);
	}

	// (only arrows: no _gthis)
	public function onlyArrows() {
		return [1, 2].map(x -> () -> x * v).map(f -> f() + v);
	}

	public function args() {
		var f = function(a:Int) return js.Syntax.code("arguments.length") + a;
		return f(1);
	}
}

class Minified {
	// (the generator's own tokens that must not merge)
	static function tokens(a:Int, b:Int) {
		var i = a;
		trace(a - -b, a + -b, i-- - -b, i++ + b, i > -1, a < -b, 1 - - - a, "a  b" + ' c ');
	}

	static function main() {
		tokens(3, 2);
		var c = new Captures();
		var first = c.run().then(v -> trace("split " + v));
		trace("args " + c.args());
		trace("arrows " + c.onlyArrows());
		var counter = 1;
		trace(new Named().hi());
		trace(js.Syntax.code("counter + 1"));
		trace(js.Syntax.code("new Named().hi()"));
		trace(js.Syntax.code("(function() { var a = 3, b = 2; return a - -b; })()"));
		trace(js.Syntax.code("(function() { var a = 1, b = 2; return a++ + +b + a; })()"));
		trace(js.Syntax.code("(function() { var a = 7; return a / 2 / 1; })()"));
		trace(js.Syntax.code("(function() { return /a\\/b[/]c/.test('a/b/c') + ' ' + '//not a comment' + \"/* nor */\"; })()"));
		trace(js.Syntax.code("(function() { var x = 2; return `t${x + `in${'}'}`}t`; })()"));
		trace(js.Syntax.code("(function() { var a = 1\n var b = 2\n return a\n + b; })()"));
		trace(js.Syntax.code("(1).toString() + 2 .toString()"));
		// (after the first split: the order of their output fixed)
		first.then(_ -> js.Bundle.split("minified", () -> {
			var inSplit = counter + 1;
			trace(js.Syntax.code("inSplit * 2"));
			return new Named().hi();
		})).then(v -> trace(v));
	}
}
