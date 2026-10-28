package hxmc;

import haxe.io.Bytes;
import hxmc.unsafe.UInt8;
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
#end

// hxmc.Span on the targets other than hxmc (Eval, JavaScript, ...): the same
// API over a haxe.io.Bytes, an offset and a length (docs/interop.md, "Spans
// on other targets"), so that a kernel's source compiles and behaves the
// same there. Nothing is checked at compile time (@:hxmc.kernel is plain
// metadata here); an access out of range throws a SpanError. Elements are
// little-endian, as on every hxmc target. Made by ofBytes; ofIoBuffer and
// unsafeOf are hxmc's only (a compile error).
abstract Span<T>(SpanData) {
	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	@:arrayAccess inline function get(i:Int):T
		return this.get(i);

	@:arrayAccess inline function set(i:Int, v:T):T {
		this.set(i, v);
		return v;
	}

	public inline function sub(pos:Int, len:Int):Span<T>
		return cast this.sub(pos, len);

	// the same bytes as elements of U, the type the result is given:
	// `var words:Span<Int> = bytes.reinterpret();`
	public macro function reinterpret(self:Expr):Expr
		return SpanData.reinterpretOf(self);

	public inline function blit(pos:Int, src:ReadOnlySpan<T>, srcpos:Int, len:Int):Void
		this.blit(pos, cast src, srcpos, len);

	public inline function fill(pos:Int, len:Int, v:T):Void
		this.fill(pos, len, v);

	// (no other thread holds a span here: plain accesses)
	public inline function load(i:Int):T
		return this.load(i);

	public inline function store(i:Int, v:T):Void
		this.store(i, v);

	public inline function compareExchange(i:Int, expected:T, replacement:T):T
		return this.compareExchange(i, expected, replacement);

	@:to inline function toReadOnly():ReadOnlySpan<T>
		return cast this;

	public static inline function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):Span<UInt8>
		return cast SpanData.ofBytes(b, pos, len);

	public static macro function ofIoBuffer(args:Array<Expr>):Expr
		return SpanData.hxmcOnly("Span.ofIoBuffer");

	public static macro function unsafeOf(args:Array<Expr>):Expr
		return SpanData.hxmcOnly("Span.unsafeOf");
}

// an access out of range (on hxmc the program ends; here a span is GC code's)
class SpanError extends haxe.Exception {}

// (a span's state; its element type as a kind, from ofBytes or reinterpret)
@:noCompletion class SpanData {
	public static inline var U8 = 0;
	public static inline var I8 = 1;
	public static inline var U16 = 2;
	public static inline var I16 = 3;
	public static inline var I32 = 4;
	public static inline var F32 = 5;
	public static inline var F64 = 6;
	public static inline var BOOL = 7;
	public static inline var I64 = 8;
	public static inline var STRUCT = 9;

	public var b:Bytes;
	// (bytes: the first element's offset in b, an element's size)
	public var off:Int;
	public var size:Int;
	public var length:Int;
	public var kind:Int;
	// (struct elements: objects of their own, from at in objs; make a zeroed
	// one, copy one's fields into another)
	public var objs:Array<Dynamic>;
	public var at:Int;
	public var make:() -> Dynamic;
	public var copy:(Dynamic, Dynamic) -> Void;

	public function new(b:Bytes, off:Int, size:Int, length:Int, kind:Int) {
		this.b = b;
		this.off = off;
		this.size = size;
		this.length = length;
		this.kind = kind;
		this.at = 0;
	}

	// [pos, pos + len) inside n, len -1 to the end: its length, or -1
	static function range(n:Int, pos:Int, len:Int):Int {
		if (len == -1) len = n - pos;
		return pos < 0 || len < 0 || pos > n - len ? -1 : len;
	}

	public static function ofBytes(b:Bytes, pos:Int, len:Int):SpanData {
		var n = range(b.length, pos, len);
		if (n < 0) throw haxe.io.Error.OutsideBounds;
		return new SpanData(b, pos, 1, n, U8);
	}

	inline function check(i:Int)
		if (i < 0 || i >= length) throw new SpanError('span index $i out of range [0, $length)');

	function checkRange(pos:Int, len:Int)
		if (pos < 0 || len < 0 || pos > length - len) throw new SpanError('span range $pos + $len out of range [0, $length)');

	public function get(i:Int):Dynamic {
		check(i);
		var p = off + i * size;
		return switch kind {
			case U8: b.get(p);
			case I8: (b.get(p) << 24) >> 24;
			case U16: b.getUInt16(p);
			case I16: (b.getUInt16(p) << 16) >> 16;
			case I32: b.getInt32(p);
			case F32: b.getFloat(p);
			case F64: b.getDouble(p);
			case BOOL: b.get(p) != 0;
			case I64: haxe.Int64.make(b.getInt32(p + 4), b.getInt32(p));
			case _: objs[at + i];
		}
	}

	public function set(i:Int, v:Dynamic) {
		check(i);
		put(off + i * size, i, v);
	}

	function put(p:Int, i:Int, v:Dynamic)
		switch kind {
			case U8 | I8: b.set(p, (v : Int) & 0xFF);
			case U16 | I16: b.setUInt16(p, (v : Int) & 0xFFFF);
			case I32: b.setInt32(p, v);
			case F32: b.setFloat(p, v);
			case F64: b.setDouble(p, v);
			case BOOL: b.set(p, v ? 1 : 0);
			case I64:
				var x:haxe.Int64 = v;
				b.setInt32(p, x.low);
				b.setInt32(p + 4, x.high);
			case _: copy(objs[at + i], v);
		}

	public function sub(pos:Int, len:Int):SpanData {
		checkRange(pos, len);
		return view(off + pos * size, len, at + pos);
	}

	function view(off:Int, len:Int, at:Int):SpanData {
		var s = new SpanData(b, off, size, len, kind);
		s.objs = objs;
		s.at = at;
		s.make = make;
		s.copy = copy;
		return s;
	}

	public function blit(pos:Int, src:SpanData, srcpos:Int, len:Int) {
		checkRange(pos, len);
		src.checkRange(srcpos, len);
		if (kind != STRUCT) {
			b.blit(off + pos * size, src.b, src.off + srcpos * size, len * size);
			return;
		}
		// (overlapping ones too: through copies)
		var tmp = [for (k in 0...len) {
			var o = make();
			copy(o, src.objs[src.at + srcpos + k]);
			o;
		}];
		for (k in 0...len)
			copy(objs[at + pos + k], tmp[k]);
	}

	public function fill(pos:Int, len:Int, v:Dynamic) {
		checkRange(pos, len);
		for (k in 0...len)
			put(off + (pos + k) * size, pos + k, v);
	}

	public inline function load(i:Int):Dynamic
		return get(i);

	public inline function store(i:Int, v:Dynamic)
		set(i, v);

	public function compareExchange(i:Int, expected:Dynamic, replacement:Dynamic):Dynamic {
		var old:Dynamic = get(i);
		var same = switch kind {
			case I64: haxe.Int64.eq(old, expected);
			case I32 | U8 | I8 | U16 | I16 | BOOL: old == expected;
			case _: throw new SpanError("compareExchange: atomic accesses are of Int, UInt and Int64 elements");
		}
		if (same) set(i, replacement);
		return old;
	}

	// the same bytes as elements of another kind (a struct's: objects of
	// their own, zeroed, which the bytes do not see)
	public static function reinterpret(s:SpanData, kind:Int, size:Int, make:() -> Dynamic, copy:(Dynamic, Dynamic) -> Void):SpanData {
		var r = new SpanData(s.b, s.off, size, Std.int((s.length * s.size) / size), kind);
		if (kind == STRUCT) {
			r.objs = [for (k in 0...r.length) make()];
			r.make = make;
			r.copy = copy;
		}
		return r;
	}

	#if macro
	public static function hxmcOnly(what:String):Expr
		return Context.error('$what is hxmc\'s only: an IoBuffer or a Ptr is hxmc.unsafe\'s, which ${Context.definedValue("target.name")} does not have; lend a Bytes (ofBytes)', Context.currentPos());

	// `self.reinterpret()`: the element type from the type the result is given
	public static function reinterpretOf(self:Expr):Expr {
		var pos = Context.currentPos();
		var want = Context.getExpectedType();
		var elem = want == null ? null : switch Context.follow(want) {
			case TAbstract(_.get() => a, [t]) if (a.pack.join(".") == "hxmc" && (a.name == "Span" || a.name == "ReadOnlySpan")): t;
			case _: null;
		}
		if (elem == null) return Context.error("reinterpret: give the result a span type (var words:Span<Int> = s.reinterpret())", pos);
		var e = element(elem, pos);
		return macro @:pos(pos) cast hxmc.Span.SpanData.reinterpret(cast $self, $v{e.kind}, $v{e.size}, ${e.make}, ${e.copy});
	}

	// an element type's kind, size and alignment (a struct's: its C layout),
	// and for a struct, its zeroed object and its copy
	public static function element(t:Type, pos:Position):{kind:Int, size:Int, align:Int, make:Expr, copy:Expr} {
		inline function scalar(kind:Int, size:Int)
			return {kind: kind, size: size, align: size, make: macro null, copy: macro null};
		switch t {
			case TType(_) | TLazy(_):
				return element(Context.follow(t, true), pos);
			case TAbstract(_.get() => a, _):
				switch a.pack.join(".") + "." + a.name {
					case ".Int" | ".UInt" | "haxe.UInt32" | "haxe.Int32": return scalar(I32, 4);
					case ".Float": return scalar(F64, 8);
					case ".Bool": return scalar(BOOL, 1);
					case "hxmc.unsafe.UInt8": return scalar(U8, 1);
					case "hxmc.unsafe.Int8": return scalar(I8, 1);
					case "hxmc.unsafe.UInt16": return scalar(U16, 2);
					case "hxmc.unsafe.Int16": return scalar(I16, 2);
					case "hxmc.unsafe.Float32": return scalar(F32, 4);
					case "hxmc.I64" | "haxe.Int64": return scalar(I64, 8);
					case _:
				}
			case TInst(cr, _) if (cr.get().meta.has(":hxmc.struct")):
				return struct(cr, pos);
			case _:
		}
		return Context.error('a span of ${haxe.macro.TypeTools.toString(t)}: its elements are C scalars or @:hxmc.struct classes', pos);
	}

	// a struct's C layout, its zeroed object, its copy (scalar fields only)
	public static function struct(cr:Ref<ClassType>, pos:Position):{kind:Int, size:Int, align:Int, make:Expr, copy:Expr} {
		var c = cr.get();
		// the class as a value, already typed: no path names a private type in
		// an expression (`pkg._Kern.State` is none, `pkg.Kern.State` the class
		// Kern's field)
		var cls = Context.storeTypedExpr({expr: TTypeExpr(TClassDecl(cr)), t: TDynamic(null), pos: pos});
		var off = 0, align = 1, zero = [], copy = [];
		for (f in c.fields.get()) {
			if (!f.kind.match(FVar(_, _))) continue;
			var e = element(f.type, f.pos);
			if (e.kind == STRUCT)
				Context.error('the struct ${c.name}\'s field ${f.name}: a struct field of a span\'s struct element is hxmc\'s only', f.pos);
			off = (off + e.align - 1) & -e.align;
			off += e.size;
			if (e.align > align) align = e.align;
			var z:Expr = switch e.kind {
				case F32 | F64: macro 0.0;
				case BOOL: macro false;
				case I64: macro haxe.Int64.ofInt(0);
				case _: macro 0;
			}
			var n = f.name;
			zero.push(macro o.$n = $z);
			// (a field never written is null on dynamic targets: zero, as hxmc's are)
			copy.push(macro {
				var v:Dynamic = s.$n;
				d.$n = v == null ? $z : v;
			});
		}
		var size = (off + align - 1) & -align;
		var make = macro function():Dynamic {
			var o:Dynamic = Type.createEmptyInstance(cast $cls);
			$b{zero};
			return o;
		};
		var copyFn = macro function(d:Dynamic, s:Dynamic):Void $b{copy};
		return {kind: STRUCT, size: size, align: align, make: make, copy: copyFn};
	}
	#end
}
