class H {
	public static var fuel:Int = 20000;
	public static function tick():Void {
		if (--fuel < 0)
			throw new Fuel();
	}
	public static function out(s:String):Void {
		#if js
		js.Syntax.code("console.log({0})", s);
		#elseif flash
		trace(s);
		#else
		Sys.println(s);
		#end
	}
	public static function nz(i:Int):Int
		return i == 0 ? 1 : i;
	public static function ix(i:Int, len:Int):Int {
		if (len <= 0)
			return 0;
		var r = i % len;
		return r < 0 ? r + len : r;
	}
	public static function at<T>(a:Array<T>, i:Int, d:T):T
		return a.length == 0 ? d : a[ix(i, a.length)];
	public static function lim(i:Int):Int
		return i < 0 ? 0 : i > 6 ? 6 : i;
	public static function w(i:Int):Int
		return i & 0xFFFFFF;
	public static function cap(s:String):String
		return s.length > 1000 ? s.substr(0, 1000) : s;
	public static function capa<T>(a:Array<T>):Array<T>
		return a.length > 1000 ? a.slice(0, 1000) : a;
	public static function cf(f:Float):Float
		return Math.isNaN(f) ? 0 : f > 1e6 ? 1e6 : f < -1e6 ? -1e6 : f;
	public static function fmt(f:Float):String {
		if (Math.isNaN(f))
			return "nan";
		if (!Math.isFinite(f))
			return f > 0 ? "inf" : "-inf";
		if (Math.abs(f) > 1e9)
			return "big";
		return Std.string(Math.fround(f * 100.0) / 100.0);
	}
	public static function exn(e:Dynamic):String {
		if (Std.isOfType(e, Fuel))
			return "fuel";
		if (Std.isOfType(e, String) || Std.isOfType(e, Int) || Std.isOfType(e, Bool))
			return Std.string(e);
		if (Std.isOfType(e, Err))
			return "Err" + (e : Err).errCode;
		return "other";
	}
	public static function id<T>(x:T):T
		return x;
	public static function apply<T, U>(x:T, f:T->U):U
		return f(x);
	@:generic public static function first<T>(a:Array<T>, d:T):T
		return a.length > 0 ? a[0] : d;
}

class Fuel {
	public function new() {}
}

class Err extends haxe.Exception {
	public var errCode:Int;

	public function new(code:Int) {
		super("err" + code);
		this.errCode = code;
	}
}

class Box<T> {
	public var value:T;

	public function new(v:T) {
		value = v;
	}

	public function get():T
		return value;

	public function map<U>(f:T->U):Box<U>
		return new Box(f(value));
}
