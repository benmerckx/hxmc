@:hxmc.struct class Rect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.struct class Size {
	public var w:Float; public var h:Float;
	public inline function new(w, h) { this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
	static function alloc():NSView;
	function initWithFrame(frame:Rect):NSView;
	var frame(get, set):Rect;
	function get_frame():Rect;
	function set_frame(v:Rect):Rect;
	var intrinsicContentSize(get, never):Size;
	function get_intrinsicContentSize():Size;
	function layout():Void;
	var hidden(get, set):Bool;
	@:selector("isHidden") function get_hidden():Bool;
	function set_hidden(v:Bool):Bool;
}

class Custom extends NSView {
	public var sets = 0;
	public var layouts = 0;
	public function new(r:Rect) super.initWithFrame(r);
	override function set_frame(v:Rect):Rect {
		sets++;
		return super.set_frame(new Rect(v.x, v.y, v.w + 1, v.h));   // forwarded, changed
	}
	override function get_frame():Rect {
		var f = super.get_frame();                                  // a struct from super
		return new Rect(f.x, f.y, f.w, f.h * 10);
	}
	public var hides:Array<Bool> = [];
	override function set_hidden(v:Bool):Bool {
		hides.push(v);
		return super.set_hidden(v);
	}
	override function get_intrinsicContentSize():Size
		return new Size(123, 45);
	override function layout() {
		layouts++;
		super.layout();
	}
}

class ObjCSuper {
	static function main() {
		var c = new Custom(new Rect(0, 0, 10, 10));
		var v:NSView = c;   // through Objective-C from here on
		v.frame = new Rect(1, 2, 3, 4);
		var f = v.frame;
		trace('frame through both overrides: ${f.x} ${f.y} ${f.w} ${f.h}, setter calls ${c.sets}');
		var s = v.intrinsicContentSize;
		trace('intrinsicContentSize: ${s.w} ${s.h}');
		v.hidden = true;
		v.hidden = false;
		v.hidden = true;
		trace("BOOL arguments: " + c.hides + ", isHidden " + v.hidden);
		v.layout();
		trace("layout calls: " + c.layouts);
	}
}
