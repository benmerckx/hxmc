// Loads in an outer loop of memory that only an inner loop writes, where the
// inner loop's latch comes after the outer loop's in reverse postorder (Opt:
// the `&&` of `while (w < 2 && x)` is threaded, its join removed): the outer
// header's memory versions count the inner loop's writes, so no load there
// takes a value from before the loops. An object field and a static var
// written by a call (seen as 0 throughout once), and an array local held in
// a shadow-stack slot that a collection in the inner loop moves (the stale
// address read after it: a crash, or another object's contents).
import hxmc.NativeGc;

private class Box {
	public var n:Int;

	public function new() {}
}

class LoopVersions {
	static var count = 0;

	static function bump(b:Box) {
		b.n++;
		count++;
	}

	static function fieldAndStatic() {
		var flags = [false, true, false, true];
		var b = new Box();
		b.n = 0;
		count = 0;
		var seenField = 0, seenStatic = 0;
		for (x in flags) {
			seenField += b.n;
			seenStatic += count;
			var w = 0;
			while (w < 2 && x) {
				w++;
				bump(b);
			}
		}
		Sys.println('field and static: $seenField $seenStatic ${b.n} $count');
	}

	// (other shapes: the condition the other way round, a do-while, a while
	// as the outer loop, a third loop inside; no call on the outer loop's own
	// path, which would give its header new versions anyway)
	static function shapes() {
		var flags = [true, false, true];
		var b = new Box(), s = 0;
		b.n = 0;
		for (x in flags) {
			s += b.n;
			var w = 0;
			while (x && w < 2) {
				w++;
				bump(b);
			}
		}
		Sys.println('reversed: $s ${b.n}');
		var b = new Box(), s = 0;
		b.n = 0;
		for (x in flags) {
			s += b.n;
			var w = 0;
			do {
				w++;
				bump(b);
			} while (w < 2 && x);
		}
		Sys.println('do-while: $s ${b.n}');
		var b = new Box(), s = 0, i = 0;
		b.n = 0;
		while (i < flags.length) {
			var x = flags[i++];
			s += b.n;
			var w = 0;
			while (w < 2 && x) {
				w++;
				bump(b);
			}
		}
		Sys.println('while: $s ${b.n}');
		var b = new Box(), s = 0, t = 0;
		b.n = 0;
		for (x in flags) {
			s += b.n;
			var w = 0;
			while (w < 2 && x) {
				w++;
				t += b.n;
				var u = 0;
				while (u < 2 && x) {
					u++;
					bump(b);
				}
			}
		}
		Sys.println('three loops: $s $t ${b.n}');
	}

	static var collections = 0;

	static function collect() {
		NativeGc.collect(false);
		collections++;
	}

	static function movedArray() {
		var sum = 0;
		for (round in 0...3) {
			// (young: the collection below moves it)
			var flags = [round == 0, true, false, round == 2];
			var values = [for (i in 0...flags.length) i * 10 + round];
			var k = 0;
			for (x in flags) {
				sum += values[k++];
				var w = 0;
				while (w < 2 && x) {
					w++;
					collect();
				}
			}
		}
		Sys.println('moved array: $sum $collections');
	}

	static function main() {
		fieldAndStatic();
		shapes();
		movedArray();
	}
}
