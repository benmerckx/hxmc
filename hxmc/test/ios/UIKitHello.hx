import hxmc.objc.AutoreleasePool;
import hxmc.objc.Block;
import hxmc.objc.Id;
import hxmc.objc.ObjCClass;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// A UIKit app (make native-check NATIVE=uikit, in a bundle: the iOS simulator, iPhone and
// iPad, and Mac Catalyst): the program defines hxmc_ui_main (DataGen.UI_MAIN),
// which runs UIApplicationMain with a Haxe delegate; the delegate makes the
// window, then runs the program's body (hx_main_body), which checks the
// window once it is shown and ends the process.
@:hxmc.struct class CGRect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements Id {
	static function alloc():NSObject;
	function init():NSObject;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIResponder extends NSObject {}
@:hxmc.framework("UIKit") @:hxmc.objc extern interface UIApplicationDelegate extends Id {
	@:selector("application:didFinishLaunchingWithOptions:") @:optional function didFinishLaunching(app:UIApplication, options:Null<NSObject>):Bool;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIApplication extends UIResponder {
	static var sharedApplication(default, null):UIApplication;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIScreen extends NSObject {
	static var mainScreen(default, null):UIScreen;
	var bounds(default, null):CGRect;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIView extends UIResponder {
	static function alloc():UIView;
	function initWithFrame(frame:CGRect):UIView;
	var bounds(default, null):CGRect;
	function addSubview(v:UIView):Void;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UILabel extends UIView {
	static function alloc():UILabel;
	var text(get, set):Ptr;
	function get_text():Ptr;
	function set_text(v:Ptr):Ptr;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIViewController extends UIResponder {
	static function alloc():UIViewController;
	var view(default, null):UIView;
}
@:hxmc.framework("UIKit") @:hxmc.objc extern class UIWindow extends UIView {
	static function alloc():UIWindow;
	var rootViewController(get, set):UIViewController;
	function get_rootViewController():UIViewController;
	function set_rootViewController(v:UIViewController):UIViewController;
	var keyWindow(get, null):Bool;
	@:selector("isKeyWindow") function get_keyWindow():Bool;
	function makeKeyAndVisible():Void;
}
@:hxmc.framework("Foundation") @:hxmc.objc extern class NSTimer extends NSObject {
	@:selector("scheduledTimerWithTimeInterval:repeats:block:")
	static function schedule(interval:Float, repeats:Bool, block:Block<(t:NSTimer) -> Void>):NSTimer;
}
@:hxmc.c @:hxmc.framework("UIKit") extern class UIKit {
	static function UIApplicationMain(argc:Int, argv:Ptr, principal:Null<NSObject>, delegate:Ptr):Int;
}
@:hxmc.c @:hxmc.framework("Foundation") extern class F {
	static function NSStringFromClass(c:ObjCClass):Ptr;
}

class AppDelegate extends UIResponder implements UIApplicationDelegate {
	public static var window:UIWindow;
	public static var label:UILabel;

	public function new() {}

	public function didFinishLaunching(app:UIApplication, options:Null<NSObject>):Bool {
		var w:UIWindow = cast UIWindow.alloc().initWithFrame(UIScreen.mainScreen.bounds);
		var vc:UIViewController = cast UIViewController.alloc().init();
		label = cast UILabel.alloc().initWithFrame(new CGRect(20, 60, 300, 40));
		label.text = Strings.toNSString("hello from hxmc");
		vc.view.addSubview(label);
		w.rootViewController = vc;
		w.makeKeyAndVisible();
		window = w;
		Sys.println("launched");
		// the program's body, now that the app is up
		Mem.call0(Mem.sym("hx_main_body"));
		return true;
	}
}

class UIKitHello {
	@:hxmc.export("hxmc_ui_main") static function uiMain():Void {
		AutoreleasePool.run(() -> {
			UIKit.UIApplicationMain(Mem.getI32(Mem.sym("rt_argc"), 0), Mem.getPtr(Mem.sym("rt_argv"), 0), null, F.NSStringFromClass(ObjCClass.of(AppDelegate)));
		});
	}

	static function main() {
		Sys.println("main");
		// a turn of the run loop later: the window shown
		NSTimer.schedule(0.5, false, _ -> {
			var w = AppDelegate.window;
			Sys.println('window key ${w.keyWindow}, bounds ${w.bounds.w > 0 && w.bounds.h > 0}, label ${Strings.ofNSString(AppDelegate.label.text)}');
			Sys.exit(0);
		});
	}
}
