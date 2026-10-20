// Fields added to anonymous structures at run time (`o.x = ...` on a
// Dynamic, Reflect.setField: slot 0's pairs, hxmc.rt.Dyn; GcFields on
// WasmGC), seen wherever a structure's fields are: Std.string and trace
// (nested in arrays, structures, enum arguments, maps' values), haxe.Json,
// Reflect.copy, compare, fields, hasField, field, deleteField (an added
// field leaves no hole; one of the structure's own cannot be removed:
// false, it stays), haxe.Serializer and Unserializer, equality,
// Type.typeof, Type.enumEq, DynamicAccess, reads, writes and calls through
// structural types and Dynamic; then many of them under collections.
// Against the reference's --interp: Eval prints {a: 1}, its fields in its
// own order (Std.string, Reflect.fields, Json, Serializer), and removes a
// field of the structure's own; hxmc prints { a : 1 }, a structure's own
// fields by name, then the added ones in the order they were added, as
// Reflect.fields lists them, and keeps its own fields (docs/hxmc.md,
// "Anonymous structures"). canon() prints a structure from Reflect, sorted:
// the same on both.
enum Wrap {
	One(v:Dynamic);
	Two(a:Int, v:Dynamic);
}

typedef Added = {x:Int, y:String, ?z:Int};
typedef Kinds = {i:Int, f:Float, b:Bool, s:String};

class AnonFields {
	static function sorted(a:Array<String>):String {
		var c = a.copy();
		c.sort(Reflect.compare);
		return c.join(",");
	}

	// a structure from its Reflect.fields, sorted, recursively
	static function canon(v:Dynamic):String {
		return switch Type.typeof(v) {
			case TObject:
				var fs = Reflect.fields(v);
				fs.sort(Reflect.compare);
				"<" + [for (f in fs) f + "=" + canon(Reflect.field(v, f))].join(" ") + ">";
			case TClass(Array):
				var a:Array<Dynamic> = v;
				"[" + [for (x in a) canon(x)].join(" ") + "]";
			case _:
				Std.string(v);
		}
	}

	static function show(label:String, v:Dynamic)
		Sys.println(label + " " + Std.string(v) + " " + canon(v));

	static function main() {
		// the report's case
		var o:Dynamic = {};
		o.x = 1;
		Reflect.setField(o, "y", "two");
		trace(o);
		trace(Reflect.fields(o));
		var p:Dynamic = {a: 1};
		p.b = 2;
		trace(p);
		show("o", o);
		show("p", p);
		var empty:Dynamic = {};
		show("empty", empty);

		// Std.string where it recurses, and string concatenation
		Sys.println("concat " + ("" + p) + " " + (p + "") + " " + ("<" + o + ">"));
		Sys.println("array " + Std.string([o, p, empty]));
		show("nested", {in1: o, in2: p});
		var outer:Dynamic = {};
		outer.inner = p;
		outer.list = [o];
		show("outer", outer);
		Sys.println("enum " + Std.string(One(o)) + " " + Std.string(Two(3, p)) + " " + Std.string([One(p)]));
		var m = new Map<String, Dynamic>();
		m.set("k", o);
		Sys.println("map " + m.toString());

		// added values of every kind
		var k:Dynamic = {};
		k.i = 7;
		k.f = 1.5;
		k.b = true;
		k.s = "str";
		k.n = null;
		k.a = [1, 2];
		k.o = {z: 0};
		k.o.w = "deep";
		trace(k);
		show("kinds", k);
		Sys.println("kinds " + Reflect.hasField(k, "n") + " " + Reflect.field(k, "n") + " " + Reflect.fields(k).length);

		// haxe.Json
		for (v in [o, p, k]) {
			var j = haxe.Json.stringify(v);
			Sys.println("json " + j + " " + canon(haxe.Json.parse(j)));
		}

		// Reflect.copy: its own added fields
		var c:Dynamic = Reflect.copy(p);
		c.b = 20;
		c.c = 30;
		show("copy of", p);
		show("copy", c);
		// Reflect.compare, equality, Type.typeof, Type.enumEq
		var p2:Dynamic = p;
		Sys.println("compare " + Reflect.compare(p, p2) + " " + (Reflect.compare(p, c) != 0));
		Sys.println("eq " + (p == p2) + " " + (p == c) + " " + (p != c) + " " + Type.typeof(p) + " " + Type.typeof(o) + " " + Reflect.isObject(o));
		Sys.println("enumEq " + Type.enumEq(One(p), One(p2)) + " " + Type.enumEq(One(p), One(c)));

		// fields, hasField, field after adding
		Sys.println("fields " + sorted(Reflect.fields(p)) + " " + Reflect.hasField(p, "a") + " " + Reflect.hasField(p, "b") + " " + Reflect.hasField(p, "zz"));
		Sys.println("field " + Reflect.field(p, "a") + " " + Reflect.field(p, "b") + " " + Reflect.field(p, "zz") + " " + p.b + " " + p.zz);
		// an added field set again keeps its place
		Reflect.setField(o, "x", 11);
		show("set again", o);

		// deleteField of added fields: no hole left, set again later
		var d:Dynamic = {a: 1};
		d.b = 2;
		d.c = 3;
		d.e = 4;
		Sys.println("delete " + Reflect.deleteField(d, "c") + " " + Reflect.deleteField(d, "c") + " " + Reflect.deleteField(d, "zz"));
		show("deleted", d);
		Sys.println("deleted " + sorted(Reflect.fields(d)) + " " + Reflect.fields(d).length + " " + Reflect.hasField(d, "c") + " " + Reflect.field(d, "c") + " " + d.e);
		d.c = 33;
		show("added again", d);
		Sys.println("delete " + Reflect.deleteField(d, "b") + " " + Reflect.deleteField(d, "e") + " " + Reflect.deleteField(d, "c"));
		show("only own", d);
		Sys.println("only own " + Reflect.fields(d).length);
		d.f = 5;
		show("one added", d);
		var dc:Dynamic = Reflect.copy(d);
		Reflect.deleteField(dc, "f");
		show("copy deleted", dc);
		show("its original", d);
		var all:Dynamic = {};
		all.u = 1;
		Reflect.deleteField(all, "u");
		show("all deleted", all);
		Sys.println("all deleted " + Reflect.fields(all).length);
		// deleteField of a field of the structure's own: it stays (Eval removes it)
		var own:Dynamic = {a: 1, b: "x"};
		own.c = 3;
		Sys.println("delete own " + Reflect.deleteField(own, "a") + " " + Reflect.hasField(own, "a") + " " + Reflect.field(own, "a"));
		show("delete own", own);

		// haxe.Serializer and Unserializer (which makes an empty structure
		// and sets the fields)
		for (v in [o, p, k, d]) {
			var s = haxe.Serializer.run(v);
			var u:Dynamic = haxe.Unserializer.run(s);
			Sys.println("serialized " + s);
			show("unserialized", u);
		}

		// DynamicAccess
		var da:haxe.DynamicAccess<Dynamic> = p;
		Sys.println("keys " + sorted(da.keys()) + " " + da.exists("b") + " " + da.get("b"));
		Sys.println("values " + sorted([for (v in da) Std.string(v)]) + " " + sorted([for (key => v in da) key + "=" + v]));
		da.set("q", 9);
		show("da set", p);
		Sys.println("da remove " + da.remove("q") + " " + da.remove("q"));
		show("da removed", p);
		show("da copy", da.copy());

		// through structural types: reads, writes, a missing optional field
		var st:Added = o;
		Sys.println("struct " + st.x + " " + (st.x + 1) + " " + st.y + " " + st.z);
		st.x = 41;
		st.x++;
		st.x += 100;
		st.y += "!";
		st.z = 9;
		show("struct", o);
		var sk:Kinds = k;
		Sys.println("struct " + sk.i + " " + sk.f + " " + sk.b + " " + sk.s + " " + (sk.i * sk.f));
		// a closure added, called through Dynamic and a structural type
		var fn:Dynamic = {base: 10};
		fn.get = function() return 5;
		fn.add = function(a:Int, b:Int) return a + b;
		var sf:{get:Void->Int, add:Int->Int->Int} = fn;
		Sys.println("calls " + fn.get() + " " + fn.add(2, 3) + " " + sf.get() + " " + sf.add(4, 5) + " " + Reflect.isFunction(Reflect.field(fn, "get")));
		// a field of the structure's own set by name stays in place
		Reflect.setField(p, "a", 100);
		p.b = 200;
		show("own set", p);

		// added fields holding structures with added fields
		var root:Dynamic = {};
		root.child = {};
		root.child.leaf = {v: 1};
		root.child.leaf.w = 2;
		trace(root);
		show("root", root);

		// many, under collections (the corpus' 64 KB nursery): added,
		// deleted, printed, kept
		var keep:Array<Dynamic> = [];
		var total = 0;
		for (i in 0...3000) {
			var x:Dynamic = {id: i};
			x.a = i * 2;
			Reflect.setField(x, "s", "v" + i);
			x.b = [i];
			Reflect.deleteField(x, "a");
			x.c = {n: i};
			x.c.m = "m" + i;
			if (i % 500 == 0) show("many", x);
			if (i % 7 == 0) keep.push(x);
			total += canon(x).length;
		}
		var check = 0;
		for (x in keep)
			check += x.id + x.b[0] + x.c.n + (x.s : String).length + (Reflect.hasField(x, "a") ? 1000000 : 0) + Reflect.fields(x).length;
		Sys.println("many " + keep.length + " " + total + " " + check + " " + Std.string(keep[keep.length - 1]));
	}
}
