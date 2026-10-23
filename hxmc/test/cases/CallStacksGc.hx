// Call stacks across collections (hxmc.rt.Stacks): an exception's stack is
// recorded where it is made, or for a value caught where it was thrown, as a
// haxe.io.Bytes of return addresses (a small one allocated together with
// its data), and named only when read (haxe.Exception.stack). Exceptions
// made in pairs on one line, at several depths (the deepest Bytes not a
// small one), one of each pair read at once, the other after collections
// (minor and major, allocations between): the same frames. Run with the
// corpus' small nursery and RT_VERIFY=1. (The recording once copied the
// addresses over the Bytes object instead of into its data: its slot then
// held a return address, and the object the collector copied had the first
// address alone.)
import haxe.CallStack;
import haxe.Exception;
import hxmc.NativeGc;

class CallStacksGc {
	static var pairs:Array<Array<Exception>> = [];

	static function frames(s:CallStack):Array<String> {
		return [
			for (item in s)
				switch item {
					case FilePos(Method(c, m), _, l, _): c + "." + m + ":" + l;
					case _: "?";
				}
		];
	}

	static function made(n:Int) {
		if (n > 0) {
			made(n - 1);
			return;
		}
		var pair = [];
		for (k in 0...2)
			pair.push(new Exception("made"));
		pairs.push(pair);
	}

	static function thrown(n:Int) {
		if (n > 0) {
			thrown(n - 1);
			return;
		}
		throw "thrown";
	}

	static function caught(n:Int) {
		var pair = [];
		for (k in 0...2)
			try {
				thrown(n);
			} catch (e:Exception) {
				pair.push(e);
			}
		pairs.push(pair);
	}

	static function main() {
		var depths = [0, 5, 30, 80];
		for (n in depths) {
			made(n);
			caught(n);
		}
		var first = [for (p in pairs) frames(p[0].stack)];
		var junk = [];
		for (round in 0...4) {
			for (i in 0...20000)
				junk.push([i, i + 1]);
			NativeGc.collect(round == 3);
			junk = [];
		}
		for (i in 0...pairs.length) {
			var after = frames(pairs[i][1].stack);
			var depth = depths[i >> 1], what = (i & 1) == 0 ? "made" : "caught";
			trace('$what at depth $depth: ${after.length} frames, the same after collections: ${after.join(" < ") == first[i].join(" < ")}');
		}
		trace(first[2].slice(0, 3).join(" < "));
		trace(first[3].slice(0, 3).join(" < "));
	}
}
