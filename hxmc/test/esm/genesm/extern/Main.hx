// Pull a large js.html typing graph; Genesm must not emit .mjs for those extern modules.
class Main {
	static function main() {
		js.Browser.document.getElementById("x");
	}
}