import hxmc.objc.AutoreleasePool;
import hxmc.objc.Selector;
import hxmc.unsafe.*;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
	function release():Void;
	function retain():NSObject;
	function respondsToSelector(s:Selector):Bool;
	@:selector("performSelector:withObject:") function perform(sel:Selector, o:Null<NSObject>):Null<NSObject>;
	@:hxmc.framework("Foundation") function description():NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function alloc():NSString;
	function initWithUTF8String(s:CString):NSString;
	var UTF8String(default, null):CString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	var count(default, null):Int64;
	function objectAtIndex(i:Int64):NSObject;
	function sortedArrayUsingSelector(s:Selector):NSArray;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSArray {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
}

// a protocol no image declares: made at run time
@:hxmc.objc extern interface Greeter {
	function greet(s:NSString):NSString;
	@:optional function wave():Void;
}

@:hxmc.struct @:publicFields class Pt {
	var x:Float;
	var y:Float;

	function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

class Info {
	public var text:String;

	public function new(text)
		this.text = text;
}

@:hxmc.objc class Counter extends NSObject implements Greeter {
	public extern static function alloc():Counter;

	public var count:Int;
	public var scale:Float;
	public var on:Bool;
	public var at:Pt;
	public var name:Null<NSString>;
	@:hxmc.weak public var buddy:Null<NSObject>;
	@:hxmc.weak public var info:Null<Info>;

	public static var log:Array<String> = [];

	public static function ns(s:String):NSString
		return cast hxmc.objc.Strings.toNSString(s);

	override function init():Counter {
		super.init();
		count = 10;
		log.push("init");
		return this;
	}

	public function initWithCount(n:Int):Counter {
		var self = super.init();
		count = n;
		log.push("initWithCount " + n + " " + (self == this));
		return this;
	}

	public function bump(by:Int):Int {
		count += by;
		return count;
	}

	public function greet(s:NSString):NSString
		return ns("hello " + s.UTF8String.toString() + " from " + count);

	public function compare(o:Counter):Int64
		return count < o.count ? -1 : count > o.count ? 1 : 0;

	public function poke(o:Null<NSObject>):Null<NSObject> {
		log.push("poke " + count + " " + (o == null ? "nil" : (cast o : Counter).count + ""));
		return this;
	}

	override function respondsToSelector(s:Selector):Bool {
		if (s == Selector.of("wave")) return false;
		return super.respondsToSelector(s);
	}

	override function description():NSString
		return ns("Counter(" + count + ")");

	override function dealloc() {
		log.push("dealloc " + count + (name != null ? " " + name.UTF8String.toString() : ""));
	}
}

@:hxmc.objc("HxDoubler") class Doubler extends Counter {
	public extern static function alloc():Doubler;

	public var extra:Int;

	override function bump(by:Int):Int {
		extra++;
		return super.bump(by * 2);
	}

	override function dealloc() {
		Counter.log.push("Doubler dealloc " + extra);
	}
}

// an initializer returning another object than its receiver (a class
// cluster's): the receiver released, the other one returned (+1)
@:hxmc.objc class Swapper extends Counter {
	public extern static function alloc():Swapper;

	public static var other:Null<Counter>;

	override function init():Counter {
		release();
		return other;
	}
}

// `this` after super.init...(...) is what it returned (`self = [super init]`)
@:hxmc.objc class SwapUser extends Swapper {
	public extern static function alloc():SwapUser;

	override function init():Counter {
		var before = count;
		var r = super.init();
		Counter.log.push("SwapUser: this is the result " + (this == r) + ", count " + before + " -> " + count);
		return this;
	}
}

class Peer extends Counter {
	public var haxe = "peer";

	public function new(n:Int) {
		super.initWithCount(n);
	}

	override function bump(by:Int):Int
		return super.bump(by + 100);
}

class ObjCMode {
	static function flush() {
		for (l in Counter.log)
			trace(l);
		Counter.log = [];
	}

	static function main() {
		AutoreleasePool.run(() -> {
			var c = Counter.alloc().init();
			trace(c.count, c.scale, c.on);
			c.scale = 1.5;
			c.on = true;
			c.at = new Pt(3, 4);
			c.at.x = 30; // (in place, as a C struct instance variable)
			trace(c.count, c.scale, c.on, c.at.x, c.at.y);
			trace(c.bump(5));
			c.count++;
			c.count += 2;
			trace(c.count);
			c.name = Counter.ns("first");
			trace(c.name.UTF8String.toString());
			trace(c.description().UTF8String.toString());
			trace(c.greet(Counter.ns("Ada")).UTF8String.toString());
			// from Objective-C: performSelector:withObject:
			var r = c.perform(Selector.of("poke:"), null);
			trace(r == c);
			trace("respondsToSelector bump: " + c.respondsToSelector(Selector.of("bump:")) + ", wave: " + c.respondsToSelector(Selector.of("wave"))
				+ ", greet: " + c.respondsToSelector(Selector.of("greet:")));
			trace(Std.isOfType(c, Counter), Std.isOfType(c, Doubler), Std.isOfType(c, Greeter), Std.isOfType(c, NSString));
			var o:NSObject = c;
			var back = Std.downcast(o, Counter);
			trace(back == c, Std.downcast(o, Doubler) == null);
			var d:Dynamic = c;
			trace(Std.isOfType(d, Counter));
		});
		flush();
		AutoreleasePool.run(() -> {
			var d:Doubler = cast Doubler.alloc().initWithCount(1);
			trace(d.bump(3), d.extra, d.count);
			var c:Counter = d;
			trace(c.bump(1), d.extra); // a message: the subclass's
			trace(Std.isOfType(c, Doubler));
			// a framework calling back: sorted by compare:
			var a = NSMutableArray.alloc().init();
			for (n in [5, 2, 9, 1])
				a.addObject(Counter.alloc().initWithCount(n));
			var s = a.sortedArrayUsingSelector(Selector.of("compare:"));
			trace([for (i in 0...s.count.toInt()) (cast s.objectAtIndex(i) : Counter).count]);
			// held by Haxe: an array, a closure
			var held = [Counter.alloc().initWithCount(42)];
			var f = () -> held[0].count;
			trace(f());
		});
		flush();
		AutoreleasePool.run(() -> {
			Swapper.other = Counter.alloc().initWithCount(77);
			var s = SwapUser.alloc().init();
			trace(s == Swapper.other, s.count);
			Swapper.other = null;
		});
		flush();
		AutoreleasePool.run(() -> {
			var p = new Peer(3);
			trace(p.count, p.bump(1), p.haxe);
		});
		flush();
		hxmc.rt.Gc.collect(true);
		hxmc.rt.Gc.collect(true);
		trace("collected");
		flush();
		trace("done");
	}
}
