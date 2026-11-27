package regress;

class Interceptor {
	static var calls = 0;

	static function __init__() {
		Patch.intercept(Regressions.Target, "ring", () -> calls++);
	}

	public static function count() trace("interceptions so far: " + calls);
}
