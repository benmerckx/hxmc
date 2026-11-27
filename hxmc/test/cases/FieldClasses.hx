// Field classes by declaring class (hxmc/src/hxmc/Effects.hx, fieldClassOf):
// a field written through a superclass's type, a subclass's or a callee's is
// read again through any of them; a write to another class's field at the
// same offset leaves the read as it was. Each line prints what it computes.
class A {
	public var x:Int;
	public var f:Float;

	public function new(x:Int) {
		this.x = x;
		this.f = x / 4;
	}
}

class B extends A {
	public var y:Int;

	public function new(x:Int, y:Int) {
		super(x);
		this.y = y;
	}
}

class C extends B {}

class D {
	public var z:Int;
	public var g:Float;

	public function new() {}
}

class FieldClasses {
	@:noinline static function setX(a:A, v:Int) {
		for (i in 0...1)
			a.x = v;
	}

	@:noinline static function setZ(d:D, v:Int) {
		for (i in 0...1)
			d.z = v;
	}

	static function main() {
		var c = new C(1, 2);
		var b:B = c, a:A = c;
		var before = c.x;
		a.x = 10;
		Sys.println('through the parent: $before ${c.x} ${b.x}');
		setX(b, 20);
		Sys.println('through a callee: ${c.x} ${a.x}');
		var d = new D();
		var t = 0;
		for (i in 0...5) {
			t += c.x + c.y;
			d.z = i;
			setZ(d, i * 2);
			a.f += d.z;
		}
		Sys.println('apart: $t ${d.z} ${c.f}');
		var s = 0;
		for (i in 0...4) {
			s += b.x;
			setX(a, b.x + 1);
		}
		Sys.println('in a loop: $s ${c.x}');
	}
}
