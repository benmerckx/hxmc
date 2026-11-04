// A Java class names itself: @:hxmc.java("pkg.Class").
// target: linux-x86_64
// expect: Java class Anonymous has no name: declare it @:hxmc.java("pkg.Class")
@:hxmc.java extern class Anonymous {
	static function f():Int;
}

class JniNoName {
	static function main()
		trace(Anonymous.f());
}
