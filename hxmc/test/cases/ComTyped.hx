import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.com.*;
import hxmc.unsafe.Int32;

// COM with typed parameters, no raw memory (built -D hxmc.strict;
// docs/interop.md, "COM"): spans for arrays and out parameters (Span.of a
// variable; @:hxmc.len as for C functions), hxmc.com.Out<IFoo> for an [out]
// interface pointer of a method or of a C function (adopted: NULL is null).
// ComTyped_dyn.c is ComCalls' counter with SumAll and Pair. Windows only.
// define: hxmc.strict
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
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A03}")
extern interface ICallback extends IUnknown {}

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
	@:hxmc.len(a, 1) @:hxmc.len(b, 1) function Outs(a:Span<Int32>, b:Span<Float>):Void;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A05}")
extern interface ICounter2 extends ICounter {
	function More(x:Int):Int;
	function Flag(b:Bool):Int;
	@:hxmc.com.direct function Truthy(x:Int):Bool;
	function IsBig(x:Int):Bool;
	@:hxmc.len(v, n) function SumAll(v:ReadOnlySpan<Int>, n:Int):Int;
	function Pair(a:Out<ICounter>, b:Out<ICounter>):Void;
}

@:hxmc.lib("comtypeddyn") @:hxmc.c extern class Native {
	static function counter_new(out:Out<ICounter>):Int;
	static function counter_live():Int;
}

class ComTyped {
	static function main() {
		Com.init(MultiThreaded);
		var out = new Out<ICounter>();
		trace(Native.counter_new(out), out.value != null);
		var c = out.value;
		c.Add(7);
		var a:Int32 = 0, b = 0.0;
		c.Outs(Span.of(a), Span.of(b));
		trace("outs", a, b);
		var c2 = Com.as(c, ICounter2);
		var five = 5;
		trace("sumAll", c2.SumAll(ReadOnlySpan.of(five), 1), c2.SumAll(ReadOnlySpan.of(five), 0));
		var x = new Out<ICounter>(), y = new Out<ICounter>();
		c2.Pair(x, y);
		trace("pair", x.value != null, y.value == null, x.value.Get());
		// (each Out's counter released once collected, as any [out] value)
		var live0 = Native.counter_live();
		for (i in 0...50) {
			var o = new Out<ICounter>();
			c2.Pair(o, new Out<ICounter>());
			o.value.Add(i);
		}
		hxmc.rt.Gc.collect(true);
		Com.runDeferred();
		hxmc.rt.Gc.collect(true);
		Com.runDeferred();
		trace("pairs released", Native.counter_live() - live0);
	}
}
