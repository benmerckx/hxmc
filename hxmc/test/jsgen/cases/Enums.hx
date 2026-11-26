// enums as classes ($hx.declareEnum): constructors with and without arguments, a generic and recursive enum, a
// GADT, matching, constructors as functions, reflection (Type, Reflect, Std), equality, serialization; `instanceof` an enum
// (its values: Symbol.hasInstance), which TypeScript narrows by
// ts: import { Color, Tree } from "./Enums.ts";
// ts: declare const v: unknown;
// ts: const c: Color | null = v instanceof Color ? v : null;
// ts: const t: Tree<unknown> | null = v instanceof Tree ? v : null;
// ts: // @ts-expect-error
// ts: const n: Tree<unknown> | null = v instanceof Color ? v : null;
// ts: export { c, t, n };
enum Color {
	Red;
	Green;
	Rgb(r:Int, g:Int, b:Int);
	Named(name:String);
}

enum Tree<T> {
	Leaf(v:T);
	Node(l:Tree<T>, r:Tree<T>);
	Empty;
}

enum Expr<T> {
	IntLit(i:Int):Expr<Int>;
	BoolLit(b:Bool):Expr<Bool>;
	If<T>(c:Expr<Bool>, a:Expr<T>, b:Expr<T>):Expr<T>;
}

class Enums {
	static function sum(t:Tree<Int>):Int
		return switch t {
			case Leaf(v): v;
			case Node(l, r): sum(l) + sum(r);
			case Empty: 0;
		}

	static function eval<T>(e:Expr<T>):T
		return switch e {
			case IntLit(i): i;
			case BoolLit(b): b;
			case If(c, a, b): eval(c) ? eval(a) : eval(b);
		}

	static function main() {
		var cs = [Red, Green, Rgb(1, 2, 3), Named("x")];
		for (c in cs)
			trace(c, Type.enumIndex(c), Type.enumConstructor(c), Type.enumParameters(c), switch c {
				case Rgb(r, g, b): r + g + b;
				case Named(n): n.length;
				case Red | Green: -1;
			});
		trace(Type.getEnum(Red) == Color, Type.getEnumName(Color), Type.getEnumConstructs(Color), Type.allEnums(Color));
		trace(Type.createEnum(Color, "Rgb", [4, 5, 6]), Type.createEnumIndex(Color, 3, ["y"]), Type.createEnum(Color, "Green"));
		trace(Type.enumEq(Rgb(1, 2, 3), Rgb(1, 2, 3)), Type.enumEq(Rgb(1, 2, 3), Rgb(1, 2, 4)), Red == Red, Red == Green);
		trace(Std.isOfType(Red, Color), Std.isOfType(Leaf(1), Color), Std.isOfType(Leaf(1), Tree), Type.getClass(Red), Reflect.isEnumValue(Red),
			Reflect.isObject(Red), Reflect.isEnumValue({}));
		trace(Type.enumEq(Type.typeof(Rgb(1, 2, 3)), TEnum(Color)), Type.resolveEnum("Color") == Color);
		trace(sum(Node(Leaf(1), Node(Leaf(2), Empty))), [1, 2].map(Leaf), [Red, Green].map(Type.enumIndex));
		trace(eval(If(BoolLit(false), IntLit(1), IntLit(2))));
		var s = new haxe.Serializer();
		s.serialize(Node(Leaf(1), Leaf(2)));
		s.serialize(Named("z"));
		var u = new haxe.Unserializer(s.toString());
		u.setResolver({resolveClass: Type.resolveClass, resolveEnum: Type.resolveEnum});
		trace(s.toString(), u.unserialize(), u.unserialize());
		trace(Std.string(Rgb(7, 8, 9)), "" + Named("q"), Red.match(Red), Rgb(1, 2, 3).match(Rgb(1, _, _)));
	}
}
