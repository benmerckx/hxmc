package staticinitsetup;

@:native("staticinitsetup.RenamedSetup")
class Setup {
	static var seed:Map<String, String>;

	static function __init__() {
		Sys.println("setup");
		seed = ["x" => "works"];
	}

	public static function read():String
		return seed.get("x");
}
