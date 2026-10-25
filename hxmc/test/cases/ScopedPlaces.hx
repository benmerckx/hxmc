// Writing into scoped collections in place: an element written by `[]` is
// typed as the element (a literal makes one), and a Fixed field's element
// set from a value with effects (the Fixed stays where it is).
import hxmc.scoped.*;

@:hxmc.scoped class P {
	public var x:Int;
	public var y:Int;
}

@:hxmc.scoped class Box {
	public var tag:Int;
	public var data:Fixed<Int, 4>;

	public function new(tag:Int)
		this.tag = tag;
}

@:hxmc.scoped class Code {
	static var counter = 0;

	static function next():Int
		return ++counter;

	// literals through []: a Grow, a Slice, a Fixed of struct values; a Grow of
	// Str through an interpolation; a Slice of Slices through an array literal
	public static function literals():Int {
		var g = new Grow<P>();
		g.push({x: 0, y: 0});
		g[0] = {x: 1, y: 2};
		var s:Slice<P> = Scope.slice(2);
		s[1] = {x: 3, y: 4};
		var f = new Fixed<P, 2>();
		f[0] = {x: 5, y: 6};
		var n = 7;
		var t = new Grow<Str>();
		t.push("");
		t[0] = 'n=$n';
		var ss:Slice<Slice<Int>> = Scope.slice(1);
		ss[0] = [8, 9];
		return g[0].x * 10 + g[0].y + s[1].x * 1000 + s[1].y * 100 + f[0].x * 100000 + f[0].y * 10000 + t[0].length * 1000000 + ss[0][1]
			* 10000000;
	}

	// a Fixed field's elements set from calls, in a local and through a Ref
	public static function effects():Int {
		counter = 0;
		var b = new Box(1);
		b.data[0] = next();
		b.data[2] = next() * 10;
		var g = new Grow<Box>();
		g.push(new Box(2));
		g.ref(0).value.data[1] = next() * 100;
		g.ref(0).value.data[3] += next() * 1000;
		b.data[1]++;
		g.ref(0).value.data[0]++;
		return b.data[0] + b.data[2] + g[0].data[1] + g[0].data[3] + b.data[1] * 7 + g[0].data[0] * 70;
	}
}

class ScopedPlaces {
	static function main() {
		trace(Code.literals());
		trace(Code.effects());
	}
}
