package typing;

import core.Globals.Pos;
import core.MetaList.StrictMeta as MetaTag;
import core.Ast;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TPrinting.*;
import core.Texpr.Builder;
import core.ds.NotFound;
import core.ds.VectorTools.vector;
import context.Typecore.Typer as TyperContext;
import context.Typecore.*;
import context.AbstractCast;

using core.ds.VectorTools;

// How values of a type can be accessed by index: the element type, how to read the element at an index and how
// to read the length. For loops and array patterns use this (#8012). Abstracts follow how the typer types `e[i]` and
// `e.length` on them: an @:arrayAccess getter, @:arrayAccess on the abstract or a conversion to an array, and a
// get_length or a length forwarded by @:forward.
// port: array_access, renamed: ArrayAccess is Haxe's, and this module's.
typedef ArrayAccessData = {var aaType:T; var aaGet:ArrayGet; var aaLength:ArrayLength;}

enum ArrayGet {
	AGIndex; // e[i]
	AGDynamic; // e[i] of a Dynamic value, typed as a monomorph of its own
	AGCall(c:TClass, cf:TClassField, tl:TParams); // a call of the abstract's @:arrayAccess getter
}

enum ArrayLength {
	ALField; // the class's length field
	ALCall(c:TClass, cf:TClassField, tl:TParams); // a call of the abstract's get_length
	ALForward(t:T, length:ArrayLength); // the length of the abstract's underlying type, which @:forward forwards
}

class ArrayAccess {
	public static function getArrayLength(ctx:TyperContext, arr:TExpr, p:Pos):TExpr {
		var fa = try quickField(arr.etype, "length") catch (_:NotFound) core.Error.raiseMsg('Could not find field length on ${sTypeKind(arr.etype)}',
			arr.epos);
		var t = switch fa {
			case FDynamic(_): tDynamic;
			case _: ctx.com.basic.tint;
		}
		return mk(TField(arr, fa), t, p);
	}

	// The element of e[i], for a type which isn't an abstract with @:arrayAccess functions, the way the typer finds it:
	// through @:arrayAccess on an abstract to its underlying type, or by unifying with an array.
	// port: the pair (get, element type) as {get, t}.
	public static function getArrayElement(ctx:TyperContext, t:T, p:Pos):{get:ArrayGet, t:T} return switch follow(t) {
		case TInst({clPath: {pack: [], name: "Array" | "ArrayAccess"}}, [pt]):
			// This case is not technically needed because the default case would handle it, but it avoids the monomorph
			// creation and unification there.
			{get: AGIndex, t: pt};
		case TDynamic(null):
			{get: AGDynamic, t: tDynamic};
		case TInst(c, tl) if (c.clArrayAccess != null):
			{get: AGIndex, t: applyParams(c.clParams, tl, c.clArrayAccess)};
		case TInst(c, tl) if (c.clSuper != null):
			var r = getArrayElement(ctx, TInst(c.clSuper.cls, c.clSuper.params), p);
			{get: r.get, t: applyParams(c.clParams, tl, r.t)};
		case TAbstract(a, tl) if (core.Meta.has(MetaTag.ArrayAccess, a.aMeta) && !core.Meta.has(MetaTag.CoreType, a.aMeta)):
			getArrayElement(ctx, applyParams(a.aParams, tl, a.aThis), p);
		case _:
			var pt = spawnMonomorph(ctx, p);
			try unifyRaise(t, ctx.t.tarray(pt), p) catch (err:Dynamic) {
				switch err {
					case(core.ds.ExceptionTools.typing(_) => Some({errMessage: Unify(_)})): throw NotFound.raise();
					case _: throw err;
				}
			}
			{get: AGIndex, t: pt};
	};

	// The length of an abstract: its get_length, or the length of its underlying type if @:forward forwards it.
	public static function getAbstractLength(a:TAbstract, c:TClass, tl:TParams):ArrayLength {
		var cfLength = try core.ds.PMap.find("get_length", c.clStatics) catch (_:NotFound) null;
		if (cfLength != null) {
			switch follow(cfLength.cfType) {
				case TFun(s): switch follow(s.ret) {
						case TAbstract({aPath: {pack: [], name: "Int"}}, _):
						case _: throw NotFound.raise();
					}
				case _: throw NotFound.raise();
			}
			return ALCall(c, cfLength, tl);
		}
		var forwards = try {
			var entry = core.Meta.get(MetaTag.Forward, a.aMeta);
			entry.exprs.length == 0 || entry.exprs.exists(function(e) return switch e.expr {
				case EConst(Ident("length") | String("length", _)): true;
				case _: false;
			});
		} catch (_:NotFound) false;
		if (!forwards) throw NotFound.raise();
		var t = core.Abstract.getUnderlyingType(a, tl, true);
		return ALForward(t, getForwardedLength(t));
	}

	public static function getForwardedLength(t:T):ArrayLength return switch follow(t) {
		case t = TInst(_, _):
			switch quickField(t, "length") {
				case FInstance(c, tl, cf):
					switch follow(applyParams(c.clParams, tl, cf.cfType)) {
						case TAbstract({aPath: {pack: [], name: "Int"}}, []): ALField;
						case _: throw NotFound.raise();
					}
				case _:
					throw NotFound.raise();
			}
		case TAbstract(a = {aImpl: c}, tl) if (c != null):
			getAbstractLength(a, c, tl);
		case _:
			throw NotFound.raise();
	};

	public static function getArrayAccess(ctx:TyperContext, t:T, p:Pos):ArrayAccessData return switch follow(t) {
		case TInst({clPath: {pack: [], name: "Array"}}, [pt]):
			{aaType: pt, aaGet: AGIndex, aaLength: ALField};
		case TDynamic(null):
			{aaType: tDynamic, aaGet: AGDynamic, aaLength: ALField};
		case TInst(c = {clArrayAccess: pt}, pl) if (pt != null):
			var length = c.clFields.get("length");
			if (length == null) throw NotFound.raise();
			switch follow(length.cfType) {
				case TAbstract({aPath: {pack: [], name: "Int"}}, []):
				case _: throw NotFound.raise();
			}
			{aaType: applyParams(c.clParams, pl, pt), aaGet: AGIndex, aaLength: ALField};
		case TAbstract(a = {aImpl: c}, tl) if (c != null):
			var aaLength = getAbstractLength(a, c, tl);
			try {
				// first try: do we have an @:arrayAccess getter field?
				var access = AbstractCast.findArrayReadAccessRaise(ctx, a, tl, mk(TConst(TNull), ctx.t.tint, p), p);
				{aaType: access.ret, aaGet: AGCall(c, access.field, tl), aaLength: aaLength};
			} catch (_:NotFound) {
				// second try: do we have @:arrayAccess on a core-type abstract?
				if (core.Meta.has(MetaTag.ArrayAccess, a.aMeta) && core.Meta.has(MetaTag.CoreType, a.aMeta)) {
					// in which case we assume that a singular type parameter is the element type
					if (tl.length != 1) throw NotFound.raise();
					{aaType: tl[0], aaGet: AGIndex, aaLength: aaLength};
				} else {
					// otherwise, as the typer does when the abstract has no @:arrayAccess function
					if (a.aArray.length != 0) throw NotFound.raise();
					var element = getArrayElement(ctx, t, p);
					{aaType: element.t, aaGet: element.get, aaLength: aaLength};
				}
			}
		case _:
			throw NotFound.raise();
	};

	public static function makeArrayGet(ctx:TyperContext, aa:ArrayAccessData, eBase:TExpr, eIndex:TExpr, p:Pos):TExpr return switch aa.aaGet {
		case AGIndex: Builder.makeArrayAccess(eBase, eIndex, aa.aaType, p);
		case AGDynamic: Builder.makeArrayAccess(eBase, eIndex, spawnMonomorph(ctx, p), p);
		case AGCall(c, cf, tl): CallUnification.makeStaticCallBetter(ctx, c, cf, tl, vector(eBase, eIndex), aa.aaType, p);
	};

	public static function makeArrayLength(ctx:TyperContext, aa:ArrayAccessData, e:TExpr, p:Pos):TExpr {
		function make(length:ArrayLength, e:TExpr):TExpr return switch length {
			case ALField: getArrayLength(ctx, e, p);
			case ALCall(c, cf, tl): CallUnification.makeStaticCallBetter(ctx, c, cf, tl, vector(e), ctx.com.basic.tint, p);
			case ALForward(t, length): make(length, mk(TCast(e, null), t, e.epos));
		}
		return make(aa.aaLength, e);
	}
}
