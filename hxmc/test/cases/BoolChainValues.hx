// && and || chains used as values (returned, stored, passed): Opt's
// knownPhiArgs makes the operand that a branch already tested a constant
// (1 on the then edge of a comparison or boolean phi, 0 on the else edge),
// so the joins before thread. Values that are not booleans keep theirs.
class K {
	public var kind:Int;
	public var bits:Int;

	public function new(k, b) {
		kind = k;
		bits = b;
	}
}

class BoolChainValues {
	static function isA(k:K):Bool
		return k.kind == 3;

	static function isB(k:K):Bool
		return k.kind == 5 || k.kind == 6;

	static function anyOf(k:K):Bool
		return isA(k) || isB(k) || k.kind == 9 || k.kind > 40 && k.bits & 1 != 0;

	static function allOf(k:K):Bool
		return k.bits & 2 != 0 && k.kind != 0 && (k.bits & 4 == 0 || k.kind < 20);

	static function mixed(k:K):Int {
		var a = anyOf(k), b = allOf(k);
		var c = a && !b || k.kind == 17;
		return (a ? 1 : 0) + (b ? 2 : 0) + (c ? 4 : 0);
	}

	static function notBool(k:K):Int {
		// (an Int operand: a branch on it tells only that it is not 0)
		var x = k.bits & 12;
		var y = x != 0 ? x : k.kind;
		return y;
	}

	static function main() {
		var s = 0, n = 0, h = 0;
		for (i in 0...300) {
			var k = new K(i % 50, i * 7);
			if (anyOf(k)) n++;
			s += mixed(k);
			h = h * 31 + notBool(k);
		}
		trace(n, s, h);
	}
}
