// AndroidHello with the views glue's functions (hxmc.os.android.Glue): the
// APK carries classes.dex and org.hxmc.Activity (make android-check; not run)
class AndroidViews extends AndroidHello {
	static function main() {
		hxmc.os.android.Glue.setContentView(hxmc.os.android.Glue.event(1, 2, 3, 4, 5));
	}
}
