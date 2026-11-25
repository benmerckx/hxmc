package lazies;

class Panel {
	public static function render(n:Int) return "panel of " + [for (i in 0...n) new Widget(i).label()].join(" ");
}
