// not-live: haxe_EventLoop__init
// haxe.Timer.stamp() (inline: Sys.time()) keeps no event loop. Typing
// haxe.Timer loads haxe.EventLoop (the type of Timer's `event`) and hxmc's
// sys.thread.Thread, whose `events` reads haxe.EventLoop; hxmc's std is a
// user class path, so Haxe's default DCE kept that override whole, and with
// it haxe.EventLoop and its __init__ (the main loop, the threads'
// callbacks): more than doubling the executable. Its overrides are DCE'd as
// the std now (hxmc.StdDce).
class TimerStamp {
	static function main() {
		var t0 = haxe.Timer.stamp();
		var t1 = haxe.Timer.stamp();
		Sys.println(t0 > 0 && t1 >= t0);
		Sys.println(Math.abs(Sys.time() - t1) < 60);
	}
}
