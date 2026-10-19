package ml2hx.std;

import ml2hx.rt.*;

// threads' Event on one thread: a channel holds what is sent; receiving
// from an empty channel could never complete (no other thread to send).
class EventChannel<T> {
	public final queue:Array<T> = [];
	public function new() {}
}

class EventEvent<T> {
	public final poll:Unit->MlOption<T>;
	public function new(poll) this.poll = poll;
}

class Event {
	public static function newChannel<T>(_:Unit):EventChannel<T> return new EventChannel();
	public static function send<T>(c:EventChannel<T>, v:T):EventEvent<Unit>
		return new EventEvent(_ -> {
			c.queue.push(v);
			Some(Unit.value);
		});
	public static function receive<T>(c:EventChannel<T>):EventEvent<T>
		return new EventEvent(_ -> c.queue.length > 0 ? Some(c.queue.shift()) : None);
	public static function always<T>(v:T):EventEvent<T> return new EventEvent(_ -> Some(v));
	public static function poll<T>(e:EventEvent<T>):MlOption<T> return e.poll(Unit.value);
	public static function sync<T>(e:EventEvent<T>):T {
		return switch e.poll(Unit.value) {
			case Some(v): v;
			case None: throw new SysError("Event.sync: deadlock (one thread)");
		}
	}
}
