package hxmc.wasmgc;

import hxmc.Buf;
import hxmc.ir.Ir;
import hxmc.wasm.Enc;

// Reflection for the runtime (hxmc.rt.gc.GcNative, through W): tables made
// by _start before anything runs (class types by class index, field names by
// class and by anonymous structure, enum types, constructor names), and the
// functions that read and write a field by its index, make an empty
// instance, an instance by its constructor (Type.createInstance), an enum
// value, read an enum value's arguments.
class Meta {
	final m:GcModule;
	static inline var EQREF = 0x6D; // (a local of any reference, GcModule's "p")
	public var clsTypes(default, null) = -1;
	public var clsFields(default, null) = -1;
	public var enumTypes(default, null) = -1;
	public var enumNames(default, null) = -1;
	public var shapeNames(default, null) = -1;
	public var clsStatics(default, null) = -1;

	public function new(m:GcModule)
		this.m = m;

	// ---- the tables (mutable globals, set by _start)

	function table():Int
		return m.mutableGlobal();

	public function need() {
		if (clsTypes >= 0) return;
		clsTypes = table();
		clsFields = table();
		enumTypes = table();
		enumNames = table();
		shapeNames = table();
		clsStatics = table();
	}

	// _start's code that fills them
	public function fill(b:Buf) {
		if (clsTypes < 0) return;
		var pt = m.dataType("p");
		inline function setGlobal(g:Int) {
			b.u8(0x24);
			Enc.uleb(b, g);
		}
		// a Haxe Array<String> of the names
		function names(ns:Array<String>) {
			b.u8(0x41);
			Enc.sleb(b, ns.length);
			for (n in ns) {
				b.u8(0x23);
				Enc.uleb(b, m.strLit(n));
			}
			m.gc(b, 0x08, pt, ns.length);
			m.gc(b, 0x00, m.arrType("p"));
		}
		var cls = m.classList();
		for (c in cls) {
			b.u8(0x23);
			Enc.uleb(b, m.typeValue(TRClass(c)));
		}
		m.gc(b, 0x08, pt, cls.length);
		setGlobal(clsTypes);
		// (the class of dates: none, its time not a field, as natively:
		// GcGen.Uses.dateClass; then the derived fields, @:hxmc.lengthOf:
		// indices from c.fields.length)
		for (c in cls)
			names(c == m.uses.dateClass ? [] : [for (f in c.fields) f.name].concat([for (d in c.derived) d.name]));
		m.gc(b, 0x08, pt, cls.length);
		setGlobal(clsFields);
		var es = m.enumList();
		for (e in es) {
			b.u8(0x23);
			Enc.uleb(b, m.typeValue(TREnum(e)));
		}
		m.gc(b, 0x08, pt, es.length);
		setGlobal(enumTypes);
		for (e in es)
			names([for (c in e.ctors) c.name]);
		m.gc(b, 0x08, pt, es.length);
		setGlobal(enumNames);
		var ss = m.shapeList();
		for (s in ss)
			names([for (f in s.fields) f.name]);
		m.gc(b, 0x08, pt, ss.length);
		setGlobal(shapeNames);
		// the names of the statics reached through each class value (Lower.reflectStatics), or null
		for (c in cls)
			if (c.statics == null) m.constZero(b, "p") else names([for (s in c.statics) s.name]);
		m.gc(b, 0x08, pt, cls.length);
		setGlobal(clsStatics);
	}

	// ---- encodings

	static function get(b:Buf, i:Int) {
		b.u8(0x20);
		Enc.uleb(b, i);
	}

	static function i32(b:Buf, v:Int) {
		b.u8(0x41);
		Enc.sleb(b, v);
	}

	function test(b:Buf, t:Int) {
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, t);
	}

	function box(b:Buf, t:Ty)
		m.box(b, t);

	// a Dynamic on the stack as a t: unboxed, or cast to its type (keyOf)
	function unboxAs(b:Buf, t:Ty) {
		unbox(b, t);
		var k = m.keyOf(t);
		if (k.charAt(0) == "t") m.castTo(b, Std.parseInt(k.substr(1)));
	}

	function unbox(b:Buf, t:Ty)
		if (GcModule.repr(t) != "p") {
			b.u8(0x10);
			Enc.uleb(b, Helpers.unbox(m, t == TBool ? "b" : GcModule.repr(t)));
		}

	// the class index of local 0 (an object)
	function clsOf(b:Buf) {
		get(b, 0);
		m.castTo(b, m.objType);
		m.indexOf(b);
	}

	static function storable(t:Ty):Bool
		return !t.match(TStruct(_));

	// a table, as the array it is
	function tableGet(b:Buf, g:Int) {
		b.u8(0x23);
		Enc.uleb(b, g);
		m.castTo(b, m.dataType("p"));
	}

	// ---- the functions

	function helper(name:String, key:String, locals:Array<Int>, body:Buf->Void):Int {
		var h = m.hasHelper(name);
		if (h != null) return h;
		need();
		var b = new Buf();
		var i = m.addHelper(name, key, b, locals);
		body(b);
		return i;
	}

	// the class of an object (its type value), null for anything else
	public function classOf():Int
		return helper("meta_class_of", "p_p", [], b -> {
			get(b, 0);
			test(b, m.objType);
			b.u8(0x04);
			b.u8(0x6D);
			tableGet(b, clsTypes);
			clsOf(b);
			m.gc(b, 0x0B, m.dataType("p"));
			b.u8(0x05);
			m.constZero(b, "p");
			b.u8(0x0B);
		});

	// the index of an anonymous structure's layout (its field 1), -1 when not one
	public function shapeIndex():Int
		return helper("meta_shape_index", "p_i", [], b -> {
			get(b, 0);
			test(b, m.anonBaseType);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 0);
			m.castTo(b, m.anonBaseType);
			m.indexOf(b, true);
			b.u8(0x0F);
			b.u8(0x0B);
			i32(b, -1);
		});

	// a switch on the i32 in local sel over 0...n: each case's code (which may
	// return), then on past the switch (also for the values outside)
	static function dispatch(b:Buf, sel:Int, n:Int, body:Int->Void) {
		b.u8(0x02);
		b.u8(0x40);
		for (_ in 0...n) {
			b.u8(0x02);
			b.u8(0x40);
		}
		get(b, sel);
		b.u8(0x0E);
		Enc.uleb(b, n);
		for (i in 0...n)
			Enc.uleb(b, i);
		Enc.uleb(b, n);
		for (i in 0...n) {
			b.u8(0x0B);
			body(i);
			b.u8(0x0C);
			Enc.uleb(b, n - 1 - i);
		}
		b.u8(0x0B);
	}

	// the names of an object's fields (class or anonymous structure; null otherwise), by index
	public function fieldNames():Int {
		var si = shapeIndex();
		return helper("meta_field_names", "p_p", [Enc.I32], b -> {
			get(b, 0);
			test(b, m.objType);
			b.u8(0x04);
			b.u8(0x40);
			tableGet(b, clsFields);
			clsOf(b);
			m.gc(b, 0x0B, m.dataType("p"));
			b.u8(0x0F);
			b.u8(0x0B);
			get(b, 0);
			b.u8(0x10);
			Enc.uleb(b, si);
			b.u8(0x22);
			b.u8(1);
			i32(b, 0);
			b.u8(0x4E);
			b.u8(0x04);
			b.u8(0x40);
			tableGet(b, shapeNames);
			get(b, 1);
			m.gc(b, 0x0B, m.dataType("p"));
			b.u8(0x0F);
			b.u8(0x0B);
			m.constZero(b, "p");
		});
	}

	// o's field i (of fieldNames), boxed: by its class or layout (br_table), then by i
	public function objGet():Int {
		var si = shapeIndex();
		return helper("meta_obj_get", "pi_p", [Enc.I32], b -> {
			get(b, 0);
			test(b, m.objType);
			b.u8(0x04);
			b.u8(0x40);
			clsOf(b);
			b.u8(0x21);
			b.u8(2);
			var cls = m.classList();
			dispatch(b, 2, cls.length, k -> {
				var c = cls[k];
				for (j in 0...c.fields.length) {
					if (!storable(c.fields[j].ty)) continue;
					get(b, 1);
					i32(b, j);
					b.u8(0x46);
					b.u8(0x04);
					b.u8(0x40);
					get(b, 0);
					m.castTo(b, m.classType(c));
					m.gc(b, 0x02, m.classType(c), j + 1);
					box(b, c.fields[j].ty);
					b.u8(0x0F);
					b.u8(0x0B);
				}
				// a derived field: the length of its NativeArray field (array.len)
				for (k in 0...c.derived.length) {
					get(b, 1);
					i32(b, c.fields.length + k);
					b.u8(0x46);
					b.u8(0x04);
					b.u8(0x40);
					get(b, 0);
					m.castTo(b, m.classType(c));
					m.gc(b, 0x02, m.classType(c), c.fieldIndex(c.derived[k].of) + 1);
					m.gc(b, 0x0F);
					box(b, TI32);
					b.u8(0x0F);
					b.u8(0x0B);
				}
			});
			m.constZero(b, "p");
			b.u8(0x0F);
			b.u8(0x0B);
			get(b, 0);
			b.u8(0x10);
			Enc.uleb(b, si);
			b.u8(0x21);
			b.u8(2);
			var ss = m.shapeList();
			dispatch(b, 2, ss.length, k -> {
				var sh = ss[k];
				for (j in 0...sh.fields.length) {
					if (!storable(sh.fields[j].ty)) continue;
					get(b, 1);
					i32(b, j);
					b.u8(0x46);
					b.u8(0x04);
					b.u8(0x40);
					get(b, 0);
					m.castTo(b, m.shapeType(sh));
					m.gc(b, 0x02, m.shapeType(sh), j + 2);
					box(b, sh.fields[j].ty);
					b.u8(0x0F);
					b.u8(0x0B);
				}
			});
			m.constZero(b, "p");
		});
	}

	// a shallow copy of a class instance or an anonymous structure (Reflect.copy:
	// its own identity hash, a structure's added fields left to GcNative), null
	// for anything else: by its class or layout (br_table)
	public function objCopy():Int {
		var si = shapeIndex();
		return helper("meta_obj_copy", "p_p", [Enc.I32], b -> {
			get(b, 0);
			test(b, m.objType);
			b.u8(0x04);
			b.u8(0x40);
			clsOf(b);
			b.u8(0x21);
			b.u8(1);
			var cls = m.classList();
			dispatch(b, 1, cls.length, k -> {
				var c = cls[k];
				i32(b, m.clsOf(c));
				for (j in 0...c.fields.length) {
					get(b, 0);
					m.castTo(b, m.classType(c));
					m.gc(b, 0x02, m.classType(c), j + 1);
				}
				m.gc(b, 0x00, m.classType(c));
				b.u8(0x0F);
			});
			m.constZero(b, "p");
			b.u8(0x0F);
			b.u8(0x0B);
			get(b, 0);
			b.u8(0x10);
			Enc.uleb(b, si);
			b.u8(0x21);
			b.u8(1);
			var ss = m.shapeList();
			dispatch(b, 1, ss.length, k -> {
				var sh = ss[k];
				m.constZero(b, "p");
				i32(b, m.shapeId(sh));
				for (j in 0...sh.fields.length) {
					get(b, 0);
					m.castTo(b, m.shapeType(sh));
					m.gc(b, 0x02, m.shapeType(sh), j + 2);
				}
				m.gc(b, 0x00, m.shapeType(sh));
				b.u8(0x0F);
			});
			m.constZero(b, "p");
		});
	}

	// o's field i = v (unboxed)
	// (whether it was set: a derived field, @:hxmc.lengthOf, is not)
	public function objSet():Int {
		var si = shapeIndex();
		return helper("meta_obj_set", "pip_i", [Enc.I32], b -> {
			get(b, 0);
			test(b, m.objType);
			b.u8(0x04);
			b.u8(0x40);
			clsOf(b);
			b.u8(0x21);
			b.u8(3);
			var cls = m.classList();
			dispatch(b, 3, cls.length, k -> {
				var c = cls[k];
				for (j in 0...c.fields.length) {
					if (!storable(c.fields[j].ty)) continue;
					get(b, 1);
					i32(b, j);
					b.u8(0x46);
					b.u8(0x04);
					b.u8(0x40);
					get(b, 0);
					m.castTo(b, m.classType(c));
					get(b, 2);
					unbox(b, c.fields[j].ty);
					var fk = m.fieldKey(c, j);
					if (fk.charAt(0) == "t") m.castTo(b, Std.parseInt(fk.substr(1)));
					m.gc(b, 0x05, m.classType(c), j + 1);
					i32(b, 1);
					b.u8(0x0F);
					b.u8(0x0B);
				}
				// a derived field cannot be set (GcNative.setField throws)
				for (k in 0...c.derived.length) {
					get(b, 1);
					i32(b, c.fields.length + k);
					b.u8(0x46);
					b.u8(0x04);
					b.u8(0x40);
					i32(b, 0);
					b.u8(0x0F);
					b.u8(0x0B);
				}
			});
			i32(b, 1);
			b.u8(0x0F);
			b.u8(0x0B);
			get(b, 0);
			b.u8(0x10);
			Enc.uleb(b, si);
			b.u8(0x21);
			b.u8(3);
			var ss = m.shapeList();
			dispatch(b, 3, ss.length, k -> {
				var sh = ss[k];
				for (j in 0...sh.fields.length) {
					if (!storable(sh.fields[j].ty)) continue;
					get(b, 1);
					i32(b, j);
					b.u8(0x46);
					b.u8(0x04);
					b.u8(0x40);
					get(b, 0);
					m.castTo(b, m.shapeType(sh));
					get(b, 2);
					unbox(b, sh.fields[j].ty);
					m.gc(b, 0x05, m.shapeType(sh), j + 2);
					i32(b, 1);
					b.u8(0x0F);
					b.u8(0x0B);
				}
			});
			i32(b, 1);
		});
	}

	// a type value's field (0 kind, 1 id, 2 name)
	public function typeField(b:Buf, f:Int) {
		m.castTo(b, m.typeType());
		m.gc(b, 0x02, m.typeType(), f);
	}

	// an instance of the class (a type value) with its fields zero, no constructor run
	public function createEmpty():Int
		return helper("meta_create_empty", "p_p", [Enc.I32], b -> {
			get(b, 0);
			typeField(b, 1);
			b.u8(0x21);
			b.u8(1);
			for (c in m.classList()) {
				get(b, 1);
				i32(b, c.id);
				b.u8(0x46);
				b.u8(0x04);
				b.u8(0x40);
				i32(b, m.clsOf(c));
				for (f in c.fields)
					m.constZero(b, GcModule.repr(f.ty));
				m.gc(b, 0x00, m.classType(c));
				b.u8(0x0F);
				b.u8(0x0B);
			}
			m.constZero(b, "p");
		});

	// the function Type.createInstance calls for class c (ClassInfo.maker), if kept
	function makerOf(c:ClassInfo):Null<FuncInfo>
		return c.maker == null || c.maker.fn == null || !m.reached(c.maker.fn) ? null : c.maker.fn;

	// Type.createInstance (GcNative.createInstance): an instance of the class (a
	// type value, local 0) made as createEmpty's, its entry's constructor
	// (makerOf) called on it with the arguments (local 1: an array, those
	// missing null, unboxed as the parameters are); null when it has no
	// constructor kept
	public function createInstance():Int {
		var h = m.hasHelper("meta_create_instance");
		if (h != null) return h;
		var arrGet = Helpers.arrGetDyn(m);
		return helper("meta_create_instance", "pp_p", [Enc.I32, EQREF], b -> {
			get(b, 0);
			typeField(b, 1);
			b.u8(0x21);
			b.u8(2);
			for (c in m.classList()) {
				var f = makerOf(c);
				if (f == null) continue;
				get(b, 2);
				i32(b, c.id);
				b.u8(0x46);
				b.u8(0x04);
				b.u8(0x40);
				i32(b, m.clsOf(c));
				for (fl in c.fields)
					m.constZero(b, GcModule.repr(fl.ty));
				m.gc(b, 0x00, m.classType(c));
				b.u8(0x21);
				b.u8(3);
				get(b, 3);
				unboxAs(b, f.args[0].ty);
				for (i in 1...f.args.length) {
					get(b, 1);
					i32(b, i - 1);
					b.u8(0x10);
					Enc.uleb(b, arrGet);
					unboxAs(b, f.args[i].ty);
				}
				b.u8(0x10);
				Enc.uleb(b, m.funcOf(f));
				get(b, 3);
				b.u8(0x0F);
				b.u8(0x0B);
			}
			m.constZero(b, "p");
		});
	}

	// the kind of the class's entry for Type.createInstance (a type value, local
	// 0): 0 none (Reach left it out), 1 no constructor, 2 a constructor
	public function makerKind():Int
		return helper("meta_maker_kind", "p_i", [Enc.I32], b -> {
			get(b, 0);
			typeField(b, 1);
			b.u8(0x21);
			b.u8(1);
			for (c in m.classList()) {
				if (c.maker == null) continue;
				get(b, 1);
				i32(b, c.id);
				b.u8(0x46);
				b.u8(0x04);
				b.u8(0x40);
				i32(b, makerOf(c) != null ? 2 : c.maker.fn == null ? 1 : 0);
				b.u8(0x0F);
				b.u8(0x0B);
			}
			i32(b, 0);
		});

	// the enum of an enum value (its type value: the table at its enum index), null for anything else
	public function enumOf():Int
		return helper("meta_enum_of", "p_p", [], b -> {
			get(b, 0);
			test(b, m.enumType);
			b.u8(0x04);
			b.u8(0x6D);
			tableGet(b, enumTypes);
			get(b, 0);
			m.castTo(b, m.enumType);
			m.gc(b, 0x02, m.enumType, 1);
			m.gc(b, 0x0B, m.dataType("p"));
			b.u8(0x05);
			m.constZero(b, "p");
			b.u8(0x0B);
		});

	// whether two enum values are equal (Type.enumEq, as hxmc.rt.Dyn's): the
	// same enum and constructor, their arguments equal (enums compared so, the
	// rest as Dynamic: gc_dyn_eq)
	public function enumEq():Int {
		var h = m.hasHelper("meta_enum_eq");
		if (h != null) return h;
		need();
		var b = new Buf();
		var idx = m.addHelper("meta_enum_eq", "pp_i", b, [Enc.I32, Enc.I32, -1 - m.enumType, -1 - m.enumType]);
		var dynEq = m.exportOf("gc_dyn_eq");
		get(b, 0);
		get(b, 1);
		b.u8(0xD3);
		b.u8(0x04);
		b.u8(0x40);
		i32(b, 1);
		b.u8(0x0F);
		b.u8(0x0B);
		// (both enums, as such in locals 4 and 5; else not equal)
		b.u8(0x02);
		b.u8(0x6D);
		for (x in 0...2) {
			get(b, x);
			b.u8(0xFB);
			b.u8(0x19);
			b.u8(1);
			b.u8(0);
			b.u8(0x6D);
			Enc.sleb(b, m.enumType);
			b.u8(0x21);
			b.u8(4 + x);
		}
		// (the same enum, local 2; the same constructor, local 3)
		for (f in 0...2) {
			get(b, 4);
			m.gc(b, 0x02, m.enumType, f);
			b.u8(0x22);
			b.u8(3 - f);
			get(b, 5);
			m.gc(b, 0x02, m.enumType, f);
			b.u8(0x47);
			b.u8(0x04);
			b.u8(0x40);
			i32(b, 0);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		var es = m.enumList();
		dispatch(b, 2, es.length, ei -> {
			var e = es[ei];
			var maxTag = 0;
			for (c in e.ctors)
				if (c.tag > maxTag) maxTag = c.tag;
			dispatch(b, 3, maxTag + 1, tag -> {
				var c = null;
				for (k in e.ctors)
					if (k.tag == tag) c = k;
				if (c == null || c.params.length == 0) return;
				var t = m.ctorType(c);
				for (k in 0...c.params.length) {
					var r = GcModule.repr(c.params[k]);
					inline function field(x:Int) {
						get(b, x);
						m.castTo(b, t);
						m.gc(b, 0x02, t, k + 2);
					}
					field(0);
					field(1);
					switch r {
						case "i": b.u8(0x47);
						case "f": b.u8(0x62);
						case "l": b.u8(0x52);
						case _:
							// (references: the same, else both enums compared so, else as Dynamic)
							b.u8(0x10);
							Enc.uleb(b, Helpers.refEq3(m, idx, dynEq));
							b.u8(0x45);
					}
					b.u8(0x04);
					b.u8(0x40);
					i32(b, 0);
					b.u8(0x0F);
					b.u8(0x0B);
				}
			});
		});
		i32(b, 1);
		b.u8(0x0F);
		b.u8(0x0B);
		b.u8(0x1A);
		i32(b, 0);
		return idx;
	}

	// the names of an enum's constructors (a type value)
	public function enumNamesOf():Int
		return helper("meta_enum_names", "p_p", [], b -> {
			tableGet(b, enumNames);
			get(b, 0);
			typeField(b, 1);
			m.gc(b, 0x0B, m.dataType("p"));
		});

	// an enum value's arguments, boxed, in an Array<Dynamic> (an empty one for
	// anything else): a dispatch on its enum to that enum's function, which
	// dispatches on its constructor. (One function testing every constructor of
	// the program in turn took as long as there were constructors, and V8, which
	// charges a call to its tiering budget by how far into the function it
	// returns, compiled it with its optimizing tier after a few dozen calls: half
	// a second of a thread's time, which the port's startup waited for at exit,
	// as for enumCreate's.)
	public function enumParams():Int {
		var h = m.hasHelper("meta_enum_params");
		if (h != null) return h;
		var es = m.enumList();
		var per = [for (ei in 0...es.length) enumParamsOf(es[ei], ei)];
		return helper("meta_enum_params", "p_p", [Enc.I32], b -> {
			get(b, 0);
			test(b, m.enumType);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 0);
			m.castTo(b, m.enumType);
			m.gc(b, 0x02, m.enumType, 1);
			b.u8(0x21);
			b.u8(1);
			dispatch(b, 1, es.length, ei -> {
				if (per[ei] < 0) return;
				get(b, 0);
				b.u8(0x10);
				Enc.uleb(b, per[ei]);
				b.u8(0x0F);
			});
			b.u8(0x0B);
			emptyArray(b);
		});
	}

	// an empty Array<Dynamic>
	function emptyArray(b:Buf) {
		i32(b, 0);
		i32(b, 0);
		m.gc(b, 0x07, m.dataType("p"));
		m.gc(b, 0x00, m.arrType("p"));
	}

	// the arguments of a value of the enum e (index ei), by its constructor; -1
	// when no constructor of e has any
	function enumParamsOf(e:EnumInfo, ei:Int):Int {
		var maxTag = 0, any = false;
		for (c in e.ctors) {
			if (c.tag > maxTag) maxTag = c.tag;
			if (c.params.length > 0) any = true;
		}
		if (!any) return -1;
		return helper("meta_enum_params_" + ei, "p_p", [Enc.I32], b -> {
			get(b, 0);
			m.castTo(b, m.enumType);
			m.gc(b, 0x02, m.enumType, 0);
			b.u8(0x21);
			b.u8(1);
			dispatch(b, 1, maxTag + 1, tag -> {
				var c = null;
				for (k in e.ctors)
					if (k.tag == tag) c = k;
				if (c == null || c.params.length == 0) return;
				i32(b, c.params.length);
				for (k in 0...c.params.length) {
					get(b, 0);
					m.castTo(b, m.ctorType(c));
					m.gc(b, 0x02, m.ctorType(c), k + 2);
					box(b, c.params[k]);
				}
				m.gc(b, 0x08, m.dataType("p"), c.params.length);
				m.gc(b, 0x00, m.arrType("p"));
				b.u8(0x0F);
			});
			emptyArray(b);
		});
	}

	// the enum's (a type value) constructor `index` with the arguments (an
	// Array<Dynamic>, unboxed), null for no such constructor: a dispatch on the
	// enum to its function (see enumParams)
	public function enumCreate():Int {
		var h = m.hasHelper("meta_enum_create");
		if (h != null) return h;
		var es = m.enumList();
		var arrGet = Helpers.arrGetDyn(m);
		var per = [for (ei in 0...es.length) enumCreateOf(es[ei], ei, arrGet)];
		return helper("meta_enum_create", "pip_p", [Enc.I32], b -> {
			get(b, 0);
			typeField(b, 1);
			b.u8(0x21);
			b.u8(3);
			dispatch(b, 3, es.length, ei -> {
				get(b, 1);
				get(b, 2);
				b.u8(0x10);
				Enc.uleb(b, per[ei]);
				b.u8(0x0F);
			});
			m.constZero(b, "p");
		});
	}

	// the constructor (local 0) of the enum e (index ei) with the arguments (local 1)
	function enumCreateOf(e:EnumInfo, ei:Int, arrGet:Int):Int {
		var maxTag = 0;
		for (c in e.ctors)
			if (c.tag > maxTag) maxTag = c.tag;
		return helper("meta_enum_create_" + ei, "ip_p", [], b -> {
			dispatch(b, 0, maxTag + 1, tag -> {
				var c = null;
				for (k in e.ctors)
					if (k.tag == tag) c = k;
				if (c == null) return;
				if (c.params.length == 0 && c.global >= 0) {
					// the constructor's own value (`==` to it)
					b.u8(0x23);
					Enc.uleb(b, m.globalOf(c.global));
				} else if (c.params.length == 0) {
					i32(b, c.tag);
					i32(b, ei);
					m.gc(b, 0x00, m.enumTypeOf(e));
				} else {
					i32(b, c.tag);
					i32(b, ei);
					for (k in 0...c.params.length) {
						get(b, 1);
						i32(b, k);
						b.u8(0x10);
						Enc.uleb(b, arrGet);
						unboxAs(b, c.params[k]);
					}
					m.gc(b, 0x00, m.ctorType(c));
				}
				b.u8(0x0F);
			});
			m.constZero(b, "p");
		});
	}

	// whether local 0 is an instance of the class or interface whose type
	// value's id is local 1 (Std.isOfType with a type known at run time only:
	// GcNative.isOfType), by a switch on the id: over the interfaces the classes
	// made implement (an interface's id is -1 - its index: GcModule.typeValue),
	// else over the classes made
	public function instOf():Int
		return helper("meta_inst_of", "pi_i", [Enc.I32], b -> {
			var byId = new Map<Int, ClassInfo>(), n = 0, ifaces = new Map<Int, ClassInfo>(), ni = 0;
			for (c in m.classList()) {
				byId.set(c.id, c);
				if (c.id + 1 > n) n = c.id + 1;
				for (i in c.ifaces) {
					var k = m.interfaceIndex(i);
					ifaces.set(k, i);
					if (k + 1 > ni) ni = k + 1;
				}
			}
			get(b, 1);
			i32(b, 0);
			b.u8(0x48);
			b.u8(0x04);
			b.u8(0x40);
			i32(b, -1);
			get(b, 1);
			b.u8(0x6B);
			b.u8(0x21);
			b.u8(2);
			dispatch(b, 2, ni, k -> {
				var i = ifaces.get(k);
				if (i == null) return;
				get(b, 0);
				b.u8(0x10);
				Enc.uleb(b, Helpers.implementsOf(m, i));
				b.u8(0x0F);
			});
			i32(b, 0);
			b.u8(0x0F);
			b.u8(0x0B);
			dispatch(b, 1, n, id -> {
				var c = byId.get(id);
				if (c == null) return;
				get(b, 0);
				test(b, m.classType(c));
				b.u8(0x0F);
			});
			i32(b, 0);
		});

	// the names of the statics of the class of index local 0 (clsStatics), null when
	// it has none
	public function staticNames():Int
		return helper("meta_static_names", "i_p", [], b -> {
			tableGet(b, clsStatics);
			get(b, 0);
			m.gc(b, 0x0B, m.dataType("p"));
		});

	// static k (local 1) of the class of index local 0, boxed: a method as a closure
	// (null: one Reach dropped, no name reaching it)
	public function staticGet():Int
		return helper("meta_static_get", "ii_p", [], b -> {
			var cls = m.classList();
			dispatch(b, 0, cls.length, ci -> {
				var ss = cls[ci].statics;
				if (ss == null) return;
				dispatch(b, 1, ss.length, k -> {
					var s = ss[k];
					if (s.clos != null && !m.reached(s.clos.fn)) return;
					if (s.clos != null) {
						var fi = m.funcOf(s.clos.fn);
						m.declare(fi);
						b.u8(0xD2);
						Enc.uleb(b, fi);
						m.gc(b, 0x00, m.lambdaTypeOf(s.clos));
					} else {
						b.u8(0x23);
						Enc.uleb(b, m.globalOf(s.global));
						box(b, m.globalTy(s.global));
					}
					b.u8(0x0F);
				});
			});
			m.constZero(b, "p");
		});

	// static k (local 1) of the class of index local 0 = v (local 2, unboxed):
	// false for a method (it cannot be rebound)
	public function staticSet():Int
		return helper("meta_static_set", "iip_i", [], b -> {
			var cls = m.classList();
			dispatch(b, 0, cls.length, ci -> {
				var ss = cls[ci].statics;
				if (ss == null) return;
				dispatch(b, 1, ss.length, k -> {
					var s = ss[k];
					if (s.clos != null) return;
					get(b, 2);
					unboxAs(b, m.globalTy(s.global));
					b.u8(0x24);
					Enc.uleb(b, m.globalOf(s.global));
					i32(b, 1);
					b.u8(0x0F);
				});
			});
			i32(b, 0);
		});

	// the class types, then the enum types: the type at index i (null past the end)
	public function typeAt():Int
		return helper("meta_type_at", "i_p", [], b -> {
			var nc = m.classList().length, ne = m.enumList().length;
			get(b, 0);
			i32(b, nc);
			b.u8(0x48);
			b.u8(0x04);
			b.u8(0x40);
			tableGet(b, clsTypes);
			get(b, 0);
			m.gc(b, 0x0B, m.dataType("p"));
			b.u8(0x0F);
			b.u8(0x0B);
			get(b, 0);
			i32(b, nc + ne);
			b.u8(0x48);
			b.u8(0x04);
			b.u8(0x40);
			tableGet(b, enumTypes);
			get(b, 0);
			i32(b, nc);
			b.u8(0x6B);
			m.gc(b, 0x0B, m.dataType("p"));
			b.u8(0x0F);
			b.u8(0x0B);
			m.constZero(b, "p");
		});
}
