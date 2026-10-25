// define: hxmc.scoped-packages=scopedpkg
// Scoped by default (docs/plans/lowlevel.md, "Syntax"): the types of a
// package -D hxmc.scoped-packages lists, a module's level fields when its own
// type is scoped, and object literals for scoped classes.
import hxmc.scoped.*;

@:hxmc.scoped class Pair {
	public var a:Int;
	public var b:Int;

	public function new(a:Int, b:Int) {
		this.a = a;
		this.b = b;
	}

	public static function sum():Int {
		var p:Pair = {a: 3, b: 4};
		var q:Pair = {b: 10, a: 20};
		return p.a * p.b + q.a - q.b;
	}
}

class ScopedDefaults {
	static function main() {
		trace(Pair.sum());
		trace(scopedpkg.Geo.walk(100));
		trace(scopedpkg.Geo.copies());
		trace(scopedmod.Dist.total(10));
	}
}
