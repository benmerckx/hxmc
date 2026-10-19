package ml2hx.rt;

// Polymorphic variants: the tag is OCaml's hash of the label (so ordering
// and hashing agree with OCaml); PolyVariant1 carries the argument.
class PolyVariant {
	public final tag:Int;
	public final label:String;
	public function new(tag:Int, label:String) {
		this.tag = tag;
		this.label = label;
	}
	static var constants = new Map<Int, PolyVariant>();
	public static function constant(tag:Int, label:String):PolyVariant {
		var v = constants.get(tag);
		if (v == null) {
			v = new PolyVariant(tag, label);
			constants.set(tag, v);
		}
		return v;
	}
	public static function arg1<T>(v:PolyVariant, tag:Int):MlOption<T> {
		return v.tag == tag && Std.isOfType(v, PolyVariant1) ? Some((cast v : PolyVariant1<T>).arg) : None;
	}
}
