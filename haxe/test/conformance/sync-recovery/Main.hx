// A macro that forces a type whose definition refers to a missing type
// (upstream 5f0696800, MacroApi.protect_typing): in display requests and
// diagnostics the typing error is reported and becomes an exception the
// macro catches; in a compilation it is raised as before. -D probe=<name>
// picks the API call (build.hxml).
import haxe.macro.Context;

typedef Broken = Missing;

class Main {
	macro static function probe() {
		var r = try {
			switch Context.definedValue("probe") {
				case "getType": Context.getType("Broken");
				case "followWithAbstracts": Context.followWithAbstracts(Context.getType("Broken"));
				case _: Context.follow(Context.getType("Broken"));
			}
			"forced";
		} catch (e:Dynamic) "caught: " + e;
		return macro $v{r};
	}

	static function main() {
		var s = probe();
		Sys.println(s);
	}
}
