import hxmc.unsafe.*;

// C interop (docs/interop.md, "C interop"): externs called directly
// in the target's C convention (narrow integers, floats, bool, many
// arguments on the stack, variadic calls), a prebuilt object linked
// statically (Ffi.c) and a dynamic library (Ffi_dyn.c: a DLL on Windows, a
// dylib on macOS, statically linked on Linux), both built by the corpus
// harness with zig; structs through pointers, Arena, CString, calls in a
// safe region and @:hxmc.fast calls.
@:hxmc.struct @:publicFields class Rect {
	var x:Int32;
	var y:Int32;
	var w:Float;
	var tag:UInt8;
	var s:Int16;
	var f:Float32;
	var next:Ptr<Rect>;
}

@:hxmc.c @:hxmc.fast extern class Fast {
	@:native("t_add") static function add(a:Int, b:Int):Int;
	static function t_neg8(a:Int8):Int8;
	static function t_inc_u8(a:UInt8):UInt8;
	static function t_mul16(a:Int16, b:Int16):Int16;
	static function t_add_u16(a:UInt16, b:UInt16):UInt16;
	static function t_add64(a:Int64, b:Int64):Int64;
	static function t_scale(a:Float32, b:Float32):Float32;
	static function t_mix(a:Int8, b:Float32, c:Int64, d:Float, e:UInt8, f:Int16, g:Float32, h:Float, i:Int, j:Float32):Float;
	static function t_pos(v:Int):Bool;
	static function t_many(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, i:Int, j:Int, k:Int, l:Int):Int;
	static function t_many_f(a:Float32, b:Float32, c:Float32, d:Float32, e:Float32, f:Float32, g:Float32, h:Float32, i:Float32, j:Float32, k:Float32):Float32;
	static function t_many_small(a:Int8, b:UInt8, c:Int16, d:UInt16, e:Int8, f:UInt8, g:Int16, h:UInt16, i:Int8, j:UInt8, k:Int16, l:UInt16):Int;
	static function t_sum(p:Ptr<Int64>, n:Int):Int64;
	static function t_fill(r:Ptr<Rect>, x:Int):Void;
	static function t_area(r:Ptr<Rect>):Float;
	static function t_greet():CString;
	static function t_sizeof_rect():Int;
	static function t_offset_next():Int;
	@:hxmc.varargs(1) static function t_sum_va(n:Int, a:Int, b:Int, c:Int):Int;
	@:hxmc.varargs(1) static function t_sum_vad(n:Int, a:Float, b:Float, c:Float):Float;
	static function t_fnptr():Ptr;
	@:hxmc.indirect static function callAdd(f:Ptr, a:Int, b:Int):Int;
	// a no-GC callback may be called from a fast call
	@:native("t_apply_fast") static function applyFast(f:Ptr, v:Int):Int;
}

// calls in a safe region (not @:hxmc.fast): a collection may run meanwhile
extern class Slow {
	@:hxmc.c("t_strlen") static function strlen(s:CString):UInt64;
	@:hxmc.c("t_sub") static function sub(a:Int, b:Int):Int;
	// (the callbacks that allocate: from calls in a safe region)
	@:hxmc.c("t_apply") static function apply(f:Ptr, v:Int):Int;
	@:hxmc.c("t_apply_d") static function applyD(f:Ptr, ctx:Ptr, v:Float):Float;
}

@:hxmc.lib("ffidyn") extern class Dyn {
	@:hxmc.c("dyn_twice") static function twice(v:Int):Int;
	@:hxmc.c("dyn_hyp2") static function hyp2(a:Float, b:Float):Float;
	@:hxmc.c("dyn_name") @:hxmc.fast static function name():CString;
}

class Ffi {
	@:hxmc.callback @:hxmc.unsafe static function twice(v:Int):Int
		return 2 * v;

	static var made:Array<String> = [];

	// (allocates: a collection may run during it, with a 64 KB nursery)
	@:hxmc.callback static function makeStrings(n:Int):Int {
		for (i in 0...n)
			made.push("x" + i);
		return made.length;
	}

	@:hxmc.callback static function scaled(ctx:Ptr, v:Float):Float
		return (ctx : Ptr<Float>).value * v + made.length;

	static function main() {
		trace(Fast.add(2, 40));
		trace(Fast.t_neg8(-128), Fast.t_neg8(5));
		trace(Fast.t_inc_u8(255), Fast.t_inc_u8(7));
		trace(Fast.t_mul16(300, 300), Fast.t_add_u16(65535, 2));
		var big:Int64 = haxe.Int64.make(1, 0);
		trace(haxe.Int64.toStr(Fast.t_add64(big, 5)));
		trace(Fast.t_scale(1.5, 0.1));
		trace(Fast.t_mix(-3, 0.25, 1000, 0.5, 250, -300, 0.125, 2.0, 7, 0.0625));
		trace(Fast.t_pos(3), Fast.t_pos(-3));
		trace(Fast.t_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
		trace(Fast.t_many_f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11));
		trace(Fast.t_many_small(-1, 255, -300, 65535, -2, 254, -301, 65534, -3, 253, -302, 65533));
		trace(Fast.t_sum_va(3, 10, 20, 30), Fast.t_sum_vad(3, 0.5, 0.25, 0.125));
		trace(Fast.t_sizeof_rect() == Struct.sizeOf(Rect), Fast.t_offset_next() == Struct.offsetOf(Rect, "next"), Struct.sizeOf(Rect), Struct.alignOf(Rect));
		var g = Fast.t_greet();
		trace(g.toString(), g.length(), Slow.strlen(g).toInt(), Slow.sub(1, 2));
		Arena.scoped(a -> {
			var xs:Ptr<Int64> = a.alloc(8 * 4);
			for (i in 0...4)
				xs[i] = (i + 1) * 100;
			trace(haxe.Int64.toStr(Fast.t_sum(xs, 4)));
			var r = a.make(Rect);
			Fast.t_fill(r, 6);
			trace(r.value.x, r.value.y, r.value.w, r.value.tag, r.value.s, r.value.f, r.value.next == r);
			r.value.tag = 300; // wraps to 44
			r.value.f += 0.25;
			trace(r.value.tag, Fast.t_area(r));
			var rs = a.makeArray(Rect, 3);
			for (i in 0...3)
				rs[i].x = i * 10;
			trace(rs[2].x, rs.offset(1).value.x);
			var c = a.cstring("héllo wörld");
			trace(c.length(), c.toString(), Slow.strlen(c).toInt());
			// garbage meanwhile: the arena's memory never moves
			var keep = [for (i in 0...20000) "s" + i];
			trace(keep.length, c.toString(), rs[1].x);
		});
		// an exception leaves the scope too (the arena is freed)
		try {
			Arena.scoped(a -> {
				var p:Ptr<Int8> = a.alloc(16);
				p[3] = -7;
				if (p[3] < 0) throw "out of the scope: " + p[3];
			});
		} catch (e:String) {
			trace(e);
		}
		var n = Arena.scopedValue(a -> Slow.strlen(a.cstring("twelve bytes")).toInt());
		trace(n);
		trace(Dyn.twice(21), Dyn.hyp2(3, 4), Dyn.name().toString());
		trace(Fast.callAdd(Fast.t_fnptr(), 30, 12), Fast.applyFast(Callback.addr(twice), 20), Slow.apply(Callback.addr(twice), 4));
		var keep = "kept across";
		trace(Slow.apply(Callback.addr(makeStrings), 5000), made[4999], keep);
		// an allocating callback called by a fast C call: the caller is out of
		// a safe region after it as before (rt_callback_begin, rt_callback_end)
		var before = made.length;
		trace(Fast.applyFast(Callback.addr(makeStrings), 3000) - 1 - before, [for (i in 0...2000) "after" + i][1999], made[before + 2999]);
		Arena.scoped(a -> {
			var k:Ptr<Float> = a.alloc(8);
			k.value = 1.5;
			trace(Slow.applyD(Callback.addr(scaled), k, 4));
		});
	}
}
