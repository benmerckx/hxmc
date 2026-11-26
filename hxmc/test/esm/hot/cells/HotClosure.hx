class HotClosure {
	public static function make():String->String {
		return function(s) return "v1:" + s;
	}
}