class Counter {
	var n = 0;
	public function new() {}
	public function next() return label(step());
	function step() return ++n;
	static function label(i:Int) return "a" + i;
}
