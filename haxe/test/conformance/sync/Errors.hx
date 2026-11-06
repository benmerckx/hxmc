// Errors and warnings that changed with the pin's move to 74c5b464e, one per
// -D probe=<name> (errors.hxml): quoted field names (27d1fbc58), ?var in a
// reified class (886a9c7f2), properties redefined in a subclass (a843e700e),
// abstract fields without an expression called directly (605779e30) and the
// enum equality warning (ada6156b1).
enum E {
	A;
	B(i:Int);
}

abstract Op(Int) from Int {
	@:op(A + B) function add(o:Op):Op;
}

class Base {
	public var a(get, never):Int;
	public var b(get, set):Int;
	public var c:Int = 0;
	function get_a() return 1;
	function get_b() return 1;
	function set_b(v) return v;
	public function new() {}
}

#if (probe == "less-visible")
class Child extends Base {
	var a(get, never):Int;
}
#elseif (probe == "other-accessor")
class Child extends Base {
	public var b(get, default):Int;
}
#elseif (probe == "physical")
class Child extends Base {
	public var c:Int;
}
#elseif (probe == "same-accessors")
class Child extends Base {
	public var b(get, set):Int;
}
#end

class Errors {
	static function main() {
		#if (probe == "single-quotes")
		var o:{'x':Int} = {x: 1};
		#elseif (probe == "invalid-name")
		var o:{"a b":Int} = null;
		#elseif (probe == "access-single-quotes")
		var o = {x: 1};
		trace(o.'x');
		#elseif (probe == "access-invalid-name")
		var o = {x: 1};
		trace(o."1x");
		#elseif (probe == "class-quoted")
		var o:{} = null;
		#elseif (probe == "macro-class-optional")
		var c = macro class {
			var ?x:Int;
		};
		#elseif (probe == "no-expr")
		var o:Op = 1;
		@:privateAccess Op.add(o, o);
		#elseif (probe == "enum-eq")
		var e = A;
		var f = B(1);
		trace(e == A, A == e, e != A, e == f);
		#end
		Sys.println("ran");
	}
}
