// An image holds no references: a Str field cannot be in one.
// expect: Image: hxmc.scoped.Str is not in an image (scalars, Rels, scoped classes and Fixed of them: no references)
import hxmc.scoped.*;

@:hxmc.scoped class Item {
	public var id:Int;
	public var name:Str;
}

@:hxmc.scoped class Code {
	public static function bad():Int {
		var g = new Grow<Item>();
		g.push({id: 1, name: "a"});
		return Image.of(g).length;
	}
}

class ScopedImageRefs {
	static function main()
		trace(Code.bad());
}
