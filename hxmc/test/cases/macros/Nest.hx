package macros;

import haxe.macro.Expr;

// BigInit's table: `Cons(BigInitValues.v<i % 50>, Cons(..., Nil))`, n deep (the
// shape of ml2hx's generated tables)
class Nest {
	public static macro function table(n:Int):Expr {
		var e:Expr = macro Nil;
		var i = n;
		while (i-- > 0) {
			var v = "v" + (i % 50);
			e = macro Cons(BigInitValues.$v, $e);
		}
		return e;
	}

	public static macro function values():Array<Field> {
		var fields = haxe.macro.Context.getBuildFields();
		for (i in 0...50)
			fields.push({
				name: "v" + i,
				access: [APublic, AStatic],
				kind: FVar(macro :Array<Int>, macro [$v{i}]),
				pos: haxe.macro.Context.currentPos()
			});
		return fields;
	}
}
