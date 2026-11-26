package abstracts;

// abstracts of each kind (Abstracts): from and to their underlying type, only to, only from, neither; an enum abstract; a
// generic one
abstract Meters(Float) from Float to Float {
	public inline function new(v:Float) this = v;

	public function km():Float return this / 1000;
}

abstract Celsius(Float) to Float {
	public function new(v:Float) this = v;

	public function warmer(d:Float):Celsius return new Celsius(this + d);
}

abstract Token(String) from String {
	public function upper():String return this.toUpperCase();
}

abstract Id(Int) {
	public function new(i:Int) this = i;

	public function next():Id return new Id(this + 1);

	public function toInt():Int return this;
}

enum abstract Color(Int) {
	var Red;
	var Green;
	var Blue;

	public function name():String return switch (cast this : Color) {
		case Red: "red";
		case Green: "green";
		case Blue: "blue";
	}
}

enum abstract Level(Int) to Int {
	var Low;
	var Mid;
	var High;
}

enum abstract Code(Int) from Int to Int {
	var Ok = 0;
	var Fail = 1;
}

abstract Pair<T>(Array<T>) {
	public function new(a:T, b:T) this = [a, b];

	public function first():T return this[0];
}
