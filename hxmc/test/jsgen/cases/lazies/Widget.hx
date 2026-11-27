package lazies;

class Widget {
	final i:Int;

	public function new(i) this.i = i;

	public function label() return "widget " + i;
}
