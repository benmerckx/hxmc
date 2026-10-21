package coro;

import core.TType;
import core.Ast;
import core.Texpr;
import core.Globals;
import core.Globals.*;
import core.TFunctions.*;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

/*
	Code that should eventually be moved elsewhere.
*/
// port: OCaml methods named Haxe keywords use a make prefix.
class TexprBuilder {
	var basic:BasicTypes;
	var defaultPos:Pos;

	public function new(basic:BasicTypes, defaultPos:Pos) {
		this.basic = basic;
		this.defaultPos = defaultPos;
	}

	public var tvoid(get, never):T;

	function get_tvoid():T return basic.tvoid;

	public function assign(lhs:TExpr,
			rhs:TExpr):TExpr return mk(TBinop(OpAssign, lhs, rhs), lhs.etype, core.Ast.punion(lhs.epos, rhs.epos));

	public function binop(op:Binop, lhs:TExpr, rhs:TExpr,
			t:T):TExpr return mk(TBinop(op, lhs, rhs), t, core.Ast.punion(lhs.epos, rhs.epos));

	public function bool(b:Bool, p:Pos):TExpr return mk(TConst(TBool(b)), basic.tbool, p);

	public function makeBreak(p:Pos):TExpr return mk(TBreak, tDynamic, p);

	public function call(e1:TExpr, el:Vector<TExpr>,
			tret:T):TExpr return mk(TCall(e1, el), tret, core.Ast.punion(e1.epos, Texpr.punionEl(e1.epos, el)));

	public function makeContinue(p:Pos):TExpr return mk(TContinue, tDynamic, p);

	public function local(v:TVar, p:Pos):TExpr return mk(TLocal(v), v.vType, p);

	public function ifThen(eif:TExpr,
			ethen:TExpr):TExpr return mk(TIf(eif, ethen, null), basic.tvoid, core.Ast.punion(eif.epos, ethen.epos));

	public function ifThenElse(eif:TExpr, ethen:TExpr, eelse:TExpr,
			t:T):TExpr return mk(TIf(eif, ethen, eelse), t, core.Ast.punion(eif.epos, eelse.epos));

	public function instanceField(e:TExpr, c:TClass, params:core.TType.TParams, cf:TClassField,
			t:T):TExpr return mk(TField(e, FInstance(c, params, cf)), t, e.epos);

	public function int(i:Int, p:Pos):TExpr return mk(TConst(TInt(i)), basic.tint, p);

	public function meta0(m:core.MetaList.StrictMeta,
			e:TExpr):TExpr return mk(TMeta({meta: m, exprs: vector(), pos: e.epos}, e), e.etype, e.epos);

	public function meta1(m:core.MetaList.StrictMeta, marg1:core.Ast.Expr,
			e:TExpr):TExpr return mk(TMeta({meta: m, exprs: vector(marg1), pos: e.epos}, e), e.etype, e.epos);

	public function makeNull(t:T, p:Pos):TExpr return mk(TConst(TNull), t, p);

	public function opBoolAnd(e1:TExpr, e2:TExpr):TExpr return binop(OpBoolAnd, e1, e2, basic.tbool);

	public function opEq(e1:TExpr, e2:TExpr):TExpr return binop(OpEq, e1, e2, basic.tbool);

	public function makeReturn(e:TExpr):TExpr return mk(TReturn(e), tDynamic, e.epos);

	public function staticField(e:TExpr, c:TClass, cf:TClassField, t:T):TExpr return mk(TField(e, FStatic(c, cf)), t, e.epos);

	public function string(s:String, p:Pos):TExpr return mk(TConst(TString(s)), basic.tstring, p);

	public function makeSuper(t:T, p:Pos):TExpr return mk(TConst(TSuper), t, p);

	public function makeThis(t:T, p:Pos):TExpr return mk(TConst(TThis), t, p);

	public function makeThrow(e:TExpr):TExpr return mk(TThrow(e), tDynamic, e.epos);

	public function varInit(v:TVar, e:TExpr):TExpr return mk(TVar(v, e), basic.tvoid, core.Ast.punion(v.vPos, e.epos));

	public function varInitNull(v:TVar):TExpr return varInit(v, makeNull(v.vType, v.vPos));

	public function voidBlock(el:Vector<TExpr>):TExpr return mk(TBlock(el), basic.tvoid, Texpr.punionEl(defaultPos, el));

	public function voidBlockAt(el:Vector<TExpr>, p:Pos):TExpr return mk(TBlock(el), basic.tvoid, p);
}
