package regress;

// a type only a split uses, intercepted by a class only a split nested in it uses
class Late {
	public function new() {}

	public function ring(n:Int) return "late " + n;
}

class LateInterceptor {
	static var calls = 0;

	static function __init__() {
		Patch.intercept(Late, "ring", () -> calls++);
	}

	public static function count() trace("late interceptions so far: " + calls);
}
