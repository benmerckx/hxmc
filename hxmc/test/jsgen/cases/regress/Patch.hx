package regress;

// wraps a class's method on its prototype (as arma's InterceptCalls does), so that an `__init__`
// using it refers to the class, not to raw JS
class Patch {
	public static function intercept(cls:Class<Dynamic>, name:String, before:() -> Void) {
		var proto:Dynamic = (cast cls).prototype;
		var original = Reflect.field(proto, name);
		Reflect.setField(proto, name, function(n) {
			before();
			return "intercepted " + js.Syntax.code("{0}.call(this, {1})", original, n);
		});
	}
}
