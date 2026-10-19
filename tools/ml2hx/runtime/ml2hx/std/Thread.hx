package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// OCaml's Thread on host threads under one master lock (ml2hx.rt.Gil); on a
// target without threads a thread runs to completion when created (a valid
// schedule of OCaml's threads for programs that do not wait on each other).
// OCaml's thread descriptor: a block of its id, start closure and
// termination (caml_thread_new_descriptor)
// a domain: its id and domain-local state (its threads share them)
class DomainState {
	public final id:Int;
	public var dls:Array<Dynamic> = [];
	public function new(id:Int) this.id = id;
}

class ThreadT implements Block {
	public final id:Int;
	public var finished = false;
	public var domain:DomainState;
	public function new(id:Int, domain:DomainState) {
		this.id = id;
		this.domain = domain;
	}
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
	static final main = new ThreadT(0, new DomainState(0));
	public static var current = main;
	// a thread of a domain (ml2hx.prim.Domain), started on the master lock
	// (or run now without threads): body runs on it, then finish
	public static function spawn(domain:DomainState, body:ThreadT->Void):ThreadT {
		var t = new ThreadT(next++, domain);
		#if (target.threaded || target.name == "hxmc")
		Gil.start(main);
		sys.thread.Thread.create(() -> {
			Gil.enterNew(t);
			body(t);
			t.finished = true;
			Gil.exit();
		});
		#else
		var saved = current;
		current = t;
		body(t);
		t.finished = true;
		current = saved;
		#end
		return t;
	}
	static function run<A, B>(t:ThreadT, f:A->B, x:A) {
		try f(x) catch (e:ThreadExitExn) {} catch (e:haxe.Exception) {
			std.Sys.stderr().writeString("Thread " + t.id + " killed on uncaught exception " + MlException.wrap(e).toString() + "\n");
		}
		t.finished = true;
	}
	public static function create<A, B>(f:A->B, x:A):ThreadT {
		return spawn(current.domain, t -> run(t, f, x));
	}
	public static inline function self(_:Unit):ThreadT return current;
	public static inline function id(t:ThreadT):Int63 return Int63.ofInt(t.id);
	public static function join(t:ThreadT):Unit {
		while (!t.finished) Gil.wait();
		return Unit.value;
	}
	public static function yield(_:Unit):Unit {
		if (Gil.active) {
			Gil.leave();
			#if sys std.Sys.sleep(0); #end
			Gil.enter();
		}
		return Unit.value;
	}
	public static function delay(d:Float):Unit {
		Gil.leave();
		#if sys std.Sys.sleep(d); #end
		Gil.enter();
		return Unit.value;
	}
}
