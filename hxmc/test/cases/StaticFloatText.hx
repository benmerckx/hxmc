// Floats turned into text in static initializers, which run before main
// (helder: `static final s = Std.string(0.8)` threw Null Access at startup;
// Ints were fine). The shortest digits of a Float read FloatText's table G,
// itself a static set at startup.
class Texts {
	public static final a = Std.string(0.8);
	public static final b = "" + 0.8;
	public static final c = Std.string(1e21);
	public static final d = Std.string(0.1 + 0.2);
	public static final e = Std.string(Math.NaN);
	public static final f = Std.string(-0.0);
	public static final g = Std.string(Math.PI);
}

class StaticFloatText {
	static function main() {
		Sys.println([Texts.a, Texts.b, Texts.c, Texts.d, Texts.e, Texts.f, Texts.g].join(" "));
	}
}
