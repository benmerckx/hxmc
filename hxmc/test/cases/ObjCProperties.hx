@:hxmc.struct class Rect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	// a category of Foundation's on libobjc's class
	@:hxmc.framework("Foundation") function description():NSString;
}
@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	var UTF8String(get, never):hxmc.unsafe.CString;
	function get_UTF8String():hxmc.unsafe.CString;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
	static function alloc():NSView;
	function initWithFrame(frame:Rect):NSView;
	var frame(get, set):Rect;
	function get_frame():Rect;
	function set_frame(v:Rect):Rect;
	var flipped(get, never):Bool;
	@:selector("isFlipped") function get_flipped():Bool;
	function addSubview(v:NSView):Void;
	function convertRect(rect:Rect, toView:Null<NSView>):Rect;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSScreen extends NSObject {
	static var mainScreen(get, never):Null<NSScreen>;
	static var screens(get, never):NSObject;
	static function get_mainScreen():Null<NSScreen>;
	static function get_screens():NSObject;
}

class Flipped extends NSView {
	public var sets = 0;
	public function new(r:Rect) super.initWithFrame(r);
	override function get_flipped() return true;
	override function set_frame(v:Rect):Rect {
		sets++;
		return super_set(v);
	}
	inline function super_set(v:Rect) return v; // (super.set_frame: objc_msgSendSuper, not yet)
}

class ObjCProperties {
	static function main() {
		var o = NSObject.alloc().init();
		trace("category: " + o.description().UTF8String.toString().substr(0, 10));
		var v = NSView.alloc().initWithFrame(new Rect(1, 2, 3, 4));
		v.frame = new Rect(5, 6, 7, 8);
		var f = v.frame;
		trace('frame ${f.x} ${f.y} ${f.w} ${f.h}, assignment value ${(v.frame = new Rect(9, 9, 9, 9)).w}, flipped ${v.flipped}');
		var fl = new Flipped(new Rect(0, 0, 10, 10));
		trace("override getter, seen by Objective-C: " + (fl : NSView).flipped);
		// AppKit flips coordinates through isFlipped: a subview at y 1 in a flipped parent
		var child = NSView.alloc().initWithFrame(new Rect(0, 1, 2, 2));
		fl.addSubview(child);
		var r = child.convertRect(new Rect(0, 0, 2, 2), fl);
		trace("converted into the flipped view: y " + r.y);
		(fl : NSView).frame = new Rect(0, 0, 20, 20);
		trace("override setter, sent by Objective-C: " + fl.sets);
		trace("class property: " + (NSScreen.screens != null));
	}
}
