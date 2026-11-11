// An abstract class that leaves an interface's method to its subclasses gets
// the interface's field as its own (TypeloadCheck's implicit field: a copy of
// the field that shares its metadata). Applying @:native (core.Native)
// prepends @:realPath to each field's metadata. Upstream's lists are
// immutable, so each of the two fields gets one; a list changed in place gave
// both fields both entries (Probe prints the metadata after generation).
interface Named {
	@:native("nativeName") function name():String;
}

@:keep
abstract class Base implements Named {
	public function new() {}
}

@:keep
class Impl extends Base {
	public function name():String return "impl";
}

class SharedFieldMeta {
	static function main() {
		var n:Named = new Impl();
		trace(n != null);
	}
}
