// what MirGen once failed on in tsc-haxe: a copy of a phi (an inlined
// function's result, read as another type: its key was taken before the
// phi's was known) and an Int64 rotation (MirWriter.rotation: its count an
// I32 constant, pushed as an i64)
import haxe.Int64;

class CopiesRotations {
	static inline function filter<T>(a:Null<Array<T>>, f:T->Bool):Null<Array<T>> {
		var result = a;
		if (a != null) {
			var i = 0;
			while (i < a.length && f(a[i]))
				i++;
			if (i < a.length) {
				final r = a.slice(0, i);
				for (k in i + 1...a.length)
					if (f(a[k])) r.push(a[k]);
				result = r;
			}
		}
		return result;
	}

	static function evens(a:Array<Int>, all:Bool):Array<Int> {
		final b = a.copy();
		b.push(10);
		if (all) return b;
		return filter(b, x -> x % 2 == 0);
	}

	static inline function rotl(x:Int64, k:Int):Int64
		return (x << k) | (x >>> (64 - k));

	static function mix(h:Int64):Int64 {
		h = h ^ (rotl(h, 49) ^ rotl(h, 24));
		return h * Int64.make(0x9fb21c65, 0x1e98df25);
	}

	static function main() {
		Sys.println(evens([2, 4, 5, 6, 7, 8], false));
		Sys.println(evens([2, 4], false));
		Sys.println(evens([1, 2], true));
		var h = Int64.make(0x12345678, 0x9abcdef0);
		for (i in 0...3) {
			h = mix(h);
			Sys.println(Int64.toStr(h));
		}
	}
}
