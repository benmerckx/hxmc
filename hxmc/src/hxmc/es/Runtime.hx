package hxmc.es;

using StringTools;

// The runtime: `$hx`, an object of the symbols reflection's data is under, and of the helpers the generated code
// calls, written as source, with only what the program uses. A part names others it needs (`needs`); `{Boot}`
// in a part's code is a type's binding (Chunk).
class Runtime {
	public static final PARTS:Array<{name:String, needs:Array<String>, code:String}> = [
		// symbols (Symbol.for: two programs on one page share them)
		{name: "name", needs: [], code: 'name: Symbol.for("haxe.name")'},
		{name: "interfaces", needs: [], code: 'interfaces: Symbol.for("haxe.interfaces")'},
		{name: "properties", needs: [], code: 'properties: Symbol.for("haxe.properties")'},
		{name: "staticProperties", needs: [], code: 'staticProperties: Symbol.for("haxe.staticProperties")'},
		{name: "isInterface", needs: [], code: 'isInterface: Symbol.for("haxe.isInterface")'},
		{name: "fields", needs: [], code: 'fields: Symbol.for("haxe.fields")'},
		{name: "index", needs: [], code: 'index: Symbol.for("haxe.index")'},
		{name: "constructs", needs: [], code: 'constructs: Symbol.for("haxe.constructs")'},
		{name: "enumOf", needs: [], code: 'enumOf: Symbol.for("haxe.enum")'},
		{name: "closures", needs: [], code: 'closures: Symbol.for("haxe.closures")'},
		// registries (Type.resolveClass, Type.resolveEnum), @:expose's
		{name: "classes", needs: [], code: "classes: {}"},
		{name: "enums", needs: [], code: "enums: {}"},
		// the values of the core types Std.isOfType takes
		{name: "Int", needs: [], code: "Int: {}"},
		{name: "Dynamic", needs: [], code: "Dynamic: {}"},
		{name: "Float", needs: [], code: "Float: Number"},
		{name: "Bool", needs: [], code: "Bool: Boolean"},
		{name: "Class", needs: [], code: "Class: {}"},
		{name: "Enum", needs: [], code: "Enum: {}"},
		// a method as a value, the same function each time for the same object and method
		{
			name: "bind",
			needs: ["closures"],
			code: "bind(o, name) {
	const m = o[name];
	if (m == null) return null;
	if (typeof o != \"object\" && typeof o != \"function\") return m.bind(o);
	const cache = Object.hasOwn(o, $hx.closures) ? o[$hx.closures] : (o[$hx.closures] = new Map());
	let f = cache.get(m);
	if (f === undefined) cache.set(m, f = m.bind(o));
	return f;
}"
		},
		{
			name: "arrayIterator",
			needs: [],
			code: "arrayIterator(a) {
	let i = 0;
	return { hasNext: () => i < a.length, next: () => a[i++] };
}"
		},
		{
			name: "arrayKeyValueIterator",
			needs: [],
			code: "arrayKeyValueIterator(a) {
	let i = 0;
	return { hasNext: () => i < a.length, next: () => ({ key: i, value: a[i++] }) };
}"
		},
		// `.iterator` and `.iterator()` of what may be an Array
		{
			name: "iterator",
			needs: ["arrayIterator", "bind"],
			code: "iterator(o) {
	if (Array.isArray(o)) return () => $hx.arrayIterator(o);
	return typeof o.iterator == \"function\" ? $hx.bind(o, \"iterator\") : o.iterator;
}"
		},
		{
			name: "keyValueIterator",
			needs: ["arrayKeyValueIterator", "bind"],
			code: "keyValueIterator(o) {
	if (Array.isArray(o)) return () => $hx.arrayKeyValueIterator(o);
	return typeof o.keyValueIterator == \"function\" ? $hx.bind(o, \"keyValueIterator\") : o.keyValueIterator;
}"
		},
		{
			name: "getIterator",
			needs: ["arrayIterator"],
			code: "getIterator(o) {
	return Array.isArray(o) ? $hx.arrayIterator(o) : o.iterator();
}"
		},
		{
			name: "getKeyValueIterator",
			needs: ["arrayKeyValueIterator"],
			code: "getKeyValueIterator(o) {
	return Array.isArray(o) ? $hx.arrayKeyValueIterator(o) : o.keyValueIterator();
}"
		},
		// the base of every enum's values
		{
			name: "EnumValue",
			needs: [],
			code: "EnumValue: class EnumValue {}"
		},
		// an enum: its constructors by name, in their order (`spec`: a function each, which `new` constructs, `null` for a
		// value of none of arguments; its path under $hx.name, where the program reads it): their indexes, their enum on their
		// prototypes; its path, its list of them, its @:meta
		{
			name: "declareEnum",
			needs: ["index", "constructs", "enumOf", "EnumValue"],
			code: "declareEnum(spec, meta, names) {
	const e = {};
	Object.keys(spec).forEach((n, i) => {
		let f = spec[n];
		const nullary = f == null;
		if (nullary) f = { [n]: function () {} }[n];
		f.prototype = Object.create($hx.EnumValue.prototype, { constructor: { value: f, writable: true, configurable: true } });
		f.prototype[$hx.index] = i;
		f.prototype[$hx.enumOf] = e;
		e[n] = nullary ? new f() : f;
	});
	e[$hx.constructs] = names ?? Object.keys(spec);
	Object.defineProperty(e, Symbol.hasInstance, { value: (o) => o != null && o[$hx.enumOf] === e });
	if (Object.hasOwn(spec, $hx.name)) e[$hx.name] = spec[$hx.name];
	if (meta != null) e.__meta__ = meta;
	return e;
}"
		},
		// an interface's value, which `instanceof` checks (its implementations list it: $hx.interfaces)
		{
			name: "interface",
			needs: ["name", "interfaces", "isInterface", "fields"],
			code: "interface(name, supers, fields) {
	const i = { [$hx.name]: name, [$hx.isInterface]: true };
	if (fields) i[$hx.fields] = fields;
	if (supers) Object.defineProperty(i, $hx.interfaces, { get: supers });
	const has = (c) => {
		for (; c != null && c !== Function.prototype; c = Object.getPrototypeOf(c)) {
			if (c === i) return true;
			if (Object.hasOwn(c, $hx.interfaces)) for (const s of c[$hx.interfaces]) if (s === i || has(s)) return true;
		}
		return false;
	};
	Object.defineProperty(i, Symbol.hasInstance, { value: (o) => o != null && has(o.constructor) });
	return i;
}"
		},
		// the splits' files: the bindings they take (`scope`), their files by name, where they are, those loaded
		{name: "scope", needs: [], code: "scope: {}"},
		{name: "files", needs: [], code: "files: {}"},
		{name: "base", needs: [], code: "base: null"},
		{name: "loaded", needs: [], code: "loaded: {}"},
		// a split's file, loaded once (js.Bundle.import, relative to js.Bundle.base or the main file): its initializers
		{
			name: "load",
			needs: ["scope", "files", "base", "loaded"],
			code: "load(name) {
	const url = new URL($hx.files[name] + \".js\", {js.Bundle}.base ?? $hx.base).href;
	return {js.Bundle}.import(url).then((m) => $hx.loaded[name] ??= m.default($hx));
}"
		},
		// (modules) the types the runtime names, which their modules register
		{name: "types", needs: [], code: "types: {}"},
		// (modules) a split's file, loaded once (js.Bundle.import, relative to js.Bundle.base or this file): its initializers
		{
			name: "loadModule",
			needs: ["files", "loaded"],
			code: "load(name) {
	const url = new URL($hx.files[name] + \".js\", {js.Bundle}.base ?? import.meta.url).href;
	return {js.Bundle}.import(url).then((m) => $hx.loaded[name] ??= m.default);
}"
		},
		// @:expose: a path under the global object
		{
			name: "expose",
			needs: [],
			code: "expose(path, value) {
	const parts = path.split(\".\"), last = parts.pop();
	let o = globalThis;
	for (const p of parts) o = o[p] ??= {};
	o[last] = value;
}"
		},
	];

	// (TypeScript) the runtime's type: its symbols unique (a class's computed keys), the base of enums' values (exported:
	// the files that name it import it), `declareEnum`'s; the rest `any`
	public static final TS = "declare namespace Hx {
" + [
		for (s in ["name", "interfaces", "properties", "staticProperties", "isInterface", "fields", "index", "constructs", "enumOf", "closures"])
			"\tconst " + s + ": unique symbol;\n"
	].join("") + "	interface EnumValue {
		readonly [index]: number;
		readonly [enumOf]: object;
	}
	const EnumValue: abstract new () => EnumValue;
	type EnumInit<S> = S extends abstract new (...a: infer A) => any ? (this: any, ...a: A) => void : null;
	type EnumOf<D> = { [K in keyof D]: D[K] extends abstract new (...a: any) => infer R ? R : D[K] }[keyof D];
	function declareEnum<D>(spec: { [K in keyof D]: EnumInit<D[K]> } & { [name]?: string }, meta?: any, names?: string[]): D & { [Symbol.hasInstance](v: unknown): v is EnumOf<D> };
}
export type EnumValue = Hx.EnumValue;
";

	// what `uses` needs, with what those need
	public static function closure(uses:Map<String, Bool>):Map<String, Bool> {
		var out = new Map<String, Bool>();
		function add(n:String) {
			if (out.exists(n)) return;
			var p = Lambda.find(PARTS, x -> x.name == n);
			if (p == null) return;
			out.set(n, true);
			for (d in p.needs) add(d);
		}
		for (k in uses.keys()) add(k);
		return out;
	}

	// `const $hx = { ... };` with the parts used; `type` resolves `{Name}`; `values`: a part's value, where the output has it
	// (the splits' files, where they are)
	public static function source(uses:Map<String, Bool>, type:String->String, ?values:Map<String, String>):String {
		var all = closure(uses);
		inline function code(p:{name:String, code:String}) return values != null && values.exists(p.name) ? p.name + ": " + values.get(p.name) : p.code;
		var parts = [for (p in PARTS) if (all.exists(p.name)) "\t" + code(p).split("\n").join("\n\t")];
		if (parts.length == 0) return "";
		var code = "const $hx = {\n" + parts.join(",\n") + "\n};\n";
		return ~/\{([A-Za-z_][A-Za-z0-9_.]*)\}/g.map(code, r -> {
			var t = type(r.matched(1));
			t == null ? r.matched(0) : t;
		});
	}
}
