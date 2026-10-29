@:hxmc.struct class Rect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
	static function alloc():NSView;
	function initWithFrame(frame:Rect):NSView;
	var frame:Rect;
}
class V extends NSView {
	public function new(r:Rect) {
		trace("before");
		super.initWithFrame(r);
		trace("after");
	}
}
class W extends NSView {
	public var n = 1;
	public function new() {}
}
class ObjCInit {
	static function main() {
		var w = new W();
		trace("W " + w.frame.w);
		var v = new V(new Rect(1, 2, 3, 4));
		trace("V " + v.frame.w);
	}
}
