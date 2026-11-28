class Use {
	public static function both() return new a.Thing().id() + "+" + new b.Thing().id();
	public static function pick() return Color.Red;
	public static function color(c:Color) return switch c { case Red: "red"; case Green: "green"; case _: "other"; };
}
