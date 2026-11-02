import hxmc.objc.AutoreleasePool;
import hxmc.objc.ObjCClass;
import hxmc.objc.Selector;
import hxmc.unsafe.*;

// dealloc (docs/interop.md, "Haxe classes extending Objective-C classes"):
// a Haxe class's override runs once, as a finaliser's, when the object is
// unreachable from both sides, with its fields and messages intact; held by
// Objective-C, not before it lets go; a subclass's calling its Haxe
// superclass's; an object Objective-C made too. Objective-C's own dealloc
// runs afterwards: a weak reference to it turns nil.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements hxmc.objc.Id {
	function dealloc():Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function array():NSMutableArray;
	function addObject(o:NSObject):Void;
	function removeAllObjects():Void;
}

class Res extends NSObject {
	public static var log:Array<String> = [];

	public var name:String;

	public function new(name:String)
		this.name = name;

	public function describe():String
		return name + "(" + name.length + ")";

	override function dealloc()
		log.push("dealloc " + describe());
}

class Sub extends Res {
	override function dealloc() {
		Res.log.push("sub " + name);
		super.dealloc();
	}
}

class Quiet extends NSObject {
	public function new() {}

	override function dealloc()
		Res.log.push("quiet");
}

class Holder {
	@:hxmc.weak public var w:Null<NSObject>;

	public function new() {}
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	@:hxmc.fast @:hxmc.lib("/usr/lib/libSystem.B.dylib") static function dlsym(h:Ptr, name:CString):Ptr;
	@:hxmc.indirect static function send(f:Ptr, o:Ptr, sel:Selector):Ptr;
	static function objc_release(o:Ptr):Void;
}

class ObjCDealloc {
	static function collect() {
		for (_ in 0...3) {
			hxmc.rt.Gc.collect(true);
			hxmc.rt.Gc.runFinalisers();
		}
	}

	static function logged():Array<String> {
		var l = Res.log.copy();
		l.sort(Reflect.compare);
		Res.log = [];
		return l;
	}

	static function churn(prefix:String, n:Int)
		AutoreleasePool.run(() -> for (i in 0...n) new Res(prefix + i));

	static function main() {
		churn("r", 4);
		collect();
		trace("dropped", logged());

		// held by Objective-C: not before it lets go
		var arr = NSMutableArray.array();
		AutoreleasePool.run(() -> arr.addObject(new Res("kept")));
		collect();
		trace("held", logged());
		AutoreleasePool.run(() -> arr.removeAllObjects());
		collect();
		trace("let go", logged());

		// a subclass's, calling its Haxe superclass's
		AutoreleasePool.run(() -> new Sub("s"));
		collect();
		trace("subclass", logged());

		// one Objective-C made, then released
		AutoreleasePool.run(() -> {
			var msg = Rt.dlsym(Ptr.ofI64(-2), cast Mem.cstr("objc_msgSend"));
			var o = Rt.send(msg, Rt.send(msg, cast ObjCClass.of(Quiet), Selector.of("alloc")), Selector.of("init"));
			Rt.objc_release(o);
		});
		collect();
		trace("made by Objective-C", logged());

		// Objective-C's own dealloc afterwards: the weak reference nil
		var h = new Holder();
		AutoreleasePool.run(() -> h.w = new Res("weak"));
		AutoreleasePool.run(() -> trace("weak before", h.w != null));
		collect();
		trace("weak after", logged(), h.w == null);
	}
}
