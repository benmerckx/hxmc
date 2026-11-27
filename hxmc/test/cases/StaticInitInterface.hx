class StaticInitInterface {
	static final look = make(new Look());

	static function make(look:AccentLookup):String
		return look.make("blue");

	static function main() {
		Sys.println(look);
	}
}

private interface AccentLookup {
	function make(accent:String):String;
}

private class Look implements AccentLookup {
	public function new() {}

	public function make(accent:String):String
		return Tokens.of(accent);
}

private class Tokens {
	static final ACCENTS = ["blue" => "#0562ef", "red" => "#d1403a"];

	public static function of(accent:String):String
		return ACCENTS.get(accent);
}
