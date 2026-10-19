package ml2hx.std;

import ml2hx.rt.*;

// threads' Event: synchronous channels (a send completes when a receive
// takes its value), over the master lock (ml2hx.rt.Gil): a thread that syncs
// waits, the lock released, until a partner arrives. send, receive, always,
// sync and poll (no choose/wrap/guard). With one thread (no lock), a send
// is buffered and a receive takes from the buffer (no partner could arrive).
class EventChannel<T> {
	public final senders:Array<{value:T, done:Bool}> = [];
	public final receivers:Array<{value:Null<T>, done:Bool}> = [];
	public final buffer:Array<T> = [];
	public function new() {}
}

class EventEvent<T> {
	public final kind:Int; // 0 send, 1 receive, 2 always
	public final channel:Null<EventChannel<Dynamic>>;
	public final value:Dynamic;
	public function new(kind, channel, value) {
		this.kind = kind;
		this.channel = channel;
		this.value = value;
	}
}

class Event {
	public static function newChannel<T>(_:Unit):EventChannel<T> return new EventChannel();
	public static function send<T>(c:EventChannel<T>, v:T):EventEvent<Unit> return new EventEvent(0, cast c, v);
	public static function receive<T>(c:EventChannel<T>):EventEvent<T> return new EventEvent(1, cast c, null);
	public static function always<T>(v:T):EventEvent<T> return new EventEvent(2, null, v);

	// the event's completion if a partner is there (or one thread: the buffer)
	static function tryNow(e:EventEvent<Dynamic>):MlOption<Dynamic> {
		var c = e.channel;
		switch e.kind {
			case 0:
				if (c.receivers.length > 0) {
					var r = c.receivers.shift();
					r.value = e.value;
					r.done = true;
					Gil.notifyAll();
					return Some(Unit.value);
				}
				if (!Gil.active) {
					c.buffer.push(e.value);
					return Some(Unit.value);
				}
				return None;
			case 1:
				if (c.senders.length > 0) {
					var s = c.senders.shift();
					s.done = true;
					Gil.notifyAll();
					return Some(s.value);
				}
				if (c.buffer.length > 0) return Some(c.buffer.shift());
				return None;
			case _:
				return Some(e.value);
		}
	}

	public static function poll<T>(e:EventEvent<T>):MlOption<T> return cast tryNow(cast e);

	public static function sync<T>(e:EventEvent<T>):T {
		switch tryNow(cast e) {
			case Some(v): return v;
			case None:
		}
		if (!Gil.active) throw new SysError("Event.sync: deadlock (one thread)");
		var c = e.channel;
		if (e.kind == 0) {
			var s = {value: e.value, done: false};
			c.senders.push(s);
			while (!s.done) Gil.wait();
			return cast Unit.value;
		}
		var r:{value:Null<Dynamic>, done:Bool} = {value: null, done: false};
		c.receivers.push(r);
		while (!r.done) Gil.wait();
		return r.value;
	}
}
