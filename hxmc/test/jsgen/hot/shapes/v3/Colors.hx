class Colors {
	public static function pick() return Color.Blue;
	public static function name(c:Color) return switch c { case Red: "red"; case Blue: "blue"; };
}
