// Dynamic methods through an interface (upstream's unit.issues.Issue3159):
// a call through the interface calls the field's current function, not the
// method; reads and assignments through the interface, a structure and
// Dynamic see the same field; a subclass overriding the dynamic method, and
// an interface extending another. The output is the reference's (--interp).
interface IHas {
	dynamic function foo():Void;
	dynamic function bar(x:Int):Int;
}

interface IMore extends IHas {
	function baz():String;
}

class Impl implements IMore {
	public var log:Array<String> = [];

	public function new() {}

	public dynamic function foo()
		log.push("Impl.foo");

	public dynamic function bar(x:Int):Int
		return x + 1;

	public function baz()
		return "baz " + log.join(",");
}

class Sub extends Impl {
	override public dynamic function foo()
		log.push("Sub.foo");

	override public dynamic function bar(x:Int):Int
		return x * 10;
}

class InterfaceDynMethod {
	static function run(name:String, o:Impl) {
		var i:IHas = o;
		i.foo();
		trace(name + " " + i.bar(4) + " " + o.log);
		i.foo = () -> o.log.push("assigned through the interface");
		i.foo();
		o.foo();
		trace(name + " " + o.log);
		var g = i.foo;
		g();
		trace(name + " " + o.log.length);
		i.bar = x -> x - 1;
		trace(name + " " + i.bar(4) + " " + o.bar(4));
		o.bar = x -> x * x;
		trace(name + " " + i.bar(4));
		var m:IMore = o;
		m.foo = () -> o.log.push("through IMore");
		m.foo();
		trace(name + " " + m.baz());
		var d:Dynamic = o;
		d.foo = () -> o.log.push("through Dynamic");
		i.foo();
		trace(name + " " + o.log[o.log.length - 1]);
		Reflect.setField(o, "bar", (x:Int) -> 7);
		trace(name + " " + i.bar(0));
		var s:{function bar(x:Int):Int;} = o;
		trace(name + " " + s.bar(1));
	}

	static function main() {
		run("impl", new Impl());
		run("sub", new Sub());
		var fresh:IHas = new Sub();
		var f = fresh.bar;
		trace(f(3));
		// (the field before first use, by name: the method)
		var s:{function bar(x:Int):Int;} = new Impl();
		trace(s.bar(1));
		var d:Dynamic = new Sub();
		trace(d.bar(2));
		trace(Reflect.field(new Impl(), "bar")(3));
		var again:IHas = new Impl();
		trace(again.bar(5));
	}
}
