// Values of constructors without arguments made through reflection
// (Type.createEnum, createEnumIndex, allEnums, Std.string's round trip) are
// the constructors' own values: `==` to the literals, as in every Haxe target.
enum Color {
	Red;
	Green;
	Rgb(r:Int, g:Int, b:Int);
	Blue;
}

enum Single {
	Only;
}

enum abstract Code(Int) {
	var A = 1;
}

class EnumIdentity {
	static function same(a:Dynamic, b:Dynamic):Bool
		return a == b;

	static function main() {
		var all = Type.allEnums(Color);
		Sys.println(all.length + " " + [for (c in all) Std.string(c)].join(","));
		Sys.println((all[0] == Red) + " " + (all[1] == Green) + " " + (all[2] == Blue));
		Sys.println(Type.createEnumIndex(Color, 0) == Red);
		Sys.println(Type.createEnumIndex(Color, 3, []) == Blue);
		Sys.println(Type.createEnum(Color, "Green") == Green);
		Sys.println(Type.createEnum(Color, "Green", null) == Green);
		Sys.println(same(Type.createEnum(Color, "Blue"), Blue));
		Sys.println(Type.createEnum(Single, "Only") == Only);
		Sys.println(Type.allEnums(Single)[0] == Only);
		// a constructor with arguments: a new value each time
		var a = Type.createEnum(Color, "Rgb", [1, 2, 3]);
		var b = Type.createEnum(Color, "Rgb", [1, 2, 3]);
		Sys.println((a == b) + " " + Type.enumEq(a, b) + " " + Std.string(a));
		// in a switch, a map's key and Array.indexOf
		var m = new Map<Color, String>();
		m.set(Green, "green");
		Sys.println(m.get(Type.createEnumIndex(Color, 1)));
		Sys.println(all.indexOf(Blue) + " " + [Red, Green, Blue].indexOf(Type.createEnumIndex(Color, 3)));
		Sys.println(switch Type.createEnumIndex(Color, 1) {
			case Green: "switch green";
			case _: "switch other";
		});
		// the serializer's round trip makes them with createEnumIndex/createEnum
		var s = haxe.Serializer.run([Red, Blue]);
		var u:Array<Color> = haxe.Unserializer.run(s);
		Sys.println((u[0] == Red) + " " + (u[1] == Blue));
		var x:Code = A;
		Sys.println(x == A);
	}
}
