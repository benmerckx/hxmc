package statics;

// (statics calling each other's modules: no order runs both as their modules do, one is lazy)
class Ping {
	public static var x = Pong.one() + 1;

	public static function two() return 2;
}
