// Objects not yet escaped (hxmc/src/hxmc/Opt.hx, versions: private
// objects): a call that does not get the object cannot write its fields,
// one that gets it (and does not keep it) can, and once the object escaped
// (a static here) any call may. Each line prints fields read around calls.
class P {
	public var x:Int;
	public var y:Float;

	public function new(x:Int) {
		this.x = x;
		this.y = x / 2;
	}
}

class PrivateObjects {
	static var other:P;
	static var kept:P;

	@:noinline static function bumpOther(k:Int) {
		for (i in 0...k)
			other.x++;
	}

	@:noinline static function bump(p:P, k:Int) {
		for (i in 0...k)
			p.x++;
	}

	@:noinline static function bumpKept(k:Int) {
		for (i in 0...k)
			kept.x += 10;
	}

	static function main() {
		other = new P(100);
		var a = new P(1);
		var r1 = a.x;
		bumpOther(3);
		var r2 = a.x;
		Sys.println('not passed: $r1 $r2 ${other.x}');
		var b = new P(5);
		var s1 = b.x;
		bump(b, 2);
		var s2 = b.x;
		bump(b, 1);
		Sys.println('passed: $s1 $s2 ${b.x}');
		var c = new P(7);
		kept = c;
		var t1 = c.x;
		bumpKept(1);
		Sys.println('escaped: $t1 ${c.x}');
		var d = new P(2);
		var sum = 0.0;
		for (i in 0...3) {
			sum += d.y;
			bumpOther(1);
			bump(d, 1);
			sum += d.x;
		}
		Sys.println('loop: $sum ${d.x} ${other.x}');
	}
}
