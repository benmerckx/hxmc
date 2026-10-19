package ml2hx.prim;

import ml2hx.rt.*;

// A block made by Obj.new_block (or Obj.dup of a value of no Haxe class).
class ObjBlock implements Block {
	public var tag:Int;
	public final fields:Array<Dynamic>;
	public function new(tag:Int, fields:Array<Dynamic>) {
		this.tag = tag;
		this.fields = fields;
	}
	public function blockTag():Int return tag;
	public function blockSize():Int return fields.length;
	public function blockField(i:Int):Dynamic return fields[i];
}

// OCaml's obj.c and the Obj primitives over the runtime's values, as
// ml2hx.rt.Poly classifies them (immediates, blocks, strings, floats...).
class Obj {
	static inline var INT_TAG = 1000;
	static inline var OUT_OF_HEAP_TAG = 1001;
	static inline var CUSTOM_TAG = 255;

	public static function isInt(v:Dynamic):Bool return Poly.kind(v) == Poly.K_IMM;

	public static function camlObjTag(v:Dynamic):Int63 {
		var k = Poly.kind(v);
		if (k == Poly.K_IMM) return Int63.ofInt(INT_TAG);
		if (Std.isOfType(v, Lazy)) return Int63.ofInt((v : Lazy<Dynamic>).isVal() ? 250 : 246);
		return Int63.ofInt(Poly.tag(v, k));
	}

	public static function size(v:Dynamic):Int63 {
		var k = Poly.kind(v);
		return switch k {
			case Poly.K_STRING: Int63.ofInt(((v : String).length + 8) >> 3);
			case Poly.K_BYTES: Int63.ofInt(((v : haxe.io.Bytes).length + 8) >> 3);
			case Poly.K_DOUBLE: Int63.one;
			case _: Int63.ofInt(Poly.size(v, k));
		}
	}

	public static function field(v:Dynamic, i:Int63):Dynamic {
		var k = Poly.kind(v);
		var n = i.toInt();
		return switch k {
			case Poly.K_ENUM: Type.enumParameters(v)[n];
			case Poly.K_ARRAY: (v : Array<Dynamic>)[n];
			case Poly.K_BLOCK: (v : Block).blockField(n);
			case _: throw new InvalidArgument("Obj.field: not a block of fields");
		}
	}

	public static function setField(v:Dynamic, i:Int63, x:Dynamic):Unit {
		var n = i.toInt();
		if (Std.isOfType(v, Array)) (v : Array<Dynamic>)[n] = x;
		else if (Std.isOfType(v, ObjBlock)) (v : ObjBlock).fields[n] = x;
		else if (Std.isOfType(v, Ref) && n == 0) (v : Ref<Dynamic>).value = x;
		else {
			// a record of the program: its n-th field (declaration order)
			var cls = Type.getClass(v);
			var names = cls == null ? null : Type.getInstanceFields(cls).filter(f -> !Reflect.isFunction(Reflect.field(v, f)));
			if (names == null || n >= names.length) throw new InvalidArgument("Obj.set_field: not a mutable block");
			Reflect.setField(v, names[n], x);
		}
		return Unit.value;
	}

	public static function camlObjBlock(tag:Int63, size:Int63):Dynamic
		return new ObjBlock(tag.toInt(), [for (_ in 0...size.toInt()) Int63.zero]);

	public static function camlObjDup(v:Dynamic):Dynamic {
		var k = Poly.kind(v);
		return switch k {
			case Poly.K_IMM | Poly.K_STRING | Poly.K_DOUBLE: v;
			case Poly.K_BYTES: (v : haxe.io.Bytes).sub(0, (v : haxe.io.Bytes).length);
			case Poly.K_ARRAY: (v : Array<Dynamic>).copy();
			case Poly.K_BLOCK:
				if (Std.isOfType(v, ObjBlock)) new ObjBlock((v : ObjBlock).tag, (v : ObjBlock).fields.copy());
				else {
					var cls = Type.getClass(v);
					var c = Type.createEmptyInstance(cls);
					for (f in Type.getInstanceFields(cls)) {
						var x = Reflect.field(v, f);
						if (!Reflect.isFunction(x)) Reflect.setField(c, f, x);
					}
					c;
				}
			case _: v;
		}
	}

	public static function camlObjWithTag(tag:Int63, v:Dynamic):Dynamic {
		var k = Poly.kind(v);
		return new ObjBlock(tag.toInt(), Poly.fields(v, k).copy());
	}

	public static function camlObjReachableWords(v:Dynamic):Int63 {
		var seen = new haxe.ds.ObjectMap<Dynamic, Bool>();
		var total = 0;
		var stack:Array<Dynamic> = [v];
		while (stack.length > 0) {
			var x:Dynamic = stack.pop();
			var k = Poly.kind(x);
			if (k == Poly.K_IMM || k == Poly.K_FUNC) continue;
			if (k != Poly.K_DOUBLE && k != Poly.K_STRING) {
				if (seen.exists(x)) continue;
				seen.set(x, true);
			}
			total += size(x).toInt() + 1;
			if (k == Poly.K_ENUM || k == Poly.K_ARRAY || k == Poly.K_BLOCK) for (f in Poly.fields(x, k)) stack.push(f);
		}
		return Int63.ofInt(total);
	}

	public static function camlObjRawField(v:Dynamic, i:Int63):haxe.Int64 {
		var x:Dynamic = field(v, i);
		var imm = Poly.immediateOf(x);
		if (imm == null) throw new InvalidArgument("Obj.raw_field: not an immediate");
		return imm * 2 + 1;
	}
	public static function camlObjSetRawField(v:Dynamic, i:Int63, raw:haxe.Int64):Unit return setField(v, i, Int63.ofInt64(raw >> 1));
	public static function camlObjAddOffset(v:Dynamic, ofs:haxe.Int32):Dynamic throw new InvalidArgument("Obj.add_offset: no addresses in ml2hx");
}
