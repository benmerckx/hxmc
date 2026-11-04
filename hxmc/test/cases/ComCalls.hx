import hxmc.com.*;
import hxmc.unsafe.*;

// COM interop (docs/interop.md, "COM"; Windows only): calls of a C object's
// methods through its vtable (slots in declaration order after IUnknown's),
// [out, retval] results, raw and thrown HRESULTs, direct results (a double,
// a struct through a pointer after `this`), structs by value, out
// parameters, BSTR, LPCWSTR and LPWSTR strings, VARIANTs, QueryInterface
// (Com.query, Com.as, cast, Std.isOfType), identity, and the reference
// counts of the values that hold the object (released once collected).
// ComCalls_dyn.c is the C side.
@:hxmc.struct class Pt {
	public var x:Int;
	public var y:Int;

	public function new(x, y) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.struct class Big {
	public var a:Float;
	public var b:Float;
	public var c:Float;

	public function new(a, b, c) {
		this.a = a;
		this.b = b;
		this.c = c;
	}
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A03}")
extern interface ICallback extends IUnknown {
	function Run(x:Int):Int;
	function Name():BStr;
	function Mix(s:String, p:Pt, f:Float):Int;
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
	function SumBig(b:Big):Float;
	function GetPt():Pt;
	function Echo(s:BStr):BStr;
	function Greet(name:String):String;
	function EchoVariant(v:Variant):Variant;
	function Call(cb:ICallback, x:Int):Int;
	function Hold(cb:Null<ICallback>):Void;
	function Drop():Void;
	function Self():ICounter;
	function Child():ICounter;
	function Outs(a:Ptr<Int32>, b:Ptr<Float>):Void;
}

// (a base's slots first: More is the slot after Outs)
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A05}")
extern interface ICounter2 extends ICounter {
	function More(x:Int):Int;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A02}")
extern interface ISecond extends IUnknown {
	function Value():Int;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A04}")
extern interface INone extends IUnknown {}

@:hxmc.lib("comcallsdyn") @:hxmc.c extern class Native {
	static function counter_new(out:Ptr):Int;
	static function counter_live():Int;
	static function com_count(p:Ptr):Int;
}

class ComCalls {
	static function counter():ICounter {
		var out = Mem.stack(8);
		var hr = Native.counter_new(out);
		if (hr != 0) throw new ComException(hr);
		return Com.adopt(Mem.getPtr(out, 0), ICounter);
	}

	static function main() {
		Com.init(MultiThreaded);
		var c = counter();
		c.Add(5);
		c.Add(37);
		trace("get", c.Get());
		trace("raw", ComException.hex(c.Fail(0x80070057)), c.Fail(1));
		try {
			c.Check(0x80004005);
			trace("no throw");
		} catch (e:ComException) {
			trace("thrown", ComException.hex(e.hresult), e.message.length > 0);
		}
		c.Check(1); // (S_FALSE: a success)
		trace("twice", c.Twice(1.25));
		var p = c.Corner();
		trace("corner", p.x, p.y);
		trace("sumPt", c.SumPt(new Pt(30, 12)));
		trace("sumBig", c.SumBig(new Big(0.5, 1.5, 40)));
		var q = c.GetPt();
		trace("getPt", q.x, q.y);
		trace("echo", c.Echo("abé"), (c.Echo("x\x00y") : String).length, c.Echo(""), c.Echo(null));
		trace("greet", c.Greet("wörld"));
		// out parameters: native memory (an Arena's, or a frame's)
		var a:Ptr<Int32> = Mem.stack(8), b:Ptr<Float> = Mem.stack(8);
		c.Outs(a, b);
		trace("outs", a.value, b.value);

		// VARIANTs: I4 and R8 changed, BSTR, BOOL, EMPTY and UNKNOWN copied (VariantCopy)
		trace("variant", Variants.toDynamic(c.EchoVariant(Variants.ofInt(21))), Variants.toDynamic(c.EchoVariant(Variants.ofFloat(3))));
		var vs = Variants.ofString("vär");
		var vs2 = c.EchoVariant(vs);
		trace("variant", Variants.toDynamic(vs2), Variants.toDynamic(c.EchoVariant(Variants.ofBool(true))),
			Variants.toDynamic(c.EchoVariant(Variants.empty())));
		var vu = Variants.ofUnknown(c);
		var vu2 = c.EchoVariant(vu);
		var back:ICounter = cast Com.query(Variants.toDynamic(vu2), ICounter);
		trace("variant unknown", back.Get(), Com.same(back, c));
		Variants.clear(vs);
		Variants.clear(vs2);
		Variants.clear(vu);
		Variants.clear(vu2);

		// QueryInterface
		var s = Com.query(c, ISecond);
		trace("second", s != null, s.Value());
		trace("none", Com.query(c, INone) == null, Std.isOfType(c, INone), Std.isOfType(c, ISecond));
		try {
			Com.as(c, INone);
		} catch (e:ComException) {
			trace("as", ComException.hex(e.hresult));
		}
		var c2 = cast(s, ICounter2);
		trace("more", c2.More(4), c2.Get());
		try {
			var n:INone = cast(c, INone);
			trace("cast", n);
		} catch (e:ComException) {
			trace("cast", ComException.hex(e.hresult));
		}
		var d = Std.downcast((s : IUnknown), ICounter);
		trace("downcast", d != null && d.Get() == 42);
		// (one value per interface pointer, one object)
		trace("identity", d == c, (s : IUnknown) == (c : IUnknown), Com.same(s, c), Com.same(c, c.Self()), Com.same(c, c.Child()));
		trace("self", c.Self() == c);

		// counts: each value holds one reference; dropped values release
		// theirs once a collection finds them dead (put off to the thread
		// that made them, which runs them as it allocates)
		var live0 = Native.counter_live();
		for (i in 0...200)
			c.Child().Add(i);
		hxmc.rt.Gc.collect(true);
		Com.runDeferred();
		hxmc.rt.Gc.collect(true);
		Com.runDeferred();
		trace("children released", Native.counter_live() - live0);
		var k = counter();
		trace("count", Com.refCount(k));
		var k2 = Com.query(k, ISecond);
		trace("count with second", Com.refCount(k));
		Com.detach(k2);
		trace("count detached", Com.refCount(k));
		try {
			k2.Value();
		} catch (e:ComException) {
			trace("detached", ComException.hex(e.hresult));
		}
		trace("ptr", Native.com_count(Com.ptr(k, ICounter)));
		trace("still", c.Get(), k.Get());
		Com.uninit();
	}
}
