package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Thread on a single-threaded runtime: a thread runs to completion when
// created (a valid schedule of OCaml's preemptive threads for programs that
// do not wait on each other).
class ThreadT {
	public final id:Int;
	public function new(id:Int) this.id = id;
}

class Thread {
	static var next = 1;
	static final main = new ThreadT(0);
	static var current = main;
	public static function create<A, B>(f:A->B, x:A):ThreadT {
		var t = new ThreadT(next++);
		var saved = current;
		current = t;
		try f(x) catch (e:haxe.Exception) {
			Stdlib.prerrString("Thread " + t.id + " killed on uncaught exception " + Printexc.toString(MlException.wrap(e)) + "\n");
		}
		current = saved;
		return t;
	}
	public static inline function self(_:Unit):ThreadT return current;
	public static inline function id(t:ThreadT):Int63 return Int63.ofInt(t.id);
	public static inline function join(t:ThreadT):Unit return Unit.value;
	public static inline function yield(_:Unit):Unit return Unit.value;
	public static function delay(d:Float):Unit {
		#if sys std.Sys.sleep(d); #end
		return Unit.value;
	}
}
