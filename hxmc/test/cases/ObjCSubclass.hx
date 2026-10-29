import hxmc.unsafe.*;

@:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function description():NSString;
	function retainCount():Int;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function alloc():NSString;
	function initWithUTF8String(s:CString):NSString;
	var UTF8String(default, null):CString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
	function objectAtIndex(i:Int64):NSObject;
	function removeAllObjects():Void;
	var count(default, null):Int64;
}

@:hxmc.c @:hxmc.lib("/System/Library/Frameworks/Foundation.framework/Foundation") extern class F {
	static function NSSelectorFromString(s:NSString):Ptr;
}

class Greeter extends NSObject {
	public var name:String;
	public var greeted = 0;

	public function new(name:String) {
		trace("ctor");
		this.name = name;
	}

	override function description():NSString
		return NSString.alloc().initWithUTF8String(cast Mem.cstr("Greeter")); // (literal only, for now)

	public function greet(who:NSString):Void {
		greeted++;
		trace('$name greets ${who.UTF8String.toString()} ($greeted)');
	}
}

@:hxmc.objc extern class Performer extends NSObject {
	@:selector("performSelector:withObject:") function perform(sel:Ptr, o:NSObject):NSObject;
}

class ObjCSubclass {
	static inline function ns(s:String):NSString
		return NSString.alloc().initWithUTF8String(cast Mem.cstr(s));

	static function main() {
		trace("start");
		var g = new Greeter("Ada");
		trace("made");
		var arr = NSMutableArray.alloc().init();
		arr.addObject(g);
		trace("added");
		trace(arr.description().UTF8String.toString());
		var p:Performer = cast arr.objectAtIndex(0);
		p.perform(F.NSSelectorFromString(ns("greet:")), ns("Bob"));
		trace(g.greeted);

		// toggle: kept alive only by the array, the Haxe object must survive collections
		for (i in 0...3) arr.addObject(new Greeter("G" + i));
		g = null;
		churn();
		for (i in 0...4) {
			var o:Performer = cast arr.objectAtIndex(i);
			o.perform(F.NSSelectorFromString(ns("greet:")), ns("you"));
		}
		// released by the array: the peers become weak and are collected
		arr.removeAllObjects();
		churn();
		toggles();
		trace("done");
	}

	public static function churn() {
		var keep = [];
		for (i in 0...2000000) {
			var a = [i, i + 1];
			if (i % 1000 == 0) keep.push(a);
		}
		trace("churned " + keep.length);
	}

	// kept alive by Objective-C alone, then released by it: collected
	static function toggles() {
		var arr = NSMutableArray.alloc().init();
		var slots = LibC.malloc(8 * 3);
		for (i in 0...3) {
			var g = new Greeter("W" + i);
			arr.addObject(g);
			Mem.setPtr(slots, 8 * i, Ptr.nil());
			Rt.objc_storeWeak(slots.add(8 * i), g);
		}
		churn();
		trace("held by the array: " + [for (i in 0...3) alive(slots.add(8 * i))]);
		arr.removeAllObjects();
		hxmc.rt.Gc.collect(true);
		trace("after removal: " + [for (i in 0...3) alive(slots.add(8 * i))]);
	}

	static function alive(loc:Ptr):Bool {
		var o = Rt.objc_loadWeakRetained(loc);
		if (o == null) return false;
		Rt.objc_release(o);
		return true;
	}
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	static function objc_storeWeak(loc:Ptr, o:NSObject):NSObject;
	static function objc_loadWeakRetained(loc:Ptr):Null<NSObject>;
	static function objc_release(o:NSObject):Void;
}
