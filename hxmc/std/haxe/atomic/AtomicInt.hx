// hxmc: haxe/upstream/std/hl/_std/haxe/atomic/AtomicInt.hx over a cell (a T_NATIVE
// K_RAW object, the low 4 bytes of slot 0) and the Atomic intrinsics
// (sequentially consistent), with the docs of haxe/upstream/std/haxe/atomic/AtomicInt.hx

package haxe.atomic;

import hxmc.unsafe.Atomic;
import hxmc.unsafe.Mem;

/**
	Atomic integer.
**/
abstract AtomicInt(Dynamic) {
	#if hxmc.wasm_gc
	// (-D hxmc.wasm-gc: the cell a NativeArray<Int> of one element, there being no threads)
	static function cell(v:Int):Dynamic {
		var a = new hxmc.NativeArray<Int>(1);
		a[0] = v;
		return a;
	}

	static inline function arr(a:Dynamic):hxmc.NativeArray<Int>
		return cast a;

	static function add32(a:Dynamic, v:Int):Int {
		var o = arr(a)[0];
		arr(a)[0] = o + v;
		return o;
	}

	static function cas32(a:Dynamic, e:Int, r:Int):Int {
		var o = arr(a)[0];
		if (o == e) arr(a)[0] = r;
		return o;
	}

	static function exchange32(a:Dynamic, v:Int):Int {
		var o = arr(a)[0];
		arr(a)[0] = v;
		return o;
	}

	static function load32(a:Dynamic):Int
		return arr(a)[0];

	static function store32(a:Dynamic, v:Int)
		arr(a)[0] = v;

	// (op 0 and, 1 or, 2 xor): the previous value
	static function bitwise(a:Dynamic, v:Int, op:Int):Int {
		var o = arr(a)[0];
		arr(a)[0] = op == 0 ? o & v : op == 1 ? o | v : o ^ v;
		return o;
	}
	#else
	static function cell(v:Int):Dynamic {
		var a = Mem.allocRaw(1, 16, 2); // T_NATIVE, K_RAW
		Mem.setI32(Mem.addr(a), 0, v);
		return a;
	}

	// (the cell's address is taken in functions that never reach a GC point:
	// inlined into the program, it could be taken before an allocation that
	// moves the cell)
	@:hxmc.noGc static function add32(a:Dynamic, v:Int):Int
		return Atomic.add32(Mem.addr(a), v);

	@:hxmc.noGc static function cas32(a:Dynamic, e:Int, r:Int):Int
		return Atomic.cas32(Mem.addr(a), e, r);

	@:hxmc.noGc static function exchange32(a:Dynamic, v:Int):Int
		return Atomic.exchange32(Mem.addr(a), v);

	@:hxmc.noGc static function load32(a:Dynamic):Int
		return Atomic.load32(Mem.addr(a));

	@:hxmc.noGc static function store32(a:Dynamic, v:Int)
		Atomic.store32(Mem.addr(a), v);

	// a compare-exchange loop (op 0 and, 1 or, 2 xor): the previous value
	@:hxmc.noGc static function bitwise(a:Dynamic, v:Int, op:Int):Int {
		var p = Mem.addr(a);
		var o = Atomic.load32(p);
		while (true) {
			var n = op == 0 ? o & v : op == 1 ? o | v : o ^ v;
			var seen = Atomic.cas32(p, o, n);
			if (seen == o) return o;
			o = seen;
		}
	}
	#end

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
