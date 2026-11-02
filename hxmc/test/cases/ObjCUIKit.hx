import hxmc.objc.AutoreleasePool;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// UIKit's views without an app (Mac Catalyst and the iOS simulator): UIKit
// imported from its platform's place (Catalyst: /System/iOSSupport, where
// Foundation stays macOS's), a view and a label, a Haxe subclass whose
// override UIKit calls (layoutSubviews), a struct through super.
@:hxmc.struct class CGRect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}
@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	var count(default, null):Int64;
	function objectAtIndex(i:Int64):NSObject;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIView extends NSObject {
	static function alloc():UIView;
	function initWithFrame(frame:CGRect):UIView;
	var frame(get, set):CGRect;
	function get_frame():CGRect;
	function set_frame(v:CGRect):CGRect;
	var bounds(default, null):CGRect;
	var subviews(default, null):NSArray;
	var superview(default, null):Null<UIView>;
	var alpha(get, set):Float;
	function get_alpha():Float;
	function set_alpha(v:Float):Float;
	var hidden(get, set):Bool;
	@:selector("isHidden") function get_hidden():Bool;
	function set_hidden(v:Bool):Bool;
	var tag(get, set):Int64;
	function get_tag():Int64;
	function set_tag(v:Int64):Int64;
	function addSubview(v:UIView):Void;
	function viewWithTag(tag:Int64):Null<UIView>;
	function setNeedsLayout():Void;
	function layoutIfNeeded():Void;
	function layoutSubviews():Void;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UILabel extends UIView {
	static function alloc():UILabel;
	var text(get, set):Ptr;
	function get_text():Ptr;
	function set_text(v:Ptr):Ptr;
	var numberOfLines(get, set):Int64;
	function get_numberOfLines():Int64;
	function set_numberOfLines(v:Int64):Int64;
}

class Box extends UIView {
	public var layouts = 0;
	public function new(r:CGRect) super.initWithFrame(r);
	override function layoutSubviews() {
		super.layoutSubviews();
		layouts++;
	}
}

class ObjCUIKit {
	static function show(r:CGRect):String
		return '${r.x} ${r.y} ${r.w} ${r.h}';

	static function main() {
		AutoreleasePool.run(() -> {
			var box = new Box(new CGRect(0, 0, 320, 200));
			var label:UILabel = cast UILabel.alloc().initWithFrame(new CGRect(10, 20, 300, 40));
			label.text = Strings.toNSString("hello from UIKit");
			label.numberOfLines = 2;
			label.tag = 42;
			box.addSubview(label);
			trace("label", Strings.ofNSString(label.text), (label.numberOfLines : Int), show(label.frame));
			trace("box", show(box.bounds), (box.subviews.count : Int), box.viewWithTag(42) == label, label.superview == box);
			box.alpha = 0.5;
			box.hidden = true;
			trace("alpha", box.alpha, "hidden", box.hidden);
			box.setNeedsLayout();
			box.layoutIfNeeded();
			trace("layouts", box.layouts);
			label.frame = new CGRect(1, 2, 3, 4);
			trace("frame", show(label.frame));
		});
		trace("done");
	}
}
