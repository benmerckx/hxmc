package ml2hx.rt;

class PolyVariant1<T> extends PolyVariant implements Block {
	public final arg:T;
	public function new(tag:Int, label:String, arg:T) {
		super(tag, label);
		this.arg = arg;
	}

	public function blockTag():Int return 0;
	public function blockSize():Int return 2;
	public function blockField(i:Int):Dynamic return i == 0 ? (Int63.ofInt(tag) : Dynamic) : arg;
}
