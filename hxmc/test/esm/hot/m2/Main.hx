import esm.hot.Cell;
import esm.hot.Scope;

class Main {
	static function main() {
		// Keep M2 fixtures in the emit graph (hot uses -dce no; explicit refs for smoke compiles).
		Reflect.field(HotClosure, "make");
		Reflect.field(HotCell, "tick");
		Reflect.field(KeyedSite, "run");
	}
}