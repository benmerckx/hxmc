package org.hxmc.demo;

import android.app.Activity;
import android.os.Bundle;

// The app's Java: what a packager writes around hxmc's libmain.so. Loading
// the library runs JNI_OnLoad, and with it the program's main, which sets
// boot; the activity then hands itself to it, on the UI thread.
public class MainActivity extends Activity {
	public static Activity current;
	public static Runnable boot;

	@Override
	protected void onCreate(Bundle saved) {
		super.onCreate(saved);
		current = this;
		System.loadLibrary("main");
		if (boot != null) boot.run();
	}
}
