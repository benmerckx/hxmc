package ml2hx.rt;

class NotFound extends haxe.Exception {
	public function new() {
		super("Not_found");
	}
	public static function raise():NotFound {
		return new NotFound();
	}
}
