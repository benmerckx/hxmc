package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Thread on a single-threaded runtime: a thread runs to completion when
// created (a valid schedule of OCaml's preemptive threads for programs that
// do not wait on each other).
// OCaml's thread descriptor: a block of its id, start closure and
// termination (caml_thread_new_descriptor)
class ThreadT implements Block {
	public final id:Int;
	public function new(id:Int) this.id = id;
	public function blockTag():Int return 0;
	public function blockSize():Int return 3;
	public function blockField(i:Int):Dynamic return i == 0 ? Int63.ofInt(id) : Unit.value;
}

// Thread.Exit: ends the thread that raises it, silently, at the top of
// Thread.create's function.
class ThreadExitExn extends MlException {
	public function new() super();
	override public function exnName():String return "Thread.Exit";
	override public function exnArity():Int return 0;
	public static final instance = new ThreadExitExn();
}

class Thread {
	public static function exit(_:Unit):Unit throw ThreadExitExn.instance;
	static var next = 1;
	static final main = new ThreadT(0);
	static var current = main;
	public static function create<A, B>(f:A->B, x:A):ThreadT {
		var t = new ThreadT(next++);
		var saved = current;
		current = t;
		try f(x) catch (e:ThreadExitExn) {} catch (e:haxe.Exception) {
			std.Sys.stderr().writeString("Thread " + t.id + " killed on uncaught exception " + MlException.wrap(e).toString() + "\n");
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
