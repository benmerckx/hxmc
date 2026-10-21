// A method of a class over Void (Base<Void>) overriding one that returns T,
// called through the base and directly (upstream's unit test Issue13046): the
// tool crashed with a null access in Escape.objectSite on the function
// calling it.
private class Base<T> {
	public function new() {}

	public function call():T {
		return null;
	}

	public function call2():T {
		return null;
	}
}

private class Sub extends Base<Void> {
	public var calls = 0;

	override function call():Void {
		calls++;
		if (calls > 1)
			return;
		calls++;
	}

	override function call2():Void {}
}

class VoidOverride {
	static function main() {
		var sub = new Sub();
		var i:Base<Void> = sub;
		i.call();
		Sys.println(sub.calls);
		i.call();
		Sys.println(sub.calls);
		sub.call();
		Sys.println(sub.calls);
		i.call2();
		sub.call2();
		Sys.println("done");
	}
}
