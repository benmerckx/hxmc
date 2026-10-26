// hxmc.unsafe.UInt64's `/` and `%` are unsigned (they were I64's, signed):
// dividends and divisors of 2^63 and more, by constants and by divisors known
// only at run time; the expected quotients and remainders are a C compiler's
// (uint64_t), printed as signed 64-bit numbers.
import haxe.Int64;
import hxmc.I64;
import hxmc.unsafe.UInt64;

class UInt64Div {
	static function opaque(v:I64):UInt64
		return (cast Int64.parseString(Int64.toStr(cast v)) : I64);

	static function show(v:UInt64):String
		return Int64.toStr(cast (v : I64));

	static function main() {
		var xs:Array<UInt64> = [
			(cast Int64.make(0xFFFFFFFF, 0xFFFFFFFF) : I64), (cast Int64.make(0x80000000, 0) : I64), (cast Int64.make(0x80000000, 1) : I64),
			(cast Int64.make(0xDEADBEEF, 0x12345678) : I64), (cast Int64.make(0x7FFFFFFF, 0xFFFFFFFF) : I64), (12345 : I64)
		];
		var ds:Array<UInt64> = [
			(3 : I64), (10 : I64), (1000000007 : I64), (cast Int64.make(0x80000000, 0) : I64), (cast Int64.make(0xFFFFFFFF, 0xFFFFFFFE) : I64),
			(cast Int64.make(0x12345678, 0x9ABCDEF0) : I64)
		];
		for (x in xs) {
			Sys.println('${show(x)} by 10: ${show(x / 10)} ${show(x % 10)}, by 7: ${show(x / 7)} ${show(x % 7)}');
			for (d in ds) {
				var dv = opaque(d);
				Sys.println('  by ${show(d)}: ${show(x / dv)} ${show(x % dv)}');
			}
		}
	}
}
