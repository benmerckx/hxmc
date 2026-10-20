package typing;

import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Globals.*;
import core.Texpr;
import core.Texpr.Builder;
import core.TPrinting.Printer;
import core.TUnification;
import core.TUnification.TUnification.*;
import core.WithType.WithTypeValue;
import context.Typecore.Typer as TyperContext;
import context.Typecore.FieldAccess as FieldAccessData;
import context.display.DeprecationCheck;
import core.ds.InvalidArgument;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TPrinting.*;
import core.Globals;
import core.Meta;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.AbstractCast;
import context.Typecore.TyperManager;
import typing.FieldAccess.*;

enum AccessKind {
	// Access is not possible or allowed.
	AKNo(access:AccessKind, pos:Pos);
	// Access on arbitrary expression.
	AKExpr(e:TExpr);
	// Safe navigation access chain
	AKSafeNav(sn:SafeNavAccess);
	// Access on non-property field.
	AKField(fa:context.Typecore.FieldAccess);
	// Access on property field. The field is the property, not the accessor.
	AKAccessor(fa:context.Typecore.FieldAccess);
	// Access via static extension.
	AKUsingField(sea:StaticExtensionAccess);
	// Access via static extension on property field. The field is the property, not the accessor.
	// This currently only happens on abstract properties.
	AKUsingAccessor(sea:StaticExtensionAccess);
	// Access on abstract via array overload.
	AKAccess(a:TAbstract, params:TParams, c:TClass, e1:TExpr, e2:TExpr);
	// Access on abstract via resolve method.
	AKResolve(sea:StaticExtensionAccess, name:String);
}

typedef SafeNavAccess = {var snPos:Pos; // position of the safe navigation chain start (the initial ?.field expression)
	var snBase:TExpr; // starting value to be checked for null
	var snTempVar:Null<TExpr>; // temp var declaration to store complex base expression
	var snAccess:AccessKind;} // safe navigation access to be done if the base value is not null

enum ObjectDeclKind {
	ODKWithStructure(a:TAnon);
	ODKWithClass(c:TClass, params:TParams);
	ODKPlain;
	ODKFailed;
}

enum FromKind {
	FromType;
	FromField;
}

// How values of a type can be accessed by index: the element type, how to read the element at an index and how
// to read the length. For loops and array patterns use this (#8012).
// port: array_access, renamed: ArrayAccess is Haxe's.
typedef ArrayAccessData = {var aaType:T; var aaGet:TExpr->TExpr->T->Pos->TExpr; var aaLength:TExpr->Pos->TExpr;}

class MetaConfig {
	public static function asBool(e:Expr):Bool return switch e.expr {
		case EConst(Ident("true")): true;
		case EConst(Ident("false")): false;
		case _: throw new InvalidArgument("bool");
	};

	public static function readArgConfig(meta:MetaTag, f:{name:String, expr:Expr}->Void, l:Metadata):Void {
		for (m in l) if (m.meta == meta) for (e in m.exprs) switch e.expr {
			case EConst(Ident(s)):
				f({name: s, expr: {expr: EConst(Ident("true")), pos: Globals.nullPos}});
			case EBinop(OpAssign, {expr: EConst(Ident(s))}, e2):
				f({name: s, expr: e2});
			case _:
		}
	}
}

class AbstractFromConfig {
	public var ignoredByInference = false;

	public function new() {}

	public static function make():AbstractFromConfig return new AbstractFromConfig();

	public static function updateConfigFromMeta(config:AbstractFromConfig, ml:Metadata):AbstractFromConfig {
		MetaConfig.readArgConfig(MetaTag.From, function(arg) {
			if (arg.name == "ignoredByInference") try config.ignoredByInference = MetaConfig.asBool(arg.expr)
			catch (_:InvalidArgument) {}
		}, ml);
		return config;
	}
}

class ValueReference {
	final ctx:TyperContext;
	final vars:Array<{variable:TVar, expr:TExpr}> = [];

	public function new(ctx:TyperContext) {
		this.ctx = ctx;
	}

	public function getVars():Array<{variable:TVar, expr:TExpr}> return vars.copy();

	public function asVar(name:String, e:TExpr):TExpr {
		var v = allocVar(VGenerated, name, e.etype, e.epos);
		vars.push({variable: v, expr: e});
		return mk(TLocal(v), v.vType, v.vPos);
	}

	function getExprAux(depth:Int, name:String, e:TExpr):TExpr return switch Texpr.skip(e).eexpr {
		case TLocal(_) | TTypeExpr(_) | TConst(_): e;
		case TField(ef, fa) if (depth == 0): mk(TField(getExprAux(depth + 1, "fh", ef), fa), e.etype, e.epos);
		case TArray(e1, e2) if (depth == 0):
			var e1 = getExprAux(depth + 1, "base", e1);
			var e2 = getExprAux(depth + 1, "index", e2);
			mk(TArray(e1, e2), e.etype, e.epos);
		case _: asVar(name, e);
	};

	public function getExpr(name:String, e:TExpr):TExpr return getExprAux(0, name, e);

	public function getExprPart(name:String, e:TExpr):TExpr return getExprAux(1, name, e);

	public function toTexpr(e:TExpr):TExpr {
		if (vars.length == 0) return e;
		var el = vars.map(pair -> mk(TVar(pair.variable, pair.expr), ctx.t.tvoid, pair.variable.vPos));
		var block = mk(TBlock(el.concat([e])), e.etype, e.epos);
		return mk(TMeta({meta: MetaTag.MergeBlock, exprs: [], pos: Globals.nullPos}, block), block.etype, block.epos);
	}

	public function toTexprEl(el:Array<TExpr>, e:TExpr):TExpr {
		var declarations = vars.map(pair -> mk(TVar(pair.variable, pair.expr), ctx.t.tvoid, pair.variable.vPos));
		var block = mk(TBlock(declarations.concat(el).concat([e])), e.etype, e.epos);
		return mk(TMeta({meta: MetaTag.MergeBlock, exprs: [], pos: Globals.nullPos}, block), block.etype, block.epos);
	}
}

class TyperBase {
	public static var typeCallTargetRef:TyperContext->Expr->Array<Expr>->WithTypeValue->Null<Pos>->AccessKind = function(_, _, _, _, _) {
		throw "Uninitialized typeCallTargetRef";
	};
	public static var typeAccessRef:TyperContext->ExprDef->Pos->AccessMode->WithTypeValue->AccessKind = function(_, _, _, _, _) {
		throw "Uninitialized typeAccessRef";
	};

	public static function isLowerIdent(s:String, p:Pos):Bool {
		try return Ast.isLowerIdent(s)
		catch (e:InvalidArgument) {
			return raiseTypingError(e.message, p);
		}
	}

	public static function getThis(ctx:TyperContext, p:Pos):TExpr return switch ctx.e.curfun {
		case FunStatic: raiseTypingError("Cannot access this from a static function", p);
		case FunMemberClassLocal | FunMemberAbstractLocal:
			var v = ctx.f.vthis;
			if (v == null) {
				if (ctx.e.curfun == FunMemberAbstractLocal) {
					v = ctx.f.locals.findOpt("this");
					if (v == null) throw core.ds.NotFound.raise();
					addVarFlag(v, VUsedByTyper);
				} else v = addLocal(ctx, VGenerated, genLocalPrefix + "this", ctx.c.tthis, p);
				ctx.f.vthis = v;
			} else ctx.f.locals = ctx.f.locals.add(v.vName, v);
			mk(TLocal(v), ctx.c.tthis, p);
		case FunMemberAbstract:
			var v = ctx.f.locals.findOpt("this");
			if (v == null) raiseTypingError("Cannot reference this abstract here", p);
			mk(TLocal(v), v.vType, p);
		case FunConstructor | FunMember if (TyperManager.isCoroutineContext(ctx)):
			// For coroutine member methods, emit `TLocal v` instead of `TConst TThis`.
			// `typeloadFunction.ml` will later inject  var v = TConst TThis  before the
			// first use of `v`, so the typed body looks like:
			//     var _this = this;     <- TVar(v, Some(TConst TThis))
			//     ... body using TLocal v ...
			// The coroutine transformer detects `TConst TThis` in the initialiser and
			// rewrites it to `_hx_continuation._hx_captured` (inline path) or
			// `_hx_gthis` (thunk path).  All remaining `TLocal v` usages then refer to
			// this cached value, avoiding repeated field accesses.
			var v = ctx.f.vthis;
			if (v == null) {
				v = addLocal(ctx, VGenerated, genLocalPrefix + "this", ctx.c.tthis, p);
				ctx.f.vthis = v;
			}
			mk(TLocal(v), ctx.c.tthis, p);
		case FunConstructor | FunMember: mk(TConst(TThis), ctx.c.tthis, p);
	};

	public static function getStoredTypedExpr(ctx:TyperContext,
			id:Int):TExpr return Texpr.duplicateTvars(e -> getThis(ctx, e.epos), ctx.com.partScope.storedTypedExprs.find(id));

	public static function typeStoredExpr(ctx:TyperContext, e1:Expr):TExpr {
		var id = switch e1.expr {
			case EConst(Int(s, _)): Std.parseInt(s);
			case _: throw "Invalid stored expression id";
		};
		return getStoredTypedExpr(ctx, id);
	}

	public static function assignToThisIsAllowed(ctx:TyperContext):Bool return switch ctx.c.curclass.clKind {
		case KAbstractImpl(_): switch ctx.f.curfield.cfKind {
				case Method(MethInline): true;
				case Method(_) if (hasClassFieldFlag(ctx.f.curfield, CfAbstractConstructor)): true;
				case _: false;
			}
		case _: false;
	};

	public static function typeModuleTypeSimple(mt:ModuleType, p:Pos):TExpr return switch mt { // No checks and building
		case TClassDecl(c): mk(TTypeExpr(TClassDecl(c)), c.clType, p);
		case TEnumDecl(e): mk(TTypeExpr(TEnumDecl(e)), e.eType, p);
		case TTypeDecl(s):
			var t = applyTypedef(s, s.tParams.map(_ -> mkMono()));
			switch follow(t) {
				case TEnum(e, _): typeModuleTypeSimple(TEnumDecl(e), p);
				case TInst(c, _): typeModuleTypeSimple(TClassDecl(c), p);
				case TAbstract(a, _): typeModuleTypeSimple(TAbstractDecl(a), p);
				case _: throw "Invalid simple module type";
			}
		case TAbstractDecl(a) if (a.aImpl != null): typeModuleTypeSimple(TClassDecl(a.aImpl), p);
		case TAbstractDecl(a):
			var tmp = abstractModuleType(a, []);
			mk(TTypeExpr(TAbstractDecl(a)), TType(tmp, []), p);
	};

	public static function typeModuleType(ctx:TyperContext, t:ModuleType, p:Pos):TExpr {
		function loop(t:ModuleType, tparams:Null<TParams>):TExpr return switch t {
			case TClassDecl({clKind: KGenericBuild(_)}):
				var info = InstanceBuilder.getBuildInfo(ctx, t, p);
				var t1 = info.buildApply(tparams == null ? [] : tparams);
				var mt:ModuleType;
				try mt = moduleTypeOfType(t1)
				catch (_:core.ds.Exit) {
					if (follow(t1) == tDynamic) mt = Typeload.loadTypeDef(ctx, p, mkTypePath([], "Dynamic"));
					else mt = raiseTypingError("Invalid module type", p);
				}
				loop(mt, null);
			case TClassDecl(c): mk(TTypeExpr(TClassDecl(c)), c.clType, p);
			case TEnumDecl(e): mk(TTypeExpr(TEnumDecl(e)), e.eType, p);
			case TTypeDecl(s):
				var t1 = applyTypedef(s, s.tParams.map(_ -> spawnMonomorph(ctx, p)));
				DeprecationCheck.checkTypedef(createDeprecationContext(ctx), s, p);
				switch follow(t1) {
					case TEnum(e, params): loop(TEnumDecl(e), params);
					case TInst(c, params): loop(TClassDecl(c), params);
					case TAbstract(a, params): loop(TAbstractDecl(a), params);
					case _: raiseTypingError(Globals.sTypePath(s.tPath) + " is not a value", p);
				}
			case TAbstractDecl(a) if (a.aImpl != null): loop(TClassDecl(a.aImpl), tparams);
			case TAbstractDecl(a):
				if (!Meta.has(MetaTag.RuntimeValue, a.aMeta)) raiseTypingError(Globals.sTypePath(a.aPath) + " is not a value", p);
				var tmp = abstractModuleType(a, []);
				mk(TTypeExpr(TAbstractDecl(a)), TType(tmp, []), p);
		};
		return loop(t, null);
	}

	public static function mkModuleTypeAccess(ctx:TyperContext, t:ModuleType, p:Pos):AccessKind return AKExpr(typeModuleType(ctx, t, p));

	public static function sFieldAccess(tabs:String, fa:FieldAccessData):String {
		var host = switch fa.faHost {
			case FHStatic(c): "FHStatic(" + Globals.sTypePath(c.clPath) + ")";
			case FHInstance(c, tl): "FHInstance(" + Globals.sTypePath(c.clPath) + ", " + sTypes(tl) + ")";
			case FHAbstract(a, tl, c): "FHAbstract("
				+ Globals.sTypePath(a.aPath)
				+ ", "
				+ sTypes(tl)
				+ ", "
				+ Globals.sTypePath(c.clPath)
				+ ")";
			case FHAnon: "FHAnon";
		};
		return Printer.sRecordFields(tabs, [
			{name: "fa_on", value: pretty(fa.faOn)},
			{name: "fa_field", value: fa.faField.cfName},
			{name: "fa_host", value: host},
			{name: "fa_inline", value: Std.string(fa.faInline)},
			{name: "fa_pos", value: position(fa.faPos)}
		]);
	}

	static function pretty(e:TExpr):String return sExprPretty(true, "", false, t -> sType(printContext(), t), e);

	static function position(p:Pos):String return p.pfile + "(" + p.pmin + "-" + p.pmax + ")";

	public static function sStaticExtensionAccess(sea:StaticExtensionAccess):String return Printer.sRecordFields("", [
		{name: "se_this", value: pretty(sea.seThis)},
		{name: "se_access", value: sFieldAccess("\t", sea.seAccess)}
	]);

	public static function sAccessKind(acc:AccessKind):String return switch acc {
		case AKNo(a, _): "AKNo " + sAccessKind(a);
		case AKExpr(e): "AKExpr " + pretty(e);
		case AKSafeNav(sn): "AKSafeNav(" + sSafeNavAccess(sn) + ")";
		case AKField(fa): "AKField(" + sFieldAccess("", fa) + ")";
		case AKAccessor(fa): "AKAccessor(" + sFieldAccess("", fa) + ")";
		case AKUsingField(sea): "AKUsingField(" + sStaticExtensionAccess(sea) + ")";
		case AKUsingAccessor(sea): "AKUsingAccessor(" + sStaticExtensionAccess(sea) + ")";
		case AKAccess(a, tl, c, e1, e2): "AKAccess(" + Globals.sTypePath(a.aPath) + ", ["
			+ tl.map(t -> sType(printContext(), t)).join(", ") + "], " + Globals.sTypePath(c.clPath) + ", " + pretty(e1) + ", "
			+ pretty(e2) + ")";
		case AKResolve(sea, name): "AKResolve(" + sStaticExtensionAccess(sea) + ", " + name + ")";
	};

	public static function sSafeNavAccess(sn:SafeNavAccess):String return Printer.sRecordFields("", [
		{name: "sn_base", value: pretty(sn.snBase)},
		{name: "sn_temp_var", value: sn.snTempVar == null ? "None" : "Some " + pretty(sn.snTempVar)},
		{name: "sn_access", value: sAccessKind(sn.snAccess)}
	]);

	public static function sDotPathPart(part:DotPathPart):String return Printer.sRecordFields("", [
		{name: "name", value: part.name},
		{name: "case", value: part.caseKind == PUppercase ? "PUppercase" : "PLowercase"},
		{name: "pos", value: position(part.pos)}
	]);

	public static function getConstructibleConstraint(ctx:TyperContext, tl:TParams, p:Pos):Null<TSignature> {
		inline function extract(t:T):TSignature return switch follow(t) {
			case TFun({args: tl, ret: tr}): {args: tl, ret: tr};
			case _: raiseTypingError("Constructible type parameter should be function", p);
		};
		for (t in tl) switch follow(t) {
			case TAnon(a):
				if (a.aFields.exists("new")) return extract(a.aFields.get("new").cfType);
			case TAbstract({aPath: {pack: ["haxe"], name: "Constructible"}}, [t1]):
				return extract(t1);
			case TInst({clKind: KTypeParameter(ttp)}, _):
				var result = getConstructibleConstraint(ctx, getConstraints(ttp), p);
				if (result != null) return result;
			case _:
		}
		return null;
	}

	public static function unifyStaticExtension(ctx:TyperContext, e:TExpr, t:T, p:Pos):TExpr {
		inline function check(t:T):Bool return switch follow(t) {
			case TAbstract(a, _) if (Meta.has(MetaTag.MultiType, a.aMeta)): true;
			case _: false;
		};
		if (check(e.etype) || check(t)) return AbstractCast.castOrUnifyRaise(ctx, t, e, p);
		var config = defaultUnificationContext();
		config.allowDynamicToCast = false;
		core.TUnification.unifyCustom(config, e.etype, t);
		return e;
	}

	public static function getAbstractFroms(ctx:TyperContext, a:TAbstract, pl:TParams):Array<{kind:FromKind, type:T}> {
		var l = a.aFrom.map(t -> {kind: FromType, type: applyParams(a.aParams, pl, t)});
		for (pair in a.aFromField) {
			var f = pair.field;
			// We never want to use the @:from we're currently in because that's recursive (see #10604)
			if (f == ctx.f.curfield
				|| AbstractFromConfig.updateConfigFromMeta(AbstractFromConfig.make(), f.cfMeta).ignoredByInference) continue;
			switch follow(core.TFunctions.fieldType(f)) {
				case TFun({args: [{type: v}], ret: t}):
					try {
						typeEq(EqStrict, t, TAbstract(a, pl.map(duplicate))); // unify fields monomorphs
						l.unshift({kind: FromField, type: v});
					} catch (_:core.TUnification.Unify_error) {}
				case _:
			}
		}
		return l;
	}

	public static function getNextArrayElement(arr:TExpr, index:TExpr, t:T, p:Pos):TExpr return mk(TArray(arr, index), t, p);

	public static function getArrayLength(ctx:TyperContext, arr:TExpr, p:Pos):TExpr {
		var fa;
		try {
			fa = quickField(arr.etype, "length");
		} catch (ex:core.ds.NotFound) {
			return Error.raiseMsg('Could not find field length on ${core.TPrinting.sTypeKind(arr.etype)}', arr.epos);
		}
		return mk(TField(arr, fa), ctx.com.basic.tint, p);
	}

	public static function getArrayAccess(ctx:TyperContext, t:T, p:Pos):ArrayAccessData return switch follow(t) {
		case TInst(c = {clArrayAccess: pt}, pl) if (pt != null):
			var length = c.clFields.get("length");
			if (length == null || c.clFields.exists("iterator")) throw core.ds.NotFound.raise();
			switch follow(length.cfType) {
				case TAbstract({aPath: {pack: [], name: "Int"}}, []):
				case _: throw core.ds.NotFound.raise();
			}
			{aaType: applyParams(c.clParams, pl, pt), aaGet: getNextArrayElement, aaLength: getArrayLength.bind(ctx)};
		case TAbstract(a = {aImpl: c}, tl) if (c != null):
			var length = core.ds.PMap.find("get_length", c.clStatics);
			function getLength(e:TExpr,
					p:Pos):TExpr return CallUnification.makeStaticCallBetter(ctx, c, length, tl, [e], ctx.com.basic.tint, p);
			switch follow(length.cfType) {
				case TFun(s): switch follow(s.ret) {
						case TAbstract({aPath: {pack: [], name: "Int"}}, _):
						case _: throw core.ds.NotFound.raise();
					}
				case _: throw core.ds.NotFound.raise();
			}
			try {
				// first try: do we have an @:arrayAccess getter field?
				var access = AbstractCast.findArrayReadAccessRaise(ctx, a, tl, mk(TConst(TNull), ctx.t.tint, p), p);
				function getNext(base:TExpr, index:TExpr, t:T,
						p:Pos):TExpr return CallUnification.makeStaticCallBetter(ctx, c, access.field, tl, [base, index], access.ret, p);
				{aaType: access.ret, aaGet: getNext, aaLength: getLength};
			} catch (ex:core.ds.NotFound) {
				// second try: do we have @:arrayAccess on the abstract itself?
				if (!core.Meta.has(MetaTag.ArrayAccess, a.aMeta)
					// let's allow this only for core-type abstracts
					|| !core.Meta.has(MetaTag.CoreType, a.aMeta)
					// in which case we assume that a singular type parameter is the element type
					|| tl.length != 1) throw core.ds.NotFound.raise();
				{aaType: tl[0], aaGet: getNextArrayElement, aaLength: getLength};
			}
		case _: throw core.ds.NotFound.raise();
	};

	public static function safeNavBranch(ctx:TyperContext, sn:SafeNavAccess, fThen:Void->TExpr):TExpr {
		// generate null-check branching for the safe navigation chain
		var eobj = sn.snBase, enull = Builder.makeNull(eobj.etype, sn.snPos);
		var eneq = Builder.binop(OpNotEq, eobj, enull, ctx.t.tbool, sn.snPos);
		var ethen = fThen(), tnull = ctx.t.tnull(ethen.etype);
		if (!isNullable(ethen.etype)) ethen = mk(TCast(ethen, null), tnull, ethen.epos);
		var eelse = Builder.makeNull(tnull, sn.snPos),
			eif = mk(TIf(eneq, ethen, eelse), tnull, sn.snPos);
		return sn.snTempVar == null ? eif : mk(TBlock([sn.snTempVar, eif]), eif.etype, eif.epos);
	}

	public static function getSafeNavBase(ctx:TyperContext, eobj:TExpr):{base:TExpr, tempVar:Null<TExpr>}
		return switch Texpr.skip(eobj).eexpr {
			case TLocal(_) | TTypeExpr(_) | TConst(_): {base: eobj, tempVar: null};
			case _:
				var v = allocVar(VGenerated, "tmp", eobj.etype, eobj.epos);
				var temp = mk(TVar(v, eobj), ctx.t.tvoid, v.vPos);
				{base: mk(TLocal(v), v.vType, v.vPos), tempVar: temp};
		};
}
