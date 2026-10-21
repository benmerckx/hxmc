// Math as a class value (upstream's unit.TestReflect.testTypes): an extern
// class the runtime implements, it had the class value of T_NONE ("None",
// not found by name); now a runtime type of its own, T_MATH, named Math.
// An interface used as a value is found by name too (Dyn.resolveType).
// The output is the reference's (--interp).
interface IShape {}

class MathClassValue {
	static function main() {
		var types:Array<Dynamic> = [Math, String, Array, Date, MathClassValue, IShape];
		for (t in types) {
			var name = Type.getClassName(t);
			trace(name + " " + (Type.resolveClass(name) == t) + " " + (t == null));
		}
		var m:Dynamic = Math;
		trace(m == Math);
		trace(Type.resolveClass("Math") == Math);
		trace(Std.isOfType(1.5, Math));
		trace(Type.getClassName(Type.resolveClass("Math")));
		trace(Math.floor(Math.PI * 100));
	}
}
