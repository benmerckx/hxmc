package hxmc.es;

import core.TType;
import core.TFunctions.*;
import hxmc.es.Es.EsTools;

// TypeScript's types as the printer writes them (Printer.types): Haxe's types in TypeScript's syntax (Dts's
// mapping), a type's name as link has it in the file (`ref`, which notes the import it needs; null: `any`), the
// type parameters in scope.
interface Types {
	var scope:Array<String>;
	function type(t:T):String;
	// `<T extends C>`
	function params(ps:TypeParams):String;
	// a function type's `(a: A, b?: B): R`
	function signature(t:T):String;
	function interfaceDecl(c:TClass, name:String, indent:String):String;
	// an enum's declaration (`$hx.declareEnum`'s type argument: its constructors, as Haxe declares them), and what follows the
	// value: its type (the union of its constructors'), its constructors' types (what a match on `x[index]` narrows to)
	function enumTypes(en:TEnum, name:String, index:String, indent:String, exported:Bool):{decl:String, after:String};
}

class Ts implements Types {
	final ref:ModuleType->Null<String>;
	// Haxe's `EnumValue`'s name (the runtime's, imported)
	final enumValue:Void->String;
	// (the properties JavaScript has as accessors: an interface declares them, not their accessor methods)
	final props:Null<Properties>;

	public var scope:Array<String> = [];

	public function new(ref, enumValue, ?props) {
		this.ref = ref;
		this.enumValue = enumValue;
		this.props = props;
	}

	// (a structure's property: its accessor methods, as the code reads it)
	function dts(f:Void->String):String {
		Dts.accessors = true;
		var s = try f() catch (e:haxe.Exception) {
			Dts.accessors = false;
			throw e;
		}
		Dts.accessors = false;
		return s;
	}

	public function type(t:T):String return dts(() -> Dts.type(t, ref, scope));

	public function params(ps:TypeParams):String return dts(() -> Dts.typeParams(ps, ref, scope));

	public function signature(t:T):String return switch follow(t) {
		case TFun(s): dts(() -> "(" + Dts.args(s, ref, scope) + "): " + Dts.type(s.ret, ref, scope));
		case _: "(...args: any[]): any";
	}

	// its members, those of the interfaces it extends theirs (TypeScript's `extends`)
	public function interfaceDecl(c:TClass, name:String, indent:String):String {
		var b = new StringBuf();
		var own = [for (p in c.clParams) p.ttpName];
		var outer = scope;
		scope = outer.concat(own);
		b.add("interface " + name + params(c.clParams));
		var supers = [for (i in c.clImplements) {
			var r = ref(TClassDecl(i.cls));
			if (r != null) r + Dts.typeArgs(i.params, ref, scope);
		}];
		if (supers.length > 0) b.add(" extends " + supers.join(", "));
		b.add(" {\n");
		for (f in c.clFields) {
			var n = EsTools.validIdent(f.cfName) ? f.cfName : Printer.quote(f.cfName);
			var opt = core.Meta.has(core.Meta.Optional, f.cfMeta) ? "?" : "";
			switch [f.cfKind, follow(f.cfType)] {
				case [Var(_), _]:
					var ro = Properties.readonlyVar(f) || (props != null && props.readonlyProperty(f)) ? "readonly " : "";
					if (isPhysicalField(f) || (props != null && !props.unchanged(f))) b.add(indent + "\t" + ro + n + opt + ": " + type(f.cfType) + ";\n");
				case [Method(_), TFun(_)] if (!jsAccessor(f)):
					var inner = scope;
					scope = inner.concat([for (p in f.cfParams) p.ttpName]);
					b.add(indent + "\t" + n + opt + params(f.cfParams) + signature(f.cfType) + ";\n");
					scope = inner;
				case _:
			}
		}
		b.add(indent + "}");
		scope = outer;
		return b.toString();
	}

	// an accessor method the output has as a JS accessor, which its property declares
	function jsAccessor(f:TClassField):Bool {
		var fam = props == null ? null : props.familyOf(f);
		return fam != null && !fam.keeps(fam.isGetter(f));
	}

	// (docs/plans/esgen-enums.md) A constructor's interface has the enum's type parameters and those of its own the
	// result doesn't fix (`If<T>(…):Expr<T>`: the enum's `T`). A result of other arguments (a GADT's
	// `IntLit(i:Int):Expr<Int>`) is in the union where the enum's arguments match it.
	public function enumTypes(en:TEnum, name:String, index:String, indent:String, exported:Bool):{decl:String, after:String} {
		var outer = scope;
		var eps = en.eParams.toArray();
		var enumNames = [for (p in eps) p.ttpName];
		var names = [for (n in en.eConstrs.names()) n];
		names.sort((a, b) -> en.eConstrs.find(a).efIndex - en.eConstrs.find(b).efIndex);
		function isParam(t:T, p:TypedTypeParam) return switch [t, p.ttpType] {
			case [TInst(a, _), TInst(b, _)]: a == b;
			case _: false;
		}
		function fieldKey(n:String) return EsTools.validIdent(n) ? n : Printer.quote(n);
		var decl = new StringBuf();
		var ifaces = [];
		decl.add("{\n");
		for (n in names) {
			var f = en.eConstrs.find(n);
			var own = f.efParams.toArray();
			var sig = switch follow(f.efType) {
				case TFun(s): s;
				case _: null;
			}
			var ret = sig == null ? f.efType : sig.ret;
			// (the declaration: a nullary constructor's value, the others' construct signatures)
			if (sig == null) {
				scope = outer;
				decl.add(indent + "\treadonly " + fieldKey(n) + ": " + type(ret) + ";\n");
			} else {
				var tps = eps.concat([for (p in own) if (!enumNames.contains(p.ttpName)) p]);
				scope = outer.concat([for (p in tps) p.ttpName]);
				var s = "(" + dts(() -> Dts.args(sig, ref, scope)) + ") => " + type(ret);
				// (but the enum's a GADT's constructor doesn't name)
				tps = [for (p in tps) if (new EReg("\\b" + p.ttpName + "\\b", "").match(s)) p];
				decl.add(indent + "\treadonly " + fieldKey(n) + ": new " + params(haxe.ds.Vector.fromArrayCopy(tps)) + s + ";\n");
			}
			// (its own parameters the result fixes, the enum's arguments it requires)
			var fixedOwn:Array<TypedTypeParam> = [];
			var fixedTo:Array<T> = [];
			var conds:Array<{i:Int, t:T}> = [];
			switch follow(ret) {
				case TEnum(_, args):
					for (i in 0...args.length) {
						if (i >= eps.length) break;
						var a = args[i];
						var o = Lambda.find(own, p -> isParam(a, p));
						if (o != null && !fixedOwn.contains(o)) {
							fixedOwn.push(o);
							fixedTo.push(eps[i].ttpType);
						} else if (!isParam(a, eps[i]))
							conds.push({i: i, t: a});
					}
				case _:
			}
			var rest = [for (p in own) if (!fixedOwn.contains(p) && !enumNames.contains(p.ttpName)) p];
			scope = outer.concat(enumNames).concat([for (p in rest) p.ttpName]);
			function fixed(t:T) return fixedOwn.length == 0 ? t : applyParams(haxe.ds.Vector.fromArrayCopy(fixedOwn), haxe.ds.Vector.fromArrayCopy(fixedTo), t);
			var fields = sig == null ? [] : [for (a in sig.args) {key: fieldKey(a.name), type: type(fixed(a.type))}];
			var tparams = params(haxe.ds.Vector.fromArrayCopy(eps.concat(rest)));
			scope = outer.concat(enumNames);
			var cond = conds.length == 0 ? null : "[" + [for (c in conds) eps[c.i].ttpName].join(", ") + "] extends [" + [for (c in conds) type(c.t)].join(", ") + "]";
			ifaces.push({
				ctor: n,
				index: f.efIndex,
				tparams: tparams,
				fields: fields,
				cond: cond,
				args: eps.length + rest.length == 0 ? "" : "<" + enumNames.concat([for (_ in rest) "any"]).join(", ") + ">"
			});
		}
		decl.add(indent + "}");
		scope = outer;
		// (an interface's name: the constructor's, but where a type its fields name would mean it instead; none: `null`, an
		// empty enum's only value)
		var words = new Map<String, Bool>();
		for (i in ifaces) for (f in i.fields) ~/[A-Za-z_$][A-Za-z0-9_$]*/g.map(f.type, r -> {
			words.set(r.matched(0), true);
			"";
		});
		var base = ifaces.length > 0 ? enumValue() : "";
		words.set(base, true);
		var taken = new Map<String, Bool>();
		var b = new StringBuf();
		var exp = exported ? "export " : "";
		var union = [for (i in ifaces) {
			var n = EsTools.validIdent(i.ctor) && !EsTools.RESERVED.exists(i.ctor) ? i.ctor : "C" + i.index;
			while (words.exists(n) || taken.exists(n) || n == name) n += "$";
			taken.set(n, true);
			i.ctor = n;
			var m = name + "." + n + i.args;
			i.cond == null ? m : "(" + i.cond + " ? " + m + " : never)";
		}];
		b.add(indent + exp + "type " + name + params(en.eParams) + " = " + (union.length == 0 ? "null" : union.join(" | ")) + ";\n");
		if (ifaces.length > 0) {
			b.add(indent + exp + "declare namespace " + name + " {\n");
			for (i in ifaces) {
				b.add(indent + "\tinterface " + i.ctor + i.tparams + " extends " + base + " {\n");
				b.add(indent + "\t\treadonly [" + index + "]: " + i.index + ";\n");
				for (f in i.fields) b.add(indent + "\t\treadonly " + f.key + ": " + f.type + ";\n");
				b.add(indent + "\t}\n");
			}
			b.add(indent + "}\n");
		}
		return {decl: decl.toString(), after: b.toString()};
	}
}
