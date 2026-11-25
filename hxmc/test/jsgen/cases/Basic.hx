// splits, nested and sibling ones (a type both use: in their parent's
// chunk), one in an instance method (capturing this), captured locals
class Basic {
	static function main() {
		final a = 1, b = 2, c = 3;
		var shared = new Shared("main");
		trace(shared.describe());
		// (a function is no object, a class is: Reflect.isObject)
		trace(Reflect.isObject(() -> 1), Reflect.isObject(Shared), Reflect.isObject({}), Reflect.isFunction(Shared));
		js.Bundle.split("something", () -> {
			ClassB.someMethod(a);
			var x = new ClassA(c);
			trace(x.value + b);
			return js.Bundle.split("nested", () -> {
				trace("nested " + new Deep().name + " " + a);
				return Common.hello("nested");
			}).then(r -> {
				trace("nested returned " + r);
				return js.Bundle.split("sibling", () -> Common.hello("sibling"));
			}).then(r -> {
				trace("sibling returned " + r);
				return "returnValue";
			});
		}).then(v -> {
			trace("split returned " + v);
			return new Basic().run();
		}).then(v -> trace("method returned " + v));
	}

	var label = "instance";

	function new() {}

	function run() {
		return js.Bundle.split("method", () -> {
			trace("in method chunk: " + label + " " + Std.string(Color.Rgb(1, 2, 3)));
			return 0;
		});
	}
}

enum Color {
	Red;
	Rgb(r:Int, g:Int, b:Int);
}

class Shared {
	public var name:String;

	public function new(name) this.name = name;

	public function describe() return "Shared(" + name + ")";
}

class ClassA extends Shared {
	public var value:Int;
	public static var created = 0;

	public function new(v:Int) {
		super("A");
		value = v * 10;
		created++;
	}
}

class ClassB {
	public static var calls = [];

	public static function someMethod(n:Int) {
		calls.push(n);
		trace("ClassB.someMethod " + n + " " + calls.length);
	}
}

class Deep {
	public var name = "deep";

	public function new() {}
}

class Common {
	public static function hello(s:String) return "hello " + s;
}
