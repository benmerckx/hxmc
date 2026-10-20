package hxmc.os.android;

// The functions whose presence makes the APK writer add classes.dex
// (hxmc/src/hxmc/android/Glue.hx: USED_BY, VIEWS_USED_BY) and make
// org.hxmc.Activity the activity, as a views library's JNI glue defines
// them: AndroidViews (make android-check) checks the DEX writer's output
// without such a library. Not run.
@:keep
class Glue {
	public static function event(id:Int, kind:Int, object:Int, a:Int, b:Int):Int
		return id + kind + object + a + b;

	public static function setContentView(view:Int):Void {}
}
