package core;

import Type as StdType;
import core.Globals;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TFunctions.NotFound;
import core.TUnification.*;
import core.TPrinting.*;
import core.Error;
import core.Abstract as AbstractTools;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

// port: from haxe/src/core/texpr.ml.
class Texpr {
	public static function iter(f:TExpr->Void, e:TExpr):Void switch e.eexpr {
		case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
		case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _):
			f(a);
			f(b);
		case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
			TMeta(_, a):
			f(a);
		case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
			for (a in el) f(a);
		case TObjectDecl(fl):
			for (a in fl) f(a.expr);
		case TCall(a, el):
			f(a);
			for (a in el) f(a);
		case TVar(_, eo) | TReturn(eo):
			if (eo != null) f(eo);
		case TFunction(fu):
			for (arg in fu.tfArgs) if (arg.defaultValue != null) f(arg.defaultValue);
			f(fu.tfExpr);
		case TIf(c, a, b):
			f(c);
			f(a);
			if (b != null) f(b);
		case TSwitch(s):
			f(s.switchSubject);
			for (c in s.switchCases) {
				for (a in c.casePatterns) f(a);
				f(c.caseExpr);
			}
			if (s.switchDefault != null) f(s.switchDefault);
		case TTry(a, catches):
			f(a);
			for (c in catches) f(c.expr);
	}

	// port: iter with an argument passed through, for recursive walkers that would
	// otherwise allocate a closure per node (`iterWith(walk,x,e)`).
	public static function iterWith<A>(f:A->TExpr->Void, x:A, e:TExpr):Void switch e.eexpr {
		case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
		case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _):
			f(x, a);
			f(x, b);
		case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
			TMeta(_, a):
			f(x, a);
		case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
			for (a in el) f(x, a);
		case TObjectDecl(fl):
			for (a in fl) f(x, a.expr);
		case TCall(a, el):
			f(x, a);
			for (a in el) f(x, a);
		case TVar(_, eo) | TReturn(eo):
			if (eo != null) f(x, eo);
		case TFunction(fu):
			for (arg in fu.tfArgs) if (arg.defaultValue != null) f(x, arg.defaultValue);
			f(x, fu.tfExpr);
		case TIf(c, a, b):
			f(x, c);
			f(x, a);
			if (b != null) f(x, b);
		case TSwitch(s):
			f(x, s.switchSubject);
			for (c in s.switchCases) {
				for (a in c.casePatterns) f(x, a);
				f(x, c.caseExpr);
			}
			if (s.switchDefault != null) f(x, s.switchDefault);
		case TTry(a, catches):
			f(x, a);
			for (c in catches) f(x, c.expr);
	}

	// port: these generic array helpers are inline: see core.ds.List.
	extern overload public static inline function exists<A>(f:A->Bool, el:Array<A>):Bool {
		var r = false;
		for (e in el) if (f(e)) {
			r = true;
			break;
		}
		return r;
	}

	extern overload public static inline function exists<A>(f:A->Bool, el:Vector<A>):Bool {
		var r = false;
		for (e in el) if (f(e)) {
			r = true;
			break;
		}
		return r;
	}

	extern overload public static inline function all<A>(f:A->Bool, el:Array<A>):Bool {
		var r = true;
		for (e in el) if (!f(e)) {
			r = false;
			break;
		}
		return r;
	}

	extern overload public static inline function all<A>(f:A->Bool, el:Vector<A>):Bool {
		var r = true;
		for (e in el) if (!f(e)) {
			r = false;
			break;
		}
		return r;
	}

	/**
		Returns `true` if `predicate` is evaluated to `true` for at least one of sub-expressions.
		Returns `false` otherwise.
		Does not evaluate `predicate` for the `e` expression.
	**/
	public static function checkExpr(f:TExpr->Bool, e:TExpr):Bool return switch e.eexpr {
		case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_): false;
		case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _): f(a) || f(b);
		case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
			TMeta(_, a): f(a);
		case TArrayDecl(el) | TNew(_, _, el) | TBlock(el): exists(f, el);
		case TObjectDecl(fl): exists(a -> f(a.expr), fl);
		case TCall(a, el): f(a) || exists(f, el);
		case TVar(_, eo) | TReturn(eo): eo != null && f(eo);
		case TFunction(fu): exists(a -> a.defaultValue != null && f(a.defaultValue), fu.tfArgs) || f(fu.tfExpr);
		case TIf(c, a, b): f(c) || f(a) || b != null && f(b);
		case TSwitch(s):
			f(s.switchSubject)
			|| exists((c:TSwitchCase) -> exists(f, c.casePatterns) || f(c.caseExpr), s.switchCases)
			|| s.switchDefault != null
			&& f(s.switchDefault);
		case TTry(a, catches): f(a) || exists(c -> f(c.expr), catches);
	};

	// port: checkExpr with an argument passed through (see iterWith).
	public static function checkExprWith<A>(f:A->TExpr->Bool, x:A, e:TExpr):Bool {
		switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
				return false;
			case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _):
				return f(x, a) || f(x, b);
			case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
				TMeta(_, a):
				return f(x, a);
			case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
				for (a in el) if (f(x, a)) return true;
				return false;
			case TObjectDecl(fl):
				for (a in fl) if (f(x, a.expr)) return true;
				return false;
			case TCall(a, el):
				if (f(x, a)) return true;
				for (a in el) if (f(x, a)) return true;
				return false;
			case TVar(_, eo) | TReturn(eo):
				return eo != null && f(x, eo);
			case TFunction(fu):
				for (a in fu.tfArgs) if (a.defaultValue != null && f(x, a.defaultValue)) return true;
				return f(x, fu.tfExpr);
			case TIf(c, a, b):
				return f(x, c) || f(x, a) || b != null && f(x, b);
			case TSwitch(s):
				if (f(x, s.switchSubject)) return true;
				for (c in s.switchCases) {
					for (p in c.casePatterns) if (f(x, p)) return true;
					if (f(x, c.caseExpr)) return true;
				}
				return s.switchDefault != null && f(x, s.switchDefault);
			case TTry(a, catches):
				if (f(x, a)) return true;
				for (c in catches) if (f(x, c.expr)) return true;
				return false;
		}
	}

	// port: non-generic copies: on HashLink a typed function passed to a generic parameter is
	// wrapped in a new closure on every call, which is what these helpers avoid.
	static function mapListWithScom(f:context.SafeCom.SafeContext->TExpr->TExpr, x:context.SafeCom.SafeContext,
			el:Vector<TExpr>):Vector<TExpr> {
		for (i in 0...el.length) {
			var cur = el[i], y = f(x, cur);
			if (y != cur) {
				var r = el.copy();
				r[i] = y; // port: one allocation of the final length
				for (j in i + 1...el.length) r[j] = f(x, el[j]);
				return r;
			}
		}
		return el;
	}

	public static function mapExprWithScom(f:context.SafeCom.SafeContext->TExpr->TExpr, x:context.SafeCom.SafeContext, e:TExpr):TExpr {
		var def:TExprDef = switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_): return e;
			case TArray(a, b):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TArray(a2, b2);
			case TBinop(op, a, b):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TBinop(op, a2, b2);
			case TWhile(a, b, flag):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TWhile(a2, b2, flag);
			case TThrow(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TThrow(a2);
			case TEnumParameter(a, ef, i):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TEnumParameter(a2, ef, i);
			case TEnumIndex(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TEnumIndex(a2);
			case TField(a, fa):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TField(a2, fa);
			case TParenthesis(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TParenthesis(a2);
			case TUnop(op, flag, a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TUnop(op, flag, a2);
			case TArrayDecl(el):
				var el2 = mapListWithScom(f, x, el);
				if (el2 == el) return e;
				TArrayDecl(el2);
			case TNew(c, pl, el):
				var el2 = mapListWithScom(f, x, el);
				if (el2 == el) return e;
				TNew(c, pl, el2);
			case TBlock(el):
				var el2 = mapListWithScom(f, x, el);
				if (el2 == el) return e;
				TBlock(el2);
			case TObjectDecl(fl):
				var changed = false;
				var fl2 = fl.map(a -> {
					var x = f(x, a.expr);
					if (x != a.expr) changed = true;
					{key: a.key, expr: x};
				});
				if (!changed) return e;
				TObjectDecl(fl2);
			case TCall(a, el):
				var a2 = f(x, a);
				var el2 = mapListWithScom(f, x, el);
				if (a2 == a && el2 == el) return e;
				TCall(a2, el2);
			case TVar(v, eo):
				if (eo == null) return e;
				var eo2 = f(x, eo);
				if (eo2 == eo) return e;
				TVar(v, eo2);
			case TFunction(fu):
				var changed = false;
				var args = fu.tfArgs.map(a -> {
					var d = a.defaultValue == null ? null : f(x, a.defaultValue);
					if (d != a.defaultValue) changed = true;
					{variable: a.variable, defaultValue: d};
				});
				var body = f(x, fu.tfExpr);
				if (!changed && body == fu.tfExpr) return e;
				TFunction({tfArgs: args, tfType: fu.tfType, tfExpr: body});
			case TIf(c, a, b):
				var c2 = f(x, c);
				var a2 = f(x, a);
				var b2 = b == null ? null : f(x, b);
				if (c2 == c && a2 == a && b2 == b) return e;
				TIf(c2, a2, b2);
			case TSwitch(s):
				var subject = f(x, s.switchSubject);
				var changed = subject != s.switchSubject;
				var cases = s.switchCases.map(c -> {
					var ps = mapListWithScom(f, x, c.casePatterns);
					var ce = f(x, c.caseExpr);
					if (ps != c.casePatterns || ce != c.caseExpr) changed = true;
					({casePatterns: ps, caseExpr: ce} : core.TType.TSwitchCase);
				});
				var def = s.switchDefault == null ? null : f(x, s.switchDefault);
				if (def != s.switchDefault) changed = true;
				if (!changed) return e;
				TSwitch(mkSwitch(subject, cases, def, s.switchExhaustive));
			case TTry(a, catches):
				var a2 = f(x, a);
				var changed = a2 != a;
				var cs = catches.map(c -> {
					var x = f(x, c.expr);
					if (x != c.expr) changed = true;
					{variable: c.variable, expr: x};
				});
				if (!changed) return e;
				TTry(a2, cs);
			case TReturn(eo):
				if (eo == null) return e;
				var eo2 = f(x, eo);
				if (eo2 == eo) return e;
				TReturn(eo2);
			case TCast(a, mt):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TCast(a2, mt);
			case TMeta(m, a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TMeta(m, a2);
		};
		return withExpr(e, def);
	}

	public static function checkExprWithScom(f:context.SafeCom.SafeContext->TExpr->Bool, x:context.SafeCom.SafeContext, e:TExpr):Bool {
		switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
				return false;
			case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _):
				return f(x, a) || f(x, b);
			case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
				TMeta(_, a):
				return f(x, a);
			case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
				for (a in el) if (f(x, a)) return true;
				return false;
			case TObjectDecl(fl):
				for (a in fl) if (f(x, a.expr)) return true;
				return false;
			case TCall(a, el):
				if (f(x, a)) return true;
				for (a in el) if (f(x, a)) return true;
				return false;
			case TVar(_, eo) | TReturn(eo):
				return eo != null && f(x, eo);
			case TFunction(fu):
				for (a in fu.tfArgs) if (a.defaultValue != null && f(x, a.defaultValue)) return true;
				return f(x, fu.tfExpr);
			case TIf(c, a, b):
				return f(x, c) || f(x, a) || b != null && f(x, b);
			case TSwitch(s):
				if (f(x, s.switchSubject)) return true;
				for (c in s.switchCases) {
					for (p in c.casePatterns) if (f(x, p)) return true;
					if (f(x, c.caseExpr)) return true;
				}
				return s.switchDefault != null && f(x, s.switchDefault);
			case TTry(a, catches):
				if (f(x, a)) return true;
				for (c in catches) if (f(x, c.expr)) return true;
				return false;
		}
	}

	static function mapListWithBool(f:Bool->TExpr->TExpr, x:Bool, el:Vector<TExpr>):Vector<TExpr> {
		for (i in 0...el.length) {
			var cur = el[i], y = f(x, cur);
			if (y != cur) {
				var r = el.copy();
				r[i] = y; // port: one allocation of the final length
				for (j in i + 1...el.length) r[j] = f(x, el[j]);
				return r;
			}
		}
		return el;
	}

	public static function mapExprWithBool(f:Bool->TExpr->TExpr, x:Bool, e:TExpr):TExpr {
		var def:TExprDef = switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_): return e;
			case TArray(a, b):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TArray(a2, b2);
			case TBinop(op, a, b):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TBinop(op, a2, b2);
			case TWhile(a, b, flag):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TWhile(a2, b2, flag);
			case TThrow(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TThrow(a2);
			case TEnumParameter(a, ef, i):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TEnumParameter(a2, ef, i);
			case TEnumIndex(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TEnumIndex(a2);
			case TField(a, fa):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TField(a2, fa);
			case TParenthesis(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TParenthesis(a2);
			case TUnop(op, flag, a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TUnop(op, flag, a2);
			case TArrayDecl(el):
				var el2 = mapListWithBool(f, x, el);
				if (el2 == el) return e;
				TArrayDecl(el2);
			case TNew(c, pl, el):
				var el2 = mapListWithBool(f, x, el);
				if (el2 == el) return e;
				TNew(c, pl, el2);
			case TBlock(el):
				var el2 = mapListWithBool(f, x, el);
				if (el2 == el) return e;
				TBlock(el2);
			case TObjectDecl(fl):
				var changed = false;
				var fl2 = fl.map(a -> {
					var x = f(x, a.expr);
					if (x != a.expr) changed = true;
					{key: a.key, expr: x};
				});
				if (!changed) return e;
				TObjectDecl(fl2);
			case TCall(a, el):
				var a2 = f(x, a);
				var el2 = mapListWithBool(f, x, el);
				if (a2 == a && el2 == el) return e;
				TCall(a2, el2);
			case TVar(v, eo):
				if (eo == null) return e;
				var eo2 = f(x, eo);
				if (eo2 == eo) return e;
				TVar(v, eo2);
			case TFunction(fu):
				var changed = false;
				var args = fu.tfArgs.map(a -> {
					var d = a.defaultValue == null ? null : f(x, a.defaultValue);
					if (d != a.defaultValue) changed = true;
					{variable: a.variable, defaultValue: d};
				});
				var body = f(x, fu.tfExpr);
				if (!changed && body == fu.tfExpr) return e;
				TFunction({tfArgs: args, tfType: fu.tfType, tfExpr: body});
			case TIf(c, a, b):
				var c2 = f(x, c);
				var a2 = f(x, a);
				var b2 = b == null ? null : f(x, b);
				if (c2 == c && a2 == a && b2 == b) return e;
				TIf(c2, a2, b2);
			case TSwitch(s):
				var subject = f(x, s.switchSubject);
				var changed = subject != s.switchSubject;
				var cases = s.switchCases.map(c -> {
					var ps = mapListWithBool(f, x, c.casePatterns);
					var ce = f(x, c.caseExpr);
					if (ps != c.casePatterns || ce != c.caseExpr) changed = true;
					({casePatterns: ps, caseExpr: ce} : core.TType.TSwitchCase);
				});
				var def = s.switchDefault == null ? null : f(x, s.switchDefault);
				if (def != s.switchDefault) changed = true;
				if (!changed) return e;
				TSwitch(mkSwitch(subject, cases, def, s.switchExhaustive));
			case TTry(a, catches):
				var a2 = f(x, a);
				var changed = a2 != a;
				var cs = catches.map(c -> {
					var x = f(x, c.expr);
					if (x != c.expr) changed = true;
					{variable: c.variable, expr: x};
				});
				if (!changed) return e;
				TTry(a2, cs);
			case TReturn(eo):
				if (eo == null) return e;
				var eo2 = f(x, eo);
				if (eo2 == eo) return e;
				TReturn(eo2);
			case TCast(a, mt):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TCast(a2, mt);
			case TMeta(m, a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TMeta(m, a2);
		};
		return withExpr(e, def);
	}

	public static function checkExprWithBool(f:Bool->TExpr->Bool, x:Bool, e:TExpr):Bool {
		switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
				return false;
			case TArray(a, b) | TBinop(_, a, b) | TWhile(a, b, _):
				return f(x, a) || f(x, b);
			case TThrow(a) | TField(a, _) | TEnumParameter(a, _, _) | TEnumIndex(a) | TParenthesis(a) | TCast(a, _) | TUnop(_, _, a) |
				TMeta(_, a):
				return f(x, a);
			case TArrayDecl(el) | TNew(_, _, el) | TBlock(el):
				for (a in el) if (f(x, a)) return true;
				return false;
			case TObjectDecl(fl):
				for (a in fl) if (f(x, a.expr)) return true;
				return false;
			case TCall(a, el):
				if (f(x, a)) return true;
				for (a in el) if (f(x, a)) return true;
				return false;
			case TVar(_, eo) | TReturn(eo):
				return eo != null && f(x, eo);
			case TFunction(fu):
				for (a in fu.tfArgs) if (a.defaultValue != null && f(x, a.defaultValue)) return true;
				return f(x, fu.tfExpr);
			case TIf(c, a, b):
				return f(x, c) || f(x, a) || b != null && f(x, b);
			case TSwitch(s):
				if (f(x, s.switchSubject)) return true;
				for (c in s.switchCases) {
					for (p in c.casePatterns) if (f(x, p)) return true;
					if (f(x, c.caseExpr)) return true;
				}
				return s.switchDefault != null && f(x, s.switchDefault);
			case TTry(a, catches):
				if (f(x, a)) return true;
				for (c in catches) if (f(x, c.expr)) return true;
				return false;
		}
	}

	public static function withExpr(e:TExpr, def:TExprDef):TExpr return {eexpr: def, etype: e.etype, epos: e.epos};

	// port: upstream rebuilds every node; here a node whose children all come back
	// unchanged is returned as is (texprs are immutable; this saves most allocations
	// of identity-like passes). Evaluation order is unchanged.
	static function mapList(f:TExpr->TExpr, el:Vector<TExpr>):Vector<TExpr> {
		for (i in 0...el.length) {
			var x = el[i], y = f(x);
			if (y != x) {
				var r = el.copy();
				r[i] = y; // port: one allocation of the final length
				for (j in i + 1...el.length) r[j] = f(el[j]);
				return r;
			}
		}
		return el;
	}

	public static function mapExpr(f:TExpr->TExpr, e:TExpr):TExpr {
		var def:TExprDef = switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_): return e;
			case TArray(a, b):
				var a2 = f(a);
				var b2 = f(b);
				if (a2 == a && b2 == b) return e;
				TArray(a2, b2);
			case TBinop(op, a, b):
				var a2 = f(a);
				var b2 = f(b);
				if (a2 == a && b2 == b) return e;
				TBinop(op, a2, b2);
			case TWhile(a, b, flag):
				var a2 = f(a);
				var b2 = f(b);
				if (a2 == a && b2 == b) return e;
				TWhile(a2, b2, flag);
			case TThrow(a):
				var a2 = f(a);
				if (a2 == a) return e;
				TThrow(a2);
			case TEnumParameter(a, ef, i):
				var a2 = f(a);
				if (a2 == a) return e;
				TEnumParameter(a2, ef, i);
			case TEnumIndex(a):
				var a2 = f(a);
				if (a2 == a) return e;
				TEnumIndex(a2);
			case TField(a, fa):
				var a2 = f(a);
				if (a2 == a) return e;
				TField(a2, fa);
			case TParenthesis(a):
				var a2 = f(a);
				if (a2 == a) return e;
				TParenthesis(a2);
			case TUnop(op, flag, a):
				var a2 = f(a);
				if (a2 == a) return e;
				TUnop(op, flag, a2);
			case TArrayDecl(el):
				var el2 = mapList(f, el);
				if (el2 == el) return e;
				TArrayDecl(el2);
			case TNew(c, pl, el):
				var el2 = mapList(f, el);
				if (el2 == el) return e;
				TNew(c, pl, el2);
			case TBlock(el):
				var el2 = mapList(f, el);
				if (el2 == el) return e;
				TBlock(el2);
			case TObjectDecl(fl):
				var changed = false;
				var fl2 = fl.map(a -> {
					var x = f(a.expr);
					if (x != a.expr) changed = true;
					{key: a.key, expr: x};
				});
				if (!changed) return e;
				TObjectDecl(fl2);
			case TCall(a, el):
				var a2 = f(a);
				var el2 = mapList(f, el);
				if (a2 == a && el2 == el) return e;
				TCall(a2, el2);
			case TVar(v, eo):
				if (eo == null) return e;
				var eo2 = f(eo);
				if (eo2 == eo) return e;
				TVar(v, eo2);
			case TFunction(fu):
				var changed = false;
				var args = fu.tfArgs.map(a -> {
					var d = a.defaultValue == null ? null : f(a.defaultValue);
					if (d != a.defaultValue) changed = true;
					{variable: a.variable, defaultValue: d};
				});
				var body = f(fu.tfExpr);
				if (!changed && body == fu.tfExpr) return e;
				TFunction({tfArgs: args, tfType: fu.tfType, tfExpr: body});
			case TIf(c, a, b):
				var c2 = f(c);
				var a2 = f(a);
				var b2 = b == null ? null : f(b);
				if (c2 == c && a2 == a && b2 == b) return e;
				TIf(c2, a2, b2);
			case TSwitch(s):
				var subject = f(s.switchSubject);
				var changed = subject != s.switchSubject;
				var cases = s.switchCases.map(c -> {
					var ps = mapList(f, c.casePatterns);
					var ce = f(c.caseExpr);
					if (ps != c.casePatterns || ce != c.caseExpr) changed = true;
					({casePatterns: ps, caseExpr: ce} : core.TType.TSwitchCase);
				});
				var def = s.switchDefault == null ? null : f(s.switchDefault);
				if (def != s.switchDefault) changed = true;
				if (!changed) return e;
				TSwitch(mkSwitch(subject, cases, def, s.switchExhaustive));
			case TTry(a, catches):
				var a2 = f(a);
				var changed = a2 != a;
				var cs = catches.map(c -> {
					var x = f(c.expr);
					if (x != c.expr) changed = true;
					{variable: c.variable, expr: x};
				});
				if (!changed) return e;
				TTry(a2, cs);
			case TReturn(eo):
				if (eo == null) return e;
				var eo2 = f(eo);
				if (eo2 == eo) return e;
				TReturn(eo2);
			case TCast(a, mt):
				var a2 = f(a);
				if (a2 == a) return e;
				TCast(a2, mt);
			case TMeta(m, a):
				var a2 = f(a);
				if (a2 == a) return e;
				TMeta(m, a2);
		};
		return withExpr(e, def);
	}

	// port: mapExpr with an argument passed through (see iterWith).
	static function mapListWith<A>(f:A->TExpr->TExpr, x:A, el:Vector<TExpr>):Vector<TExpr> {
		for (i in 0...el.length) {
			var cur = el[i], y = f(x, cur);
			if (y != cur) {
				var r = el.copy();
				r[i] = y; // port: one allocation of the final length
				for (j in i + 1...el.length) r[j] = f(x, el[j]);
				return r;
			}
		}
		return el;
	}

	public static function mapExprWith<A>(f:A->TExpr->TExpr, x:A, e:TExpr):TExpr {
		var def:TExprDef = switch e.eexpr {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_): return e;
			case TArray(a, b):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TArray(a2, b2);
			case TBinop(op, a, b):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TBinop(op, a2, b2);
			case TWhile(a, b, flag):
				var a2 = f(x, a);
				var b2 = f(x, b);
				if (a2 == a && b2 == b) return e;
				TWhile(a2, b2, flag);
			case TThrow(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TThrow(a2);
			case TEnumParameter(a, ef, i):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TEnumParameter(a2, ef, i);
			case TEnumIndex(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TEnumIndex(a2);
			case TField(a, fa):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TField(a2, fa);
			case TParenthesis(a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TParenthesis(a2);
			case TUnop(op, flag, a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TUnop(op, flag, a2);
			case TArrayDecl(el):
				var el2 = mapListWith(f, x, el);
				if (el2 == el) return e;
				TArrayDecl(el2);
			case TNew(c, pl, el):
				var el2 = mapListWith(f, x, el);
				if (el2 == el) return e;
				TNew(c, pl, el2);
			case TBlock(el):
				var el2 = mapListWith(f, x, el);
				if (el2 == el) return e;
				TBlock(el2);
			case TObjectDecl(fl):
				var changed = false;
				var fl2 = fl.map(a -> {
					var x = f(x, a.expr);
					if (x != a.expr) changed = true;
					{key: a.key, expr: x};
				});
				if (!changed) return e;
				TObjectDecl(fl2);
			case TCall(a, el):
				var a2 = f(x, a);
				var el2 = mapListWith(f, x, el);
				if (a2 == a && el2 == el) return e;
				TCall(a2, el2);
			case TVar(v, eo):
				if (eo == null) return e;
				var eo2 = f(x, eo);
				if (eo2 == eo) return e;
				TVar(v, eo2);
			case TFunction(fu):
				var changed = false;
				var args = fu.tfArgs.map(a -> {
					var d = a.defaultValue == null ? null : f(x, a.defaultValue);
					if (d != a.defaultValue) changed = true;
					{variable: a.variable, defaultValue: d};
				});
				var body = f(x, fu.tfExpr);
				if (!changed && body == fu.tfExpr) return e;
				TFunction({tfArgs: args, tfType: fu.tfType, tfExpr: body});
			case TIf(c, a, b):
				var c2 = f(x, c);
				var a2 = f(x, a);
				var b2 = b == null ? null : f(x, b);
				if (c2 == c && a2 == a && b2 == b) return e;
				TIf(c2, a2, b2);
			case TSwitch(s):
				var subject = f(x, s.switchSubject);
				var changed = subject != s.switchSubject;
				var cases = s.switchCases.map(c -> {
					var ps = mapListWith(f, x, c.casePatterns);
					var ce = f(x, c.caseExpr);
					if (ps != c.casePatterns || ce != c.caseExpr) changed = true;
					({casePatterns: ps, caseExpr: ce} : core.TType.TSwitchCase);
				});
				var def = s.switchDefault == null ? null : f(x, s.switchDefault);
				if (def != s.switchDefault) changed = true;
				if (!changed) return e;
				TSwitch(mkSwitch(subject, cases, def, s.switchExhaustive));
			case TTry(a, catches):
				var a2 = f(x, a);
				var changed = a2 != a;
				var cs = catches.map(c -> {
					var x = f(x, c.expr);
					if (x != c.expr) changed = true;
					{variable: c.variable, expr: x};
				});
				if (!changed) return e;
				TTry(a2, cs);
			case TReturn(eo):
				if (eo == null) return e;
				var eo2 = f(x, eo);
				if (eo2 == eo) return e;
				TReturn(eo2);
			case TCast(a, mt):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TCast(a2, mt);
			case TMeta(m, a):
				var a2 = f(x, a);
				if (a2 == a) return e;
				TMeta(m, a2);
		};
		return withExpr(e, def);
	}

	public static function mapExprType(f:TExpr->TExpr, ft:T->T, fv:TVar->TVar, e:TExpr):TExpr {
		var def:TExprDef;
		var et:T;
		switch e.eexpr {
			case TLocal(v):
				def = TLocal(fv(v));
			case TField(a, FClosure(null, cf)):
				var a = f(a);
				var fa:TFieldAccess = FClosure(null, cf);
				try {
					switch quickField(a.etype, cf.cfName) {
						case FInstance(c, tl, cf): fa = FClosure({cls: c, params: tl}, cf);
						case _: throw NotFound.raise();
					}
				} catch (_:NotFound) {}
				def = TField(a, fa);
			case TField(a, fa):
				var a = f(a);
				try {
					var name = switch fa {
						case FClosure(_, _): throw NotFound.raise();
						case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf): cf.cfName;
						case FEnum(_, ef): ef.efName;
						case FDynamic(s): s;
					};
					fa = quickField(a.etype, name);
				} catch (_:NotFound) {}
				def = TField(a, fa);
			case TNew(c, pl, el):
				et = ft(e.etype);
				// make sure that we use the class corresponding to the replaced type
				var t = switch c.clKind {
					case KTypeParameter(_) | KGeneric: et;
					case _: ft(TInst(c, pl));
				};
				switch follow(t) {
					case TInst(c2, pl2):
						c = c2;
						pl = pl2;
					case TAbstract({aImpl: c2}, pl2) if (c2 != null):
						c = c2;
						pl = pl2;
					case t: TUnification.error([hasNoField(t, "new")]);
				}
				return {eexpr: TNew(c, pl, el.map(f)), etype: et, epos: e.epos};
			// port: OCaml evaluates constructor and tuple arguments right-to-left.
			case TVar(v, eo):
				var eo = eo == null ? null : f(eo);
				def = TVar(fv(v), eo);
			case TFunction(fu):
				var body = f(fu.tfExpr);
				var args = fu.tfArgs.map(a -> {
					var d = a.defaultValue == null ? null : f(a.defaultValue);
					{variable: fv(a.variable), defaultValue: d};
				});
				var ret = ft(fu.tfType);
				def = TFunction({tfArgs: args, tfType: ret, tfExpr: body});
			case TTry(a, catches):
				var a = f(a);
				def = TTry(a, catches.map(c -> {
					var ce = f(c.expr);
					{variable: fv(c.variable), expr: ce};
				}));
			case _:
				def = mapExpr(f, e).eexpr;
		}
		return {eexpr: def, etype: ft(e.etype), epos: e.epos};
	}

	extern overload public static inline function all2<A, B>(f:A->B->Bool, a:Array<A>, b:Array<B>):Bool {
		var r = a.length == b.length;
		if (r) for (i in 0...a.length) if (!f(a[i], b[i])) {
			r = false;
			break;
		}
		return r;
	}

	extern overload public static inline function all2<A, B>(f:A->B->Bool, a:Vector<A>, b:Vector<B>):Bool {
		var r = a.length == b.length;
		if (r) for (i in 0...a.length) if (!f(a[i], b[i])) {
			r = false;
			break;
		}
		return r;
	}

	public static function equalFa(a:TFieldAccess, b:TFieldAccess):Bool return switch [a, b] {
		case [FStatic(c, cf), FStatic(d, df)]: c == d && cf.cfName == df.cfName;
		case [FInstance(c, tl, cf), FInstance(d, ul, df)]: c == d && all2(typeIseq, tl, ul) && cf.cfName == df.cfName;
		case [FAnon(cf), FAnon(df)]: cf.cfName == df.cfName;
		case [FDynamic(s), FDynamic(t)]: s == t;
		case [FClosure(null, cf), FClosure(null, df)]: cf.cfName == df.cfName;
		case [FClosure(ct, cf), FClosure(dt, df)] if (ct != null && dt != null): ct.cls == dt.cls && all2(typeIseq, ct.params,
				dt.params) && cf.cfName == df.cfName;
		case [FEnum(en, ef), FEnum(fn, ff)]: en == fn && ef.efName == ff.efName;
		case _: false;
	};

	public static function equal(e:TExpr, f:TExpr):Bool return switch [e.eexpr, f.eexpr] {
		case [TConst(c), TConst(d)]: StdType.enumEq(c, d);
		case [TLocal(v), TLocal(w)]: v == w;
		case [TArray(a, b), TArray(c, d)]: equal(a, c) && equal(b, d);
		case [TBinop(op, a, b), TBinop(oq, c, d)]: StdType.enumEq(op, oq) && equal(a, c) && equal(b, d);
		case [TField(a, fa), TField(b, fb)]: equal(a, b) && equalFa(fa, fb);
		case [TTypeExpr(TClassDecl(c)), TTypeExpr(TClassDecl(d))]: c == d;
		case [TTypeExpr(TEnumDecl(c)), TTypeExpr(TEnumDecl(d))]: c == d;
		case [TTypeExpr(TTypeDecl(c)), TTypeExpr(TTypeDecl(d))]: c == d;
		case [TTypeExpr(TAbstractDecl(c)), TTypeExpr(TAbstractDecl(d))]: c == d;
		case [TTypeExpr(_), TTypeExpr(_)]: false;
		case [TParenthesis(a), TParenthesis(b)]: equal(a, b);
		case [TObjectDecl(a), TObjectDecl(b)]: all2((a,
					b) -> a.key.name == b.key.name && a.key.pos == b.key.pos && a.key.quote == b.key.quote && equal(a.expr, b.expr), a, b);
		case [TArrayDecl(a), TArrayDecl(b)] | [TBlock(a), TBlock(b)]: all2(equal, a, b);
		case [TCall(a, al), TCall(b, bl)]: equal(a, b) && all2(equal, al, bl);
		case [TNew(c, tl, el), TNew(d, ul, fl)]: c == d && all2(typeIseq, tl, ul) && all2(equal, el, fl);
		case [TUnop(op, flag, a), TUnop(oq, flag2, b)]: op == oq && flag == flag2 && equal(a, b);
		case [TFunction(a), TFunction(b)]: a == b;
		case [TVar(v, null), TVar(w, null)]: v == w;
		case [TVar(v, a), TVar(w, b)] if (a != null && b != null): v == w && equal(a, b);
		case [TIf(c, a, null), TIf(d, b, null)]: equal(c, d) && equal(a, b);
		case [TIf(c, a, x), TIf(d, b, y)] if (x != null && y != null): equal(c, d) && equal(a, b) && equal(x, y);
		// port: upstream's eb2/eb2 comparison is preserved literally.
		case [TWhile(c, a, flag), TWhile(d, b, flag2)]: equal(c, d) && equal(b, b) && flag == flag2;
		case [TSwitch(a), TSwitch(b)]: equal(a.switchSubject,
				b.switchSubject) && all2((a:TSwitchCase,
					b:TSwitchCase) -> all2(equal, a.casePatterns, b.casePatterns) && equal(a.caseExpr, b.caseExpr),
				a.switchCases, b.switchCases) && equalOpt(a.switchDefault, b.switchDefault);
		case [TTry(a, cl), TTry(b, dl)]: equal(a, b) && all2((c, d) -> c.variable == d.variable && equal(c.expr, d.expr), cl, dl);
		case [TReturn(null), TReturn(null)]: true;
		case [TReturn(a), TReturn(b)] if (a != null && b != null): equal(a, b);
		case [TThrow(a), TThrow(b)]: equal(a, b);
		case [TCast(a, null), TCast(b, null)]: equal(a, b);
		case [TCast(a, mt), TCast(b, nt)] if (mt != null && nt != null): equal(a, b) && mt == nt;
		// TODO: cheating?
		case [TMeta(a, e), TMeta(b, f)]: StdType.enumEq(a.meta,
				b.meta) && all2((e, f) -> core.AstPrinter.sExpr(e) == core.AstPrinter.sExpr(f), a.exprs, b.exprs) && equal(e, f);
		case [TBreak, TBreak] | [TContinue, TContinue]: true;
		case [TEnumParameter(a, ef, i), TEnumParameter(b, ff, j)]: equal(a, b) && ef == ff && i == j;
		case _: false;
	};

	static function equalOpt(a:Null<TExpr>, b:Null<TExpr>):Bool return a == null ? b == null : b != null && equal(a, b);

	public static function eIdentity(e:TExpr):TExpr return e;

	public static function copyVar(v:TVar):TVar {
		var w = allocVar(v.vKind, v.vName, v.vType, v.vPos);
		w.vMeta = v.vMeta;
		w.vExtra = v.vExtra;
		w.vFlags = v.vFlags;
		return w;
	}

	public static function duplicateTvars(fThis:TExpr->TExpr, e:TExpr):TExpr {
		var vars = new haxe.ds.IntMap<TVar>();
		inline function copy(v:TVar):TVar {
			var w = copyVar(v);
			vars.set(v.vId, w);
			return w;
		}
		function build(e:TExpr):TExpr return switch e.eexpr {
			case TVar(v, eo):
				var w = copy(v);
				withExpr(e, TVar(w, eo == null ? null : build(eo)));
			case TTry(a, cl):
				var cl = cl.map(c -> {variable: copy(c.variable), expr: build(c.expr)});
				withExpr(e, TTry(build(a), cl));
			case TFunction(f):
				var args = f.tfArgs.map(a -> {
					variable: copy(a.variable),
					defaultValue: a.defaultValue == null ? null : build(a.defaultValue)
				});
				withExpr(e, TFunction({tfArgs: args, tfType: f.tfType, tfExpr: build(f.tfExpr)}));
			case TLocal(v): try {
					if (!vars.exists(v.vId)) throw NotFound.raise();
					withExpr(e, TLocal(vars.get(v.vId)));
				} catch (_:Dynamic) {
					e;
				}
			case TConst(TThis): fThis(e);
			case _: mapExpr(build, e);
		};
		return build(e);
	}

	public static function skip(e:TExpr):TExpr return switch e.eexpr {
		case TParenthesis(a) | TMeta(_, a) | TBlock([a]) | TCast(a, null): skip(a);
		case _: e;
	};

	public static inline function foldmapList<A, B>(f:A->B->{acc: A, value: B}, acc:A, el:Array<B>):{acc:A, value:Array<B>} {
		var result = [];
		for (e in el) {
			var r = f(acc, e);
			acc = r.acc;
			result.push(r.value);
		}
		return {acc: acc, value: result};
	}

	public static function foldmapOpt<A, B>(f:A->B->{acc: A, value: B}, acc:A, eo:Null<B>):{acc:A, value:Null<B>}
		return eo == null ? {acc: acc, value: null} : f(acc, eo);

	public static function foldmapPairs<A, B, C>(f:A->C->{acc: A, value: C}, acc:A,
			pairs:Array<{key:B, expr:C}>):{acc:A, value:Array<{key:B, expr:C}>} {
		var el = [];
		for (pair in pairs) {
			var r = f(acc, pair.expr);
			acc = r.acc;
			el.push({key: pair.key, expr: r.value});
		}
		return {acc: acc, value: el};
	}

	public static function foldmap<A>(f:A->TExpr->{acc: A, value: TExpr}, acc:A, e:TExpr):{acc:A, value:TExpr} {
		function map(e:TExpr):TExpr {
			var r = f(acc, e);
			acc = r.acc;
			return r.value;
		}
		var mapped = mapExpr(map, e);
		// port: upstream foldmap builds switch cases by cons without reversing them.
		switch mapped.eexpr {
			case TSwitch(s):
				VectorTools.reverse(s.switchCases);
			case _:
		}
		return {acc: acc, value: mapped};
	}

	public static function setDefault(b:BasicTypes, a:TVar, c:TExpr, p:Pos):TExpr {
		var t = a.vType;
		var v = mk(TLocal(a), t, p);
		var cond = TBinop(OpEq, v, mk(TConst(TNull), t, p));
		return mk(TIf(Builder.mkParent(mk(cond, b.tbool, p)), mk(TBinop(OpAssign, v, c), t, p), null), b.tvoid, p);
	}

	// Tells if the constructor might be called without any issue whatever its parameters
	public static function constructorSideEffects(e:TExpr):Bool return switch e.eexpr {
		case TBinop(op, _, _) if (op != OpAssign): true;
		case TField(_, FEnum(_, _)): false;
		case TUnop(_, _, _) | TArray(_, _) | TField(_, _) | TEnumParameter(_, _, _) | TEnumIndex(_) | TCall(_, _) | TNew(_, _, _) |
			TWhile(_, _, _) | TSwitch(_) | TReturn(_) | TThrow(_): true;
		case _: checkExpr(constructorSideEffects, e);
	};

	public static function replaceSeparators(s:String, c:String):String return s.split("_").join(c);

	// port: OCaml Int32.of_string accepts unsigned bit patterns for explicit base prefixes.
	static function int32OfString(source:String):Int {
		var s = source.split("_").join("");
		var i = 0;
		var negative = false;
		if (s.charAt(i) == "-" || s.charAt(i) == "+") {
			negative = s.charAt(i) == "-";
			i++;
		}
		var radix = 10;
		var unsigned = false;
		if (s.charAt(i) == "0") switch s.charAt(i + 1).toLowerCase() {
			case "x":
				radix = 16;
				unsigned = true;
				i += 2;
			case "o":
				radix = 8;
				unsigned = true;
				i += 2;
			case "b":
				radix = 2;
				unsigned = true;
				i += 2;
			case "u":
				unsigned = true;
				i += 2;
			case _:
		}
		if (i == s.length) throw "Int32.of_string";
		var value:Float = 0.0;
		var limit:Float = unsigned ? 4294967295.0 : (negative ? 2147483648.0 : 2147483647.0);
		while (i < s.length) {
			var c = s.charCodeAt(i++);
			var digit = c >= 48 && c <= 57 ? c - 48 : c >= 65 && c <= 70 ? c - 55 : c >= 97 && c <= 102 ? c - 87 : -1;
			if (digit < 0 || digit >= radix) throw "Int32.of_string";
			value = value * radix + digit;
			if (value > limit) throw "Int32.of_string";
		}
		if (value > 2147483647.0) value -= 4294967296.0;
		// port: `| 0`: Int32 wrap-around on hosts with unbounded Int arithmetic (JS: -(-2147483648))
		var result = Std.int(value);
		return negative ? (-result) | 0 : result;
	}

	public static function typeConstant(b:BasicTypes, c:Constant, p:Pos):TExpr return switch c {
		case Int(s, _):
			if (s.length > 10 && s.substr(0, 2) == "0x") Error.raiseTypingError("Invalid hexadecimal integer", p);
			if (s.length > 34 && s.substr(0, 2) == "0b") Error.raiseTypingError("Invalid binary integer", p);
			try {
				mk(TConst(TInt(int32OfString(s))), b.tint, p);
			} catch (_:Dynamic) {
				mk(TConst(TFloat(s)), b.tfloat, p);
			}
		case Float(s, _): mk(TConst(TFloat(s)), b.tfloat, p);
		case String(s, _): mk(TConst(TString(s)), b.tstring, p); // STRINGTODO: qs?
		case Ident("true"): mk(TConst(TBool(true)), b.tbool, p);
		case Ident("false"): mk(TConst(TBool(false)), b.tbool, p);
		case Ident("null"): mk(TConst(TNull), b.tnull(mkMono()), p);
		case Ident(s): Error.raiseTypingError("Invalid constant :  " + s, p);
		case Regexp(_, _): Error.raiseTypingError("Invalid constant", p);
	};

	public static function typeConstantValue(b:BasicTypes, e:Expr):TExpr return switch e.expr {
		case EConst(c): typeConstant(b, c, e.pos);
		case EParenthesis(a): typeConstantValue(b, a);
		case EObjectDecl(el): mk(TObjectDecl(el.map(a -> {key: a.key, expr: typeConstantValue(b, a.expr)})), mkAnon(Closed), e.pos);
		case EArrayDecl(el): mk(TArrayDecl(el.map(a -> typeConstantValue(b, a))), b.tarray(tDynamic), e.pos);
		case _: Error.raiseTypingError("Constant value expected", e.pos);
	};

	public static function isConstantValue(b:BasicTypes, e:Expr):Bool {
		try {
			typeConstantValue(b, e);
			return true;
		} catch (err:core.Error.TypingError) {
			switch err.error.errMessage {
				case Custom(_):
					return false;
				case _:
					throw err;
			}
		}
	}

	public static function forRemap(b:BasicTypes, v:TVar, etype:T, e1:TExpr, e2:TExpr, p:Pos):TExpr {
		var v2 = allocVar(VGenerated, Globals.genLocalPrefix + v.vName, etype, e1.epos);
		var ev = mk(TLocal(v2), etype, e1.epos);
		var t = AbstractTools.followWithAbstracts(etype);
		var fa = try quickField(t,
			"hasNext") catch (_:NotFound) Error.raiseTypingError(sType(printContext(), t) + " has no field hasNext()", p);
		var hasNext = mk(TField(ev, fa), tfun(vector(), b.tbool), e1.epos);
		hasNext = mk(TCall(hasNext, vector()), b.tbool, hasNext.epos);
		var next = mk(TField(ev, quickField(t, "next")), tfun(vector(), v.vType), e1.epos);
		next = mk(TCall(next, vector()), v.vType, e1.epos);
		var assign = mk(TVar(v, next), b.tvoid, p);
		var body = concat(assign, e2);
		return mk(TBlock(vector(
			mk(TVar(v2, e1), b.tvoid, e1.epos),
			mk(TWhile(mk(TParenthesis(hasNext), hasNext.etype, hasNext.epos), body, NormalWhile), b.tvoid, e1.epos)
		)), b.tvoid, p);
	}

	public static function notWhileTrueToWhileTrue(b:BasicTypes, e1:TExpr, e2:TExpr, flag:WhileFlag, t:T, p:Pos):TExpr {
		var br = mk(TBreak, tDynamic, p);
		var not = mk(TUnop(Not, Prefix, Builder.mkParent(e1)), e1.etype, e1.epos);
		inline function makeIf(eo:Null<TExpr>):TExpr return mk(TIf(not, br, eo), b.tvoid, p);
		function mapContinue(e:TExpr):TExpr return switch e.eexpr {
			case TContinue: duplicateTvars(eIdentity, makeIf(e));
			case TWhile(_, _, _): e;
			case _: mapExpr(mapContinue, e);
		};
		if (flag != NormalWhile) e2 = mapContinue(e2);
		var cond = makeIf(null);
		var block = flag == NormalWhile ? concat(cond, e2) : concat(e2, cond);
		return mk(TWhile(mk(TConst(TBool(true)), b.tbool, p), block, NormalWhile), t, p);
	}

	// --------------------------------------------------------------------------
	// BUILD META DATA OBJECT

	public static function buildMetadata(api:BasicTypes, t:ModuleType):Null<TExpr> {
		var p:Pos;
		var meta:Array<{name:String, meta:Metadata}>;
		var fields:Array<{name:String, meta:Metadata}>;
		var statics:Array<{name:String, meta:Metadata}>;
		switch t {
			case TClassDecl(c):
				var fs = c.clOrderedFields.copy();
				if (c.clConstructor != null) {
					var cf = core.ds.Record.copy(c.clConstructor);
					cf.cfName = "_";
					fs.push(cf);
				}
				p = c.clPos;
				meta = [{name: "", meta: c.clMeta}];
				fields = fs.map(f -> {name: f.cfName, meta: f.cfMeta});
				statics = c.clOrderedStatics.map(f -> {name: f.cfName, meta: f.cfMeta});
			case TEnumDecl(e):
				p = e.ePos;
				meta = [{name: "", meta: e.eMeta}];
				fields = e.eNames.map(n -> {name: n, meta: e.eConstrs.get(n).efMeta});
				statics = [];
			case TTypeDecl(d):
				p = d.tPos;
				meta = [{name: "", meta: d.tMeta}];
				fields = [];
				switch follow(d.tType) {
					case TAnon(a):
						var keys = [for (k in a.aFields.keys()) k];
						keys.sort(core.ds.Key.compareStrings);
						for (k in keys) {
							var f = a.aFields.get(k);
							fields.unshift({name: f.cfName, meta: f.cfMeta});
						}
					case _:
				}
				statics = [];
			case TAbstractDecl(a):
				p = a.aPos;
				meta = [{name: "", meta: a.aMeta}];
				fields = [];
				statics = [];
		}
		inline function filter(l:Array<{name:String, meta:Metadata}>):Array<{name:String, meta:Metadata}> return l.map(a -> {
			name: a.name,
			meta: a.meta.filter(m -> switch m.meta {
				case core.MetaList.StrictMeta.Custom(s): s.length > 0 && s.charAt(0) != ":";
				case _: false;
			})
		}).filter(a -> a.meta.length > 0);
		meta = filter(meta);
		fields = filter(fields);
		statics = filter(statics);
		function key(n:String):{name:String, pos:Pos, quote:QuoteStatus}
			return {name: n, pos: Globals.nullPos, quote: NoQuotes};
		inline function makeMetaField(ml:Metadata):TExpr {
			var seen = new haxe.ds.StringMap<Bool>();
			return mk(TObjectDecl(VectorTools.mapToVector(ml, m -> {
				var name = switch m.meta {
					case core.MetaList.StrictMeta.Custom(s): s;
					case _: throw "Texpr.buildMetadata";
				};
				if (seen.exists(name)) Error.raiseTypingError("Duplicate metadata '" + name + "'", m.pos);
				seen.set(name, true);
				return {
					key: key(name),
					expr: mk(m.exprs.length == 0 ? TConst(TNull) : TArrayDecl(m.exprs.map(e -> typeConstantValue(api, e))),
						api.tarray(tDynamic), m.pos)
				};
			})), tDynamic, p);
		}
		inline function makeMeta(l:Array<{name:String, meta:Metadata}>):TExpr return mk(TObjectDecl(VectorTools.mapToVector(l, a -> {
			key: key(a.name),
			expr: makeMetaField(a.meta)
		})), tDynamic, p);
		if (meta.length == 0 && fields.length == 0 && statics.length == 0) return null;
		var obj = [];
		if (fields.length != 0) obj.unshift({key: key("fields"), expr: makeMeta(fields)});
		if (statics.length != 0) obj.unshift({key: key("statics"), expr: makeMeta(statics)});
		for (a in meta) if (a.name == "") {
			obj.unshift({key: key("obj"), expr: makeMetaField(a.meta)});
			break;
		}
		return mk(TObjectDecl(Vector.fromArrayCopy(obj)), tDynamic, p);
	}

	public static function dumpWithPos(tabs:String, e:TExpr):String {
		var buf = new StringBuf();
		inline function line(tabs:String, p:Pos,
				s:String):Void buf.add(StringTools.lpad(Std.string(p.pmin), " ", 4)
				+ "-"
				+ StringTools.lpad(Std.string(p.pmax), " ", 4)
				+ " "
				+ tabs
				+ s
				+ "\n");
		function walk(tabs:String, e:TExpr):Void {
			inline function add(s:String) line(tabs, e.epos, s);
			inline function loop(e:TExpr) walk(tabs + "  ", e);
			switch e.eexpr {
				case TConst(c):
					add(sConst(c));
				case TLocal(v):
					add("TLocal " + v.vName);
				case TTypeExpr(mt):
					add("TTypeExpr " + Globals.sTypePath(tPath(mt)));
				case TIdent(s):
					add("TIdent " + s);
				case TEnumParameter(a, ef, _):
					add("TEnumParameter " + ef.efName);
					loop(a);
				case TEnumIndex(a):
					add("TEnumIndex");
					loop(a);
				case TArray(a, b):
					add("TArray");
					loop(a);
					loop(b);
				case TBinop(op, a, b):
					add("TBinop " + Ast.sBinop(op));
					loop(a);
					loop(b);
				case TField(a, fa):
					add("TField " + fieldName(fa));
					loop(a);
				case TParenthesis(a):
					add("TParenthesis");
					loop(a);
				case TObjectDecl(fl):
					add("TObjectDecl");
					for (f in fl) {
						line(tabs, f.key.pos, f.key.name);
						loop(f.expr);
					}
				case TArrayDecl(el):
					add("TArrayDecl");
					for (a in el) loop(a);
				case TCall(a, el):
					add("TCall");
					loop(a);
					for (a in el) loop(a);
				case TNew(c, _, el):
					add("TNew " + Globals.sTypePath(c.clPath));
					for (a in el) loop(a);
				case TUnop(op, _, a):
					add("TUnop " + Ast.sUnop(op));
					loop(a);
				case TVar(v, eo):
					add("TVar " + v.vName);
					if (eo != null) loop(eo);
				case TFunction(tf):
					add("TFunction");
					loop(tf.tfExpr);
				case TBlock(el):
					add("TBlock");
					for (a in el) loop(a);
				case TIf(a, b, c):
					add("TIf");
					loop(a);
					loop(b);
					if (c != null) loop(c);
				case TWhile(a, b, _):
					add("TWhile");
					loop(a);
					loop(b);
				case TSwitch(s):
					add("TSwitch");
					loop(s.switchSubject);
					for (c in s.switchCases) {
						for (a in c.casePatterns) walk(tabs + "    ", a);
						walk(tabs + "      ", c.caseExpr);
					}
					if (s.switchDefault != null) walk(tabs + "      ", s.switchDefault);
				case TTry(a, catches):
					add("TTry");
					loop(a);
					for (c in catches) walk(tabs + "    ", c.expr);
				case TReturn(eo):
					add("TReturn");
					if (eo != null) loop(eo);
				case TBreak:
					add("TBreak");
				case TContinue:
					add("TContinue");
				case TThrow(a):
					add("EThrow");
					loop(a);
				case TCast(a, _):
					add("TCast");
					loop(a);
				case TMeta(m, a):
					add("TMeta " + Meta.toString(m.meta));
					loop(a);
			}
		}
		walk(tabs, e);
		return buf.toString();
	}

	public static function collectCapturedVars(e:TExpr):{vars:Array<TVar>, accessesThis:Bool} {
		var known = new haxe.ds.IntMap<Bool>();
		var unknown = [];
		var accessesThis = false;
		inline function declare(v:TVar) known.set(v.vId, true);
		function loop(e:TExpr):Void switch e.eexpr {
			case TLocal(v) if (hasVarFlag(v, VCaptured) && !known.exists(v.vId)):
				known.set(v.vId, true);
				unknown.push(v);
			case TConst(TThis | TSuper):
				accessesThis = true;
			case TVar(v, eo):
				if (eo != null) loop(eo);
				declare(v);
			case TFunction(tf):
				for (a in tf.tfArgs) declare(a.variable);
				loop(tf.tfExpr);
			case TTry(a, catches):
				loop(a);
				for (c in catches) {
					declare(c.variable);
					loop(c.expr);
				}
			case _:
				iter(loop, e);
		}
		loop(e);
		return {vars: unknown, accessesThis: accessesThis};
	}

	/**
		If `e` contains a sequence of unsafe casts, then look if that sequence
		already has casts to `t` and return the bottom-most of such casts.
		If `require_cast` is `false` and the first non-cast expression has type `t`, then return that expression without any casts.
		In other cases return `e` as-is.
	**/
	public static function reduceUnsafeCasts(e:TExpr, t:T, requireCast:Bool = false):TExpr {
		inline function same(a:T, b:T):Bool return fastEq(followWithoutNull(a), followWithoutNull(b));
		function loop(e:TExpr):TExpr return switch e.eexpr {
			case TCast(subject, null):
				var result = loop(subject);
				same(e.etype, subject.etype) ? result : withExpr(e, TCast(result, null));
			case _: e;
		};
		var result = loop(e);
		return switch result.eexpr {
			case TCast(_, _): result;
			case _: requireCast ? withExpr(e, TCast(result, null)) : result;
		};
	}

	/**
		Returns a position spanning from the first expr to the last expr in `el`.
		Returns `default_pos` if `el` is empty or values of `pfile` of the first and
		the last positions are different.
	**/
	extern overload public static inline function punionEl(defaultPos:Pos, el:Array<TExpr>):Pos {
		if (el.length == 0) return defaultPos;
		if (el.length == 1) return el[0].epos;
		var first = el[0].epos;
		var last = el[1].epos;
		var i = 2;
		while (i < el.length) {
			if (i == el.length - 1) last = el[i].epos;
			i++;
		}
		return first.pfile != last.pfile ? defaultPos : Ast.punion(first, last);
	}

	extern overload public static inline function punionEl(defaultPos:Pos, el:Vector<TExpr>):Pos {
		if (el.length == 0) return defaultPos;
		if (el.length == 1) return el[0].epos;
		var first = el[0].epos;
		var last = el[1].epos;
		var i = 2;
		while (i < el.length) {
			if (i == el.length - 1) last = el[i].epos;
			i++;
		}
		return first.pfile != last.pfile ? defaultPos : Ast.punion(first, last);
	}

	public static function isExhaustive(s:TSwitch):Bool return s.switchExhaustive;

	public static function mkSwitch(subject:TExpr, cases:Vector<TSwitchCase>, def:Null<TExpr>, exhaustive:Bool):TSwitch return {
		switchSubject: subject,
		switchCases: cases,
		switchDefault: def,
		switchExhaustive: exhaustive
	};

	public static function isTrueExpr(e:TExpr):Bool return switch e.eexpr {
		case TConst(TBool(true)): true;
		case TParenthesis(a): isTrueExpr(a);
		case _: false;
	};

	public static function isFalseExpr(e:TExpr):Bool return switch e.eexpr {
		case TConst(TBool(false)): true;
		case TParenthesis(a): isFalseExpr(a);
		case _: false;
	};
}

// Collection of functions that return expressions
class Builder {
	public static function makeStaticThis(c:TClass, p:Pos):TExpr return mk(TTypeExpr(TClassDecl(c)), c.clType, p);

	public static function makeTypeexpr(mt:ModuleType, p:Pos):TExpr {
		var t = switch resolveTypedef(mt) {
			case TClassDecl(c): c.clType;
			case TEnumDecl(e): e.eType;
			case TAbstractDecl(a): TType(abstractModuleType(a, vector()), vector());
			case _: throw "Texpr.makeTypeexpr";
		};
		return mk(TTypeExpr(mt), t, p);
	}

	public static function makeStaticField(c:TClass, cf:TClassField,
			p:Pos):TExpr return mk(TField(makeStaticThis(c, p), FStatic(c, cf)), cf.cfType, p);

	public static function makeThrow(e:TExpr, p:Pos):TExpr return mk(TThrow(e), tDynamic, p);

	public static function makeInt(b:BasicTypes, i:Int, p:Pos):TExpr return mk(TConst(TInt(i)), b.tint, p);

	public static function makeFloat(b:BasicTypes, f:String, p:Pos):TExpr return mk(TConst(TFloat(f)), b.tfloat, p);

	public static function makeBool(b:BasicTypes, v:Bool, p:Pos):TExpr return mk(TConst(TBool(v)), b.tbool, p);

	public static function makeString(b:BasicTypes, s:String, p:Pos):TExpr return mk(TConst(TString(s)), b.tstring, p);

	public static function makeNull(t:T, p:Pos):TExpr return mk(TConst(TNull), t, p);

	public static function makeLocal(v:TVar, p:Pos):TExpr return mk(TLocal(v), v.vType, p);

	public static function makeConstTexpr(b:BasicTypes, c:TConstant, p:Pos):TExpr return switch c {
		case TString(s): makeString(b, s, p);
		case TInt(i): makeInt(b, i, p);
		case TFloat(f): makeFloat(b, f, p);
		case TBool(v): makeBool(b, v, p);
		case TNull: makeNull(b.tnull(mkMono()), p);
		case _: Error.raiseTypingError("Unsupported constant", p);
	};

	public static function field(e:TExpr, name:String, t:T, p:Pos):TExpr {
		var fa = try quickField(e.etype, name) catch (_:NotFound) {
			throw "Field " + sType(printContext(), e.etype) + "." + name + " requested but not found";
		};
		return mk(TField(e, fa), t, p);
	}

	public static function fcall(e:TExpr, name:String, el:Vector<TExpr>, ret:T,
			p:Pos):TExpr return mk(TCall(field(e, name, tfun(el.map(e -> e.etype), ret), p), el), ret, p);

	public static function mkParent(e:TExpr):TExpr return mk(TParenthesis(e), e.etype, e.epos);

	public static function ensureParent(e:TExpr):TExpr return switch e.eexpr {
		case TParenthesis(_): e;
		case _: mkParent(e);
	};

	public static function mkReturn(e:TExpr):TExpr return mk(TReturn(e), tDynamic, e.epos);

	public static function binop(op:Binop, a:TExpr, b:TExpr, t:T, p:Pos):TExpr return mk(TBinop(op, a, b), t, p);

	public static function index(b:BasicTypes, e:TExpr, i:Int, t:T, p:Pos):TExpr return mk(TArray(e, mk(TConst(TInt(i)), b.tint, p)), t, p);

	public static function resolveAndMakeStaticCall(c:TClass, name:String, args:Vector<TExpr>, p:Pos):TExpr {
		c.clBuild();
		var cf = c.clStatics.get(name);
		if (cf == null) throw "Texpr.resolveAndMakeStaticCall";
		var ef = makeStaticField(c, cf, Globals.mkZeroRangePos(p));
		var ret = switch follow(ef.etype) {
			case TFun(sig): sig.ret;
			case _: throw "assert: static call is not a function";
		};
		return mk(TCall(ef, args), ret, p);
	}
}

private class BreakOrContinue {
	public function new() {}
}

class DeadEnd {
	// Checks if execution of provided expression is guaranteed to be terminated with `return`, `throw`, `break` or `continue`.
	public static function hasDeadEnd(e:TExpr):Bool {
		function loop(e:TExpr):Bool {
			inline function inLoop(e:TExpr):Bool {
				try return loop(e)
				catch (_:BreakOrContinue) return false;
			}
			return switch e.eexpr {
				case TContinue | TBreak: throw new BreakOrContinue();
				case TThrow(a): loop(a) || true;
				case TReturn(a) if (a != null): loop(a) || true; // recurse first, could be `return continue`
				case TReturn(null): true;
				case TFunction(_): false; // This isn't executed, so don't recurse
				case TIf(cond, a, b) if (b != null): loop(cond) || loop(a) && loop(b);
				case TIf(cond, _, null): loop(cond);
				case TSwitch(s):
					loop(s.switchSubject)
					|| Texpr.isExhaustive(s)
					&& Texpr.all((c:TSwitchCase) -> Texpr.exists(loop, c.casePatterns) || loop(c.caseExpr), s.switchCases)
					&& (s.switchDefault == null || loop(s.switchDefault)); // true because we know it's exhaustive
				case TBinop(OpBoolAnd, a, b): loop(a) || Texpr.isTrueExpr(a) && loop(b);
				case TBinop(OpBoolOr, a, b): loop(a) || Texpr.isFalseExpr(a) && loop(b);
				case TWhile(cond, body, flag): loop(cond) || (flag == DoWhile || Texpr.isTrueExpr(cond)) && inLoop(body);
				case TTry(a, []): loop(a);
				// The try expression is irrelevant because we have to conservatively assume that
				// anything could throw control flow into the catch expressions.
				case TTry(_, catches): Texpr.all(c -> loop(c.expr), catches);
				case _: Texpr.checkExpr(loop, e);
			};
		}
		try return loop(e)
		catch (_:BreakOrContinue) return true;
	}
}
