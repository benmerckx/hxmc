// Exceptions across Objective-C's frames: an Objective-C exception reaching
// a Haxe frame is a Haxe throw of the object (a typed catch tests its class,
// Std.string is its description); a Haxe exception leaving a method or block
// Objective-C called is raised as an Objective-C exception, which unwinds
// Objective-C's frames and is the Haxe value again in a Haxe frame.
import hxmc.objc.Selector;
import hxmc.unsafe.*;

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:selector("performSelector:") function perform(sel:Selector):Null<NSObject>;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function stringWithUTF8String(s:Ptr):NSString;
	function UTF8String():Ptr;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSException extends NSObject {
	static function exceptionWithName(name:NSString, reason:NSString, userInfo:Null<NSObject>):NSException;
	function name():NSString;
	function reason():NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	static function array():NSArray;
	static function arrayWithObject(o:NSObject):NSArray;
	function objectAtIndex(i:Int64):NSObject;
	function enumerateObjectsUsingBlock(block:(obj:NSObject, idx:Int64, stop:Ptr) -> Void):Void;
}

class MyError {
	public final what:String;

	public function new(what)
		this.what = what;

	public function toString()
		return "MyError(" + what + ")";
}

class Thrower extends NSObject {
	public function new() {}

	// a Haxe exception leaving a method
	public function fail():Null<NSObject>
		throw new MyError("from a method");

	// an Objective-C exception leaving a method, through its Haxe frame
	public function outOfRange():Null<NSObject>
		return NSArray.array().objectAtIndex(3);

	// a Haxe throw of an Objective-C exception
	public function raise():Null<NSObject>
		throw NSException.exceptionWithName(ObjCExceptions.ns("Custom"), ObjCExceptions.ns("raised by Haxe"), null);

	// one caught in the method: nothing leaves it
	public function contained():Null<NSObject> {
		try {
			NSArray.array().objectAtIndex(1);
		} catch (e:NSException) {
			trace("contained: " + ObjCExceptions.str(e.name()));
		}
		return null;
	}
}

class ObjCExceptions {
	public static function ns(s:String):NSString
		return cast hxmc.objc.Strings.toNSString(s);

	public static function str(s:NSString):String
		return hxmc.objc.Strings.ofNSString(cast s);

	static function main() {
		// an Objective-C exception: caught by its class, by Dynamic, as haxe.Exception
		try {
			NSArray.array().objectAtIndex(5);
		} catch (e:NSException) {
			trace(str(e.name()) + ": " + str(e.reason()));
		}
		try {
			NSArray.array().objectAtIndex(6);
		} catch (e:Dynamic) {
			trace("Dynamic: " + Std.isOfType(e, NSException) + " " + Std.string(e));
		}
		try {
			NSArray.array().objectAtIndex(7);
		} catch (e:haxe.Exception) {
			trace("haxe.Exception: " + e.message);
		}
		// a class test sees through other values: a string is no NSException
		try {
			throw "a string";
		} catch (e:NSException) {
			trace("wrong: NSException");
		} catch (e:String) {
			trace("String: " + e);
		}
		var d:Dynamic = new MyError("x");
		trace("isOfType: " + Std.isOfType(d, NSObject) + " " + Std.isOfType("s", NSObject) + " " + (Std.downcast(d, NSObject) == null));

		var t:NSObject = new Thrower();
		// a Haxe exception through performSelector: is itself again
		var mine = null;
		try {
			t.perform(Selector.of("fail"));
		} catch (e:MyError) {
			mine = e;
			trace("round trip: " + e);
		}
		try {
			t.perform(Selector.of("fail"));
		} catch (e:NSException) {
			trace("wrong: NSException");
		} catch (e:Dynamic) {
			trace("not the same object: " + (e != mine));
		}
		// an Objective-C exception through a Haxe method and back
		try {
			t.perform(Selector.of("outOfRange"));
		} catch (e:NSException) {
			trace("through a method: " + str(e.name()));
		}
		var raised = null;
		try {
			t.perform(Selector.of("raise"));
		} catch (e:NSException) {
			raised = e;
			trace("raised: " + str(e.name()) + ": " + str(e.reason()));
		}
		t.perform(Selector.of("contained"));
		// from a block Objective-C calls
		try {
			NSArray.arrayWithObject(t).enumerateObjectsUsingBlock((o, idx, stop) -> throw new MyError("from a block"));
		} catch (e:MyError) {
			trace("block: " + e);
		}
		// many, with collections between (the pairs, the boxes, the handlers)
		var n = 0;
		for (i in 0...2000) {
			try {
				if (i % 2 == 0) t.perform(Selector.of("fail")) else NSArray.array().objectAtIndex(i);
			} catch (e:MyError) {
				n++;
			} catch (e:NSException) {
				n += 2;
			}
			if (i % 100 == 0) {
				var junk = [for (k in 0...1000) Std.string(k)];
				hxmc.NativeGc.collect(true);
			}
		}
		trace("many: " + n);
		trace("done");
	}
}
