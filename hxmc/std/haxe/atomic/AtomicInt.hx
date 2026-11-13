// hxmc: haxe/upstream/std/hl/_std/haxe/atomic/AtomicInt.hx over a cell (a T_NATIVE
// K_RAW object, the low 4 bytes of slot 0) and the Atomic intrinsics
// (sequentially consistent), with the docs of haxe/upstream/std/haxe/atomic/AtomicInt.hx

package haxe.atomic;

import hxmc.Span;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// An AtomicInt's cell, read for kernels (a view, as hxmc.rt.StrView): its
// 32 bits as a span of one Int; of any value that is no T_NATIVE object (null
// too), a span of none
@:noCompletion @:hxmc.kernel @:hxmc.unsafe class Cell {
	public static function of(a:Dynamic):Span<Int>
		return Span.unsafeOf((cast Mem.addr(a) : Ptr<Int>), !hxmc.rt.Repr.isNull(a) && hxmc.rt.Types.tindex(a) == hxmc.rt.Types.T_NATIVE ? 1 : 0);
}

/**
	Atomic integer.
**/
abstract AtomicInt(Dynamic) {
	@:hxmc.unsafe(gc) static function cell(v:Int):Dynamic {
		var a = Mem.allocRaw(1, hxmc.rt.Types.T_NATIVE, 2); // K_RAW
		Mem.setI32(Mem.addr(a), 0, v);
		return a;
	}

	// (kernels over the cell lent as a span, Cell: the cell's address is
	// taken where nothing collects)
	@:hxmc.kernel static function add32(a:Dynamic, v:Int):Int
		return Cell.of(a).add(0, v);

	@:hxmc.kernel static function cas32(a:Dynamic, e:Int, r:Int):Int
		return Cell.of(a).compareExchange(0, e, r);

	@:hxmc.kernel static function exchange32(a:Dynamic, v:Int):Int
		return Cell.of(a).exchange(0, v);

	// (a plain load or store: the cell's test and check would be most of
	// it, 3 times the raw access)
	@:hxmc.unsafe static function load32(a:Dynamic):Int
		return Atomic.load32(Mem.addr(a));

	@:hxmc.unsafe static function store32(a:Dynamic, v:Int)
		Atomic.store32(Mem.addr(a), v);

	// a compare-exchange loop (op 0 and, 1 or, 2 xor): the previous value
	@:hxmc.kernel static function bitwise(a:Dynamic, v:Int, op:Int):Int {
		var c = Cell.of(a);
		var o = c.load(0);
		while (true) {
			var n = op == 0 ? o & v : op == 1 ? o | v : o ^ v;
			var seen = c.compareExchange(0, o, n);
			if (seen == o) return o;
			o = seen;
		}
	}

	public inline function new(value:Int):Void {
		this = cell(value);
	}

	/**
		Atomically adds `b` to `a`.
		Returns the original value of `a`.
	**/
	public inline function add(b:Int):Int {
		return add32(this, b);
	}

	/**
		Atomically subtracts `b` from `a`.
		Returns the original value of `a`.
	**/
	public inline function sub(b:Int):Int {
		return add32(this, -b);
	}

	/**
		Atomically computes the bitwise and of `a` and `b` and stores it in `a`.
		Returns the original value of `a`.
	**/
	public inline function and(b:Int):Int {
		return bitwise(this, b, 0);
	}

	/**
		Atomically computes the bitwise or of `a` and `b` and stores it in `a`.
		Returns the original value of `a`.
	**/
	public inline function or(b:Int):Int {
		return bitwise(this, b, 1);
	}

	/**
		Atomically computes the bitwise xor of `a` and `b` and stores it in `a`.
		Returns the original value of `a`.
	**/
	public inline function xor(b:Int):Int {
		return bitwise(this, b, 2);
	}

	/**
		Atomically compares the value of `a` with `expected` and replaces `a` with `replacement` if they are equal..
		Returns the original value of `a`.
	**/
	public inline function compareExchange(expected:Int, replacement:Int):Int {
		return cas32(this, expected, replacement);
	}

	/**
		Atomically exchanges `a` with `value`.
		Returns the original value of `a`.
	**/
	public inline function exchange(value:Int):Int {
		return exchange32(this, value);
	}

	/**
		Atomically fetches the value of `a`.
	**/
	public inline function load():Int {
		return load32(this);
	}

	/**
		Atomically stores `value` into `a`.
		Returns the value that has been stored.
	**/
	public inline function store(value:Int):Int {
		store32(this, value);
		return value;
	}
}
