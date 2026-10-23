// what a large program (tsc-haxe, the TypeScript compiler) needed of -D hxmc.wasm-gc, printed and compared
// with the native build's output (GcCheck): an array literal of more elements than array.new_fixed takes
// (V8: 10000), FPHelper's bit casts with the low word's sign bit set, an ObjectMap of more keys than its
// 16-bit identity hashes have values.
import haxe.io.FPHelper;

class Key {
	public final n:Int;

	public function new(n)
		this.n = n;
}

class LargePrograms {
	// an array literal of n elements (a literal in the typed AST, not a comprehension)
	macro static function literal(n:Int):haxe.macro.Expr {
		final values = [for (i in 0...n) macro $v{i & 1023}];
		return macro $a{values};
	}

	static function main() {
		final big:Array<Int> = literal(12000);
		var sum = 0;
		for (x in big)
			sum += x;
		final last:Int = big[big.length - 1];
		Sys.println("literal: " + big.length + " elements, sum " + sum + ", last " + last);

		for (x in [12713980.0, 2146305.0, 83886079.0, 1e300, -3.25, 0.5, 5e-324]) {
			final b = FPHelper.doubleToI64(x);
			final y = FPHelper.i64ToDouble(b.low, b.high);
			Sys.println('bits of $x: ${StringTools.hex(b.high, 8)} ${StringTools.hex(b.low, 8)} -> ${y == x ? "same" : "DIFFERENT " + y}');
		}

		final keys = [for (i in 0...100000) new Key(i)];
		final m = new haxe.ds.ObjectMap<Key, Int>();
		for (k in keys)
			m.set(k, k.n * 3);
		var found = 0, total = 0;
		for (k in keys) {
			final v = m.get(k);
			if (v != null) {
				found++;
				total += v;
			}
		}
		for (i in 0...50000)
			m.remove(keys[i * 2]);
		var left = 0;
		for (_ in m.keys())
			left++;
		Sys.println('ObjectMap: $found of ${keys.length} found, total $total, $left left after removals, ${m.exists(keys[1])} ${m.exists(keys[0])}');
	}
}
