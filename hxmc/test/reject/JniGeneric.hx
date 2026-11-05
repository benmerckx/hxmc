// A generic class cannot implement a Java interface: its proxy is one class's.
// target: linux-x86_64
// expect: JniGeneric implements a Java interface: a generic class cannot
@:hxmc.java("java.lang.Runnable") extern interface Runnable {
	function run():Void;
}

class JniGeneric<T> implements Runnable {
	public function new() {}

	public function run() {}

	static function main() {
		var r:Runnable = new JniGeneric<Int>();
		r.run();
	}
}
