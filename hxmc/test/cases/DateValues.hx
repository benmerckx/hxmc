// Dates as values (a type index of their own, T_DATE: hxmc.rt.Dyn; the
// runtime's GcDate, named Date, on WasmGC: GcModule.typeValue, GcDyn,
// GcNative): printed (trace, Std.string, concatenation, StringBuf, inside
// arrays, structures and enum arguments), their class (Type.getClass,
// getClassName, typeof, resolveClass, Std.isOfType, downcast, casts, catch),
// equality and Reflect.compare, haxe.Serializer and Unserializer, haxe.Json,
// Reflect.copy, isObject, fields, Type.createEmptyInstance, as keys of an
// ObjectMap, and many of them under collections. First the program that
// showed the bug: a date was a native handle, printed as "Native", its class
// null (Type.getClassName then a null access). The output is the
// reference's (--interp) but for the lines marked. Dates are made from
// local fields and printed in local time: the same in every time zone.
enum Wrap {
	W(d:Date);
	Pair(a:Date, n:Int);
}

class DateValues {
	static function main() {
		var d = new Date(2026, 9, 20, 16, 22, 24);
		trace(d);
		Sys.println(Std.string(d));
		Sys.println(Type.getClass(d) == Date);
		Sys.println(Type.getClassName(Type.getClass(d)));
		var now = Date.now();
		Sys.println(Std.string(now).length + " " + (Type.getClass(now) == Date) + " " + Type.getClassName(Type.getClass(now)));

		var d2 = new Date(2026, 9, 20, 16, 22, 24);
		var e = new Date(1999, 11, 31, 23, 59, 59);
		var dy:Dynamic = d, dy2:Dynamic = d2;
		// ---- printing
		Sys.println("" + d);
		Sys.println(d + "!");
		Sys.println("at " + dy);
		var b = new StringBuf();
		b.add(d);
		b.add(" ");
		b.add(e);
		Sys.println(b.toString());
		Sys.println([d, e]);
		var any:Array<Dynamic> = [d, 1, "s", e, null];
		Sys.println(any);
		// (a structure as hxmc writes it; Eval: {date: 2026-10-20 16:22:24})
		Sys.println({date: d});
		Sys.println(W(d));
		Sys.println(Pair(e, 3));
		Sys.println(haxe.ds.Option.Some(d));
		Sys.println(Date.fromString("2001-09-09 01:46:40"));
		Sys.println(Date.fromTime(d.getTime()));
		Sys.println(Std.string(Date.fromString("1999-12-31")));

		// ---- the class
		Sys.println(Type.getClassName(Date));
		// (a class as hxmc prints it; Eval: Class<Date>)
		Sys.println(Std.string(Date));
		Sys.println(Type.resolveClass("Date") == Date);
		// (TClass(Date): its class printed as hxmc does; Eval: TClass(Class<Date>))
		Sys.println(Type.typeof(d));
		switch Type.typeof(dy) {
			case TClass(c): Sys.println("class " + Type.getClassName(c) + " " + (c == Date));
			case t: Sys.println("other " + t);
		}
		Sys.println(Std.isOfType(dy, Date) + " " + Std.isOfType("x", Date) + " " + Std.isOfType(1, Date) + " " + Std.isOfType({}, Date) + " "
			+ Std.isOfType(null, Date));
		Sys.println(Std.isOfType(dy, String) + " " + Std.isOfType(dy, Dynamic) + " " + Std.isOfType(dy, Array) + " " + Std.isOfType(dy, Wrap));
		var cl:Dynamic = Date;
		Sys.println(Std.isOfType(dy, cl) + " " + Std.isOfType("x", cl));
		Sys.println(Std.isOfType(Date, Class) + " " + Std.isOfType(Date, Enum));
		Sys.println(Std.downcast((d : {}), Date) == d);
		Sys.println(Std.downcast(("x" : {}), Date));
		var asDate:Date = cast dy;
		Sys.println(asDate.getFullYear() + " " + asDate.getMonth() + " " + asDate.getDate());
		Sys.println(cast(dy, Date) == d);
		try {
			var x:Dynamic = "s";
			Sys.println(cast(x, Date));
		} catch (ex:Dynamic)
			Sys.println("caught " + ex);
		try {
			throw d;
		} catch (s:String) {
			Sys.println("caught a string " + s);
		} catch (x:Date) {
			Sys.println("caught a date " + x);
		}
		Sys.println(any.map(x -> Std.isOfType(x, Date)));

		// ---- equality and order
		Sys.println((d == d2) + " " + (d == d) + " " + (dy == dy2) + " " + (dy == dy));
		Sys.println(Reflect.compare(d, d) + " " + Reflect.compare(e, d) + " " + Reflect.compare(d, d2));
		// (hxmc orders dates by time, as JavaScript's `a == b ? 0 : a > b ? 1 : -1`;
		// Eval compares them as any instances: -1 but for the same one)
		Sys.println(Reflect.compare(d, e));
		var later:Dynamic = new Date(2030, 0, 1, 0, 0, 0);
		// (by time; Eval: false, the order undefined)
		Sys.println(dy < later);
		var arr = [new Date(2001, 0, 1, 0, 0, 0), d, new Date(1990, 5, 5, 5, 5, 5), e];
		arr.sort(Reflect.compare);
		// (in order; Eval, the order undefined: [2026-10-20 16:22:24,1990-06-05 05:05:05,1999-12-31 23:59:59,2001-01-01 00:00:00])
		Sys.println(arr);

		// ---- serialization
		var s = haxe.Serializer.run(d);
		Sys.println(s.charAt(0));
		var u:Date = haxe.Unserializer.run(s);
		Sys.println(u.toString() + " " + (u.getTime() == d.getTime()) + " " + Std.isOfType(u, Date) + " " + (Type.getClass(u) == Date));
		var u2:Dynamic = haxe.Unserializer.run(haxe.Serializer.run([W(d), Pair(e, 2)]));
		Sys.println(u2);
		var u3:Dynamic = haxe.Unserializer.run(haxe.Serializer.run({a: [d, e], b: d}));
		Sys.println(u3.a[0] + " " + u3.a[1] + " " + u3.b + " " + (u3.a[0] == u3.b));
		Sys.println(haxe.Json.stringify({d: d}));
		Sys.println(haxe.Json.stringify([d, e]));
		Sys.println(haxe.Json.stringify({n: 1, list: [{at: e}]}));
		Sys.println(haxe.Json.parse(haxe.Json.stringify({d: d})).d);

		// ---- reflection
		Sys.println(Reflect.isObject(d) + " " + Reflect.fields(d));
		var c:Date = Reflect.copy(d);
		Sys.println((c == d) + " " + c + " " + Std.isOfType(c, Date));
		var empty = Type.createEmptyInstance(Date);
		Sys.println(empty.getTime() + " " + Std.isOfType(empty, Date));
		var m = new haxe.ds.ObjectMap<Date, Int>();
		m.set(d, 1);
		m.set(e, 2);
		Sys.println(m.get(d) + " " + m.get(e) + " " + m.exists(d2));

		// ---- many, under collections (a 64 KB nursery: the corpus')
		var kept = [];
		var total = 0.0;
		for (i in 0...20000) {
			var x = new Date(2000 + i % 30, i % 12, 1 + i % 28, i % 24, i % 60, i % 60);
			var w:Dynamic = W(x);
			if (i % 2500 == 0) kept.push(w);
			total += x.getMonth();
		}
		Sys.println(total);
		Sys.println(kept);
	}
}
