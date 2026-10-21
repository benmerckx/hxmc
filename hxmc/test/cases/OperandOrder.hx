// define: analyzer-optimize
// A local read as an operand before a later operand assigns it: the analyzer
// leaves `[_g_offset, s.cca(_g_offset++)]` in that order (StringTools'
// keyValueIterator in a comprehension, upstream's unit test TestStringTools),
// and hxmc read the local after the increment ([[1,97],...]): a local is read
// first unless the later operands leave it alone.
class OperandOrder {
	static function id(x:Int)
		return x;

	static function main() {
		var s = "abc";
		Sys.println([for (i => c in StringTools.keyValueIterator(s)) [i, c]]);
		var r = [];
		var i = 0;
		while (i < 3)
			r.push(i + id(i++));
		Sys.println(r);
		var o = [];
		var j = 0;
		while (j < 3)
			o.push({a: j, b: id(j++)});
		Sys.println([for (x in o) x.a * 10 + x.b]);
	}
}
