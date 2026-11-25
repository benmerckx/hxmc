package cycles;

// (its module imports its subclass's: a cycle that runs Base's first)
class Base {
	public function new() {}

	public function name() return "base";

	public static function make():Base return new Derived();
}
