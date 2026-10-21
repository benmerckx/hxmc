package context.display;

import core.Globals;
import core.Globals.Pos;
import core.Json.JsonValue;
import core.Json.JsonField;
import context.Common;
import core.MetaList.StrictMeta as MetaTag;
import core.Ast;
import core.Meta;
import core.DisplayTypes;

using core.ds.VectorTools;

class DocumentSymbols {
	public static function collectModuleSymbols(mname:Null<{file:String, name:String}>, withLocals:Bool,
			data:Package):Array<SymbolInformationData> {
		var pack = data.pack, decls = data.declarations;
		var l:Array<SymbolInformationData> = [];
		function add(name:String, kind:SymbolKindValue, location:Pos, parent:String, deprecated:Bool):Void {
			var si = SymbolInformation.make(name, kind, location, parent == "" ? null : parent, deprecated);
			l.push(si);
		}
		var expr:String->Expr->Void = null;
		function exprOpt(parent:String, eo:Null<Expr>):Void if (eo != null) expr(parent, eo);
		function func(parent:String, f:Func):Void {
			for (a in f.fArgs) {
				add(a.name.name, Variable, a.name.pos, parent, false);
				exprOpt(parent, a.expr);
			}
			exprOpt(parent, f.fExpr);
		}
		expr = function(parent:String, e:Expr):Void {
			function add_(name:String, kind:SymbolKindValue, location:Pos,
					deprecated:Bool):Void add(name, kind, location, parent, deprecated);
			switch e.expr {
				case EVars(vl):
					for (v in vl) {
						add_(v.evName.name, Variable, v.evName.pos, false);
						exprOpt(parent, v.evExpr);
					}
				case ETry(e1, catches):
					expr(parent, e1);
					for (c in catches) {
						add_(c.name.name, Variable, c.name.pos, false);
						expr(parent, c.expr);
					}
				case EFunction(FKNamed({name: s}, _), f):
					add_(s, Function, e.pos, false);
					func(parent, f);
				case EBinop(OpIn, {expr: EConst(Ident(s)), pos: p}, e2):
					add_(s, Variable, p, false);
					expr(parent, e2);
				case _:
					Ast.iterExpr(expr.bind(parent), e);
			}
		};
		function isDeprecated(meta:Metadata):Bool return Meta.has(MetaTag.Deprecated, meta);
		function field_(parent:String, parentKind:SymbolKindValue, cffName:PlacedName, cffKind:ClassFieldKind,
				cffAccess:Array<PlacedAccess>, cffPos:Pos, cffMeta:Metadata):Void {
			var fieldParent = parent + "." + cffName.name;
			function addField(kind:SymbolKindValue):Void add(cffName.name, kind, cffPos, parent, isDeprecated(cffMeta));
			switch cffKind {
				case FVar(_, eo):
					addField(if (parentKind == EnumAbstract
						&& !core.ds.ArrayTools.exists(cffAccess,
							a -> a.access == AStatic)) EnumMember else if (core.ds.ArrayTools.exists(cffAccess,
						a -> a.access == AInline)) Constant else Field);
					if (withLocals) exprOpt(fieldParent, eo);
				case FFun(f):
					addField(if (cffName.name == "new") Constructor else if ((parentKind == EnumAbstract || parentKind == Abstract)
						&& Meta.hasOneOf([MetaTag.Op, MetaTag.ArrayAccess, MetaTag.Resolve], cffMeta)) Operator else Method);
					if (withLocals) func(fieldParent, f);
				case FProp(_, _, _, eo):
					addField(Property);
					if (withLocals) exprOpt(fieldParent, eo);
			}
		}
		function field(parent:String, parentKind:SymbolKindValue,
				cff:ClassField):Void field_(parent, parentKind, cff.cffName, cff.cffKind, cff.cffAccess, cff.cffPos, cff.cffMeta);
		var typeDecls = new haxe.ds.StringMap<Bool>();
		for (decl in decls) {
			var p = decl.pos;
			function getDeclPath(name:PlacedName):{typePath:Array<String>, typeName:String} {
				var moduleName = core.Path.moduleNameOfFile(p.pfile);
				var typeName = name.name;
				var isPrimaryType = typeName == moduleName;
				var typePath = isPrimaryType ? pack : pack.concat([moduleName]);
				return {typePath: typePath, typeName: typeName};
			}
			function stringOfPath(l:Array<String>):String return l.join(".");
			function addType(name:PlacedName, meta:Metadata, kind:SymbolKindValue):String {
				var r = getDeclPath(name);
				typeDecls.set(r.typeName, true);
				add(r.typeName, kind, p, stringOfPath(r.typePath), isDeprecated(meta));
				return stringOfPath(r.typePath.concat([r.typeName]));
			}
			switch decl.definition {
				case EImport(_) | EUsing(_):
				case EClass(d):
					var kind = d.flags.has(HInterface) ? Interface : Class;
					var parent = addType(d.name, d.meta, kind);
					for (f in d.data) field(parent, kind, f);
				case EEnum(d):
					var parent = addType(d.name, d.meta, Enum);
					for (ef in d.data) add(ef.ecName.name, EnumMember, ef.ecPos, parent, isDeprecated(ef.ecMeta));
				case ETypedef(d):
					switch d.data.type {
						case CTAnonymous(fields):
							var parent = addType(d.name, d.meta, Struct);
							for (f in fields) field(parent, Struct, f);
						case _:
							addType(d.name, d.meta, TypeAlias);
					}
				case EAbstract(d):
					var kind = d.flags.has(AbEnum) ? EnumAbstract : Abstract;
					var parent = addType(d.name, d.meta, kind);
					for (f in d.data) field(parent, kind, f);
				case EStatic(d):
					var r = getDeclPath(d.name);
					var dotpath = stringOfPath(r.typePath);
					field_(dotpath, Class, d.name, d.data, d.flags.toArray(), p, d.meta);
			}
		}
		if (mname != null && !typeDecls.exists(mname.name)) add(mname.name, Module, Globals.filePos(mname.file), pack.join("."), false);
		return l;
	}
}

// port: DocumentSymbols.Printer
class DocumentSymbolsPrinter {
	static inline function kv(n:String, v:JsonValue):JsonField return {name: n, value: v};

	public static function jsonOfModuleSymbols(com:CommonContext, symbols:Array<{file:String, symbols:Array<SymbolInformationData>}>,
			filter:Null<String>):JsonValue {
		var regex = filter == null ? null : StrRegexp.regexpCaseFold(filter);
		var reported = new haxe.ds.StringMap<Bool>();
		function posKey(p:Pos):String return p.pmin + ":" + p.pmax + ":" + p.pfile;
		function add(si:SymbolInformationData):Bool {
			if (reported.exists(posKey(si.pos))) return false;
			var b = regex == null ? true : regex.match(si.name);
			reported.set(posKey(si.pos), true);
			return b;
		}
		var ja:Array<JsonValue> = [];
		for (e in symbols) {
			var jl = [];
			for (si in e.symbols) {
				if (!add(si)) continue;
				var l = [
					kv("name", JString(si.name)),
					kv("kind", JInt(SymbolKind.toInt(si.kind))),
					kv("range", core.json.Genjson.generatePosAsRange(si.pos))
				];
				if (si.containerName != null) l.push(kv("containerName", JString(si.containerName)));
				if (si.deprecated) l.unshift(kv("isDeprecated", JBool(true)));
				jl.push(JObject(l));
			}
			if (jl.length > 0) ja.unshift(JObject([kv("file", JString(e.file)), kv("symbols", JArray(jl))]));
		}
		return JArray(ja);
	}
}

// port: OCaml `Str` regular expressions, translated to `EReg`.
class StrRegexp {
	public static function regexpCaseFold(s:String):EReg return new EReg(translate(s), "i");

	// port: Str syntax: `\(` `\)` group, `\|` alternative, `\{` literal; `(`, `)`, `|`, `{` `}` are literal.
	public static function translate(s:String):String {
		var b = new StringBuf();
		var i = 0;
		while (i < s.length) {
			var c = s.charAt(i);
			if (c == "\\" && i + 1 < s.length) {
				var n = s.charAt(i + 1);
				switch n {
					case "(" | ")" | "|":
						b.add(n);
					case "b":
						b.add("\\b");
					case _:
						b.add("\\" + n);
				}
				i += 2;
				continue;
			}
			switch c {
				case "(" | ")" | "|" | "{" | "}":
					b.add("\\" + c);
				case _:
					b.add(c);
			}
			i++;
		}
		return b.toString();
	}
}
