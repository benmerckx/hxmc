// Closures converted to another function type compare as what they adapt
// (upstream's unit.teststd.TestReflect: Reflect.compareMethods(a.push,
// a.push)): a closure of an Array or String method is an adapter, made
// where it is used, of the runtime's function taking Dynamic (Lower.adapter),
// so two of one method and object were unequal; Reflect.compareMethods and
// == on Dynamic now compare what the adapters convert (Dyn.peel). Also a
// function converted to another function type (upstream's
// Issue6705.testTypeChange), and Dynamic converted to a function type. The
// output is the reference's (--interp).
class MethodAdapters {
	static function f1(x:Float) {}

	static function eqDyn(a:Dynamic, b:Dynamic):Bool
		return a == b;

	static function main() {
		var a = [1];
		var b = [2];
		var v:Dynamic = a.push;
		trace(Reflect.compareMethods(a.push, a.push));
		trace(Reflect.compareMethods(a.push, a.pop));
		trace(Reflect.compareMethods(a.push, b.push));
		trace(Reflect.compareMethods(a.push, v));
		trace(Reflect.compareMethods(b.push, v));
		trace(eqDyn(a.push, a.push) + " " + eqDyn(a.push, b.push) + " " + eqDyn(a.pop, a.push));
		var s = "abc", t = "abd";
		trace(Reflect.compareMethods(s.charAt, s.charAt) + " " + Reflect.compareMethods(s.charAt, t.charAt) + " " + Reflect.compareMethods(s.charAt, s.indexOf));
		var x = function(t:Int) return 1;
		var y = function(t:Int) return -1;
		trace(Reflect.compareMethods(x, x) + " " + Reflect.compareMethods(x, y) + " " + Reflect.compareMethods(x, null) + " " + Reflect.compareMethods(null, x));
		// (a function converted to another function type: an adapter)
		var f2:Int->Void = f1;
		trace(Reflect.compareMethods(f1, f2) + " " + eqDyn(f1, f2));
		var g:Dynamic = x;
		var g1:Int->Int = g;
		trace(Reflect.compareMethods(g1, x) + " " + eqDyn(g1, g));
		// (adapters still call what they adapt)
		var push:Int->Int = a.push;
		push(5);
		var pushD:Dynamic = a.push;
		pushD(6);
		trace(a);
	}
}
