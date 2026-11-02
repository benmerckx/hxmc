import hxmc.objc.AutoreleasePool;
import hxmc.objc.ObjCClass;
import hxmc.objc.Selector;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// objects of Haxe classes Objective-C makes (docs/interop.md, "Haxe classes
// extending Objective-C classes"): the initializer the constructor calls on
// super (init when none), sent by Objective-C to an object it allocated,
// runs the constructor, which makes the Haxe object of that object; one
// without its own constructor, the inherited one's; a factory of the
// Objective-C class making them; then sent methods and seen from Haxe as
// any. Methods an initializer sends find the Haxe object.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements hxmc.objc.Id {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSError extends NSObject {
	@:selector("initWithDomain:code:userInfo:") function initWithDomain(domain:NSString, code:Int64, userInfo:Null<NSObject>):NSError;
	@:selector("errorWithDomain:code:userInfo:") static function errorWithDomain(domain:NSString, code:Int64, userInfo:Null<NSObject>):NSError;
	function code():Int64;
	function domain():NSString;
}

class Counter extends NSObject {
	public static var made = 0;

	public var serial:Int;
	public var tags:Array<String> = ["field initializer"];

	public function new() {
		serial = ++made;
	}

	public function serialNumber():Int
		return serial;
}

// its constructor the inherited one
class SubCounter extends Counter {}

class AppError extends NSError {
	public static var made = 0;

	public var note:String;

	public function new(domain:NSString, code:Int64, userInfo:Null<NSObject>) {
		made++;
		note = "made with " + code.toInt();
		super.initWithDomain(domain, code, userInfo);
	}

	public function describe():String
		return note + " in " + Strings.ofNSString(cast domain());
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	@:hxmc.fast @:hxmc.lib("/usr/lib/libSystem.B.dylib") static function dlsym(h:Ptr, name:CString):Ptr;
	@:hxmc.indirect static function send(f:Ptr, o:Ptr, sel:Selector):Ptr;
	@:hxmc.indirect static function sendInt(f:Ptr, o:Ptr, sel:Selector):Int;
	@:hxmc.indirect static function initError(f:Ptr, o:Ptr, sel:Selector, domain:NSString, code:Int64, info:Ptr):Ptr;
	static function objc_release(o:Ptr):Void;
}

class ObjCAdopt {
	static function main() AutoreleasePool.run(() -> {
		var msg = Rt.dlsym(Ptr.ofI64(-2), cast Mem.cstr("objc_msgSend"));
		// one made by Haxe first (entry 1 of the runtime's table)
		var first = new Counter();
		// [[Counter alloc] init] by Objective-C: its own Haxe object
		var o = Rt.send(msg, Rt.send(msg, cast ObjCClass.of(Counter), Selector.of("alloc")), Selector.of("init"));
		trace("made by Objective-C", Rt.sendInt(msg, o, Selector.of("serialNumber")), first.serial, Counter.made);
		var c:Counter = cast o;
		trace("seen from Haxe", c.serial, c.tags, c == (cast o : Counter), c != first);
		// a subclass without its own constructor
		var s = Rt.send(msg, Rt.send(msg, cast ObjCClass.of(SubCounter), Selector.of("alloc")), Selector.of("init"));
		var sc:Counter = cast s;
		trace("subclass", Rt.sendInt(msg, s, Selector.of("serialNumber")), Std.isOfType(sc, SubCounter), Counter.made);
		// an initializer with arguments, sent by Objective-C, and the class's
		// factory (alloc and the initializer, in Foundation)
		var e = Rt.initError(msg, Rt.send(msg, cast ObjCClass.of(AppError), Selector.of("alloc")), Selector.of("initWithDomain:code:userInfo:"),
			cast Strings.toNSString("org.example"), 42, Ptr.nil());
		trace("initializer with arguments", (cast e : AppError).describe(), AppError.made);
		var f:AppError = cast Rt.initError(msg, cast ObjCClass.of(AppError), Selector.of("errorWithDomain:code:userInfo:"), cast Strings.toNSString("org.example.factory"), 7,
			Ptr.nil());
		trace("factory", f.describe(), f.code().toInt(), AppError.made);
		// and made by Haxe, as before
		var h = new AppError(cast Strings.toNSString("org.example.haxe"), 1, null);
		trace("made by Haxe", h.describe(), AppError.made);
		// (Objective-C's references given up: collectable then)
		Rt.objc_release(o);
		Rt.objc_release(s);
		Rt.objc_release(e);
		for (_ in 0...3)
			hxmc.rt.Gc.collect(true);
		trace("after", first.serialNumber(), Counter.made);
	});
}
