// Statics through a class value (hxmc.ir.Lower.reflectStatics, kept by
// hxmc.ir.Reach, found in the type's table by hxmc.rt.Dyn): Reflect, Dynamic
// access, functions as closures, Type.getClassFields in the reference's
// order, the __meta__ static the filters add (haxe.rtti.Meta). The output is
// the reference's (--interp) but for the lines marked. First the program that
// showed the bug: a static read through its class value was 0 (its
// initializer dropped: no live code read it otherwise), Reflect.field and
// Type.getClassFields found nothing, Meta.getType nothing (then a crash).
@RuntimeMeta([42, 0])
class StaticReflection {
	static var x = 5;

	static function main() {
		var c:Dynamic = StaticReflection;
		trace(Reflect.field(StaticReflection, "x"));
		trace(c.x);
		// (a structure as hxmc writes it; Eval: {obj: {RuntimeMeta: [[42,0]]}})
		trace(Reflect.field(StaticReflection, "__meta__"));
		trace(Type.getClassFields(StaticReflection));
		var m = haxe.rtti.Meta.getType(StaticReflection);
		trace(m.RuntimeMeta[0][0]);
		Statics.run();
	}
}

class Base {
	public static var inherited = 1;

	public static function inheritedFn()
		return "base";
}

class Sub extends Base {
	public static var own = 2;
	public static var prop(get, never):Int;
	public static var bounded(default, set):Int = 3;
	public static inline var INLINED = 9;
	public static final RATIO = 1.5;
	public static var flag = true;
	public static var big:haxe.Int64 = haxe.Int64.make(1, 2);
	public static var name:String;
	public static var list = [1, 2];

	static function get_prop()
		return 7;

	static function set_bounded(v:Int)
		return bounded = v * 10;

	public static function twice(x:Int)
		return x * 2;

	public static function opt(x:Int = 4)
		return x + 1;

	// (no live code calls it or looks its name up: left out, as -dce full
	// leaves it out; Eval, without DCE, lists it)
	static function dropped()
		return 0;
}

@Tagged("i")
interface Marked {}

class Tagged implements Marked {
	@doc("a") public static var a = 1;
	@flag public static function f() {}

	@inst(1) public var i:Int;

	public function new() {}
}

class Statics {
	public static function run() {
		var c:Dynamic = Sub;
		// a superclass's statics are not the subclass's (Eval finds them through
		// its prototypes: 1, 1, true; JS does not)
		trace(Reflect.field(Sub, "inherited"));
		trace(c.inherited);
		trace(Reflect.isFunction(Reflect.field(Sub, "inheritedFn")));
		trace(Reflect.hasField(Sub, "inherited") + " " + Reflect.hasField(Sub, "own") + " " + Reflect.hasField(Base, "inherited"));
		trace(Type.getClassFields(Base));
		trace(Reflect.field(Type.getSuperClass(Sub), "inherited"));
		// properties: a getter's has no storage, a setter's has
		trace(Reflect.field(Sub, "prop") + " " + Reflect.getProperty(Sub, "prop"));
		trace(Reflect.field(Sub, "bounded"));
		Reflect.setProperty(Sub, "bounded", 5);
		trace(Sub.bounded);
		// written by Reflect and by Dynamic access, read by typed code
		Reflect.setField(Sub, "own", 20);
		trace(Sub.own);
		c.own = 21;
		c.own += 1;
		trace(Sub.own + " " + c.own);
		// every representation; an inline variable has its value too
		trace(Reflect.field(Sub, "INLINED") + " " + Reflect.field(Sub, "RATIO") + " " + c.flag + " " + c.big + " " + Reflect.field(Sub, "name") + " " + c.list);
		// functions as closures, with their default values
		var f = Reflect.field(Sub, "twice");
		trace(f(21));
		trace(Reflect.callMethod(Sub, Reflect.field(Sub, "twice"), [5]));
		trace(c.twice(6) + " " + c.opt() + " " + c.opt(1));
		trace(Reflect.isFunction(c.twice) + " " + Reflect.field(Sub, "nothing"));
		// (Eval lists dropped too, second)
		trace(Type.getClassFields(Sub));
		trace(Reflect.fields(Sub));
		// metadata: of statics, of fields, of an interface (the filters give it a __meta__ too)
		trace(haxe.rtti.Meta.getStatics(Tagged).a.doc[0]);
		trace(Reflect.hasField(haxe.rtti.Meta.getStatics(Tagged), "f"));
		trace(haxe.rtti.Meta.getFields(Tagged).i.inst[0]);
		trace(haxe.rtti.Meta.getType(Marked).Tagged[0]);
		trace(Type.getClassFields(Marked));
		// the class value of an instance
		var k:Dynamic = Type.getClass(new Tagged());
		trace(k.a + " " + (k == Tagged));
	}
}
