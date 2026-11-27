// Declared effects (hxmc/src/hxmc/Effects.hx): a call keeps the loads of
// what its callee does not write (its summary, Facts.findEffects) and
// reloads what it may write, through other aliases, statics, arrays and
// its own callees; a collection keeps the Ints and Floats loaded before it
// and never a reference; a field an allocation zeroed reads as zero until
// it is written.
class Cell {
	public var n:Int;
	public var f:Float;
	public var next:Cell;
	public var flag:Int;

	public function new(n:Int) {
		this.n = n;
		this.f = n / 2;
	}
}

class EffectsCalls {
	static var count = 0;
	static var cells:Array<Cell> = [];
	static var keep:Cell;

	// (each too big to inline: a loop and a try)
	@:noinline static function bumpN(c:Cell, k:Int) {
		for (i in 0...k)
			c.n++;
	}

	@:noinline static function bumpCount(k:Int) {
		for (i in 0...k)
			count++;
	}

	@:noinline static function readOnly(c:Cell):Int {
		var s = 0;
		for (i in 0...3)
			s += c.n;
		return s;
	}

	@:noinline static function through(c:Cell, k:Int)
		for (i in 0...k)
			bumpN(c, 1);

	@:noinline static function churn(k:Int):Int {
		var s = 0;
		for (i in 0...k) {
			var c = new Cell(i);
			c.next = new Cell(i + 1);
			s += c.next.n;
		}
		return s;
	}

	@:noinline static function grow(k:Int)
		for (i in 0...k)
			cells.push(new Cell(i));

	static function aliases() {
		var a = new Cell(1);
		var b = a;
		var x = a.n;
		bumpN(b, 2);
		Sys.println('alias: $x ${a.n}');
		var y = a.n;
		var r = readOnly(a);
		Sys.println('read only: $y ${a.n} $r');
		through(a, 3);
		Sys.println('through: ${a.n}');
		var c0 = count;
		bumpCount(4);
		Sys.println('static: $c0 $count');
		var l = cells.length;
		grow(5);
		Sys.println('array: $l ${cells.length} ${cells[cells.length - 1].n}');
	}

	// a reference field read before collections and after them
	static function moved() {
		var a = new Cell(7);
		a.next = new Cell(8);
		keep = a;
		var before = a.next.n;
		var f = a.f;
		var s = 0;
		for (i in 0...50)
			s += churn(2000);
		Sys.println('moved: $before ${a.next.n} $f ${a.f} $s');
		var t = 0.0;
		for (i in 0...1000) {
			t += a.f + a.next.f;
			churn(10);
		}
		Sys.println('loop: $t');
	}

	// zeroed fields: read before any write, then written
	static function zeroed():Int {
		var total = 0;
		for (i in 0...10) {
			var c = new Cell(i);
			if (c.flag == 0) total += c.n else keep = c;
			if (c.next == null) total++;
			c.flag = i;
			total += c.flag;
		}
		return total;
	}

	// a loop over an Array with a call that writes no array's header
	static function versioned():Int {
		var xs = [for (i in 0...100) i];
		var c = new Cell(0);
		var s = 0;
		for (i in 0...xs.length) {
			s += xs[i];
			if (i % 10 == 0) bumpN(c, 1);
		}
		return s + c.n;
	}

	static function main() {
		aliases();
		moved();
		Sys.println('zeroed: ${zeroed()}');
		Sys.println('versioned: ${versioned()}');
	}
}
