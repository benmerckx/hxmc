/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package optimization;

import core.Globals;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Texpr;
import core.Texpr.*;
import core.TFunctions.TypeExit;
import optimization.AnalyzerTypes;
import optimization.AnalyzerTypes.BasicBlock.*;
import optimization.AnalyzerTypes.Graph.*;
import optimization.AnalyzerTexpr.*;
import optimization.OptimizerTexpr.*;

private typedef BlockValue = {var bb:BasicBlockData; var value:TExpr;}
private typedef BlockValues = {var bb:BasicBlockData; var values:Array<TExpr>;}

/*
	Transforms an expression to a graph, and a graph back to an expression. This module relies on TexprFilter being
	run first.

	The created graph is intact and can immediately be transformed back to an expression, or used for analysis first.
*/
class AnalyzerTexprTransformer {
	public static function buildFunc(ctx:AnalyzerContext, bb:BasicBlockData, tf:TFunc, t:T,
			p:Pos):{root:BasicBlockData, exit:BasicBlockData} {
		var builder = new FunctionGraphBuilder(ctx, tf, p);
		return builder.build(bb, t);
	}

	public static function fromTfunction(ctx:AnalyzerContext, tf:TFunc, t:T, p:Pos):Void {
		var g = ctx.graph;
		var f = buildFunc(ctx, g.gRoot, tf, t, p);
		ctx.entry = f.root;
		closeNode(g.gRoot);
		g.gExit = f.exit;
	}

	public static function terminatorToTexprMaybe(term:TerminatorKind):Null<TExpr> return switch term {
		case TermReturn(p): mk(TReturn(null), tDynamic, p);
		case TermBreak(p): mk(TBreak, tDynamic, p);
		case TermContinue(p): mk(TContinue, tDynamic, p);
		case TermReturnValue(e, p): mk(TReturn(e), tDynamic, p);
		case TermThrow(e, p): mk(TThrow(e), tDynamic, p);
		case TermCondBranch(e): e; // TODO: this shouldn't be here
		case _: null;
	};

	public static function blockToTexprEl(ctx:AnalyzerContext, bb:BasicBlockData):Array<TExpr> {
		if (bb.bbDominator == ctx.graph.gUnreachable) return [];
		inline function block(bb:BasicBlockData):TExpr return blockToTexpr(ctx, bb);
		inline function ifLive(bb:BasicBlockData):Null<BasicBlockData> return !ctx.didOptimize || !ctx.config.localDce
			|| hasBlockFlag(bb, BlockDce) ? bb : null;
		function getTerminator():TExpr return switch bb.bbTerminator {
			case TermCondBranch(e): e;
			case _: throw "AnalyzerTexprTransformer.getTerminator";
		};
		var next:Null<BasicBlockData>;
		var term:Null<TExpr>;
		switch bb.bbSyntaxEdge {
			case SESubBlock(sub, n):
				next = n;
				term = block(sub);
			case SEMerge(n):
				next = n;
				term = null;
			case SENone:
				next = null;
				term = terminatorToTexprMaybe(bb.bbTerminator);
			case SETry(bt, _, catches, n, p):
				next = ifLive(n);
				term = mk(TTry(block(bt), catches.map(c -> {variable: c.v, expr: block(c.bb)})), ctx.com.basic.tvoid, p);
			case SEIfThen(bt, n, p):
				next = ifLive(n);
				term = mk(TIf(getTerminator(), block(bt), null), ctx.com.basic.tvoid, p);
			case SEIfThenElse(bt, be, n, t, p):
				next = ifLive(n);
				term = mk(TIf(getTerminator(), block(bt), block(be)), t, p);
			case SEWhile(body, n, p):
				var e2 = block(body);
				next = ifLive(n);
				term = mk(TWhile(getTerminator(), e2, NormalWhile), ctx.com.basic.tvoid, p);
			case SESwitch(ss):
				var cases = ss.ssCases.map(c -> ({casePatterns: c.values, caseExpr: block(c.bb)} : core.TType.TSwitchCase));
				var s = mkSwitch(getTerminator(), cases, ss.ssDefault == null ? null : block(ss.ssDefault), ss.ssExhaustive);
				next = ss.ssNext;
				term = mk(TSwitch(s), ctx.com.basic.tvoid, ss.ssPos);
		}
		var el = bb.bbEl.copy();
		if (term != null) el.push(term);
		if (next != null) el = el.concat(blockToTexprEl(ctx, next));
		return el;
	}

	public static function blockToTexpr(ctx:AnalyzerContext, bb:BasicBlockData):TExpr {
		if (!bb.bbClosed) throw "assert: block not closed";
		return mk(TBlock(blockToTexprEl(ctx, bb)), bb.bbType, bb.bbPos);
	}

	public static function func(ctx:AnalyzerContext, i:Int):TExpr {
		var info = ctx.graph.gFunctions.get(i);
		if (info == null) throw core.TFunctions.NotFound.raise();
		var e = blockToTexpr(ctx, info.bb);
		function loop(e:TExpr):TExpr return switch e.eexpr {
			case TLocal(v): withExpr(e, TLocal(getVarOrigin(ctx.graph, v)));
			case TVar(v, eo):
				var eo = eo == null ? null : loop(eo);
				var origin = getVarOrigin(ctx.graph, v);
				maybeInheritVarName(origin, v);
				withExpr(e, TVar(origin, eo));
			case TBinop(OpAssign, e1, e4 = {eexpr: TBinop(op, e2, e3)}) if (targetHandlesAssignOps(ctx.com, e3)):
				var e1 = loop(e1);
				var e2 = loop(e2);
				var e3 = loop(e3);
				var valid = switch op {
					case OpAdd | OpMult | OpDiv | OpSub | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr | OpMod: true;
					case OpAssignOp(_) | OpInterval | OpArrow | OpIn | OpNullCoal | OpAssign | OpEq | OpNotEq | OpGt | OpGte | OpLt |
						OpLte | OpBoolAnd | OpBoolOr: false;
				};
				switch [e1.eexpr, e2.eexpr] {
					case [TLocal(v1), TLocal(v2)] if (v1 == v2 && !hasVarFlag(v1, VCaptured) && valid):
						switch [op, e3.eexpr] {
							case [OpAdd | OpSub, TConst(TInt(1))]
								if (core.TOther.ExtType.isNumeric(core.Abstract.followWithAbstracts(v1.vType))): withExpr(e,
									TUnop(op == OpAdd ? Increment : Decrement, Prefix, e1));
							case _: withExpr(e, TBinop(OpAssignOp(op), e1, e3));
						}
					case _: withExpr(e, TBinop(OpAssign, e1, withExpr(e4, TBinop(op, e2, e3))));
				}
			case TCall({eexpr: TConst(TString("fun"))}, [{eexpr: TConst(TInt(i))}]): func(ctx, i);
			case TCall({eexpr: TIdent(s)}, _) if (isReallyUnbound(s)): e;
			case _: mapExpr(loop, e);
		}
		return mk(TFunction({tfArgs: info.tf.tfArgs, tfType: info.tf.tfType, tfExpr: loop(e)}), info.type, info.pos);
	}

	public static function toTexpr(ctx:AnalyzerContext):TExpr return func(ctx, ctx.entry.bbId);
}

// port: the upstream mutually recursive local functions live in a per-function object.
private class FunctionGraphBuilder {
	var ctx:AnalyzerContext;
	var g:GraphData;
	var tf:TFunc;
	var p:Pos;
	var root:BasicBlockData;
	var exit:BasicBlockData;
	var breaks:Array<BasicBlockData> = [];
	var continueBlock:Null<BasicBlockData> = null;
	var tryStack:Array<BasicBlockData> = [];

	public function new(ctx:AnalyzerContext, tf:TFunc, p:Pos) {
		this.ctx = ctx;
		g = ctx.graph;
		this.tf = tf;
		this.p = p;
		root = createNode(BKFunctionBegin(tf), tf.tfExpr.etype, tf.tfExpr.epos);
		exit = createNode(BKFunctionEnd, tf.tfExpr.etype, tf.tfExpr.epos);
	}

	function createNode(kind:BlockKind, t:T, p:Pos):BasicBlockData {
		var bb = Graph.createNode(g, kind, t, p);
		bb.bbLoopGroups = ctx.loopStack;
		return bb;
	}

	public function build(bb:BasicBlockData, t:T):{root:BasicBlockData, exit:BasicBlockData} {
		addFunction(g, tf, t, p, root);
		addCfgEdge(bb, root, CFGFunction);
		var last = block(root, tf.tfExpr);
		closeNode(last);
		addCfgEdge(last, exit, CFGGoto); // implied return
		closeNode(exit);
		return {root: root, exit: exit};
	}

	function beginLoop(pre:BasicBlockData, cont:BasicBlockData):Void->Array<BasicBlockData> {
		var oldBreaks = breaks;
		var oldContinue = continueBlock;
		breaks = [];
		continueBlock = cont;
		var id = ctx.loopCounter;
		g.gLoops.set(id, pre);
		ctx.loopStack = [id].concat(ctx.loopStack);
		cont.bbLoopGroups = [id].concat(cont.bbLoopGroups);
		ctx.loopCounter = id + 1;
		return function() {
			var result = breaks;
			breaks = oldBreaks;
			continueBlock = oldContinue;
			ctx.loopStack = ctx.loopStack.slice(1);
			return result;
		};
	}

	function beginTry(bb:BasicBlockData):Void->Void {
		tryStack = [bb].concat(tryStack);
		return function() tryStack = tryStack.slice(1);
	}

	function addTerminator(bb:BasicBlockData, term:TerminatorKind):BasicBlockData {
		bb.bbTerminator = term;
		closeNode(bb);
		return g.gUnreachable;
	}

	function checkUnboundCall(s:String, el:Array<TExpr>):Void {
		if (s == "$ref") switch el {
			case [{eexpr: TLocal(v)}]:
				addVarFlag(v, VCaptured);
			case _:
		}
		if (isUnboundCallThatMightHaveSideEffects(s, el)) ctx.hasUnbound = true;
	}

	function noVoid(t:T, p:Pos):Void if (core.TOther.ExtType.isVoid(follow(t))) core.Error.raiseTypingError("Cannot use Void as value", p);

	// port: name_stack is consed and popped with List.tl upstream; here its top is the array's last element.
	var popName:Void->Void = null;

	function pushName(s:String):Void->Void {
		ctx.nameStack.push(s);
		if (popName == null) popName = function() ctx.nameStack.pop();
		return popName;
	}

	function checkRef(v:TVar, e:TExpr):Void if (core.TOther.ExtType.hasReferenceSemantics(v.vType)) switch Texpr.skip(e).eexpr {
		case TLocal(w):
			addVarFlag(w, VCaptured);
		case _:
	}

	function valueRaw(bb:BasicBlockData, e:TExpr):BlockValue {
		inline function result(def:TExprDef):BlockValue return {bb: bb, value: withExpr(e, def)};
		return switch e.eexpr {
			case TLocal(_) | TIdent(_): {bb: bb, value: e};
			case TBinop(OpAssign, e1 = {eexpr: TLocal(v)}, e2): {bb: blockElement(bb, e), value: e1};
			case TBlock([e1]): value(bb, e1);
			case TBlock(_) | TSwitch(_) | TTry(_, _): bindToTemp(bb, e);
			case TIf(_, _, otherwise) if (otherwise != null): bindToTemp(bb, e);
			case TCall({eexpr: TIdent(s)}, el) if (isReallyUnbound(s)):
				checkUnboundCall(s, el);
				{bb: bb, value: e};
			case TCall(e1, el): call(bb, e, e1, el);
			case TBinop(OpAssignOp(op), ea = {eexpr: TArray(e1, e2)}, e3): arrayAssignOp(bb, op, e, ea, e1, e2, e3);
			case TBinop(OpAssignOp(op), ef = {eexpr: TField(e1, fa)}, e2): fieldAssignOp(bb, op, e, ef, e1, fa, e2);
			case TBinop(op = OpAssign | OpAssignOp(_), e1, e2):
				var r = value(bb, e1);
				var s = value(r.bb, e2);
				bb = s.bb;
				result(TBinop(op, r.value, s.value));
			case TBinop(op, e1, e2):
				var r = orderedValueList(bb, [e1, e2]);
				bb = r.bb;
				switch r.values {
					case [a, b]: result(TBinop(op, a, b));
					case [a]:
						if (bb != g.gUnreachable) throw "assert: reachable short value list";
						{bb: bb, value: a};
					case _: throw "AnalyzerTexprTransformer.binop";
				}
			case TUnop(op, flag, e1):
				var r = value(bb, e1);
				bb = r.bb;
				result(TUnop(op, flag, r.value));
			case TArrayDecl(el):
				var r = orderedValueList(bb, el);
				bb = r.bb;
				result(TArrayDecl(r.values));
			case TObjectDecl(fl):
				var r = orderedValueList(bb, fl.map(f -> f.expr));
				bb = r.bb;
				if (fl.length != r.values.length) throw "Invalid_argument: List.map2";
				result(TObjectDecl([for (i in 0...fl.length) {key: fl[i].key, expr: r.values[i]}]));
			case TField({eexpr: TTypeExpr(_)}, _): {bb: bb, value: e};
			case TField(e1, fa):
				var r = value(bb, e1);
				bb = r.bb;
				result(TField(r.value, fa));
			case TArray(e1, e2):
				var r = orderedValueList(bb, [e1, e2]);
				bb = r.bb;
				switch r.values {
					case [a, b]: result(TArray(a, b));
					case [a]:
						if (bb != g.gUnreachable) throw "assert: reachable short value list";
						{bb: bb, value: a};
					case _: throw "AnalyzerTexprTransformer.array";
				}
			case TMeta(m, e1):
				var r = value(bb, e1);
				bb = r.bb;
				result(TMeta(m, r.value));
			case TParenthesis(e1):
				var r = value(bb, e1);
				bb = r.bb;
				result(TParenthesis(r.value));
			case TCast(e1, mt):
				var r = value(bb, e1);
				bb = r.bb;
				result(TCast(r.value, mt));
			case TNew(c, tl, el):
				var r = orderedValueList(bb, el);
				bb = r.bb;
				result(TNew(c, tl, r.values));
			case TEnumParameter(e1, ef, ei):
				var r = value(bb, e1);
				bb = r.bb;
				result(TEnumParameter(r.value, ef, ei));
			case TEnumIndex(e1):
				var r = value(bb, e1);
				bb = r.bb;
				result(TEnumIndex(r.value));
			case TFunction(tf):
				var fn = AnalyzerTexprTransformer.buildFunc(ctx, bb, tf, e.etype, e.epos);
				var efun = mk(TConst(TString("fun")), tDynamic, p);
				var ec = mk(TCall(efun, [mk(TConst(TInt(fn.root.bbId)), ctx.com.basic.tint, e.epos)]), tDynamic, p);
				var next = createNode(BKNormal, bb.bbType, bb.bbPos);
				addCfgEdge(bb, next, CFGGoto);
				setSyntaxEdge(bb, SEMerge(next));
				closeNode(bb);
				addCfgEdge(fn.exit, next, CFGGoto);
				{bb: next, value: ec};
			case TConst(_) | TTypeExpr(_): {bb: bb, value: e};
			case TThrow(_) | TReturn(_) | TBreak | TContinue: {bb: blockElement(bb, e), value: mk(TConst(TNull), tDynamic, e.epos)};
			case TVar(_, _) | TWhile(_, _, _) | TIf(_, _, _): core.Error.raiseTypingError("Cannot use this expression as value", e.epos);
		};
	}

	function value(bb:BasicBlockData, e:TExpr):BlockValue {
		var r = valueRaw(bb, e);
		noVoid(r.value.etype, r.value.epos);
		return r;
	}

	function orderedValueList(bb:BasicBlockData, el:Array<TExpr>):BlockValues {
		var checker = createAffectionChecker();
		function optimizable(e:TExpr):Bool return switch e.eexpr {
			case TBinop(_, _, _) | TArray(_, _) | TCall(_, _): true;
			case TParenthesis(a): optimizable(a);
			case _: false;
		};
		var hadSideEffect = false;
		// port: `x :: acc` as a push: `annotated` is read from the end
		var annotated = [];
		var reverse = el.copy();
		reverse.reverse();
		for (e in reverse) if (hadSideEffect) annotated.push({
			affected: checker.mightBeAffected(e) || hasSideEffect(e),
			opt: optimizable(e),
			e: e
		});
		else {
			hadSideEffect = hasSideEffect(e);
			if (hadSideEffect) checker.collectModifiedLocals(e);
			var opt = optimizable(e);
			annotated.push({affected: false, opt: opt, e: e});
			hadSideEffect = hadSideEffect || opt;
		}
		var values = [];
		var i = annotated.length;
		while (i > 0) {
			var item = annotated[--i];
			if (bb != g.gUnreachable) {
				var r = item.affected || item.opt ? bindToTemp(bb, item.e) : value(bb, item.e);
				bb = r.bb;
				values.push(r.value);
			}
		}
		return {bb: bb, values: values};
	}

	function bindToTemp(bb:BasicBlockData, e:TExpr, ?v:TVar):BlockValue {
		inline function unaffected(e:TExpr, e1:TExpr, fa:TFieldAccess):Bool return switch fa {
			case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf) if (switch cf.cfKind {
					case Method(MethNormal): true;
					case _: false;
				}): true;
			case FStatic(_, {cfKind: Method(MethDynamic)}): false;
			case FEnum(_, _): true;
			case FDynamic("cca" | "__Index" | "__s"): true; // This is quite retarded, but we have to deal with this somehow...
			case _: switch [follow(e.etype), follow(e1.etype)] {
					case [TFun(_), TInst(_, _)]: false;
					case [TFun(_), _]: true; // We don't know what's going on here, don't create a temp var (see #5082).
					case _: false;
				}
		};
		var fl:Array<TExpr->TExpr> = [];
		function strip(e:TExpr):TExpr return switch e.eexpr {
			case TField(e1, fa) if (unaffected(e, e1, fa)):
				fl.unshift(e2 -> withExpr(e, TField(e2, fa)));
				strip(e1);
			case TField(e1, fa):
				var fa = switch fa {
					case FInstance(c, tl, cf = {cfKind: Method(_)}): FClosure({cls: c, params: tl}, cf);
					case _: fa;
				};
				withExpr(e, TField(e1, fa));
			case _: e;
		};
		e = strip(e);
		function name(e:TExpr):String return switch e.eexpr {
			case TLocal(v): v.vName;
			case TArray(a, _) | TField(a, _) | TParenthesis(a) | TCast(a, null) | TMeta(_, a): name(a);
			case _: ctx.nameStack.length > 0 ? ctx.nameStack[ctx.nameStack.length - 1] : ctx.tempVarName;
		};
		if (v == null) v = allocVar(VGenerated, name(e), e.etype, e.epos);
		bb = declareVarAndAssign(bb, v, e, e.epos);
		e = withExpr(e, TLocal(v));
		for (f in fl) e = f(e);
		return {bb: bb, value: e};
	}

	function declareVarAndAssign(bb:BasicBlockData, v:TVar, e:TExpr, p:Pos):BasicBlockData {
		noVoid(v.vType, p);
		// TODO: this section shouldn't be here because it can be handled as part of the normal value processing
		function strip(bb:BasicBlockData, e:TExpr):BlockValue return switch e.eexpr {
			case TParenthesis(a): strip(bb, a);
			case TBlock(el):
				if (el.length == 0) throw "AnalyzerTexprTransformer.empty value block";
				for (a in el.slice(0, el.length - 1)) {
					bb = blockElement(bb, a);
					if (bb == g.gUnreachable) throw new TypeExit();
				}
				strip(bb, el[el.length - 1]);
			case _: {bb: bb, value: e};
		};
		try {
			var r = strip(bb, e);
			bb = r.bb;
			e = r.value;
			var ev = mk(TLocal(v), v.vType, p);
			var wasAssigned = false;
			function assign(e:TExpr):TExpr {
				if (!wasAssigned) {
					wasAssigned = true;
					addTexpr(bb, mk(TVar(v, null), ctx.com.basic.tvoid, ev.epos));
				}
				return mk(TBinop(OpAssign, ev, e), ev.etype, ev.epos);
			}
			var close = pushName(v.vName);
			try {
				bb = blockElementPlus(bb, mapValues(assign, e), e -> mk(TVar(v, e), ctx.com.basic.tvoid, ev.epos));
			} catch (_:TypeExit) {
				var r = value(bb, e);
				bb = r.bb;
				addTexpr(bb, mk(TVar(v, r.value), ctx.com.basic.tvoid, ev.epos));
			}
			close();
			return bb;
		} catch (_:TypeExit) return g.gUnreachable;
	}

	function blockElementPlus(bb:BasicBlockData, pair:{expr:TExpr, finalExpr:Null<TExpr>}, f:TExpr->TExpr):BasicBlockData {
		bb = blockElement(bb, pair.expr);
		if (pair.finalExpr != null && bb != g.gUnreachable) bb = blockElement(bb, f(pair.finalExpr));
		return bb;
	}

	function blockElementValue(bb:BasicBlockData, e:TExpr, f:TExpr->TExpr):BasicBlockData return blockElementPlus(bb, mapValues(f, e), f);

	function call(bb:BasicBlockData, e:TExpr, e1:TExpr, el:Array<TExpr>):BlockValue {
		function check(e:TExpr, t:T):TExpr return switch e.eexpr {
			case TLocal(v) if (core.TOther.ExtType.hasReferenceSemantics(t)):
				addVarFlag(v, VCaptured);
				e;
			case _: if (core.TOther.ExtType.hasVariableSemantics(t)) {
					var v = allocVar(VGenerated, "tmp", t, e.epos);
					var r = bindToTemp(bb, e, v);
					bb = r.bb;
					r.value;
				} else e;
		};
		el = codegen.Codegen.UnificationCallback.checkCall(check, el, e1.etype);
		var r = orderedValueList(bb, [e1].concat(el));
		if (r.values.length == 0) throw "AnalyzerTexprTransformer.call";
		return {bb: r.bb, value: withExpr(e, TCall(r.values[0], r.values.slice(1)))};
	}

	function arrayAssignOp(bb:BasicBlockData, op:Binop, e:TExpr, ea:TExpr, e1:TExpr, e2:TExpr, e3:TExpr):BlockValue {
		var r1 = bindToTemp(bb, e1);
		var r2 = bindToTemp(r1.bb, e2);
		ea = withExpr(ea, TArray(r1.value, r2.value));
		var r4 = bindToTemp(r2.bb, ea);
		var r3 = bindToTemp(r4.bb, e3);
		var eop = withExpr(e, TBinop(op, r4.value, r3.value));
		addTexpr(r3.bb, withExpr(e, TBinop(OpAssign, ea, eop)));
		return {bb: r3.bb, value: ea};
	}

	function fieldAssignOp(bb:BasicBlockData, op:Binop, e:TExpr, ef:TExpr, e1:TExpr, fa:TFieldAccess, e2:TExpr):BlockValue {
		var keep = switch fa {
			case FInstance(c, _, _): isStackAllocated(c);
			case FClosure(ct, _) if (ct != null): isStackAllocated(ct.cls);
			case _: false;
		};
		// port: hxmc's struct values (AnalyzerTexpr.keepCopyHook): a struct base copied into a temporary would take
		// ... the assignment, so it stays a place, with its reference base (if any) bound to a temporary instead
		var hook = AnalyzerTexpr.keepCopyHook;
		function structBase(bb:BasicBlockData, e:TExpr):BlockValue return switch e.eexpr {
			case TField({eexpr: TTypeExpr(_)}, _): {bb: bb, value: e};
			case TField(e0, fa):
				var r = hook(e0.etype, e0) ? structBase(bb, e0) : bindToTemp(bb, e0);
				{bb: r.bb, value: withExpr(e, TField(r.value, fa))};
			case _: {bb: bb, value: e};
		};
		var r1:BlockValue = keep ? {bb: bb, value: e1} : hook != null && hook(e1.etype, e1) ? structBase(bb, e1) : bindToTemp(bb, e1);
		ef = withExpr(ef, TField(r1.value, fa));
		var r3 = bindToTemp(r1.bb, ef);
		var r2 = bindToTemp(r3.bb, e2);
		addTexpr(r2.bb, withExpr(e, TBinop(OpAssign, ef, withExpr(e, TBinop(op, r3.value, r2.value)))));
		return {bb: r2.bb, value: ef};
	}

	function blockElement(bb:BasicBlockData, e:TExpr):BasicBlockData return switch e.eexpr {
		// variables
		case TVar(v, null):
			addTexpr(bb, e);
			bb;
		case TVar(v, e1):
			checkRef(v, e1);
			declareVarAndAssign(bb, v, e1, e.epos);
		case TBinop(OpAssign, e1 = {eexpr: TLocal(v)}, e2):
			checkRef(v, e2);
			var close = pushName(v.vName);
			try {
				bb = blockElementValue(bb, e2, e -> mk(TBinop(OpAssign, e1, e), e.etype, e.epos));
			} catch (_:TypeExit) {
				var r = value(bb, e2);
				bb = r.bb;
				addTexpr(bb, withExpr(e, TBinop(OpAssign, e1, r.value)));
			}
			close();
			bb;
		// branching
		case TMeta({meta: core.MetaList.StrictMeta.MergeBlock}, {eexpr: TBlock(el)}): blockEl(true, bb, el);
		case TBlock([]) if (core.TOther.ExtType.isVoid(follow(e.etype))): bb;
		case TBlock(el):
			var sub = createNode(BKSub, e.etype, e.epos);
			addCfgEdge(bb, sub, CFGGoto);
			closeNode(bb);
			var subNext = blockEl(true, sub, el);
			if (subNext != g.gUnreachable) {
				var next = createNode(BKNormal, bb.bbType, bb.bbPos);
				setSyntaxEdge(bb, SESubBlock(sub, next));
				addCfgEdge(subNext, next, CFGGoto);
				closeNode(subNext);
				next;
			} else {
				setSyntaxEdge(bb, SEMerge(sub));
				closeNode(subNext);
				subNext;
			}
		case TIf(e1, e2, null):
			var r = bindToTemp(bb, e1);
			bb = r.bb;
			if (bb == g.gUnreachable) bb; else {
				var bt = createNode(BKConditional, e2.etype, e2.epos);
				bb.bbTerminator = TermCondBranch(r.value);
				addCfgEdge(bb, bt, CFGCondBranch(mk(TConst(TBool(true)), ctx.com.basic.tbool, e2.epos)));
				var tn = block(bt, e2);
				var next = createNode(BKNormal, bb.bbType, bb.bbPos);
				setSyntaxEdge(bb, SEIfThen(bt, next, e.epos));
				addCfgEdge(bb, next, CFGCondElse);
				closeNode(bb);
				addCfgEdge(tn, next, CFGGoto);
				closeNode(tn);
				next;
			}
		case TIf(e1, e2, e3):
			var r = bindToTemp(bb, e1);
			bb = r.bb;
			if (bb == g.gUnreachable) bb; else {
				var bt = createNode(BKConditional, e2.etype, e2.epos);
				var be = createNode(BKConditional, e3.etype, e3.epos);
				bb.bbTerminator = TermCondBranch(r.value);
				addCfgEdge(bb, bt, CFGCondBranch(mk(TConst(TBool(true)), ctx.com.basic.tbool, e2.epos)));
				addCfgEdge(bb, be, CFGCondElse);
				closeNode(bb);
				var tn = block(bt, e2);
				var en = block(be, e3);
				if (tn == g.gUnreachable && en == g.gUnreachable) {
					setSyntaxEdge(bb, SEIfThenElse(bt, be, g.gUnreachable, e.etype, e.epos));
					g.gUnreachable;
				} else {
					var next = createNode(BKNormal, bb.bbType, bb.bbPos);
					setSyntaxEdge(bb, SEIfThenElse(bt, be, next, e.etype, e.epos));
					addCfgEdge(tn, next, CFGGoto);
					addCfgEdge(en, next, CFGGoto);
					closeNode(tn);
					closeNode(en);
					next;
				}
			}
		case TSwitch(s):
			var exhaustive = isExhaustive(s);
			var r = bindToTemp(bb, s.switchSubject);
			bb = r.bb;
			bb.bbTerminator = TermCondBranch(r.value);
			var reachable = [];
			inline function makeCase(e:TExpr):BasicBlockData {
				var bc = createNode(BKConditional, e.etype, e.epos);
				var cn = block(bc, e);
				if (cn != g.gUnreachable) reachable.unshift(cn);
				closeNode(cn);
				return bc;
			}
			var cases = s.switchCases.map(c -> {
				var bc = makeCase(c.caseExpr);
				for (e in c.casePatterns) addCfgEdge(bb, bc, CFGCondBranch(e));
				return {values: c.casePatterns, bb: bc};
			});
			var def = s.switchDefault == null ? null : makeCase(s.switchDefault);
			if (def != null) addCfgEdge(bb, def, CFGCondElse);
			var ss:SyntaxSwitch = {
				ssCases: cases,
				ssDefault: def,
				ssPos: e.epos,
				ssNext: g.gUnreachable,
				ssExhaustive: exhaustive
			};
			if (exhaustive && reachable.length == 0) {
				setSyntaxEdge(bb, SESwitch(ss));
				closeNode(bb);
				g.gUnreachable;
			} else {
				var next = createNode(BKNormal, bb.bbType, bb.bbPos);
				if (!exhaustive) addCfgEdge(bb, next, CFGGoto);
				for (b in reachable) addCfgEdge(b, next, CFGGoto);
				ss.ssNext = next;
				setSyntaxEdge(bb, SESwitch(ss));
				closeNode(bb);
				next;
			}
		case TWhile(e1, e2, NormalWhile):
			var pre = createNode(BKLoopHead, e1.etype, e1.epos);
			addCfgEdge(bb, pre, CFGGoto);
			setSyntaxEdge(bb, SEMerge(pre));
			closeNode(bb);
			var close = beginLoop(bb, pre);
			var body = createNode(BKNormal, e2.etype, e2.epos);
			var bodyNext = block(body, e2);
			var loopBreaks = close();
			var next = if (loopBreaks.length == 0) {
				// The loop appears to be infinite, let's assume that something within it throws.
				// Otherwise DCE's mark-pass won't see its body and removes everything.
				addCfgEdge(body, exit, CFGMaybeThrow);
				g.gUnreachable;
			} else createNode(BKNormal, bb.bbType, bb.bbPos);
			for (b in loopBreaks) addCfgEdge(b, next, CFGGoto);
			setSyntaxEdge(pre, SEWhile(body, next, e.epos));
			pre.bbTerminator = TermCondBranch(e1);
			if (bodyNext != g.gUnreachable) addCfgEdge(bodyNext, pre, CFGGoto);
			addCfgEdge(pre, body, CFGGoto);
			closeNode(bodyNext);
			closeNode(pre);
			next;
		case TTry(e1, catches):
			var bt = createNode(BKNormal, e1.etype, e1.epos);
			var bx = createNode(BKException, tDynamic, e.epos);
			addCfgEdge(bb, bt, CFGGoto);
			var close = beginTry(bx);
			var tn = block(bt, e1);
			close();
			// We always want to keep catch-blocks, so let's add a pseudo CFG edge if it's unreachable.
			if (bx.bbIncoming.length == 0) addCfgEdge(tn == g.gUnreachable ? bt : tn, bx, CFGMaybeThrow);
			var reachable = tn != g.gUnreachable;
			var cs = catches.map(c -> {
				var bc = createNode(BKCatch(c.variable), c.expr.etype, c.expr.epos);
				addCfgEdge(bx, bc, CFGGoto);
				var cn = block(bc, c.expr);
				reachable = reachable || cn != g.gUnreachable;
				return {v: c.variable, bb: bc, next: cn};
			});
			var next = reachable ? createNode(BKNormal, bb.bbType, bb.bbPos) : g.gUnreachable;
			var finalCatches = cs.map(c -> {
				if (c.next != g.gUnreachable) addCfgEdge(c.next, next, CFGGoto);
				closeNode(c.next);
				return {v: c.v, bb: c.bb};
			});
			setSyntaxEdge(bb, SETry(bt, bx, finalCatches, next, e.epos));
			if (tn != g.gUnreachable) addCfgEdge(tn, next, CFGGoto);
			closeNode(tn);
			closeNode(bx);
			closeNode(bb);
			next;
		// control flow
		case TReturn(null):
			addCfgEdge(bb, exit, CFGGoto);
			addTerminator(bb, TermReturn(e.epos));
		case TReturn(e1) if (core.TOther.ExtType.isVoid(follow(e1.etype))): blockElement(blockElement(bb, e1),
				mk(TReturn(null), tDynamic, e.epos));
		case TReturn(e1): try {
				blockElementValue(bb, e1, e -> mk(TReturn(e), tDynamic, e.epos));
			} catch (_:TypeExit) {
				var r = value(bb, e1);
				addCfgEdge(r.bb, exit, CFGGoto);
				addTerminator(r.bb, TermReturnValue(r.value, e.epos));
			}
		case TBreak:
			breaks.unshift(bb);
			addTerminator(bb, TermBreak(e.epos));
		case TContinue:
			if (continueBlock == null) throw "AnalyzerTexprTransformer.continue";
			addCfgEdge(bb, continueBlock, CFGGoto);
			addTerminator(bb, TermContinue(e.epos));
		case TThrow(e1): try {
				blockElementValue(bb, e1, e1 -> mk(TThrow(e1), tDynamic, e.epos));
			} catch (_:TypeExit) {
				var r = value(bb, e1);
				if (tryStack.length == 0) addCfgEdge(r.bb, exit, CFGGoto);
				else for (bx in tryStack) addCfgEdge(r.bb, bx, CFGGoto);
				addTerminator(r.bb, TermThrow(r.value, e.epos));
			}
		// side_effects
		case TCall({eexpr: TIdent(s)}, el) if (isReallyUnbound(s)):
			checkUnboundCall(s, el);
			addTexpr(bb, e);
			bb;
		case TCall(e1, el):
			var r = call(bb, e, e1, el);
			addTexpr(r.bb, r.value);
			r.bb;
		case TNew(c, tl, el):
			var r = orderedValueList(bb, el);
			addTexpr(r.bb, withExpr(e, TNew(c, tl, r.values)));
			r.bb;
		case TCast(e1, null): blockElement(bb, e1);
		case TCast(e1, mt):
			var r = value(bb, e1);
			addTexpr(r.bb, withExpr(e, TCast(r.value, mt)));
			r.bb;
		case TBinop(OpAssignOp(op), ea = {eexpr: TArray(e1, e2)}, e3): arrayAssignOp(bb, op, e, ea, e1, e2, e3).bb;
		case TBinop(OpAssignOp(op), ef = {eexpr: TField(e1, fa)}, e2): fieldAssignOp(bb, op, e, ef, e1, fa, e2).bb;
		case TBinop(OpAssign, ea = {eexpr: TArray(e1, e2)}, e3):
			var r = orderedValueList(bb, [e1, e2, e3]);
			switch r.values {
				case [e1, e2, e3]: addTexpr(r.bb, withExpr(e, TBinop(OpAssign, withExpr(ea, TArray(e1, e2)), e3)));
				case _: throw "AnalyzerTexprTransformer.array assign";
			}
			r.bb;
		case TBinop(op = OpAssign | OpAssignOp(_), e1, e2):
			var r1 = value(bb, e1);
			var r2 = value(r1.bb, e2);
			addTexpr(r2.bb, withExpr(e, TBinop(op, r1.value, r2.value)));
			r2.bb;
		case TUnop(op = Increment | Decrement, flag, e1):
			var r = value(bb, e1);
			addTexpr(r.bb, withExpr(e, TUnop(op, flag, r.value)));
			r.bb;
		case TLocal(_) if (!ctx.config.localDce):
			addTexpr(bb, e);
			bb;
		case TField(e1, fa) if (hasSideEffect(e)):
			var r = value(bb, e1);
			addTexpr(r.bb, withExpr(e, TField(r.value, fa)));
			r.bb;
		// no-side-effect
		case TEnumParameter(_, _, _) | TEnumIndex(_) | TFunction(_) | TConst(_) | TTypeExpr(_) | TLocal(_) | TIdent(_): bb;
		// no-side-effect composites
		case TParenthesis(e1) | TMeta(_, e1) | TField(e1, _) | TUnop(_, _, e1): blockElement(bb, e1);
		case TArray(e1, e2) | TBinop(_, e1, e2): blockElement(blockElement(bb, e1), e2);
		case TArrayDecl(el): blockEl(false, bb, el);
		case TObjectDecl(fl): blockEl(false, bb, fl.map(f -> f.expr));
		case TWhile(_, _, DoWhile): throw "AnalyzerTexprTransformer.unlowered do-while";
	};

	function blockEl(allowVoid:Bool, bb:BasicBlockData, el:Array<TExpr>):BasicBlockData {
		var stack = tryStack;
		for (e in el) {
			if (stack.length != 0 && canThrow(e)) {
				var next = createNode(BKNormal, e.etype, e.epos);
				addCfgEdge(bb, next, CFGGoto);
				for (bx in stack) addCfgEdge(bb, bx, CFGMaybeThrow);
				setSyntaxEdge(bb, SEMerge(next));
				closeNode(bb);
				bb = next;
			}
			if (!allowVoid) noVoid(e.etype, e.epos);
			bb = blockElement(bb, e);
			if (bb == g.gUnreachable) return bb;
		}
		return bb;
	}

	function block(bb:BasicBlockData, e:TExpr):BasicBlockData return blockEl(true, bb, switch e.eexpr {
		case TBlock(el): el;
		case _: [e];
	});
}
