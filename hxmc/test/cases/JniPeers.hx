import hxmc.NativeGc;
import hxmc.java.*;

// Haxe classes implementing Java interfaces (docs/interop.md, "Java
// (JNI)"): a proxy of the glue (org.hxmc.Peer's subclass, written from the
// manifest hxmc puts next to the executable: JniGlue) stands for the Haxe
// object in Java, its methods the natives hxmc registers (RegisterNatives),
// their arguments and results converted as calls' are. While Java holds a
// proxy the Haxe object lives (the toggle), Java's collection of the last
// one lets it go (org.hxmc.Peer's cleanup, then Haxe's collection: its
// finaliser runs). A proxy that comes back is its Haxe object; a Haxe
// exception reaching Java is an org.hxmc.HaxeException, a JavaException
// its Throwable again; calls from a Java thread attach it to the runtime.
@:hxmc.java("java.lang.Runnable") extern interface Runnable {
	function run():Void;
}

@:hxmc.java("jnitest.JniPeers$Callback") extern interface Callback {
	function onEvent(name:String, value:Int):Int;
	function describe():String;
}

@:hxmc.java("jnitest.JniPeers$Source") extern interface Source {
	function make(id:Int):Peers;
	function values(scale:Float):Array<Float>;
	function any(x:Dynamic):Dynamic;
}

@:hxmc.java("jnitest.JniPeers") extern class Peers {
	final id:Int;
	function new(id:Int);
	static function run(r:Runnable):Void;
	static function fire(c:Callback, n:String, v:Int):Int;
	static function describe(c:Callback):String;
	static function use(s:Source):String;
	static function store(r:Runnable):Void;
	static function runStored():Void;
	static function stored():Runnable;
	static function drop():Void;
	static function gc():Void;
	static function same(a:Dynamic, b:Dynamic):Bool;
	static function className(o:Dynamic):String;
	static function isRunnable(o:Dynamic):Bool;
	static function catching(r:Runnable):String;
	static function fail(why:String):Void;
	static function onThread(r:Runnable):String;
	static function many(rs:Array<Runnable>, times:Int):Int;
}

class Counter implements Runnable {
	public static var total = 0;

	public var n = 0;

	public function new() {}

	public function run() {
		n++;
		total++;
	}
}

class Tenfold extends Counter {
	public function new()
		super();

	override public function run()
		n += 10;
}

class Events implements Callback {
	public var log:Array<String> = [];

	public function new() {}

	public function onEvent(name:String, value:Int):Int {
		log.push(name + "=" + value);
		return value * 2;
	}

	public function describe():String
		return "events " + log.join(",");
}

class Maker implements Source {
	public function new() {}

	public function make(id:Int):Peers
		return new Peers(id);

	public function values(scale:Float):Array<Float>
		return [for (i in 0...3) i * scale];

	public function any(x:Dynamic):Dynamic
		return x == null ? "none" : x + 1;
}

class Failing implements Runnable {
	public function new() {}

	public function run()
		throw "haxe boom";
}

class Through implements Runnable {
	public function new() {}

	public function run()
		Peers.fail("from java, through haxe");
}

class OnThread implements Runnable {
	public var where = "";

	public function new() {}

	public function run() {
		// (a Java thread: attached to the runtime; it allocates, collects, calls Java)
		var a = [for (i in 0...2000) "t" + i];
		NativeGc.collect(false);
		where = Thread.currentThread().getName() + " " + a.length + " " + Peers.className(this);
	}
}

@:hxmc.java("java.lang.Thread") extern class Thread {
	static function currentThread():Thread;
	function getName():String;
}

class JniPeers {
	static var finalised = 0;

	static function collect()
		for (i in 0...3)
			NativeGc.collect(true);

	static function storeOne():Counter {
		var c = new Counter();
		NativeGc.finalise(_ -> finalised++, c);
		Peers.store(c);
		return null;
	}

	static function main() {
		Jvm.create(["-Djava.class.path=classes", "-Xcheck:jni"]);
		// Java calls Haxe methods
		var c = new Counter();
		Peers.run(c);
		Peers.run(c);
		trace(c.n, Counter.total, Java.proxies(c));
		var e = new Events();
		trace(Peers.fire(e, "a", 5), Peers.describe(e), e.log);
		trace(Peers.use(new Maker()));
		// a subclass's override answers
		var t = new Tenfold();
		Peers.run(t);
		trace(t.n, Peers.className(t), Peers.className(c));
		// one proxy while Java has it; a proxy coming back is its Haxe object
		trace(Peers.same(c, c), Peers.isRunnable(c));
		Peers.store(c);
		trace(Peers.stored() == c, (cast Peers.stored() : Counter).n);
		// calls through the interface's type go through Java too
		var r:Runnable = c;
		r.run();
		trace(c.n);
		Peers.drop();
		// exceptions: a Haxe one as org.hxmc.HaxeException, a Java one as itself
		trace(Peers.catching(new Failing()));
		trace(Peers.catching(new Through()));
		trace(Peers.catching(c), c.n);
		// a Java thread calling Haxe
		var o = new OnThread();
		trace(Peers.onThread(o), o.where);
		// kept while Java holds it, though Haxe does not
		storeOne();
		collect();
		NativeGc.runFinalisers();
		var before = Counter.total;
		Peers.runStored();
		trace("stored", finalised, Counter.total - before);
		// let go once Java collected its proxy
		Peers.drop();
		var tries = 0;
		while (finalised == 0 && tries++ < 100) {
			Peers.gc();
			collect();
			NativeGc.runFinalisers();
		}
		trace("dropped", finalised);
		// many objects, many calls
		var rs:Array<Runnable> = [for (i in 0...200) new Counter()];
		before = Counter.total;
		trace(Peers.many(rs, 20), Counter.total - before);
		rs = null;
		collect();
		trace(Counter.total > 0);
	}
}
