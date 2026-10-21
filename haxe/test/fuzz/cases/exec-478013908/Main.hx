import H;

class Main {
	public static function fn1(a2:Int):Void {
		H.tick();
		var v3 = [];
		for (i4 in 0...a2)
			v3.push("x" + i4);
	}
	public static function section1():Void {
		for (x5 in ([false, true, false]).filter(v6 -> true)) {
			H.tick();
			var w7 = 0;
			while (w7 < 2 && x5) {
				w7++;
				H.tick();
				Main.fn1(3000);
			}
		}
	}
	public static function main():Void {
		H.out("start");
		try section1() catch (e:Dynamic) H.out("section1 threw " + H.exn(e));
		H.out("fuel " + H.fuel);
	}
}
