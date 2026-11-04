import hxmc.com.*;
import hxmc.unsafe.*;

// Haxe classes implementing COM interfaces (docs/interop.md, "COM";
// Windows only): C calls their methods through the vtables the compiler
// made (ComObjects_dyn.c is ComCalls_dyn.c: the same DLL), on its thread
// and on threads of its own; QueryInterface, AddRef and Release are the
// runtime's; a method's exception is an HRESULT for C and a ComException
// back in Haxe; overrides of a subclass answer; and the Haxe object lives
// while COM holds it (the toggle on its count), through collections, and
// is collected once COM lets go.
@:hxmc.struct class Pt {
	public var x:Int;
	public var y:Int;

	public function new(x, y) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A03}")
extern interface ICallback extends IUnknown {
	function Run(x:Int):Int;
	function Name():BStr;
	function Mix(s:String, p:Pt, f:Float):Int;
	@:hxmc.com.direct function Where(k:Int):Pt;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A01}")
extern interface ICounter extends IUnknown {
	function Add(n:Int):Void;
	function Get():Int;
	@:hxmc.com.hresult function Fail(code:Int):Int;
	function Check(code:Int):Void;
	@:hxmc.com.direct function Twice(x:Float):Float;
	@:hxmc.com.direct function Corner():Pt;
	function SumPt(p:Pt):Int;
	function SumBig(b:Ptr):Float;
	function GetPt():Pt;
	function Echo(s:BStr):BStr;
	function Greet(name:String):String;
	function EchoVariant(v:Variant):Variant;
	function Call(cb:ICallback, x:Int):Int;
	function Hold(cb:Null<ICallback>):Void;
	function Drop():Void;
}

@:hxmc.lib("comobjectsdyn") @:hxmc.c extern class Native {
	static function counter_new(out:Ptr):Int;
	static function callback_run(cb:Ptr, x:Int):Int;
	static function callback_name_length(cb:Ptr):Int;
	static function callback_mix(cb:Ptr):Int;
	static function callback_qi(cb:Ptr):Int;
	static function callback_where(cb:Ptr, k:Int):Int;
	static function callback_keep(cb:Ptr):Void;
	static function callback_kept_run(x:Int):Int;
	static function callback_threads(cb:Ptr, n:Int, x:Int):Int;
	static function com_count(p:Ptr):Int;
}

class Doubler implements ICallback {
	public static var made = 0;
	public static var collected = 0;

	public var calls = 0;
	public var tag:String;

	public function new(tag:String) {
		this.tag = tag;
		made++;
		hxmc.NativeGc.finalise(o -> collected++, this);
	}

	public function Run(x:Int):Int {
		calls++;
		if (x < 0) throw new ComException(0x80070057, "negative");
		if (x == 13) throw "unlucky";
		return 2 * x;
	}

	public function Name():BStr
		return "doubler " + tag;

	public function Mix(s:String, p:Pt, f:Float):Int
		return s.length * 1000 + (p.x * 10 + p.y) * 10 + Std.int(f * 10);

	public function Where(k:Int):Pt
		return new Pt(k, calls);
}

// (an override answers COM's calls too: the thunk's call is dispatched)
class Tripler extends Doubler {
	override public function Run(x:Int):Int {
		calls++;
		return 3 * x;
	}
}

// (a class whose interface a superclass's interface extends: one vtable)
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A06}")
extern interface ICallback2 extends ICallback {
	function Extra():Int;
}

class Both implements ICallback2 {
	public function new() {}

	public function Run(x:Int):Int
		return x + 1;

	public function Name():BStr
		return "both";

	public function Mix(s:String, p:Pt, f:Float):Int
		return 0;

	public function Where(k:Int):Pt
		return new Pt(0, 0);

	public function Extra():Int
		return 77;
}

class ComObjects {
	static function counter():ICounter {
		var out = Mem.stack(8);
		Native.counter_new(out);
		return Com.adopt(Mem.getPtr(out, 0), ICounter);
	}

	static function gc() {
		for (i in 0...3) {
			hxmc.NativeGc.collect(true);
			hxmc.NativeGc.runFinalisers();
			Com.runDeferred();
		}
	}

	static function main() {
		Com.init(MultiThreaded);
		var d = new Doubler("a");
		var p = Com.ptr(d, ICallback);
		trace("run", Native.callback_run(p, 21), d.calls);
		trace("name", Native.callback_name_length(p));
		trace("mix", Native.callback_mix(p));
		trace("qi", Native.callback_qi(p));
		trace("where", Native.callback_where(p, 12), (Com.wrap(p, ICallback).Where(3) : Pt).x);
		trace("thrown", ComException.hex(Native.callback_run(p, -1)), ComException.hex(Native.callback_run(p, 13)));
		// (one block per object: the same pointer every time)
		trace("same pointer", Com.ptr(d, ICallback) == p, Com.ptr(d, IUnknown) == p);
		// a Haxe object's interface value back from COM is the object itself
		var c = counter();
		trace("call", c.Call(d, 5), d.calls);
		try {
			c.Call(d, -3);
		} catch (e:ComException) {
			trace("call thrown", ComException.hex(e.hresult));
		}
		// (calls from Haxe through the interface type go through the vtable too)
		var asIface:ICallback = d;
		trace("through the interface", asIface.Run(4), (asIface.Name() : String));
		trace("query", Com.query(asIface, ICallback) == asIface, Com.query(asIface, ICounter) == null, Std.isOfType(asIface, ICallback2));

		// an override, through the vtable of its superclass's class
		var t = new Tripler("b");
		trace("override", Native.callback_run(Com.ptr(t, ICallback), 7), c.Call(t, 2));
		var b = new Both();
		var bp = Com.ptr(b, ICallback2);
		trace("both", Native.callback_run(bp, 1), Com.ptr(b, ICallback) == bp, (cast(b, ICallback2) : ICallback2).Extra());

		// counts: the pairing's one; C's references keep the Haxe object
		trace("count", Native.com_count(p));
		c.Hold(d);
		trace("held", Native.com_count(p));
		c.Drop();
		trace("dropped", Native.com_count(p));

		// lifetime: kept by C only, through collections
		Doubler.collected = 0;
		keepOne();
		gc();
		trace("kept alive", Doubler.collected, Native.callback_kept_run(10));
		Native.callback_keep(Ptr.nil());
		gc();
		trace("collected once released", Doubler.collected);
		// many objects, some held by C, through collections
		var held = counter();
		for (i in 0...300) {
			var x = new Doubler("m" + i);
			if (i % 100 == 0) held.Hold(x);
			Native.callback_run(Com.ptr(x, ICallback), i);
		}
		gc();
		trace("one held of 300", Doubler.collected - 1 >= 290, held.Call(d, 1));
		held.Drop();

		// threads of C's own call into Haxe (attached at their first call)
		var w = new Doubler("w");
		var wp = Com.ptr(w, ICallback);
		trace("threads", Native.callback_threads(wp, 4, 100), w.calls > 0);
		trace("still", d.calls > 0, t.calls, b.Extra(), w.tag);
		Com.uninit();
	}

	static function keepOne() {
		var k = new Doubler("kept");
		Native.callback_keep(Com.ptr(k, ICallback));
	}
}
