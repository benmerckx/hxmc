package hxmc.es;

import core.Globals;
import core.TType;
import core.TFunctions.*;
import generators.Genjs;

using StringTools;

// TypeScript declarations of a module's file, for the modules output (-D hxmc.js=modules
// -D dts): `pack/Module.d.ts` beside `pack/Module.js`, declaring what the file exports, by
// the generated names (`pack_A`) and by the types' own (`A`). Types are TypeScript's view of
// Haxe's: numbers, strings, booleans, arrays, functions, structures, `T | null` for Null<T>,
// the program's classes and enums by their declarations; typedefs and abstracts are what they
// stand for; externs and what has no TypeScript counterpart is `any`.
class Dts {
	// (hxmc.es.Ts) a structure's property as its accessor methods: the thread's (printers run in parallel)
	public static var accessors(get, set):Bool;

	static final accessorsOf = new sys.thread.Tls<Bool>();

	static function get_accessors():Bool return accessorsOf.value == true;

	static function set_accessors(v:Bool):Bool return accessorsOf.value = v;

	// the declarations of a module's types; ref: the name a type's code is reachable by in the
	// file (null: none, `any`), noting the import it needs
	public static function module(types:Array<ModuleType>, ref:ModuleType->Null<String>):String {
		var b = new StringBuf();
		for (t in types) switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern) && !c.clKind.match(KModuleFields(_) | KAbstractImpl(_))):
				classDecl(b, c, ref);
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):
				enumDecl(b, e, ref);
			case _:
		}
		return b.toString();
	}

	// an enum: a class per constructor (`E$C`, declared only: the runtime's are unnamed), the enum's
	// type their union, discriminated by `_hx_name` and `_hx_index`, and its value the root with the constructors
	// as statics. A constructor's own type parameters (GADT) are its class's, `any` in the union.
	static function enumDecl(b:StringBuf, e:TEnum, ref:ModuleType->Null<String>) {
		var n = ref(TEnumDecl(e));
		if (n == null) return;
		var t = enumTypes(e, n, ref);
		b.add(t.decls);
		b.add("export declare const " + n + ": " + t.value + ";\n");
	}

	// an enum's (named n) declarations (its constructors' classes, its type) and its value's type
	public static function enumTypes(e:TEnum, n:String, ref:ModuleType->Null<String>):{decls:String, value:String} {
		var b = new StringBuf();
		var names = [for (c in e.eConstrs.names()) c];
		names.sort((a, b) -> e.eConstrs.find(a).efIndex - e.eConstrs.find(b).efIndex);
		var own = [for (p in e.eParams) p.ttpName];
		var union = [], statics = [];
		for (c in names) {
			var f = e.eConstrs.find(c);
			// (a constructor's parameter of an enum's name is the enum's)
			var extra = [for (p in f.efParams) if (!own.contains(p.ttpName)) p.ttpName];
			var params = own.concat(extra);
			var scope = params;
			var tp = params.length == 0 ? "" : "<" + params.join(", ") + ">";
			var cls = n + "$" + c;
			b.add("declare abstract class " + cls + tp + " extends EnumValue {\n\treadonly _hx_name: \"" + c + "\";\n\treadonly _hx_index: " + f.efIndex + ";\n");
			// (the type arguments, which TypeScript compares only where a member uses them: declared, never set)
			if (params.length > 0) b.add("\treadonly _hx_type?: [" + params.join(", ") + "];\n");
			var sig = switch follow(f.efType) {
				case TFun(s):
					for (a in s.args) b.add("\treadonly " + Genjs.ident(a.name) + ": " + type(a.type, ref, scope) + ";\n");
					s;
				case _: null;
			}
			b.add("}\n");
			union.push(cls + (params.length == 0 ? "" : "<" + own.concat([for (_ in extra) "any"]).join(", ") + ">"));
			statics.push("\treadonly " + c + ": " + if (sig == null) cls + (params.length == 0 ? "" : "<" + [for (_ in params) "any"].join(", ") + ">") + ";" else {
				// (the enum's arguments of the type it makes: a GADT's own, `Expr<Int>`)
				var made = switch follow(sig.ret) {
					case TEnum(_, ps) if (ps.length == own.length && params.length > 0): "<" + [for (p in ps) type(p, ref, scope)].concat(extra).join(", ") + ">";
					case _: tp;
				}
				var a = "(" + args(sig, ref, scope) + "): " + cls + made;
				"{ " + tp + a + "; new " + tp + a + "; readonly prototype: " + cls + (params.length == 0 ? "" : "<" + [for (_ in params) "any"].join(", ") + ">") + " };";
			});
		}
		var tp = own.length == 0 ? "" : "<" + own.join(", ") + ">";
		b.add("export declare type " + n + tp + " = " + (union.length == 0 ? "never" : union.join(" | ")) + ";\n");
		return {decls: b.toString(), value: "(abstract new () => EnumValue) & {\n\treadonly __ename__: string;\n\treadonly __constructs__: string[];\n" + statics.join("\n") + "\n}"};
	}

	// _hx.d.ts: the runtime's enum types (Enums)
	public static final RUNTIME = "export declare abstract class EnumValue {
	readonly _hx_index: number;
	readonly _hx_name: string;
	__params__(): unknown[];
}
";

	// head: before `class` (`export declare `, `declare `, `` in a namespace); name: the declared name (else ref's)
	// (props: the properties JavaScript has as accessors, which it declares as properties, not their accessor methods)
	public static function classDecl(b:StringBuf, c:TClass, ref:ModuleType->Null<String>, head = "export declare ", ?name:String, indent = "",
			?skip:String->Bool, ?props:Properties, inherit = false) {
		var n = name != null ? name : ref(TClassDecl(c));
		if (n == null) return;
		var isExtern = hasClassFlag(c, CExtern);
		var scope = [for (p in c.clParams) p.ttpName];
		var params = typeParams(c.clParams, ref, scope);
		var iface = hasClassFlag(c, CInterface);
		b.add(indent + head + (iface ? "interface " : "class ") + n + params);
		var sup = c.clSuper != null ? ref(TClassDecl(c.clSuper.cls)) : null;
		if (sup != null) b.add(" extends " + sup + typeArgs(c.clSuper.params, ref, scope));
		// (inherit: an ancestor of no name here, the program's own: its members the class's; an extern's are not declared)
		var inherited:Array<TClassField> = [];
		if (sup == null && inherit && !isExtern) {
			var s = c.clSuper;
			while (s != null && ref(TClassDecl(s.cls)) == null && !hasClassFlag(s.cls, CExtern)) {
				for (f in s.cls.clFields) if (!c.clFields.exists(f.cfName) && !Lambda.exists(inherited, x -> x.cfName == f.cfName)) inherited.push(f);
				s = s.cls.clSuper;
			}
		}
		var impls = [for (i in c.clImplements) {
			var r = ref(TClassDecl(i.cls));
			if (r != null) r + typeArgs(i.params, ref, scope);
		}];
		// (a class implements its interfaces as Haxe checks them; TypeScript's checks differ, as for
		// properties: interfaces extend theirs only)
		if (impls.length > 0 && iface) b.add((sup != null ? ", " : " extends ") + impls.join(", "));
		b.add(" {\n");
		if (c.clConstructor != null && !iface) for (f in [c.clConstructor].concat(c.clConstructor.cfOverloads)) switch follow(f.cfType) {
			case TFun(s): b.add(indent + "\tconstructor(" + args(s, ref, scope) + ");\n");
			case _:
		}
		for (f in c.clFields) member(b, f, false, ref, scope, isExtern, indent, props);
		for (f in inherited) member(b, f, false, ref, scope, false, indent, props);
		if (!iface) for (f in c.clStatics) if (skip == null || !skip(f.cfName)) member(b, f, true, ref, scope, isExtern, indent, props);
		b.add(indent + "}\n");
	}

	// (an extern's: by its native name, with its overloads, but its inline methods, which JavaScript has not)
	static function member(b:StringBuf, f:TClassField, isStatic:Bool, ref:ModuleType->Null<String>, scope:Array<String>, isExtern = false,
			indent = "", ?props:Properties) {
		if (!hasClassFieldFlag(f, CfPublic) && !isExtern) return;
		// (the program's property: a JS accessor, its name's, or its accessor methods, and its storage, if it has one)
		if (!isExtern && f.cfKind.match(Var(_)) && Properties.isProperty(f) && (props == null || props.unchanged(f)) && !isPhysicalField(f)) return;
		if (!isExtern && props != null) switch props.familyOf(f) {
			case null:
			case fam if (!fam.keeps(fam.isGetter(f))): return;
			case _:
		}
		if (isExtern && f.cfKind.match(Method(MethInline) | Var({vRead: AccInline}))) return;
		var n = f.cfName;
		if (isExtern) try n = core.Native.getNativeName(f.cfMeta).name catch (_:core.ds.NotFound) {}
		var name = Genjs.validJsIdent(n) ? n : "\"" + n + "\"";
		var fields = isExtern ? [f].concat(f.cfOverloads) : [f];
		for (f in fields) {
			var scope = scope.concat([for (p in f.cfParams) p.ttpName]);
			b.add(indent + "\t" + (isStatic ? "static " : ""));
			switch [f.cfKind, follow(f.cfType)] {
				case [Method(_), TFun(s)]:
					b.add(name + typeParams(f.cfParams, ref, scope) + "(" + args(s, ref, scope) + "): " + type(s.ret, ref, scope) + ";\n");
				// (one written only in the class, its constructor, or not at all: `final`, `(get, never)`, `(default, null)`)
				case [Var({vWrite: AccNever | AccNo | AccCtor | AccInline}), _]:
					b.add("readonly " + name + ": " + type(f.cfType, ref, scope) + ";\n");
				case _:
					b.add(name + ": " + type(f.cfType, ref, scope) + ";\n");
			}
		}
	}

	// (with their constraints: `T extends A & B`)
	public static function typeParams(ps:TypeParams, ref:ModuleType->Null<String>, scope:Array<String>):String
		return ps.length == 0 ? "" : "<" + [for (p in ps) p.ttpName + switch getConstraints(p) {
			case c if (c.length == 0): "";
			case c: " extends " + [for (t in c) type(t, ref, scope)].join(" & ");
		}].join(", ") + ">";

	public static function typeArgs(ps:TParams, ref, scope):String return ps.length == 0 ? "" : "<" + [for (p in ps) type(p, ref, scope)].join(", ") + ">";

	// (TypeScript's rules: distinct names, nothing required after an optional one)
	public static function args(s:TSignature, ref, scope, depth = 0):String {
		var out = [], seen = new Map<String, Bool>(), optional = false;
		for (i in 0...s.args.length) {
			var a = s.args[i], n = safeName(a.name);
			if (seen.exists(n)) n += i;
			seen.set(n, true);
			optional = optional || a.optional;
			// (the last a `haxe.Rest<T>`: the rest of the arguments)
			var rest = i == s.args.length - 1 ? switch follow(a.type) {
				case TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [p]): p;
				case _: null;
			} : null;
			out.push(rest != null ? "..." + n + ": Array<" + type(rest, ref, scope, depth) + ">" : n + (optional ? "?" : "") + ": " + type(a.type, ref, scope, depth));
		}
		return out.join(", ");
	}

	static function safeName(n:String):String return n == "" || Genjs.isKeyword(n) || hxmc.es.Es.EsTools.RESERVED.exists(n) || !Genjs.validJsIdent(n) ? "_" + n.replace("$", "_") : n;

	public static function type(t:T, ref:ModuleType->Null<String>, scope:Array<String>, depth = 0):String {
		if (depth > 20) return "any";
		inline function sub(t) return type(t, ref, scope, depth + 1);
		return switch t {
			// (one bound to a structure: of the fields untyped code reads, no type)
			case TMono(m): m.tmType == null || follow(m.tmType).match(TAnon(_)) ? "any" : sub(m.tmType);
			case TLazy(l): sub(lazyType(l));
			case TDynamic(_): "any";
			// (what the code iterates with $getIterator: an array too)
			case TType({tPath: {pack: [], name: "Iterable"}}, [p]): "(" + sub(follow(t)) + " | Array<" + sub(p) + ">)";
			case TType(_, _): sub(follow(t));
			case TFun(s): "(" + args(s, ref, scope, depth + 1) + ") => " + sub(s.ret);
			// (`{}`: an object of any fields, as Haxe has it)
			case TAnon(a) if (a.aFields.isEmpty()): "any";
			// (a class itself, an abstract's implementation: its constructor)
			case TAnon({aStatus: ClassStatics(c) | AbstractStatics({aImpl: c})}) if (c != null):
				var r = ref(TClassDecl(c));
				r == null ? "any" : "typeof " + r;
			case TAnon({aStatus: EnumStatics(_) | AbstractStatics(_)}): "any";
			case TAnon(a):
				// (a field without a name: any other name, tink_hxx's `data-*`; a property, where `accessors`: its accessor
				// methods, which the code calls)
				var out = [];
				for (f in a.aFields) {
					if (f.cfName == "") {
						out.push("[key: string]: any");
						continue;
					}
					var n = Genjs.validJsIdent(f.cfName) ? f.cfName : "\"" + f.cfName + "\"";
					var opt = core.Meta.has(core.Meta.Optional, f.cfMeta) ? "?" : "";
					switch f.cfKind {
						case Var(v) if (accessors && (v.vRead.match(AccCall) || v.vWrite.match(AccCall))):
							if (v.vRead.match(AccCall)) out.push("get_" + f.cfName + opt + "(): " + sub(f.cfType));
							if (v.vWrite.match(AccCall)) out.push("set_" + f.cfName + opt + "(v: " + sub(f.cfType) + "): " + sub(f.cfType));
							if (!v.vRead.match(AccCall | AccNever | AccNo) || core.Meta.has(core.Meta.IsVar, f.cfMeta)) out.push(n + opt + ": " + sub(f.cfType));
						case _:
							out.push(n + opt + ": " + sub(f.cfType));
					}
				}
				"{" + out.join(", ") + "}";
			case TAbstract({aPath: {pack: [], name: "Int" | "Float" | "UInt"}}, _): "number";
			case TAbstract({aPath: {pack: [], name: "Bool"}}, _): "boolean";
			case TAbstract({aPath: {pack: [], name: "Void"}}, _): "void";
			case TAbstract({aPath: {pack: [], name: "Null"}}, [p]):
				// (a function type in parentheses: its return type would take the `| null`)
				var s = sub(p);
				(follow(p).match(TFun(_)) ? "(" + s + ")" : s) + " | null";
			// (the runtime's, where ref names it)
			case TAbstract(a = {aPath: {pack: [], name: "EnumValue"}}, _): ref(TAbstractDecl(a)) ?? "EnumValue";
			case TAbstract(a, params):
				// (what it stands for, where that names no type parameter of its own)
				a.aParams.length == 0 && !hasCoreMeta(a) ? sub(a.aThis) : "any";
			case TInst({clKind: KTypeParameter(p)}, _): scope.contains(p.ttpName) ? p.ttpName : "any";
			case TInst({clPath: {pack: [], name: "String"}}, _): "string";
			case TInst({clPath: {pack: [], name: "Array"}}, [p]): "Array<" + sub(p) + ">";
			case TInst({clPath: {pack: [], name: "Date"}}, _): "Date";
			case TInst({clPath: {pack: ["js", "lib"], name: "Promise"}}, [p]): "Promise<" + sub(p) + ">";
			case TInst(c, params):
				var r = ref(TClassDecl(c));
				r == null ? "any" : r + (params.length == 0 ? "" : "<" + [for (p in params) sub(p)].join(", ") + ">");
			case TEnum(e, params):
				var r = ref(TEnumDecl(e));
				r == null ? "any" : r + (params.length == 0 ? "" : "<" + [for (p in params) sub(p)].join(", ") + ">");
		}
	}

	static function hasCoreMeta(a:TAbstract):Bool return core.Meta.has(core.Meta.CoreType, a.aMeta);
}
