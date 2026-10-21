package core;

import Type as StdType;
import core.Globals;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import haxe.ds.StringMap;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: from haxe/src/core/tOther.ml.
class TExprToExpr {
	public static function tpath(path:GlobalTypePath, modulePath:GlobalTypePath, params:Vector<TypeParamOrConst>):ComplexType {
		return Ast.makePtpCt(path.name == modulePath.name ? Ast.mkTypePath(path.pack, path.name,
			params) : Ast.mkTypePath(modulePath.pack, modulePath.name, params, path.name),
			Globals.nullPos);
	}

	public static function convertType(t:T):ComplexType return switch t {
		case TMono(r):
			if (r.tmType == null) throw new TypeExit();
			convertType(r.tmType);
		case TInst(c, tl) if (c.clPrivate): Ast.makePtpCt(Ast.mkTypePath([], c.clPath.name, tl.map(tparam)), Globals.nullPos);
		case TEnum(e, tl) if (e.ePrivate): Ast.makePtpCt(Ast.mkTypePath([], e.ePath.name, tl.map(tparam)), Globals.nullPos);
		case TType(td, tl) if (td.tPrivate): Ast.makePtpCt(Ast.mkTypePath([], td.tPath.name, tl.map(tparam)), Globals.nullPos);
		case TAbstract(a, tl) if (a.aPrivate): Ast.makePtpCt(Ast.mkTypePath([], a.aPath.name, tl.map(tparam)), Globals.nullPos);
		case TEnum(e, pl): tpath(e.ePath, e.eModule.mPath, pl.map(tparam));
		case TInst(c,
			pl) if (c.clKind.match(KExpr(_)) || c.clKind.match(KTypeParameter(_))): tpath({pack: [], name: c.clPath.name},
				{pack: [], name: c.clPath.name}, pl.map(tparam));
		case TInst(c, pl): tpath(c.clPath, c.clModule.mPath, pl.map(tparam));
		// recurse on type-type
		case TType(td,
			pl): StringTools.startsWith(td.tPath.name, "#") ? convertType(follow(t)) : tpath(td.tPath, td.tModule.mPath, pl.map(tparam));
		case TAbstract(a, pl): tpath(a.aPath, a.aModule.mPath, pl.map(tparam));
		case TFun(s): CTFunction(s.args.map(function(arg):TypeHint {
					var ct = convertTypeHint(arg.type);
					if (arg.name != "") ct = {type: CTNamed({name: arg.name, pos: Globals.nullPos}, ct), pos: Globals.nullPos};
					return arg.optional ? {type: CTOptional(ct), pos: Globals.nullPos} : ct;
				}), convertTypeHint(s.ret));
		case TAnon(a): switch a.aStatus {
				case ClassStatics(c): tpath({pack: [], name: "Class"}, {pack: [], name: "Class"},
						vector(TPType({type: tpath(c.clPath, c.clPath, vector()), pos: Globals.nullPos})));
				case EnumStatics(e): tpath({pack: [], name: "Enum"}, {pack: [], name: "Enum"},
						vector(TPType({type: tpath(e.ePath, e.ePath, vector()), pos: Globals.nullPos})));
				case _:
					var fields:Array<ClassField> = [];
					var names = [for (name in a.aFields.keys()) name];
					names.sort(core.ds.Key.compareStrings);
					for (name in names) {
						var f = a.aFields.get(name);
						var access:Array<PlacedAccess> = [];
						inline function add(flag:Access):Void access.unshift({access: flag, pos: Globals.nullPos});
						add(hasClassFieldFlag(f, CfPublic) ? APublic : APrivate);
						if (hasClassFieldFlag(f, CfFinal)) add(AFinal);
						if (hasClassFieldFlag(f, CfExtern)) add(AExtern);
						var kind = switch [f.cfKind, follow(f.cfType)] {
							case [Var(v), _]:
								inline function accessToString(va:VarAccess, getOrSet:String):String return switch va {
									case AccNormal | AccCtor | AccInline | AccRequire(_, _): "default";
									case AccNo: "null";
									case AccNever: "never";
									case AccCall | AccPrivateCall: getOrSet;
								};
								FProp({name: accessToString(v.vRead, "get"), pos: Globals.nullPos},
									{name: accessToString(v.vWrite, "set"), pos: Globals.nullPos}, mkTypeHint(f.cfType, Globals.nullPos),
									null);
							case [Method(_), TFun(s)]: FFun({
									fParams: vector(),
									fArgs: s.args.map(arg -> ({
											name: {name: arg.name, pos: Globals.nullPos},
											optional: arg.optional,
											meta: [],
											type: convertTypeHint(arg.type),
											expr: null
										} : FuncArg)),
									fType: convertTypeHint(s.ret),
									fExpr: null
								});
							case _: throw "Invalid anonymous field kind";
						};
						fields.unshift({
							cffName: {name: f.cfName, pos: Globals.nullPos},
							cffKind: kind,
							cffPos: f.cfPos,
							cffDoc: f.cfDoc,
							cffMeta: f.cfMeta,
							cffAccess: access
						});
					}
					CTAnonymous(Vector.fromArrayCopy(fields));
			}
		case TDynamic(null): tpath({pack: [], name: "Dynamic"}, {pack: [], name: "Dynamic"}, vector());
		case TDynamic(t): tpath({pack: [], name: "Dynamic"}, {pack: [], name: "Dynamic"}, vector(tparam(t)));
		case TLazy(f): convertType(lazyType(f));
	};

	public static function convertTypeHint(t:T):TypeHint return {type: convertType(t), pos: Globals.nullPos};

	public static function tparam(t:T):TypeParamOrConst return switch t {
		case TInst({clKind: KExpr(e)}, _): TPExpr(e);
		case _: TPType(convertTypeHint(t));
	};

	public static function mkTypeHint(t:T, p:Pos):Null<TypeHint> return switch follow(t) {
		case TMono(_): null;
		case _: try {type: convertType(t), pos: p} catch (_:TypeExit) null;
	};

	public static function convertExpr(e:TExpr):Expr {
		inline function fullTypePath(t:ModuleType):GlobalTypePath {
			var info = tInfos(t);
			var mp = info.mtModule.mPath, p = info.mtPath;
			return mp.name == p.name ? p : {pack: mp.pack.concat([mp.name]), name: p.name};
		}
		inline function eopt(e:Null<TExpr>):Null<Expr> return e == null ? null : convertExpr(e);
		var expr:ExprDef = switch e.eexpr {
			case TConst(c): EConst(tconstToConst(c));
			case TLocal(v): EConst(Ident(v.vName == "`trace" ? "trace" : v.vName));
			case TArray(e1, e2): EArray(convertExpr(e1), convertExpr(e2));
			case TBinop(op, e1, e2): EBinop(op, convertExpr(e1), convertExpr(e2));
			case TField(e, f): EField(convertExpr(e), fieldName(f), EFNormal);
			case TTypeExpr(t): Ast.exprOfTypePath(fullTypePath(t), e.epos).expr;
			case TParenthesis(e): EParenthesis(convertExpr(e));
			case TObjectDecl(fl): EObjectDecl(fl.map(f -> ({key: f.key, expr: convertExpr(f.expr)} : ObjectField)));
			case TArrayDecl(el): EArrayDecl(el.map(convertExpr));
			case TCall(e, el): ECall(convertExpr(e), el.map(convertExpr));
			case TNew(c, pl, el):
				var ct = try convertType(TInst(c, pl)) catch (_:TypeExit) convertType(TInst(c, vector()));
				var path = switch ct {
					case CTPath(ptp): ptp;
					case _: throw "Expected constructor type path";
				};
				ENew(path, el.map(convertExpr));
			case TUnop(op, p, e): EUnop(op, p, convertExpr(e));
			case TFunction(f): EFunction(FKAnonymous, {
					fParams: vector(),
					fArgs: f.tfArgs.map(arg -> ({
							name: {name: arg.variable.vName, pos: arg.variable.vPos},
							optional: false,
							meta: arg.variable.vMeta,
							type: mkTypeHint(arg.variable.vType, Globals.nullPos),
							expr: eopt(arg.defaultValue)
						} : FuncArg)),
					fType: mkTypeHint(f.tfType, Globals.nullPos),
					fExpr: convertExpr(f.tfExpr)
				});
			case TVar(v, eo): EVars(vector(
					Ast.mkEVar({name: v.vName, pos: v.vPos}, hasVarFlag(v, VFinal), false, mkTypeHint(v.vType, v.vPos), eopt(eo), v.vMeta)
				));
			case TBlock(el): EBlock(el.map(convertExpr));
			case TIf(e, e1, e2): EIf(convertExpr(e), convertExpr(e1), eopt(e2));
			case TWhile(e1, e2, flag): EWhile(convertExpr(e1), convertExpr(e2), flag);
			case TSwitch(s):
				var cases = s.switchCases.map(c -> ({
						values:c.casePatterns.map(convertExpr), guard:null,
						expr:c.caseExpr.eexpr.match(TBlock([])) ? null : convertExpr(c.caseExpr), pos:c.caseExpr.epos
					} : core.Ast.SwitchCase));
				var de = eopt(s.switchDefault);
				var def = de == null ? null : de.expr.match(EBlock([])) ? ({
					expr: null,
					pos: Globals.nullPos
				} : core.Ast.SwitchDefault) : ({expr: de, pos: de.pos} : core.Ast.SwitchDefault);
				ESwitch(convertExpr(s.switchSubject), cases, def);
			// these are considered complex, so the AST is handled in TMeta(Meta.Ast)
			case TEnumIndex(_) | TEnumParameter(_, _, _): throw "Complex enum AST requires @:ast metadata";
			case TTry(e, catches):
				var e1 = convertExpr(e);
				ETry(e1, catches.map(c -> {
						var ct = try convertTypeHint(c.variable.vType) catch (_:TypeExit) throw "Unconvertible catch type";
						var e = convertExpr(c.expr);
						({
							name: {name: c.variable.vName, pos: c.variable.vPos},
							type: ct,
							expr: e,
							pos: e.pos
						} : core.Ast.Catch);
					}));
			case TReturn(e): EReturn(eopt(e));
			case TBreak: EBreak;
			case TContinue: EContinue;
			case TThrow(e): EThrow(convertExpr(e));
			case TCast(e, t):
				var ct = if (t == null) null else {
					var t = switch t {
						case TClassDecl(c): TInst(c, vector());
						case TEnumDecl(e): TEnum(e, vector());
						case TTypeDecl(t): TType(t, vector());
						case TAbstractDecl(a): TAbstract(a, vector());
					};
					try convertTypeHint(t)
					catch (_:TypeExit) throw "Unconvertible cast type";
				};
				ECast(convertExpr(e), ct);
			case TMeta(m, _) if (StdType.enumEq(m.meta, Meta.Ast) && m.exprs.length == 1): m.exprs[0].expr;
			case TMeta(m, e): EMeta(m, convertExpr(e));
			case TIdent(s): EConst(Ident(s));
		};
		return {expr: expr, pos: e.epos};
	}
}

enum Semantics {
	VariableSemantics;
	ReferenceSemantics;
	ValueSemantics;
}

class ExtType {
	public static function isMono(t:T):Bool return t.match(TMono({tmType: null}));

	static function absIs(t:T, name:String):Bool return switch t {
		case TAbstract(a, _) if (a.aPath.pack.length == 0 && a.aPath.name == name): true;
		case _: false;
	};

	public static function isVoid(t:T):Bool return absIs(t, "Void");

	public static function isInt(t:T):Bool return absIs(t, "Int");

	public static function isFloat(t:T):Bool return absIs(t, "Float");

	public static function isNumeric(t:T):Bool return isFloat(t) || isInt(t);

	public static function isString(t:T):Bool return switch t {
		case TInst(c, _) if (c.clPath.pack.length == 0 && c.clPath.name == "String"): true;
		case _: false;
	};

	public static function isBool(t:T):Bool return absIs(t, "Bool");

	public static function isRest(t:T):Bool return switch t {
		case TType(t, _) if (t.tPath.pack.join(".") == "haxe.extern" && t.tPath.name == "Rest"): true;
		case TAbstract(a, _) if (a.aPath.pack.join(".") == "haxe" && a.aPath.name == "Rest"): true;
		case _: false;
	};

	public static function isTypeParam(t:T):Bool return t.match(TInst({clKind: KTypeParameter(_)}, _));

	public static function semanticsName(sem:Semantics):String return switch sem {
		case VariableSemantics: "variable";
		case ReferenceSemantics: "reference";
		case ValueSemantics: "value";
	};

	public static function hasSemantics(t:T, sem:Semantics):Bool return hasSemanticsLoop(t, semanticsName(sem));

	static function hasSemanticsLoop(t:T, name:String):Bool return switch t {
		case TInst(c, _): Ast.hasMetaOption(c.clMeta, Meta.Semantics, name);
		case TEnum(en, _): Ast.hasMetaOption(en.eMeta, Meta.Semantics, name);
		case TType(td, tl): Ast.hasMetaOption(td.tMeta, Meta.Semantics, name) || hasSemanticsLoop(applyTypedef(td, tl), name);
		case TAbstract(a, _): Ast.hasMetaOption(a.aMeta, Meta.Semantics, name);
		case TLazy(f): hasSemanticsLoop(lazyType(f), name);
		case TMono(r): r.tmType != null && hasSemanticsLoop(r.tmType, name);
		case _: false;
	};

	public static function hasVariableSemantics(t:T):Bool return hasSemantics(t, VariableSemantics);

	public static function hasReferenceSemantics(t:T):Bool return hasSemantics(t, ReferenceSemantics);

	public static function hasValueSemantics(t:T):Bool return hasSemantics(t, ValueSemantics);
}

class TOther {
	public static final noMeta:Metadata = [];

	public static function mkEnum(m:ModuleDef, path:GlobalTypePath, pos:Pos, namePos:Pos):TEnum return {
		ePath: path,
		eModule: m,
		ePos: pos,
		eNamePos: namePos,
		eDoc: null,
		eMeta: [],
		eParams: vector(),
		eUsing: [],
		eRestore: function() {},
		ePrivate: false,
		eFlags: 0,
		eConstrs: new StringMap(),
		eNames: [],
		eType: mkMono()
	};

	public static function mkAbstract(m:ModuleDef, path:GlobalTypePath, pos:Pos, namePos:Pos):TAbstract return {
		aPath: path,
		aPrivate: false,
		aModule: m,
		aPos: pos,
		aNamePos: namePos,
		aDoc: null,
		aParams: vector(),
		aUsing: [],
		aRestore: function() {},
		aMeta: [],
		aFrom: [],
		aTo: [],
		aFromField: [],
		aToField: [],
		aOps: [],
		aUnops: [],
		aImpl: null,
		aArray: [],
		aThis: mkMono(),
		aRead: null,
		aWrite: null,
		aConstructor: null,
		aExtern: false,
		aEnum: false,
		aCall: null
	};

	public static function sClassPath(c:TClass):String return Globals.sTypePath(switch c.clKind {
		case KAbstractImpl(a): a.aPath;
		case _: c.clPath;
	});
}

// port: `TClass` is also the typed record name; the helper module uses a distinct name.
class TClassTools {
	public static function getMemberFields(selfToo:Bool, c0:TClass, tl:TParams):StringMap<{cls:TClass, field:TClassField}> {
		function loop(acc:StringMap<{cls:TClass, field:TClassField}>, c:TClass, tl:TParams):StringMap<{cls:TClass, field:TClassField}> {
			var apply = function(t) return applyParams(c.clParams, tl, t);
			if (selfToo || c != c0) for (cf in c.clOrderedFields) if (!acc.exists(cf.cfName)) {
				if (tl.length != 0) {
					var copy:TClassField = core.ds.Record.copy(cf);
					copy.cfType = apply(cf.cfType);
					cf = copy;
				}
				acc.set(cf.cfName, {cls: c, field: cf});
			}
			if (hasClassFlag(c, CInterface)) for (impl in c.clImplements) acc = loop(acc, impl.cls, impl.params.map(apply));
			else if (c.clSuper != null) acc = loop(acc, c.clSuper.cls, c.clSuper.params.map(apply));
			return acc;
		}
		return loop(new StringMap(), c0, tl);
	}

	public static function getAllSuperFields(c:TClass):StringMap<{cls:TClass, field:TClassField}> return getMemberFields(false, c,
		extractParamTypes(c.clParams));

	public static function getAllFields(c:TClass,
			tl:TParams):StringMap<{cls:TClass, field:TClassField}> return getMemberFields(true, c, tl);

	public static function getOverriddenFields(c:TClass, cf:TClassField):Array<TClassField> {
		var acc = [];
		while (c.clSuper != null) {
			c = c.clSuper.cls;
			var f = c.clFields.get(cf.cfName);
			if (f != null) acc.unshift(f);
		}
		return acc;
	}

	public static function addField(c:TClass, cf:TClassField):Void {
		if (hasClassFieldFlag(cf, CfStatic)) {
			c.clStatics.set(cf.cfName, cf);
			c.clOrderedStatics.unshift(cf);
		} else {
			c.clFields.set(cf.cfName, cf);
			c.clOrderedFields.unshift(cf);
		}
	}

	public static function getMapFunction(c:TClass, tl:TParams):T->T {
		function loop(map:T->T, c:TClass):T->T {
			if (c.clSuper == null) return map;
			var sup = c.clSuper;
			return loop(function(t) return map(applyParams(sup.cls.clParams, sup.params, t)), sup.cls);
		}
		return loop(function(t) return applyParams(c.clParams, tl, t), c);
	}

	public static function getClInit(c:TClass):Null<TExpr> return c.clInit == null ? null : c.clInit.cfExpr;

	public static function modifyClInit(c:TClass, e:TExpr, append:Bool):Void {
		if (c.clInit != null) c.clInit.cfExpr = c.clInit.cfExpr != null && append ? concat(c.clInit.cfExpr, e) : e;
		else {
			var cf = mkField("__init__", tDynamic, Globals.nullPos, Globals.nullPos);
			cf.cfExpr = e;
			c.clInit = cf;
		}
	}

	public static function getSingularInterfaceField(fields:Array<TClassField>):Null<TClassField> {
		// Re-declarations of java.lang.Object members (equals/hashCode/toString)
		// on an interface must not count toward the SAM check — JLS §9.8.
		// Matched by name+arity since these are unique on Object.
		inline function isObjectMember(cf:TClassField):Bool return switch [cf.cfName, follow(cf.cfType)] {
			case ["equals", TFun({args: [_]})] | ["hashCode", TFun({args: []})] | ["toString", TFun({args: []})]: true;
			case _: false;
		};
		var result:Null<TClassField> = null;
		for (cf in fields) if (!hasClassFieldFlag(cf, CfDefault) && !isObjectMember(cf) && cf.cfKind.match(Method(MethNormal))) {
			if (result != null) return null;
			result = cf;
		}
		return result;
	}

	public static function addClInit(c:TClass, e:TExpr):Void modifyClInit(c, e, true);

	public static function setClInit(c:TClass, e:TExpr):Void modifyClInit(c, e, false);
}
