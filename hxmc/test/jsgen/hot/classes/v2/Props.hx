class Props {
	@:isVar public var x(get, set):Int = 0;
	public function new() {}
	function get_x() return x * 100;
	function set_x(v:Int) return x = v;
}
