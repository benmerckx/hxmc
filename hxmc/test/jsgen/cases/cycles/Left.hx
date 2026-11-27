package cycles;

// (with Right: classes extending each other's module's, which no order runs: one is deferred)
class Left {
	public function new() {}

	public function side() return "left";
}

class LeftChild extends Right {
	override public function side() return "left child of " + super.side();
}
