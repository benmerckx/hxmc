package regress;

class Traced {
	public static function hello() trace("hello from a module of its own");

	public static function twice(yield:Int) return yield * 2;
}
