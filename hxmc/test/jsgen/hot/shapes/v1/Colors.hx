class Colors {
	public static function pick() return Color.Green;
	public static function name(c:Color) return switch c { case Red: "red"; case Green: "green"; };
}
