// Loop versioning of Array stores (hxmc/src/hxmc/LoopVersion.hx): a counted
// loop storing numbers into an Array long enough for its range runs a copy
// whose stores neither grow the array nor collect; one that would store
// past the end runs as it was (the array grows). A rooted array (live across
// a collection before the loop) is the same in the copy, and an array
// stored through one name and read through another sees its stores.
class LoopStores {
	@:noinline static function churn(k:Int):Int {
		var s = 0;
		for (i in 0...k)
			s += [i].length;
		return s;
	}

	static function fill(w:Array<Int>, n:Int):Int {
		var s = 0;
		for (j in 0...n) {
			if (j < 4)
				w[j] = j * 3;
			else
				w[j] = w[j - 1] + w[j - 4];
			s += w[j];
		}
		return s;
	}

	static function floats(a:Array<Float>, b:Array<Float>):Float {
		for (i in 0...a.length)
			a[i] = a[i] * 0.5 + 1;
		var t = 0.0;
		for (i in 0...b.length)
			t += b[i];
		return t;
	}

	static function main() {
		var w = [for (i in 0...20) 0];
		churn(20000);
		Sys.println('in range: ${fill(w, 20)} ${w[19]} ${w.length}');
		var short = [0, 0, 0];
		Sys.println('grows: ${fill(short, 12)} ${short.length} ${short[11]}');
		var a = [for (i in 0...10) i * 1.0];
		Sys.println('aliased: ${floats(a, a)} ${a[9]}');
		var bools = [for (i in 0...8) false];
		for (i in 0...bools.length)
			bools[i] = i % 3 == 0;
		Sys.println('bools: $bools');
	}
}
