package statics;

// (a static constructing a class whose constructor names Holder, which it has once Holder's body has run: assigned
// after the file's classes)
class Holder {
	public static final NULL:Named = new NullNamed();

	public static function label() return "null";
}

private class NullNamed implements Named {
	final n:String;

	public function new() n = Holder.label();

	public function name() return n;
}
