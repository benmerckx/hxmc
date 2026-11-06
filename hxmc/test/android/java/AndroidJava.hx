import android.util.Log;
import android.view.View;
import android.view.View.View_OnClickListener;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import hxmc.java.Jvm;
import hxmc.unsafe.*;
import org.hxmc.demo.MainActivity;

// An Android app's library whose Java API comes from android.jar itself
// (--java-lib-extern android.jar, codegen.JavaModern): no declarations
// written by hand. MainActivity (shell/, the packager's) loads it: its
// JNI_OnLoad runs main, which gives MainActivity a Haxe Runnable; on the UI
// thread that builds the activity's views, and a Haxe OnClickListener
// answers the button.
class AndroidJava {
	@:hxmc.export("JNI_OnLoad") @:hxmc.unsafe static function onLoad(vm:Ptr, reserved:Ptr):Int
		return Jvm.onLoad(vm);

	static function main() {
		Log.i("hxmc", "main: Jvm.exists " + Jvm.exists);
		MainActivity.boot = new Ui();
	}
}

class Ui implements java.lang.Runnable {
	public function new() {}

	public function run() {
		var activity = MainActivity.current;
		Log.i("hxmc", "onCreate on " + java.lang.Thread.currentThread().getName());
		var layout = new LinearLayout(activity);
		layout.setOrientation(LinearLayout.VERTICAL);
		var label = new TextView(activity);
		label.setText("Hello from hxmc");
		label.setTextSize(28);
		layout.addView(label);
		var button = new Button(activity);
		button.setText("Tap me");
		button.setOnClickListener(new Taps(label));
		layout.addView(button);
		activity.setContentView(layout);
		Log.i("hxmc", "views set: " + label.getText().toString());
	}
}

class Taps implements View_OnClickListener {
	var label:TextView;
	var count = 0;

	public function new(label)
		this.label = label;

	public function onClick(v:View) {
		count++;
		var squares = [for (i in 0...count) i * i];
		label.setText('tapped $count: ' + squares.join(","));
		Log.i("hxmc", "tapped " + count);
	}
}
