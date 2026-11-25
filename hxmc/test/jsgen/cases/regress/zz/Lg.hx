package regress.zz;

class Base {
	public function new() {}
}

class Lg extends Base {
	public final name:String;

	public function new(name) {
		super();
		this.name = name;
	}
}
