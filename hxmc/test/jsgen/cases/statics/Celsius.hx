package statics;

// (a static that calls a module importing this one: that module runs first)
abstract Celsius(Float) from Float to Float {
	public static var freezing:Celsius = Scale.zero();

	public function warmer(d:Float):Celsius return this + d;
}
