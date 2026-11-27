class StaticInitInstance {
	static final look = new Look().make("blue");

	static function main() {
		Sys.println(look);
	}
}

private class Look {
	public function new() {}

	public function make(accent:String):String
		return Tokens.of(accent);
}

private class Tokens {
	static final ACCENTS = ["blue" => "#0562ef", "red" => "#d1403a"];

	public static function of(accent:String):String
		return ACCENTS.get(accent);
}
