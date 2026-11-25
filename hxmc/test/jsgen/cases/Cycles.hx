// modules importing each other, with classes extending the other's (es-modules, Chunk.order, breakCycles): the
// super class's module runs first where an order of the imports does it; where none does (Left and Right), a
// class moves to a file of its own
import cycles.Base;
import cycles.Left;
import cycles.Right;

class Cycles {
	static function main() {
		trace(Base.make().name(), new Base().name(), Std.isOfType(Base.make(), cycles.Derived));
		trace(new LeftChild().side(), new Right().side(), Std.isOfType(new LeftChild(), Left), Type.getClassName(Type.getSuperClass(LeftChild)));
	}
}
