package cycles;

class Derived extends Base {
	override public function name() return "derived of " + super.name();
}
