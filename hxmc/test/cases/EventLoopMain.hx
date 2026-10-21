// The event loop after main (haxe.EntryPoint.run, which the compiler adds to
// the main expression when the program keeps it): hxmc called main alone, so
// haxe.Timer and haxe.MainLoop events never ran and the process ended
// (upstream's threads suite: its async tests).
class EventLoopMain {
	static function main() {
		var t = new haxe.Timer(5);
		var n = 0;
		t.run = () -> {
			n++;
			Sys.println("tick " + n);
			if (n == 3) t.stop();
		};
		haxe.Timer.delay(() -> Sys.println("delayed"), 300);
		haxe.EventLoop.main.run(() -> Sys.println("an event"));
		Sys.println("main done");
	}
}
