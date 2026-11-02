import hxmc.unsafe.*;

// Reflection by run-time names keeps only the classes the program can name
// (hxmc.ir.Reach; docs/hxmc.md, "Reachability"; issue #134): a class of
// another target, which only the types of code kept for reflection mention,
// is not kept, so the C functions of that target's library (here one that
// exists nowhere) are not linked: the program links and runs on every
// target, without the library (ElfCheck: no DT_NEEDED for it). A test of
// the target in a condition with && folds too (FnLower), so what its other
// side calls is never reached. The classes it can name stay: those it makes,
// those a type of live code names (as Haxe's -dce full keeps them), those
// @:keep keeps; found by Type.resolveClass with names built at run time,
// made by Type.createInstance and createEmptyInstance, their methods called
// by Reflect.callMethod.
@:hxmc.c @:hxmc.lib("libhxmc-other-target.so") extern class OtherTarget {
	static function hxmc_other_target_finish(n:Int):Int;
}

// (Android's only, as helder's AndroidWindow: its methods call the library;
// its statics are used on every target, which makes their initializer and
// the types they name lowered; its __init__ runs on Android only)
@:hxmc.android
class Phone {
	public static var current:Null<Phone> = null;
	public static var count = 0;

	public var n = 1;

	static function __init__()
		Sys.println("android init");

	public function new() {}

	public function finish():Int
		return OtherTarget.hxmc_other_target_finish(n);

	public static function finishAll(n:Int):Int
		return OtherTarget.hxmc_other_target_finish(n);
}

// a type the code kept for reflection mentions
class Tablet {
	public var size = 10;

	public function new() {}

	public function describe():String
		return "tablet " + size;
}

class Window {
	public var title:String;
	// (the field's type: Phone, of another target; Tablet's is named)
	public var phone:Null<Phone> = null;

	public function new(title:String) {
		this.title = title;
	}

	public function hello():String
		return "window " + title;

	public function phoneOf():Null<Phone>
		return Mem.target() >= 9 ? new Phone() : null;

	public function tabletOf(t:Tablet):String
		return t.describe();
}

@:keep
class Plugin {
	public function new() {}

	public function hello():String
		return "plugin";
}

class ReflectTargets {
	// a name built at run time, from character codes
	static function nameOf(codes:Array<Int>):String
		return [for (c in codes) String.fromCharCode(c)].join("");

	static function main() {
		var w = new Window("main");
		trace(w.hello() + " " + Phone.count + " " + (Phone.current == null));
		// (Android only: both sides fold away elsewhere)
		if (Mem.target() >= 9 && Sys.args().length >= 0) trace(Phone.finishAll(2));
		if (Mem.target() < 9 || Phone.finishAll(3) > 0) trace("not android");
		var window = nameOf([87, 105, 110, 100, 111, 119]);
		var hello = nameOf([104, 101, 108, 108, 111]);
		for (n in [window, nameOf([84, 97, 98, 108, 101, 116]), nameOf([80, 108, 117, 103, 105, 110]), nameOf([80, 104, 111, 110, 101])]) {
			var c = Type.resolveClass(n);
			if (c == null) {
				trace(n + " not found");
				continue;
			}
			var o:Dynamic = Type.createInstance(c, n == window ? ["made"] : []);
			var e:Dynamic = Type.createEmptyInstance(c);
			trace(Type.getClassName(c) + " " + Type.getInstanceFields(c).length + " " + Std.isOfType(e, c));
			var f = Reflect.field(o, n == window ? hello : nameOf([100, 101, 115, 99, 114, 105, 98, 101]));
			if (f == null) f = Reflect.field(o, hello);
			trace(f == null ? "no method" : Reflect.callMethod(o, f, []));
		}
		// (a class unserialized by name: haxe.Unserializer's Type.resolveClass and createEmptyInstance)
		var s = haxe.Serializer.run(w);
		var u:Window = haxe.Unserializer.run(s);
		trace(u.hello() + " " + Type.getClassName(Type.getClass(u)));
		try {
			haxe.Unserializer.run("cy5:Phoneg");
		} catch (e:Dynamic) {
			trace(Std.string(e));
		}
	}
}
