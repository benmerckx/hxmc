// Opt on switches: a switch on a phi of a constant (a value's tag, 0 of
// null) whose constant edge goes straight to its case; in a case's block
// the value is one of the case's constants, less those a test on the way
// excluded (`t == 2 || t == 4` in the case of 2 and 4); a load repeated
// where a decided branch left the first dominating it.
class Box {
	public var tag:Int;
	public var v:Int;

	public function new(tag, v) {
		this.tag = tag;
		this.v = v;
	}
}

class OptSwitchCases {
	static inline function tagOf(b:Box):Int
		return b == null ? 0 : b.tag;

	static inline function valueIf(b:Box, t:Int):Int
		return tagOf(b) == t ? b.v : -1;

	@:analyzer(ignore) static function read(b:Box):Int
		return switch tagOf(b) {
			case 0: -100;
			case 2 | 4: tagOf(b) == 2 || tagOf(b) == 4 ? b.v : -2;
			case 3: valueIf(b, 3) * 10;
			case 5: tagOf(b) == 5 ? (tagOf(b) != 6 ? b.v + 1000 : -3) : -4;
			case _: tagOf(b) == 2 ? -5 : b.v - 1000;
		}

	static function main() {
		var boxes = [null, new Box(2, 1), new Box(4, 2), new Box(3, 3), new Box(5, 4), new Box(7, 5), new Box(0, 6)];
		trace([for (b in boxes) read(b)]);
	}
}
