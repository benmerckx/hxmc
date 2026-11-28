package js;

import js.Syntax;
import js.lib.Object;

// -D hxmc.js.hot: the running program's side of hot reloading (docs/js.md, "Hot reload"). The generator adds it to the
// program (hxmc.es.JsGen); a patch (hxmc.es.Chunk.hotPatch) builds its changes with it and makes them with `apply`; a
// class's constructor asks it whether a patch replaced it (`patched`, `construct`); `$hx.bind` is its `bind`.
@:keep class Hot {
	// the classes whose constructors a patch replaced: the patch's class, whose constructor and fields construct the
	// class's instances now
	static final ctors = new js.lib.Map<Dynamic, Dynamic>();
	// the modules' functions: how a patch sets them, by the module's path (`module`)
	static final modules = new js.lib.Map<String, (String, Dynamic) -> Void>();

	// a patch: its changes made, once all are built (a patch that fails as it is built changes nothing)
	public static function apply(changes:Array<() -> Void>) {
		for (c in changes) c();
	}

	// (a class's constructor, first) whether a patch replaced c's constructor
	public static function patched(c:Dynamic):Bool return ctors.size > 0 && ctors.has(c);

	// an instance of `target` (new.target) as c's constructor would construct it, by the one a patch gave it
	public static function construct(c:Dynamic, args:Dynamic, target:Dynamic):Dynamic return Syntax.code("globalThis.Reflect.construct({0}, {1}, {2})", ctors.get(c), args, target);

	// (a module with functions, as it runs) how a patch sets them
	public static function module(path:String, set:(String, Dynamic) -> Void) modules.set(path, set);

	// a class's change: the methods and statics of `fresh` (the patch's class, extending c's super class, so that `super`
	// in them is c's) on c; o.removed: those deleted ("s:x": a static's); o.superClass, where o has it: c's super class
	// now (null: none); o.ctor: c's instances constructed by fresh's constructor and fields from now on; o.fields: of each
	// field added, a function of its value, for the instances that have none (each its own, once read or written)
	public static function cls(c:Dynamic, fresh:Dynamic, o:Dynamic):() -> Void return () -> {
		if (own(o, "superClass")) {
			var s:Dynamic = o.superClass;
			Object.setPrototypeOf(c, s == null ? Syntax.code("Function.prototype") : s);
			Object.setPrototypeOf(c.prototype, s == null ? Object.prototype : s.prototype);
		}
		copy(c, fresh);
		copy(c.prototype, fresh.prototype);
		if (o.removed != null) for (r in (o.removed : Array<String>)) Syntax.delete(StringTools.startsWith(r, "s:") ? c : c.prototype, r.substr(2));
		if (o.ctor) ctors.set(c, fresh);
		if (o.fields != null) for (k in keys(o.fields)) {
			var init:Dynamic = Syntax.field(o.fields, k);
			Object.defineProperty(c.prototype, k, {
				configurable: true,
				get: function() {
					var self = js.Lib.nativeThis;
					var v = init.call(self);
					set(self, k, v);
					return v;
				},
				set: function(v:Dynamic) set(js.Lib.nativeThis, k, v)
			});
		}
	}

	// an enum's change: its constructors as `declareEnum` takes them (`spec`, ...); those it has replaced, but a
	// constructor without parameters, whose value the program has; those added added
	public static function enumeration(e:Dynamic, spec:Dynamic, ?meta:Dynamic, ?names:Array<String>):() -> Void {
		var fresh:Dynamic = Hx.declareEnum(spec, meta, names);
		return () -> {
			for (n in Object.keys(spec)) {
				var c:Dynamic = Syntax.field(fresh, n), ctor = Syntax.typeof(c) == "function";
				Hx.set(ctor ? c.prototype : Object.getPrototypeOf(c), Hx.enumOf, e);
				if (ctor || !own(e, n)) Hx.set(e, n, c);
			}
			Hx.set(e, Hx.constructs, Hx.get(fresh, Hx.constructs));
		}
	}

	// an abstract's implementation's change: the functions of `fresh` on it, those removed deleted
	public static function object(a:Dynamic, fresh:Dynamic, removed:Array<String>):() -> Void return () -> {
		copy(a, fresh);
		for (r in removed) Syntax.delete(a, r);
	}

	// a module's functions' change, by their names (none where the program has not loaded the module yet: it will load
	// it as it is now)
	public static function functions(path:String, fns:Dynamic):() -> Void return () -> {
		var set = modules.get(path);
		if (set != null) for (n in Object.keys(fns)) set(n, Syntax.field(fns, n));
	}

	// a method as a value (`$hx.bind`): the method of its name the object's prototypes have when it is called, which a
	// patch may have replaced since; one function each time, before a patch and after (an object's own function, a
	// dynamic method assigned to it: as it is now)
	public static function bind(o:Dynamic, name:String):Dynamic {
		var m:Dynamic = Syntax.field(o, name);
		if (m == null) return null;
		if (Syntax.typeof(o) != "object" && Syntax.typeof(o) != "function") return m.bind(o);
		var mine = own(o, name);
		var key:Dynamic = mine ? m : name;
		var cache:js.lib.Map<Dynamic, Dynamic> = own(o, Hx.closures) ? Hx.get(o, Hx.closures) : {
			var c = new js.lib.Map();
			Hx.set(o, Hx.closures, c);
			c;
		}
		var f = cache.get(key);
		if (f == null) cache.set(key, f = mine ? m.bind(o) : Reflect.makeVarArgs(a -> Syntax.field(Object.getPrototypeOf(o), name).apply(o, a)));
		return f;
	}

	// (a class's own members, not a function's: `name`, `length`, `prototype` are values not writable, which no member
	// is; a prototype's `constructor`)
	static function copy(to:Dynamic, from:Dynamic) {
		for (k in keys(from)) {
			var d:Dynamic = Object.getOwnPropertyDescriptor(from, k);
			if (k != "constructor" && (d.writable || d.get != null || d.set != null)) Object.defineProperty(to, k, d);
		}
	}

	// (symbols too; the global Reflect: js.lib.Reflect is Haxe's where the program has it, as Genjs has it)
	static inline function keys(o:Dynamic):Array<Dynamic> return Syntax.code("globalThis.Reflect.ownKeys({0})", o);

	static inline function own(o:Dynamic, k:Dynamic):Bool return Object.prototype.hasOwnProperty.call(o, k);

	static function set(o:Dynamic, k:Dynamic, v:Dynamic) {
		Object.defineProperty(o, k, {value: v, writable: true, enumerable: true, configurable: true});
	}
}
