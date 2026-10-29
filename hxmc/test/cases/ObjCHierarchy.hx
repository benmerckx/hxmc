@:hxmc.struct class Rect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:hxmc.framework("Foundation") function className():NSString;
	@:selector("performSelector:") function perform(sel:hxmc.objc.Selector):Null<NSObject>;
}
@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	var UTF8String(get, never):hxmc.unsafe.CString;
	function get_UTF8String():hxmc.unsafe.CString;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
	static function alloc():NSView;
	function initWithFrame(frame:Rect):NSView;
	var flipped(get, never):Bool;
	@:selector("isFlipped") function get_flipped():Bool;
	function layout():Void;
	var frame(get, set):Rect;
}

class Base extends NSView {
	public var log:Array<String> = [];
	public function new(r:Rect) super.initWithFrame(r);
	override function layout() {
		log.push("Base.layout");
		super.layout(); // NSView's
	}
}

class Sub extends Base {
	public function new(r:Rect, tag:String) {
		super(r);
		log.push("Sub.new " + tag);
	}
	override function get_flipped() return true;
	override function layout() {
		log.push("Sub.layout");
		super.layout(); // Base's (Haxe)
	}
	public function hello():Null<NSObject> {
		log.push("Sub.hello");
		return null;
	}
}

class Leaf extends Sub {} // no constructor of its own: Sub's

class ObjCHierarchy {
	static function name(o:NSObject):String
		return o.className().UTF8String.toString();

	static function main() {
		var b = new Base(new Rect(0, 0, 1, 1));
		var s = new Sub(new Rect(0, 0, 1, 1), "s");
		var l = new Leaf(new Rect(0, 0, 1, 1), "l");
		trace([name(b), name(s), name(l)]);
		for (v in [b, s, (l : Base)]) {
			var o:NSView = v;
			o.layout();
			trace(name(o) + ": flipped " + o.flipped + ", " + v.log);
		}
		(l : NSObject).perform(hxmc.objc.Selector.of("hello"));
		trace("hello through Objective-C: " + l.log[l.log.length - 1]);
	}
}
