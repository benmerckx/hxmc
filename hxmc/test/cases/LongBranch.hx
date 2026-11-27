// Issue #228: the branch over the unrolled body exceeds AArch64's 1 MiB
// conditional branch range. Exercise both the jump and the fall-through.
import hxmc.Platform;

class LongBranch {
	static function main() {
		var n = Sys.args().length;
		Sys.println(run(n));
		Sys.println(run(n + 1));
	}

	static function run(n:Int):Int {
		var a = [for (i in 0...8) n + i];
		if (a[0] > 0) {
			// Windows ARM64's unwind records have a 1 MiB function limit.
			if (Platform.arm() && Platform.os() != Platform.WINDOWS)
				body(9000);
			else
				for (k in 0...9000)
					a[k % 8] = a[(k + 3) % 8] * (k % 7 + 2) + a[(k + 5) % 8];
		}
		return a[0];
	}

	static macro function body(n:Int) {
		var statements = [for (k in 0...n) macro a[$v{k % 8}] = a[$v{(k + 3) % 8}] * $v{k % 7 + 2} + a[$v{(k + 5) % 8}]];
		return macro $b{statements};
	}
}
