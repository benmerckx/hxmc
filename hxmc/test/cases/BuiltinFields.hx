// A String's and an Array's methods read as fields (Reflect.field, Dynamic
// access) and called with Reflect.callMethod or directly (upstream's unit
// tests Issue6276, Issue6376): they were null ("Cannot call null"); so were an
// enum's constructors read by name (TestReflect).
class BuiltinFields {
	static function main() {
		var s = "bar";
		Sys.println(Reflect.field(s, "length"));
		Sys.println(Reflect.callMethod(s, Reflect.field(s, "charAt"), [0]));
		Sys.println(Reflect.callMethod(s, Reflect.field(s, "charCodeAt"), [1]));
		Sys.println(Reflect.callMethod(s, Reflect.field(s, "indexOf"), ["r"]));
		Sys.println(Reflect.callMethod(s, Reflect.field(s, "split"), ["a"]));
		Sys.println(Reflect.callMethod(s, Reflect.field(s, "substr"), [1, 2]));
		Sys.println(Reflect.callMethod(s, Reflect.field(s, "toUpperCase"), []));
		var d:Dynamic = "foo";
		var indexOf = Reflect.field(d, "indexOf");
		Sys.println(Reflect.callMethod(d, indexOf, ["o", 0]));
		var a = [3, 1, 2];
		var push:Dynamic = Reflect.field(a, "push");
		push(4);
		Sys.println(a);
		var join = Reflect.field(a, "join");
		Sys.println(Reflect.callMethod(a, join, ["-"]));
		var da:Dynamic = a;
		var f:Dynamic = da.copy;
		Sys.println(f());
		Sys.println(Reflect.isFunction(join) + " " + (Reflect.field(a, "nothing") == null));
		// an enum's constructors
		var some:(Dynamic) -> haxe.ds.Option<Dynamic> = Reflect.field(haxe.ds.Option, "Some");
		Sys.println(some("Hello") + " " + Reflect.callMethod(null, Reflect.getProperty(haxe.ds.Option, "Some"), ["x"]));
		Sys.println(Reflect.field(haxe.ds.Option, "None") + " " + (Reflect.field(haxe.ds.Option, "Other") == null));
	}
}
