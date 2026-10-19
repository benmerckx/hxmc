package ml2hx.rt;

class PolyVariant1<T> extends PolyVariant {
	public final arg:T;
	public function new(tag:Int, label:String, arg:T) {
		super(tag, label);
		this.arg = arg;
	}
}
