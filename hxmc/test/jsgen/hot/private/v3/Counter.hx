class Counter {
	var n = 0;
	static var prefix = "c";
	public function new() {}
	public function next() return label(step());
	function step() return n += 10;
	static function label(i:Int) return prefix + i;
}
