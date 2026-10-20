package core;

import Type as StdType;
import core.Globals;
import core.Ast;
import core.TType;
import core.TType as TypeModel;
import core.TFunctions;
import core.TFunctions.*;
import core.AstPrinter;

// port: from haxe/src/core/tPrinting.ml.
typedef PrintContext = Array<{mono:TMono, id:Int}>;

class MonomorphPrinting {
	public static var showMonoIds = true;

	public static function sMonoConstraintKind(print:T->String, constr:TMonoConstraintKind):String {
		function loop(constr:TMonoConstraintKind):String return switch constr {
			case CUnknown: "";
			case CTypes(tl): [for (p in tl) print(p.type)].join(" & ");
			case CStructural(fields, _): print(mkAnon(Closed, fields));
			case CMixed(l): l.map(loop).join(" & ");
		};
		return loop(constr);
	}

	public static function printMonoName(m:TMono, id:Int, extra:String):String {
		var s = (showMonoIds ? 'Unknown<$id>' : "Unknown") + extra;
		for (modifier in m.tmModifiers) switch modifier {
			case MNullable(_):
				s = 'Null<$s>';
			case MOpenStructure | MDynamic:
		}
		return s;
	}

	// port: a print context can be shared by domains (Dump's parallel type dumps); OCaml's
	// racing `ctx := ...` stays memory safe, an Array growing under a reader does not.
	static final ctxMutex = new sys.thread.Mutex();

	public static function sMono(print:PrintContext->T->String, ctx:PrintContext, explicit:Bool, m:TMono):String {
		if (m.tmType != null && !explicit) return print(ctx, m.tmType);
		ctxMutex.acquire();
		var known = -1;
		for (pair in ctx) if (pair.mono == m) {
			known = pair.id;
			break;
		}
		var id = known >= 0 ? known : ctx.length;
		if (known < 0) ctx.unshift({mono: m, id: id});
		ctxMutex.release();
		if (known >= 0) return printMonoName(m, known, "");
		if (m.tmType != null && explicit) return printMonoName(m, id, " := " + print(ctx, m.tmType));
		var s = sMonoConstraintKind(function(t) return print(ctx, t), monomorphClassifyConstraintsRef(m));
		return printMonoName(m, id, s == "" ? s : " : " + s);
	}
}

class TPrinting {
	public static function printContext():PrintContext return [];

	public static function sTypeKind(t:T):String {
		inline function map(tl:TParams):String return tl.map(sTypeKind).join(", ");
		return switch t {
			case TMono(r): r.tmType == null ? "TMono (None)" : "TMono (Some (" + sTypeKind(r.tmType) + "))";
			case TEnum(en, tl): 'TEnum(${Globals.sTypePath(en.ePath)}, [${map(tl)}])';
			case TInst(c, tl): 'TInst(${Globals.sTypePath(c.clPath)}, [${map(tl)}])';
			case TType(t, tl): 'TType(${Globals.sTypePath(t.tPath)}, [${map(tl)}])';
			case TAbstract(a, tl): 'TAbstract(${Globals.sTypePath(a.aPath)}, [${map(tl)}])';
			case TFun(s): 'TFun([${[for (a in s.args) (a.optional ? "?" : "") + a.name + ":" + sTypeKind(a.type)].join(", ")}], ${sTypeKind(s.ret)})';
			case TAnon(_): "TAnon";
			case TDynamic(_): "TDynamic";
			case TLazy(_): "TLazy";
		};
	}

	public static function sModuleTypeKind(t:ModuleType):String return switch t {
		case TClassDecl(c): 'TClassDecl(${Globals.sTypePath(c.clPath)})';
		case TEnumDecl(en): 'TEnumDecl(${Globals.sTypePath(en.ePath)})';
		case TAbstractDecl(a): 'TAbstractDecl(${Globals.sTypePath(a.aPath)})';
		case TTypeDecl(t): 'TTypeDecl(${Globals.sTypePath(t.tPath)})';
	};

	public static function sType(ctx:PrintContext, t:T):String return switch t {
		case TMono(r): MonomorphPrinting.sMono(sType, ctx, false, r);
		case TEnum(e, tl): Globals.sTypePath(e.ePath) + sTypeParams(ctx, tl);
		case TInst(c, tl): switch c.clKind {
				case KExpr(e): AstPrinter.sExpr(e);
				case _: Globals.sTypePath(c.clPath) + sTypeParams(ctx, tl);
			}
		case TType({tType: TAnon({aStatus: ClassStatics({clKind: KAbstractImpl(a)})})}, _): 'Abstract<${Globals.sTypePath(a.aPath)}>';
		case TType(t, tl): Globals.sTypePath(t.tPath) + sTypeParams(ctx, tl);
		case TAbstract(a, tl): Globals.sTypePath(a.aPath) + sTypeParams(ctx, tl);
		case TFun({args: [], ret: t}): "() -> " + sFun(ctx, t, false);
		case TFun(s):
			var args = switch s.args {
				case [{name: "", optional: b, type: t}]: (b ? "?" : "") + sFun(ctx, t, true);
				case l: "(" + [
						for (a in l) (a.optional ? "?" : "") + (a.name == "" ? "" : a.name + " : ") + sFun(ctx, a.type, true)
					].join(", ") + ")";
			};
			args + " -> " + sFun(ctx, s.ret, false);
		case TAnon(a): switch a.aStatus {
				case ClassStatics(c): '{ ClassStatics ${Globals.sTypePath(c.clPath)} }';
				case EnumStatics(e): '{ EnumStatics ${Globals.sTypePath(e.ePath)} }';
				case AbstractStatics(a): '{ AbstractStatics ${Globals.sTypePath(a.aPath)} }';
				case _:
					var names = [for (name in a.aFields.keys()) name];
					names.sort(core.ds.Key.compareStrings);
					names.reverse();
					"{" + [
						for (name in names) {
							var f = a.aFields.get(name);
							(Meta.has(Meta.Optional, f.cfMeta) ? " ?" : " ") + f.cfName + " : " + sType(ctx, f.cfType);
						}
					].join(",") + " }";
			}
		case TDynamic(null): "Dynamic";
		case TDynamic(t2): "Dynamic" + sTypeParams(ctx, [t2]);
		case TLazy(f): sType(ctx, lazyType(f));
	};

	public static function sFun(ctx:PrintContext, t:T, void:Bool):String return switch t {
		case TFun(_): "(" + sType(ctx, t) + ")";
		case TAbstract(a, []) if (void && a.aPath.pack.length == 0 && a.aPath.name == "Void"): "(" + sType(ctx, t) + ")";
		case TMono(r): r.tmType == null ? sType(ctx, t) : sFun(ctx, r.tmType, void);
		case TLazy(f): sFun(ctx, lazyType(f), void);
		case _: sType(ctx, t);
	};

	public static function sTypeParams(ctx:PrintContext,
			l:TParams):String return l.length == 0 ? "" : "<" + [for (t in l) sType(ctx, t)].join(", ") + ">";

	public static function sConstraint(c:TMonoConstraint):String return switch c {
		case MMono(m, _): "MMono " + sTypeKind(TMono(m));
		case MField(cf): "MField " + cf.cfName;
		case MType(t, _): "MType " + sTypeKind(t);
		case MEmptyStructure: "MEmptyStructure";
	};

	public static function sTypeParam(print:T->String, ttp:TypedTypeParam):String {
		var constraints = getConstraints(ttp);
		var s = constraints.length == 0 ? ttp.ttpName : ttp.ttpName + ":" + constraints.map(print).join(" & ");
		return ttp.ttpDefault == null ? s : s + " = " + print(ttp.ttpDefault);
	}

	public static function sAccess(isRead:Bool, a:VarAccess):String return switch a {
		case AccNormal: "default";
		case AccNo: "null";
		case AccNever: "never";
		case AccCall: isRead ? "get" : "set";
		case AccPrivateCall: isRead ? "private get" : "private set";
		case AccInline: "inline";
		case AccRequire(n, _): "require " + n;
		case AccCtor: "ctor";
	};

	public static function sKind(k:FieldKind):String return switch k {
		case Var({vRead: AccNormal, vWrite: AccNormal}): "var";
		case Var(v): "(" + sAccess(true, v.vRead) + "," + sAccess(false, v.vWrite) + ")";
		case Method(m): switch m {
				case MethNormal: "method";
				case MethDynamic: "dynamic method";
				case MethInline: "inline method";
				case MethMacro: "macro method";
			}
	};

	public static function sExprKind(e:TExpr):String {
		var name = StdType.enumConstructor(e.eexpr);
		return name == "TVar" ? "Vars" : name.substr(1);
	}

	public static function sConst(c:TConstant):String return switch c {
		case TInt(i): Std.string(i);
		case TFloat(s): s;
		case TString(s): '"' + StringHelper.sEscape(s) + '"';
		case TBool(b): b ? "true" : "false";
		case TNull: "null";
		case TThis: "this";
		case TSuper: "super";
	};

	public static function sFieldAccess(print:T->String, fa:TFieldAccess):String return switch fa {
		case FStatic(c, f): 'static(${Globals.sTypePath(c.clPath)}.${f.cfName})';
		case FInstance(c, _, f): 'inst(${Globals.sTypePath(c.clPath)}.${f.cfName} : ${print(f.cfType)})';
		case FClosure(c, f): "closure(" + (c == null ? f.cfName : Globals.sTypePath(c.cls.clPath) + "." + f.cfName) + ")";
		case FAnon(f): 'anon(${f.cfName})';
		case FEnum(en, f): 'enum(${Globals.sTypePath(en.ePath)}.${f.efName})';
		case FDynamic(f): 'dynamic($f)';
	};

	static function key(name:String, quote:QuoteStatus):String return quote == NoQuotes ? name : '"' + StringHelper.sEscape(name) + '"';

	public static function sExprPretty(printVarIds:Bool, tabs:String, topLevel:Bool, print:T->String, e:TExpr):String {
		function loop(e:TExpr):String return sExprPretty(printVarIds, tabs, false, print, e);
		inline function list(el:Array<TExpr>):String return el.map(loop).join(", ");
		inline function local(v:TVar):String return printVarIds ? '${v.vName}<${v.vId}>' : v.vName;
		return switch e.eexpr {
			case TConst(c): sConst(c);
			case TLocal(v): local(v);
			case TArray(e1, e2): '${loop(e1)}[${loop(e2)}]';
			case TBinop(op, e1, e2): '${loop(e1)} ${Ast.sBinop(op)} ${loop(e2)}';
			case TEnumParameter(e1, _, i): '${loop(e1)}[$i]';
			case TEnumIndex(e1): 'enumIndex ${loop(e1)}';
			case TField(e1, f): '${loop(e1)}.${fieldName(f)}';
			case TTypeExpr(mt): Globals.sTypePath(tPath(mt));
			case TParenthesis(e1): '(${loop(e1)})';
			case TObjectDecl(fl): "{" + [for (f in fl) key(f.key.name, f.key.quote) + " : " + loop(f.expr)].join(", ") + "}";
			case TArrayDecl(el): ' [${list(el)}]'.substr(1);
			case TCall(e1, el): '${loop(e1)}(${list(el)})';
			case TNew(c, _, el): 'new ${Globals.sTypePath(c.clPath)}(${list(el)})';
			case TUnop(op, Prefix, e): '${Ast.sUnop(op)} ${loop(e)}';
			case TUnop(op, Postfix, e): '${loop(e)} ${Ast.sUnop(op)}';
			case TFunction(f):
				var args = [
					for (a in f.tfArgs) local(a.variable)
						+ ":"
						+ print(a.variable.vType)
						+ (a.defaultValue == null ? "" : " = " + loop(a.defaultValue))].join(", ");
				(topLevel ? "" : "function") + '(' + args + ') ' + loop(f.tfExpr);
			case TVar(v, eo): "var " + local(v) + (eo == null ? "" : " = " + loop(eo));
			case TBlock([]): "{}";
			case TBlock(el):
				var ntabs = tabs + "\t";
				"{\n" + [
					for (e in el) ntabs + sExprPretty(printVarIds, ntabs, topLevel, print, e) + ";\n"
				].join("") + tabs + "}";
			case TIf(e, e1, e2): 'if (${loop(e)}) ${loop(e1)}' + (e2 == null ? "" : " else " + loop(e2));
			case TWhile(ec, e, NormalWhile): 'while (${loop(ec)}) ${loop(e)}';
			case TWhile(ec, e, DoWhile): 'do (${loop(e)}) while(${loop(ec)})';
			case TSwitch(s):
				var ntabs = tabs + "\t";
				'switch (${loop(s.switchSubject)}) {\n' + [
					for (c in s.switchCases) ntabs
						+ 'case ${list(c.casePatterns)}: '
						+ sExprPretty(printVarIds, ntabs, topLevel, print, c.caseExpr)
						+ ";\n"].join("")
					+ (s.switchDefault == null ? "" : ntabs
						+ "default: "
						+ sExprPretty(printVarIds, ntabs, topLevel, print, s.switchDefault)
						+ "\n")
					+ tabs
					+ "}";
			case TTry(e, cl): "try " + loop(e) + [
					for (c in cl) ' catch (${local(c.variable)}:${print(c.variable.vType)}) ${loop(c.expr)}'
				].join(", ");
			case TReturn(null): "return";
			case TReturn(e): "return " + loop(e);
			case TBreak: "break";
			case TContinue: "continue";
			case TThrow(e): "throw " + loop(e);
			case TCast(e, null): "cast " + loop(e);
			case TCast(e, mt): 'cast (${loop(e)},${Globals.sTypePath(tPath(mt))})';
			case TMeta(m, e): "@"
				+ Meta.toString(m.meta)
				+ (m.exprs.length == 0 ? "" : "(" + m.exprs.map(AstPrinter.sExpr).join(", ") + ")")
				+ " "
				+ loop(e);
			case TIdent(s): s;
		};
	}

	public static function sFlags(flags:Int, allFlags:Array<String>):String {
		var l = [];
		for (i in 0...allFlags.length) if (hasFlag(flags, i)) l.unshift(allFlags[i]);
		return l.join(" ");
	}

	public static function sExprAst(printVarIds:Bool, tabs:String, print:T->String, e:TExpr):String {
		inline function loop(e:TExpr, extraTabs:String = ""):String return sExprAst(printVarIds, tabs + "\t" + extraTabs, print, e);
		inline function tagArgs(tabs:String, sl:Array<String>):String {
			if (sl.length == 0) return "";
			if (sl.length == 1 && sl[0].indexOf("\n") < 0) return " " + sl[0];
			var sep = "\n" + tabs + "\t";
			return sep + sl.join(sep);
		}
		function tag(s:String, sl:Array<String>, ?t:T,
				extraTabs:String = ""):String return '[$s:${print(t == null ? e.etype : t)}]' + tagArgs(tabs + extraTabs, sl);
		inline function varId(v:TVar):Int return printVarIds ? v.vId : 0;
		inline function local(v:TVar,
				?t:T):String return '[Local ${v.vName}(${varId(v)}):${print(v.vType)}${t == null ? "" : ":" + print(t)}]';
		function variable(tag:String, v:TVar, sl:Array<String>):String
			return '[$tag ${v.vName}<${varId(v)}>${v.vFlags == 0 ? "" : "(" + sFlags(v.vFlags, TypeModel.flagTVarNames) + ")"}:${print(v.vType)}]'
				+ tagArgs(tabs, sl);
		inline function moduleType(mt:ModuleType):String return '[TypeExpr ${Globals.sTypePath(tPath(mt))}:${print(e.etype)}]';
		inline function loops(el:Array<TExpr>):Array<String> return [for (e in el) loop(e)];
		return switch e.eexpr {
			case TConst(c): tag("Const", [sConst(c)], e.etype);
			case TLocal(v): local(v, e.etype);
			case TArray(e1, e2): tag("Array", [loop(e1), loop(e2)]);
			case TBinop(op, e1, e2): tag("Binop", [loop(e1), Ast.sBinop(op), loop(e2)]);
			case TUnop(op, flag, e1): tag("Unop", [Ast.sUnop(op), flag == Postfix ? "Postfix" : "Prefix", loop(e1)]);
			case TEnumParameter(e1, ef, i): tag("EnumParameter", [loop(e1), ef.efName, Std.string(i)]);
			case TEnumIndex(e1): tag("EnumIndex", [loop(e1)]);
			case TField(e1, fa):
				var sfa = switch fa {
					case FInstance(c, tl, cf): tag("FInstance", [print(TInst(c, tl)), cf.cfName + ":" + print(cf.cfType)], null, "\t");
					case FStatic(c, cf): tag("FStatic", [Globals.sTypePath(c.clPath), cf.cfName + ":" + print(cf.cfType)], null, "\t");
					case FClosure(co, cf): tag("FClosure", [
							co == null ? "None" : print(TInst(co.cls, co.params)),
							cf.cfName + ":" + print(cf.cfType)
						], null, "\t");
					case FAnon(cf): tag("FAnon", [cf.cfName + ":" + print(cf.cfType)], null, "\t");
					case FDynamic(s): tag("FDynamic", [s], null, "\t");
					case FEnum(en, ef): tag("FEnum", [Globals.sTypePath(en.ePath), ef.efName], null, "\t");
				};
				tag("Field", [loop(e1), sfa]);
			case TTypeExpr(mt): moduleType(mt);
			case TParenthesis(e1): tag("Parenthesis", [loop(e1)]);
			case TObjectDecl(fl): tag("ObjectDecl", [for (f in fl) key(f.key.name, f.key.quote) + ": " + loop(f.expr)]);
			case TArrayDecl(el): tag("ArrayDecl", loops(el));
			case TCall(e1, el): tag("Call", [loop(e1)].concat(loops(el)));
			case TNew(c, tl, el): tag("New", [print(TInst(c, tl))].concat(loops(el)));
			case TFunction(f): tag("Function", [
					for (a in f.tfArgs) variable("Arg", a.variable, a.defaultValue == null ? [] : [loop(a.defaultValue)])
				].concat([loop(f.tfExpr)]));
			case TVar(v, eo): variable("Var", v, eo == null ? [] : [loop(eo)]);
			case TBlock(el): tag("Block", loops(el));
			case TIf(e, e1,
				e2): tag("If",
					[loop(e), '[Then:${print(e1.etype)}] ${loop(e1)}'].concat(e2 == null ? [] : ['[Else:${print(e2.etype)}] ${loop(e2)}']));
			case TCast(e1, null): tag("Cast", [loop(e1)]);
			case TCast(e1, mt): tag("Cast", [loop(e1), moduleType(mt)]);
			case TThrow(e1): tag("Throw", [loop(e1)]);
			case TBreak: tag("Break", []);
			case TContinue: tag("Continue", []);
			case TReturn(null): tag("Return", []);
			case TReturn(e1): tag("Return", [loop(e1)]);
			case TWhile(e1, e2, NormalWhile): tag("While", [loop(e1), loop(e2)]);
			case TWhile(e1, e2, DoWhile): tag("Do", [loop(e1), loop(e2)]);
			case TTry(e1, catches): tag("Try", [loop(e1)].concat([
					for (c in catches) 'Catch ${local(c.variable)}' + tagArgs(tabs + "\t", [loop(c.expr, "\t")])
				]));
			case TSwitch(s):
				var sl = [
					for (c in s.switchCases) tag("Case", loops(c.casePatterns).concat([loop(c.caseExpr, "\t")]), c.caseExpr.etype, "\t")
				];
				if (s.switchDefault != null) sl.push(tag("Default", [loop(s.switchDefault, "\t")], s.switchDefault.etype, "\t"));
				tag("Switch", [loop(s.switchSubject)].concat(sl));
			case TMeta(m, e1):
				var s = Meta.toString(m.meta);
				if (m.exprs.length != 0) s += "(" + m.exprs.map(AstPrinter.sExpr).join(", ") + ")";
				tag("Meta", [s, loop(e1)]);
			case TIdent(s): tag("Ident", [s]);
		};
	}

	/**
		Shortcut to pretty-printing expressions for debugging purposes.
	**/
	public static function sExprDebug(e:TExpr):String {
		var ctx = printContext();
		return sExprPretty(false, "  ", false, function(t) return sType(ctx, t), e);
	}

	public static function sTypes(tl:TParams, sep:String = ", "):String {
		var ctx = printContext();
		return [for (t in tl) sType(ctx, t)].join(sep);
	}

	public static function sClassKind(k:TClassKind):String return switch k {
		case KNormal: "KNormal";
		case KTypeParameter(ttp): 'KTypeParameter [${sTypes(getConstraints(ttp))}]';
		case KExpr(_): "KExpr";
		case KGeneric: "KGeneric";
		case KGenericInstance(c, tl): 'KGenericInstance ${Globals.sTypePath(c.clPath)}<${sTypes(tl)}>';
		case KMacroType: "KMacroType";
		case KGenericBuild(_): "KGenericBuild";
		case KAbstractImpl(a): 'KAbstractImpl ${Globals.sTypePath(a.aPath)}';
		case KModuleFields(m): 'KModuleFields ${Globals.sTypePath(m.mPath)}';
	};

	public static function sClassFieldRefKind(k:ClassFieldRefKind):String return StdType.enumConstructor(k);
}

class Printer {
	public static function sType(t:T):String return TPrinting.sType(TPrinting.printContext(), t);

	public static function sPair(s1:String, s2:String):String return '($s1,$s2)';

	public static function sRecordField(name:String, value:String):String return '$name = $value;';

	public static function sPos(p:Pos):String return '${p.pfile}: ${p.pmin}-${p.pmax}';

	public static function sRecordFields(tabs:String,
			fields:Array<{name:String, value:String}>):String return "{\n"
			+ tabs
			+ "\t"
			+ [for (f in fields) sRecordField(f.name, f.value)].join("\n\t" + tabs) + "\n" + tabs + "}";

	static function record(tabs:String,
			fields:Array<Array<String>>):String return sRecordFields(tabs, [for (f in fields) {name: f[0], value: f[1]}]);

	public static function sList<V>(sep:String, f:V->String, l:Array<V>):String return "[" + l.map(f).join(sep) + "]";

	public static function sOpt<V>(f:V->String, o:Null<V>):String return o == null ? "None" : f(o);

	public static function sPmap<K, V>(fk:K->String, fv:V->String, pm:haxe.Constraints.IMap<K, V>):String {
		var keys:Array<K> = [];
		var iter:Iterator<K> = pm.keys();
		for (k in iter) keys.push(k);
		keys.sort(core.ds.Key.compare);
		keys.reverse();
		return "{" + [for (k in keys) fk(k) + " = " + fv(pm.get(k))].join(", ") + "}";
	}

	public static function sDoc(doc:Documentation):String return doc == null ? "None" : Ast.genDocText(doc);

	public static function sMetadataEntry(m:MetadataEntry):String return "@"
		+ Meta.toString(m.meta)
		+ (m.exprs.length == 0 ? "" : "(" + m.exprs.map(AstPrinter.sExpr).join(", ") + ")");

	public static function sMetadata(metadata:Metadata):String return sList(" ", sMetadataEntry, metadata);

	public static function sTtpHost(host:TypeParamHost):String return StdType.enumConstructor(host);

	public static function sTypeParam(tabs:String, ttp:TypedTypeParam):String return record(tabs, [
		["name", ttp.ttpName],
		["class", Globals.sTypePath(ttp.ttpClass.clPath)],
		["host", sTtpHost(ttp.ttpHost)],
		["type", TPrinting.sTypeKind(ttp.ttpType)],
		["constraints", sList(", ", TPrinting.sTypeKind, getConstraints(ttp))],
		["default", sOpt(TPrinting.sTypeKind, ttp.ttpDefault)]
	]);

	public static function sTypeParams(tabs:String, tl:TypeParams):String return sList(", ", function(t) return sTypeParam(tabs, t), tl);

	public static function sTclassFieldFlags(flags:Int):String return TPrinting.sFlags(flags, TypeModel.flagTClassFieldNames);

	public static function sTclassField(tabs:String, cf:TClassField):String return record(tabs, [
		["cf_name", cf.cfName],
		["cf_doc", sDoc(cf.cfDoc)],
		["cf_type", TPrinting.sTypeKind(followLazyAndMono(cf.cfType))],
		["cf_pos", sPos(cf.cfPos)],
		["cf_name_pos", sPos(cf.cfNamePos)],
		["cf_meta", sMetadata(cf.cfMeta)],
		["cf_kind", TPrinting.sKind(cf.cfKind)],
		["cf_params", sTypeParams(tabs + "\t", cf.cfParams)],
		[
			"cf_expr",
			sOpt(function(e) return TPrinting.sExprAst(true, "\t\t", sType, e), cf.cfExpr)
		],
		["cf_flags", sTclassFieldFlags(cf.cfFlags)],
		[
			"cf_overloads",
			sList("\n", function(cf) return sTclassField(tabs + "\t", cf), cf.cfOverloads)
		]
	]);

	public static function sTclass(tabs:String, c:TClass):String return record(tabs, [
		["cl_path", Globals.sTypePath(c.clPath)],
		["cl_module", Globals.sTypePath(c.clModule.mPath)],
		["cl_pos", sPos(c.clPos)],
		["cl_name_pos", sPos(c.clNamePos)],
		["cl_private", Std.string(c.clPrivate)],
		["cl_doc", sDoc(c.clDoc)],
		["cl_meta", sMetadata(c.clMeta)],
		["cl_flags", TPrinting.sFlags(c.clFlags, TypeModel.flagTClassNames)],
		["cl_params", sTypeParams(tabs + "\t", c.clParams)],
		["cl_kind", TPrinting.sClassKind(c.clKind)],
		["cl_super", sOpt(function(p) return sType(TInst(p.cls, p.params)), c.clSuper)],
		[
			"cl_implements",
			sList(", ", function(p) return sType(TInst(p.cls, p.params)), c.clImplements)
		],
		["cl_array_access", sOpt(sType, c.clArrayAccess)],
		[
			"cl_init",
			sOpt(function(e) return TPrinting.sExprAst(true, "", sType, e), core.TOther.TClassTools.getClInit(c))
		],
		[
			"cl_constructor",
			sOpt(function(cf) return sTclassField(tabs + "\t", cf), c.clConstructor)
		],
		[
			"cl_ordered_fields",
			sList("\n\t", function(cf) return sTclassField(tabs + "\t", cf), c.clOrderedFields)
		],
		[
			"cl_ordered_statics",
			sList("\n\t", function(cf) return sTclassField(tabs + "\t", cf), c.clOrderedStatics)
		]
	]);

	public static function sTdef(tabs:String, t:TDef):String return record(tabs, [
		["t_path", Globals.sTypePath(t.tPath)],
		["t_module", Globals.sTypePath(t.tModule.mPath)],
		["t_pos", sPos(t.tPos)],
		["t_name_pos", sPos(t.tNamePos)],
		["t_private", Std.string(t.tPrivate)],
		["t_doc", sDoc(t.tDoc)],
		["t_meta", sMetadata(t.tMeta)],
		["t_params", sTypeParams(tabs + "\t", t.tParams)],
		["t_type", TPrinting.sTypeKind(followLazyAndMono(t.tType))]
	]);

	public static function sTenumField(tabs:String, ef:TEnumField):String return record(tabs, [
		["ef_name", ef.efName],
		["ef_doc", sDoc(ef.efDoc)],
		["ef_pos", sPos(ef.efPos)],
		["ef_name_pos", sPos(ef.efNamePos)],
		["ef_type", TPrinting.sTypeKind(ef.efType)],
		["ef_index", Std.string(ef.efIndex)],
		["ef_params", sTypeParams(tabs + "\t", ef.efParams)],
		["ef_meta", sMetadata(ef.efMeta)]
	]);

	public static function sTenum(tabs:String, en:TEnum):String {
		var names = [for (name in en.eConstrs.keys()) name];
		names.sort(core.ds.Key.compareStrings);
		names.reverse();
		return record(tabs, [
			["e_path", Globals.sTypePath(en.ePath)],
			["e_module", Globals.sTypePath(en.eModule.mPath)],
			["e_pos", sPos(en.ePos)],
			["e_name_pos", sPos(en.eNamePos)],
			["e_private", Std.string(en.ePrivate)],
			["d_doc", sDoc(en.eDoc)],
			["e_meta", sMetadata(en.eMeta)],
			["e_params", sTypeParams(tabs + "\t", en.eParams)],
			["e_type", TPrinting.sTypeKind(en.eType)],
			["e_extern", Std.string(hasEnumFlag(en, EnExtern))],
			[
				"e_constrs",
				sList("\n\t", function(ef) return sTenumField(tabs + "\t", ef), [for (n in names) en.eConstrs.get(n)])
			],
			["e_names", en.eNames.join(", ")]
		]);
	}

	public static function sTabstract(tabs:String, a:TAbstract):String return record(tabs, [
		["a_path", Globals.sTypePath(a.aPath)],
		["a_modules", Globals.sTypePath(a.aModule.mPath)],
		["a_pos", sPos(a.aPos)],
		["a_name_pos", sPos(a.aNamePos)],
		["a_private", Std.string(a.aPrivate)],
		["a_doc", sDoc(a.aDoc)],
		["a_meta", sMetadata(a.aMeta)],
		["a_params", sTypeParams(tabs + "\t", a.aParams)],
		[
			"a_ops",
			sList(", ", function(p) return Ast.sBinop(p.op) + ": " + p.field.cfName, a.aOps)
		],
		[
			"a_unops",
			sList(", ", function(p) return Ast.sUnop(p.op) + " (" + (p.flag == Postfix ? "postfix" : "prefix") + "): " + p.field.cfName,
				a.aUnops)
		],
		["a_impl", sOpt(function(c) return Globals.sTypePath(c.clPath), a.aImpl)],
		["a_this", TPrinting.sTypeKind(followLazyAndMono(a.aThis))],
		["a_from", sList(", ", TPrinting.sTypeKind, a.aFrom.map(followLazyAndMono))],
		["a_to", sList(", ", TPrinting.sTypeKind, a.aTo.map(followLazyAndMono))],
		[
			"a_from_field",
			sList(", ", function(p) return TPrinting.sTypeKind(followLazyAndMono(p.type)) + ": " + p.field.cfName, a.aFromField)
		],
		[
			"a_to_field",
			sList(", ", function(p) return TPrinting.sTypeKind(followLazyAndMono(p.type)) + ": " + p.field.cfName, a.aToField)
		],
		["a_array", sList(", ", function(cf:TClassField) return cf.cfName, a.aArray)],
		["a_read", sOpt(function(cf:TClassField) return cf.cfName, a.aRead)],
		["a_write", sOpt(function(cf:TClassField) return cf.cfName, a.aWrite)]
	]);

	public static function sTvarExtra(ve:TVarExtra):String
		return 'Some(${sTypeParams("", ve.vParams)}, ${sOpt(function(e) return TPrinting.sExprAst(true, "", sType, e), ve.vExpr)})';

	public static function sTvarKind(kind:TVarKind):String return switch kind {
		case VUser(origin): "VUser(" + StdType.enumConstructor(origin) + ")";
		case VGenerated: "VGenerated";
		case VInlined: "VInlined";
		case VInlinedConstructorVariable(sl): "VInlinedConstructorVariable(" + sl.join(", ") + ")";
		case VExtractorVariable: "VExtractorVariable";
		case VAbstractThis: "VAbstractThis";
	};

	public static function sTvar(v:TVar):String return record("", [
		["v_id", Std.string(v.vId)],
		["v_name", v.vName],
		["v_type", sType(v.vType)],
		["v_kind", sTvarKind(v.vKind)],
		["v_capture", Std.string(hasVarFlag(v, VCaptured))],
		["v_extra", sOpt(sTvarExtra, v.vExtra)],
		["v_meta", sMetadata(v.vMeta)],
		[
			"v_flags",
			v.vFlags == 0 ? "" : "(" + TPrinting.sFlags(v.vFlags, TypeModel.flagTVarNames) + ")"
		],
		["v_pos", sPos(v.vPos)]
	]);

	public static function sModuleKind(kind:ModuleKind):String return StdType.enumConstructor(kind);

	public static function sModuleOrigin(origin:ModuleDepOrigin):String return StdType.enumConstructor(origin);

	public static function sModuleTaintingReason(reason:ModuleTaintingReason):String return switch reason {
		case CheckDisplayFile: "check_display_file";
		case DefineType: "define_type";
		case DefineModule: "define_module";
		case ServerInvalidate: "server/invalidate";
		case ServerInvalidateFiles: "server_invalidate_files";
		case ServerInvalidateModule: "server_invalidate_module";
	};

	public static function sModuleSkipReason(reason:ModuleSkipReason):String {
		/* A dependency chain can be as long as the module graph is deep: a buffer and a set, so
			that the string costs linear time (Printf from the inside out and List.mem on the stack
			were quadratic, which the server pays once per skipped module). */
		var buf = new StringBuf();
		// port: the Hashtbl of paths, keyed by an injective string of the path.
		var seen = new haxe.ds.StringMap<Bool>();
		function loop(first:Bool, reason:ModuleSkipReason):Void {
			switch reason {
				case DependencyDirty(path, reason):
					if (first) buf.add("DependencyDirty ");
					buf.add(Globals.sTypePath(path));
					buf.add(" - ");
					var key = path.pack.join("\n") + "\n\n" + path.name;
					if (seen.exists(key))
						buf.add("rec")
					else {
						seen.set(key, true);
						loop(false, reason);
					}
				case Tainted(cause): buf.add("Tainted " + sModuleTaintingReason(cause));
				case FileChanged(file): buf.add("FileChanged " + file);
				case Shadowed(file): buf.add("Shadowed " + file);
				case LibraryChanged: buf.add("LibraryChanged");
			}
		}
		loop(true, reason);
		return buf.toString();
	}

	public static function sModuleCacheState(state:ModuleCacheState):String return switch state {
		case MSGood: "Good";
		case MSBad(reason): "Bad: " + sModuleSkipReason(reason);
		case MSUnknown: "Unknown";
	};

	public static function sModuleDefExtra(tabs:String, me:ModuleDefExtra):String return record(tabs, [
		["m_file", core.Path.UniqueKey.lazyPath(me.mFile)],
		["m_sign", me.mSign],
		["m_time", Std.string(me.mTime)],
		["m_cache_state", sModuleCacheState(me.mCacheState)],
		["m_added", Std.string(me.mAdded)],
		["m_checked", Std.string(me.mChecked)],
		[
			"m_deps",
			sPmap(Std.string, function(mdep:ModuleDep) return mdep.mdPath.name, me.mDeps)
		],
		["m_processed", Std.string(me.mProcessed)],
		["m_kind", sModuleKind(me.mKind)],
		["m_binded_res", ""], // TODO
		["m_features", ""] // TODO
	]);

	public static function sModuleDef(m:ModuleDef):String return record("", [
		["m_id", Std.string(m.mId)],
		["m_path", Globals.sTypePath(m.mPath)],
		["m_extra", sModuleDefExtra("\t", m.mExtra)]
	]);

	public static function sTypePath(tp:TypePath):String return record("", [
		["tpackage", sList(".", function(s) return s, tp.tpackage)],
		["tname", tp.tname],
		["tparams", ""],
		["tsub", sOpt(function(s) return s, tp.tsub)]
	]);

	public static function sClassFlag(flag:ClassFlag):String return switch flag {
		case HInterface: "HInterface";
		case HExtern: "HExtern";
		case HPrivate: "HPrivate";
		case HExtends(ptp): "HExtends " + sTypePath(ptp.path);
		case HImplements(ptp): "HImplements " + sTypePath(ptp.path);
		case HFinal: "HFinal";
		case HAbstract: "HAbstract";
	};

	public static function sPlaced<V>(f:V->String, x:V, p:Pos):String return sPair(f(x), sPos(p));

	public static function sClassField(cff:ClassField):String return record("", [
		["cff_name", sPlaced(function(s) return s, cff.cffName.name, cff.cffName.pos)],
		["cff_doc", sDoc(cff.cffDoc)],
		["cff_pos", sPos(cff.cffPos)],
		["cff_meta", sMetadata(cff.cffMeta)],
		["cff_access", sList(", ", Ast.sPlacedAccess, cff.cffAccess)]
	]);
}
