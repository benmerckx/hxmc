package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Saturn.Single_consumer_queue on one thread: a FIFO queue.
class SaturnSingleconsumerqueueT<T> {
	public final items = new haxe.ds.List<T>();
	public var closed = false;
	public function new() {}
}

class SaturnSingleconsumerqueueClosed extends MlException {
	public static final instance = new SaturnSingleconsumerqueueClosed();
	public function new() super();
	override public function exnName():String return "Saturn.Single_consumer_queue.Closed";
}

class Saturn_Single_consumer_queue {
	public static function create<T>(_:Unit):SaturnSingleconsumerqueueT<T> return new SaturnSingleconsumerqueueT<T>();
	public static function push<T>(q:SaturnSingleconsumerqueueT<T>, x:T):Unit {
		if (q.closed) throw SaturnSingleconsumerqueueClosed.instance;
		q.items.add(x);
		return Unit.value;
	}
	public static function pushHead<T>(q:SaturnSingleconsumerqueueT<T>, x:T):Unit {
		q.items.push(x);
		return Unit.value;
	}
	public static function popOpt<T>(q:SaturnSingleconsumerqueueT<T>):MlOption<T> return q.items.isEmpty() ? None : Some(q.items.pop());
	public static function peekOpt<T>(q:SaturnSingleconsumerqueueT<T>):MlOption<T> return q.items.isEmpty() ? None : Some(q.items.first());
	public static function isEmpty<T>(q:SaturnSingleconsumerqueueT<T>):Bool return q.items.isEmpty();
	public static function close<T>(q:SaturnSingleconsumerqueueT<T>):Unit {
		q.closed = true;
		return Unit.value;
	}
}
