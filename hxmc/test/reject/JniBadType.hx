// A Java method's parameter must have a Java type: a Haxe enum has none.
// target: linux-x86_64
// expect: Java method take: the parameter c: Color has no Java type
enum Color {
	Red;
}

@:hxmc.java("jnitest.Taker") extern class Taker {
	static function take(c:Color):Void;
}

class JniBadType {
	static function main()
		Taker.take(Red);
}
