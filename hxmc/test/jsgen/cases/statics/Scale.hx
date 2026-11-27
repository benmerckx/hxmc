package statics;

class Scale {
	public static function zero():Celsius return 0.0;

	public static function room():Celsius return Celsius.freezing.warmer(21);
}
