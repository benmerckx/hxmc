// splits of one name share a chunk, with an initializer per call; chunks
// that load each other; a chunk loaded from main and from another chunk
// (its types' parent: main); a type two unrelated chunks use (into main)
class ViewA {
	public static function render(n:Int) return "A" + n + " " + Util.fmt(n);

	public static function openB(n:Int) return js.Bundle.split("viewB", () -> ViewB.render(n));
}

class ViewB {
	public static function render(n:Int) return "B" + n + " " + Util.fmt(n);

	public static function openA(n:Int) return js.Bundle.split("viewA", () -> ViewA.render(n));
}

class Util {
	public static function fmt(n:Int) return "<" + n + ">";
}

class OnlyC {
	public static var calls = 0;

	public static function go() return "C" + (++calls);
}

class Groups {
	static function main() {
		js.Bundle.split("viewA", () -> ViewA.render(1)).then(s -> {
			trace(s);
			return js.Bundle.split("viewA", () -> ViewA.openB(2));
		}).then(s -> {
			trace(s);
			return js.Bundle.split("viewB", () -> ViewB.openA(3));
		}).then(s -> {
			trace(s);
			var x = 4;
			return js.Bundle.split("c", () -> OnlyC.go() + x);
		}).then(s -> {
			trace(s);
			return js.Bundle.split("c", () -> OnlyC.go());
		}).then(s -> trace(s));
	}
}
