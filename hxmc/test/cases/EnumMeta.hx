// An enum's metadata through haxe.rtti.Meta (upstream's unit.TestMeta): the
// enum's __meta__ (Texpr.buildMetadata, as the other targets' generators
// write it: Lower.reflectEnum), set before the classes' static initializers
// run, beside a class's; an enum without metadata, and one only resolved by
// name. The output is the reference's (--interp).
import haxe.rtti.Meta;

@enumMeta @withArgs(1, "two", [3.5]) enum E {
	@a A;
	@b(0) B(x:Int);
	C;
}

enum Plain {
	P;
}

@classMeta("x") class Holder {
	@field public var f:Int;

	public static var early = Meta.getType(E);
}

class EnumMeta {
	static function fields(o:Dynamic) {
		if (o == null) return "null";
		var fl = Reflect.fields(o);
		fl.sort(Reflect.compare);
		return fl.join("#");
	}

	static function main() {
		var m = Meta.getType(E);
		trace(fields(m));
		trace(m.enumMeta);
		trace(Std.string(m.withArgs));
		var m = Meta.getFields(E);
		trace(fields(m));
		trace(fields(m.A) + " " + m.A.a);
		trace(fields(m.B) + " " + Std.string(m.B.b));
		trace(fields(Meta.getStatics(E)));
		trace(fields(Meta.getType(Plain)) + " " + fields(Meta.getFields(Plain)));
		trace(fields(Meta.getType(Holder)) + " " + Std.string(Meta.getType(Holder).classMeta));
		trace(fields(Meta.getFields(Holder)));
		trace(fields(Holder.early));
		trace(Meta.getType(E) == Meta.getType(E));
		trace(Type.getEnumConstructs(E));
	}
}
