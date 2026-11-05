import hxmc.NativeGc;
import hxmc.java.*;

// Java objects held by Haxe (docs/interop.md, "Java (JNI)"): a box per
// object holding a global reference while Haxe holds the box (one box per
// object: ==), deleted once the collector finds the box dead (put off,
// run by this thread after the collection); a Weak<T> a weak global
// reference (null once Java collected the object: a Java object Haxe no
// longer holds lives until Java collects it, and get() before that gives
// it a box again); Java.detach the global reference deleted at once.
// Boxes in fields, closures, maps and Dynamic stay valid through
// collections (RT_VERIFY's runs move them). Native handles that are no
// Java objects (a mutex) are told apart without a JNI call; a conversion
// runs none of the program's code (a toString that throws).
@:hxmc.java("jnitest.JniRefs") extern class Refs {
	function id():Int;
	static function make(id:Int):Refs;
	static function alive():Int;
	static function forget():Void;
	static function one():Refs;
	static function keep(o:Dynamic):Void;
	static function idOf(r:Refs):Int;
	static var kept:Dynamic;
}

// (its text throws: a conversion that read it would throw)
class Bad {
	public function new() {}

	public function toString():String
		throw "no text";
}

class Holder {
	public var ref:Refs;
	public var f:() -> Int;

	public function new(r:Refs) {
		ref = r;
		f = () -> r.id() * 2;
	}
}

class JniRefs {
	static function collect()
		for (i in 0...3)
			NativeGc.collect(true);

	static function makeMany(n:Int):Array<Refs>
		return [for (i in 0...n) Refs.make(i)];

	static function sumOf(xs:Array<Refs>):Int {
		var s = 0;
		for (x in xs)
			s += x.id();
		return s;
	}

	static function weakWhileHeld():Weak<Refs> {
		var strong = Refs.make(3);
		var w = new Weak(strong);
		collect();
		trace("weak", w.get() == strong, w.get().id(), Refs.alive());
		return w;
	}

	static function weakOf(id:Int):Weak<Refs>
		return new Weak(Refs.make(id));

	static function main() {
		Jvm.create(["-Djava.class.path=classes", "-Xcheck:jni"]);
		// one box per object
		var a = Refs.one(), b = Refs.one();
		trace(a == b, a.id(), Refs.make(1) == Refs.make(1));
		Refs.forget();
		// boxes keep their objects; dead boxes delete their references
		var held = makeMany(1000);
		collect();
		trace("held", Refs.alive(), sumOf(held));
		held = null;
		collect();
		trace("dropped", Refs.alive());
		Refs.forget();
		// in fields, closures, maps, Dynamic, through collections
		var h = new Holder(Refs.make(5));
		var m = new Map<Int, Refs>();
		for (i in 0...50)
			m.set(i, Refs.make(100 + i));
		var dyn:Dynamic = Refs.make(7);
		var arr:Array<Dynamic> = [Refs.make(8), "x", 9];
		for (round in 0...20) {
			var junk = [for (i in 0...2000) "j" + i];
			if (round % 5 == 0) collect();
		}
		var ms = 0;
		for (k => v in m)
			ms += v.id() - k;
		trace("kept", h.ref.id(), h.f(), ms, (dyn : Refs).id(), (arr[0] : Refs).id(), Refs.alive());
		h = null;
		m = null;
		dyn = null;
		arr = null;
		collect();
		trace("all dropped", Refs.alive());
		Refs.forget();
		// a weak reference
		var w = weakWhileHeld();
		collect();
		var n = Refs.alive();
		trace("weak after", n, w.get());
		var w2 = weakOf(4);
		collect();
		Refs.alive();
		trace("weak of none", w2.get());
		Refs.forget();
		// one Java keeps lives on, its box gone
		Refs.keep(Refs.make(11));
		collect();
		trace("kept by Java", Refs.alive(), (Refs.kept : Refs).id());
		Refs.keep(null);
		Refs.forget();
		// detach: the reference deleted now
		var d = Refs.make(12);
		Java.detach(d);
		trace("detached", Refs.alive());
		try d.id() catch (e:JavaException) trace(e.className, e.javaMessage);
		trace(Refs.make(13).id());
		Refs.forget();
		// many boxes made and dropped
		var total = 0;
		for (round in 0...20) {
			var xs = makeMany(500);
			total += sumOf(xs);
		}
		collect();
		trace("many", total, Refs.alive());
		notJava();
	}

	// native handles that are no Java objects, a Haxe exception while the arguments are made
	static function notJava() {
		var mutex:Dynamic = new sys.thread.Mutex();
		try {
			new Weak(mutex);
			trace("weak of a mutex");
		} catch (e:JavaException)
			trace("weak of a mutex", e.className);
		Java.detach(mutex);
		try {
			Refs.keep(mutex);
			trace("kept a mutex");
		} catch (e:JavaException)
			trace("a mutex as an Object", e.className);
		try {
			trace(Refs.idOf(mutex));
		} catch (e:JavaException)
			trace("a mutex as a Java object", e.className);
		(mutex : sys.thread.Mutex).acquire();
		(mutex : sys.thread.Mutex).release();
		// a Haxe object Java cannot hold, whose text throws: no code of its runs
		// while the arguments are made (the frame always popped)
		for (i in 0...100)
			try {
				Refs.idOf(cast new Bad());
			} catch (e:JavaException) {
				if (i == 0) trace("a Haxe object as a Java object", e.className, e.javaMessage);
			}
		trace("after", Refs.idOf(Refs.make(14)), Refs.idOf(null));
		Refs.forget();
	}
}
