// A class's __init__ runs at startup whether or not code uses the class: one
// with no statics that only does something (prints, sets another class's
// static), one whose statics nothing reads, and one that is used.
class Unused {
	static function __init__():Void {
		ClassInit.log.push("Unused.__init__");
		ClassInit.count++;
	}
}

class UnreadStatics {
	static var never:Int = 3;

	static function __init__():Void {
		ClassInit.log.push("UnreadStatics.__init__");
		ClassInit.count += 10;
	}
}

class Used {
	public static var v:Int = 1;

	static function __init__():Void {
		v = 42;
	}
}

class ClassInit {
	public static var log:Array<String> = [];
	public static var count = 0;

	static function main() {
		log.sort(Reflect.compare);
		trace(log, count, Used.v);
	}
}
