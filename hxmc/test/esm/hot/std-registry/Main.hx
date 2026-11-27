// Consumer: entry graph loads only main.mjs at runtime (see harness run.mjs).
class Main {
	static function main() {
		trace(Dom.attrStr(42));
	}
}