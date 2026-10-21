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

import core.Ast;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.TFunctions.TypeExit;
import core.Texpr;
import core.Texpr.*;
import core.Meta;
import optimization.AnalyzerTypes;
import optimization.OptimizerTexpr.*;
import context.PurityState;
import optimization.AnalyzerConfig;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

class AnalyzerTexpr {
	// port: hxmc's struct values (@:hxmc.struct, hxmc/src/hxmc/ir/CInterop.hx) are copied on assignment: true
	// ... here when a variable of type t initialized from e is such a copy, which fusion (of a variable not
	// ... VGenerated: the compiler's own temporaries stand for their expression) and copy propagation must keep
	// ... (replacing the variable by e would make its field writes reach e); always null in the compiler itself.
	public static var keepCopyHook:Null<(t:T, e:TExpr) -> Bool> = null;

	public static function sExprPretty(e:TExpr):String return core.TPrinting.sExprPretty(false, "", false,
		core.TPrinting.sType.bind(core.TPrinting.printContext()), e);

	public static function isStackAllocated(c:TClass):Bool return Meta.has(StructAccess, c.clMeta);

	public static function mapValues(f:TExpr->TExpr, e:TExpr, allowControlFlow:Bool = true):{expr:TExpr, finalExpr:Null<TExpr>} {
		var branching = false;
		var finalExpr = null;
		inline function value(e:TExpr):TExpr {
			if (branching) return f(e);
			finalExpr = e;
			return mk(TConst(TNull), e.etype, e.epos);
		}
		function loop(complex:Bool, e:TExpr):TExpr return switch e.eexpr {
			case TIf(e1, e2, e3) if (e3 != null):
				branching = true;
				var e2 = loop(true, e2);
				var e3 = loop(true, e3);
				withExpr(e, TIf(e1, e2, e3));
			case TSwitch(s):
				branching = true;
				var cases = s.switchCases.map(c -> ({
					casePatterns: c.casePatterns,
					caseExpr: loop(true, c.caseExpr)
				} : core.TType.TSwitchCase));
				var def = s.switchDefault == null ? null : loop(true, s.switchDefault);
				withExpr(e, TSwitch(mkSwitch(s.switchSubject, cases, def, s.switchExhaustive)));
			case TBlock([e1]): loop(complex, e1);
			case TBlock(el): if (el.length > 0) {
					var last = loop(true, el[el.length - 1]);
					var block = withExpr(e, TBlock(el.withLast(last)));
					withExpr(block, TMeta({meta: core.MetaList.StrictMeta.MergeBlock, exprs: vector(), pos: block.epos}, block));
				} else {
					if (!complex) throw new TypeExit();
					value(e);
				}
			case TTry(e1, catches):
				branching = true;
				var e1 = loop(true, e1);
				withExpr(e, TTry(e1, catches.map(c -> {variable: c.variable, expr: loop(true, c.expr)})));
			case TMeta(m, e1): withExpr(e, TMeta(m, loop(complex, e1)));
			case TParenthesis(e1): withExpr(e, TParenthesis(loop(complex, e1)));
			case TBreak | TContinue | TThrow(_) | TReturn(_):
				if (!allowControlFlow) throw new TypeExit();
				e;
			case _:
				if (!complex) throw new TypeExit();
				value(e);
		};
		var result = loop(false, e);
		return {expr: result, finalExpr: finalExpr};
	}

	public static function canThrow(e:TExpr):Bool return switch e.eexpr {
		case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TBlock(_): false;
		case TCall(_, _) | TNew(_, _, _) | TThrow(_)
			| TField(_, _) | TArray(_, _): true; // sigh
		case TCast(_, mt) if (mt != null): true;
		case _: checkExpr(canThrow, e);
	};

	public static function canBeInlined(e:TExpr):Bool return switch e.eexpr {
		case TConst(_): true;
		case TParenthesis(e1) | TMeta(_, e1): canBeInlined(e1);
		case _: false;
	};

	public static function targetHandlesUnops(com:context.SafeCom.SafeContext):Bool return switch com.platform {
		case Lua | Python: false;
		case _: true;
	};

	public static function targetHandlesAssignOps(com:context.SafeCom.SafeContext, e2:TExpr):Bool return switch com.platform {
		case Php: !hasSideEffect(e2);
		case Lua: false;
		case Cpp if (!core.Define.defined(com.defines, core.Define.Cppia)): !hasSideEffect(e2);
		case _: true;
	};

	public static function targetHandlesSideEffectOrder(com:context.SafeCom.SafeContext):Bool return switch com.platform {
		case Cpp: core.Define.defined(com.defines, core.Define.Cppia);
		case Php: false;
		case _: true;
	};

	public static function canBeUsedAsValue(com:context.SafeCom.SafeContext, e:TExpr):Bool {
		switch e.eexpr {
			case TConst(TNull):
				switch com.platform {
					case Cpp | Jvm | Flash | Lua: return false;
					case _:
				}
			case _:
		}
		return canBeUsedAsValueLoop(com, e);
	}

	// port: static, with com passed along: a closure per call and per node otherwise
	static function canBeUsedAsValueLoop(com:context.SafeCom.SafeContext, e:TExpr):Bool return switch e.eexpr {
		case TBlock([e]): canBeUsedAsValueLoop(com, e);
		case TBlock(_) | TSwitch(_) | TTry(_, _) | TReturn(_) | TThrow(_) | TBreak | TContinue: false;
		case TCall({eexpr: TConst(TString("phi"))}, _): false;
		// | TCall _ | TNew _ when (match com.platform with Cpp | Php -> true | _ -> false) -> raise Exit
		case TUnop(Increment | Decrement, _, _) if (!targetHandlesUnops(com)): false;
		case TFunction(_): true;
		case _: !core.Texpr.checkExprWithScom(cannotBeUsedAsValue, com, e);
	};

	static function cannotBeUsedAsValue(com:context.SafeCom.SafeContext, e:TExpr):Bool return !canBeUsedAsValueLoop(com, e);

	public static function wrapMeta(s:String,
			e:TExpr):TExpr return mk(TMeta({meta: core.MetaList.StrictMeta.Custom(s), exprs: vector(), pos: e.epos}, e), e.etype, e.epos);

	public static function isReallyUnbound(s:String):Bool return s != "`trace" && s != "__int__";

	// port: a fresh EReg per use (an EReg keeps its last match; the analyzer runs on several threads)
	static inline function r():EReg return ~/^[A-Za-z0-9_]+$/;

	public static function isUnboundCallThatMightHaveSideEffects(s:String, el:haxe.ds.Vector<TExpr>):Bool return switch [s, el] {
		case ["__js__", [{eexpr: TConst(TString(code))}]] if (r().match(code)): false;
		case _: true;
	};

	public static function maybeInheritVarName(v:TVar, alias:TVar):Void if (v.vName != alias.vName) switch [alias.vKind, v.vKind] {
		case [VUser(_), VUser(_)]:
		case [VUser(_), _]:
			// If we go from a user variable to something else, we probably want to inherit the name.
			v.vName = alias.vName;
		case _:
	}

	public static function typeChangeOk(com:context.SafeCom.SafeContext, t1:T, t2:T):Bool {
		if (t1 == t2) return true;
		function map(t:T):T return switch t {
			case TMono(r): r.tmType == null ? tDynamic : map(r.tmType);
			case _: core.TFunctions.map(map, t);
		};
		t1 = map(t1);
		t2 = map(t2);
		function nullable(t:T):Bool return switch t {
			case TMono(r): r.tmType != null && nullable(r.tmType);
			case TAbstract({aPath: {pack: [], name: "Null"}}, [_]): true;
			case TLazy(f): nullable(lazyType(f));
			case TType(t, tl): nullable(applyTypedef(t, tl));
			case TFun(_) | TInst({clKind: KTypeParameter(_)}, _): false;
			case TAbstract(a, _) if (Meta.has(CoreType, a.aMeta)): !Meta.has(NotNull, a.aMeta);
			case TAbstract(a, tl): !Meta.has(NotNull, a.aMeta) && nullable(applyParams(a.aParams, tl, a.aThis));
			case _: true;
		};
		// Check equality again to cover cases where TMono became t_dynamic
		if (t1 == t2) return true;
		return switch [follow(t1), follow(t2)] {
			case [TDynamic(_), _] | [_, TDynamic(_)]: false;
			case _: com.platformConfig.pfStatic && nullable(t1) != nullable(t2) ? false : typeIseq(t1, t2);
		};
	}

	public static function dynarrayMap<A>(f:A->A, d:Array<A>):Void for (i in 0...d.length) d[i] = f(d[i]);

	public static function dynarrayMapi<A>(f:Int->A->A, d:Array<A>):Void for (i in 0...d.length) d[i] = f(i, d[i]);
}

/*
	This module rewrites some expressions to reduce the amount of special cases for subsequent analysis. After analysis
	it restores some of these expressions back to their original form.

	The following expressions are removed from the AST after `apply` has run:
	- OpBoolAnd and OpBoolOr binary operations are rewritten to TIf
	- OpAssignOp on a variable is rewritten to OpAssign
	- Prefix increment/decrement operations are rewritten to OpAssign
	- Postfix increment/decrement operations are rewritten to a TBlock with OpAssign and OpAdd/OpSub
	- `do {} while(true)` is rewritten to `while(true) {}`
	- TWhile expressions are rewritten to `while (true)` with appropriate conditional TBreak
*/
class TexprFilter {
	public static function apply(com:context.SafeCom.SafeContext, e:TExpr):TExpr {
		function loop(e:TExpr):TExpr return switch e.eexpr {
			case TBinop(op = OpBoolAnd | OpBoolOr, e1, e2):
				var cond = op == OpBoolOr ? mk(TUnop(Not, Prefix, e1), com.basic.tbool, e.epos) : e1;
				var otherwise = mk(TConst(TBool(op == OpBoolOr)), com.basic.tbool, e.epos);
				loop(mk(TIf(cond, e2, otherwise), e.etype, e.epos));
			case TBinop(OpAssignOp(op), e1 = {eexpr: TLocal(_)}, e2):
				var inner = withExpr(e, TBinop(op, e1, e2));
				loop(withExpr(inner, TBinop(OpAssign, e1, inner)));
			case TUnop(op = Increment | Decrement, flag, e1 = {eexpr: TLocal(_)}):
				var one = mk(TConst(TInt(1)), com.basic.tint, e1.epos);
				var assign = withExpr(e, TBinop(OpAssignOp(op == Increment ? OpAdd : OpSub), e1, one));
				loop(flag == Prefix ? assign : mk(TBlock(vector(assign, withExpr(assign, TBinop(op == Increment ? OpSub : OpAdd, e1, one)))),
					assign.etype, assign.epos));
			case TWhile(e1, e2, DoWhile) if (isTrueExpr(e1)): loop(withExpr(e, TWhile(e1, e2, NormalWhile)));
			case TWhile(e1, e2, flag) if (!isTrueExpr(e1)):
				var p = e.epos;
				var br = mk(TBreak, tDynamic, p);
				var not = mk(TUnop(Not, Prefix, Texpr.Builder.mkParent(e1)), e1.etype, e1.epos);
				inline function makeIf(eo:Null<TExpr>):TExpr return mk(TIf(not, br, eo), com.basic.tvoid, p);
				function mapContinue(e:TExpr):TExpr return switch e.eexpr {
					case TContinue: duplicateTvars(eIdentity, makeIf(e));
					case TWhile(_, _, _): e;
					case _: mapExpr(mapContinue, e);
				};
				if (flag != NormalWhile) e2 = mapContinue(e2);
				var condition = makeIf(null);
				var block = flag == NormalWhile ? concat(condition, e2) : concat(e2, condition);
				var yes = Texpr.Builder.mkParent(mk(TConst(TBool(true)), com.basic.tbool, p));
				loop(mk(TWhile(yes, block, NormalWhile), e.etype, p));
			case _: mapExpr(loop, e);
		};
		return loop(e);
	}
}

/*
	An InterferenceReport represents in which way a given code may be influenced and
	how it might influence other code itself. It keeps track of read and write operations
	for both variable and fields, as well as a generic state read and write.
*/
@:structInit class InterferenceReportData {
	public var irVarReads:haxe.ds.IntMap<Bool>;
	public var irVarWrites:haxe.ds.IntMap<Bool>;
	public var irFieldReads:haxe.ds.StringMap<Bool>;
	public var irFieldWrites:haxe.ds.StringMap<Bool>;
	public var irStateRead:Bool;
	public var irStateWrite:Bool;

	public inline function new(irVarReads:haxe.ds.IntMap<Bool>, irVarWrites:haxe.ds.IntMap<Bool>, irFieldReads:haxe.ds.StringMap<Bool>,
			irFieldWrites:haxe.ds.StringMap<Bool>, irStateRead:Bool, irStateWrite:Bool) {
		this.irVarReads = irVarReads;
		this.irVarWrites = irVarWrites;
		this.irFieldReads = irFieldReads;
		this.irFieldWrites = irFieldWrites;
		this.irStateRead = irStateRead;
		this.irStateWrite = irStateWrite;
	}

	public inline function clone():InterferenceReportData return new InterferenceReportData(irVarReads, irVarWrites, irFieldReads,
		irFieldWrites, irStateRead, irStateWrite);
}

class InterferenceReport {
	public static function create():InterferenceReportData return {
		irVarReads: new haxe.ds.IntMap(),
		irVarWrites: new haxe.ds.IntMap(),
		irFieldReads: new haxe.ds.StringMap(),
		irFieldWrites: new haxe.ds.StringMap(),
		irStateRead: false,
		irStateWrite: false
	};

	public static function setVarRead(ir:InterferenceReportData, v:TVar):Void ir.irVarReads.set(v.vId, true);

	public static function setVarWrite(ir:InterferenceReportData, v:TVar):Void ir.irVarWrites.set(v.vId, true);

	public static function setFieldRead(ir:InterferenceReportData, s:String):Void ir.irFieldReads.set(s, true);

	public static function setFieldWrite(ir:InterferenceReportData, s:String):Void ir.irFieldWrites.set(s, true);

	public static function setStateRead(ir:InterferenceReportData):Void ir.irStateRead = true;

	public static function setStateWrite(ir:InterferenceReportData):Void ir.irStateWrite = true;

	public static function hasVarRead(ir:InterferenceReportData, v:TVar):Bool return ir.irVarReads.exists(v.vId);

	public static function hasVarWrite(ir:InterferenceReportData, v:TVar):Bool return ir.irVarWrites.exists(v.vId);

	public static function hasFieldRead(ir:InterferenceReportData, s:String):Bool return ir.irFieldReads.exists(s);

	public static function hasFieldWrite(ir:InterferenceReportData, s:String):Bool return ir.irFieldWrites.exists(s);

	public static function hasStateRead(ir:InterferenceReportData):Bool return ir.irStateRead;

	public static function hasStateWrite(ir:InterferenceReportData):Bool return ir.irStateWrite;

	public static function hasAnyFieldRead(ir:InterferenceReportData):Bool return ir.irFieldReads.iterator().hasNext();

	public static function hasAnyFieldWrite(ir:InterferenceReportData):Bool return ir.irFieldWrites.iterator().hasNext();

	public static function hasAnyVarRead(ir:InterferenceReportData):Bool return ir.irVarReads.iterator().hasNext();

	public static function hasAnyVarWrite(ir:InterferenceReportData):Bool return ir.irVarWrites.iterator().hasNext();

	public static function fromTexpr(e:TExpr):InterferenceReportData {
		var ir = create();
		function loop(e:TExpr):Void switch e.eexpr {
			// vars
			case TLocal(v):
				setVarRead(ir, v);
				if (hasVarFlag(v, VCaptured)) setStateRead(ir);
			case TBinop(OpAssign, {eexpr: TLocal(v)}, e2):
				setVarWrite(ir, v);
				if (hasVarFlag(v, VCaptured)) setStateWrite(ir);
				loop(e2);
			case TBinop(OpAssignOp(_), {eexpr: TLocal(v)}, e2):
				setVarRead(ir, v);
				setVarWrite(ir, v);
				if (hasVarFlag(v, VCaptured)) {
					setStateRead(ir);
					setStateWrite(ir);
				}
				loop(e2);
			case TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
				setVarRead(ir, v);
				setVarWrite(ir, v);
			// fields
			case TField(e1, fa):
				loop(e1);
				if (!isReadOnlyFieldAccess(e1, fa)) setFieldRead(ir, fieldName(fa));
			case TBinop(OpAssign, {eexpr: TField(e1, fa)}, e2):
				setFieldWrite(ir, fieldName(fa));
				loop(e1);
				loop(e2);
			case TBinop(OpAssignOp(_), {eexpr: TField(e1, fa)}, e2):
				var name = fieldName(fa);
				setFieldRead(ir, name);
				setFieldWrite(ir, name);
				loop(e1);
				loop(e2);
			case TUnop(Increment | Decrement, _, {eexpr: TField(e1, fa)}):
				var name = fieldName(fa);
				setFieldRead(ir, name);
				setFieldWrite(ir, name);
				loop(e1);
			// array
			case TArray(e1, e2):
				setStateRead(ir);
				loop(e1);
				loop(e2);
			case TBinop(OpAssign, {eexpr: TArray(e1, e2)}, e3):
				setStateWrite(ir);
				loop(e1);
				loop(e2);
				loop(e3);
			case TBinop(OpAssignOp(_), {eexpr: TArray(e1, e2)}, e3):
				setStateRead(ir);
				setStateWrite(ir);
				loop(e1);
				loop(e2);
				loop(e3);
			case TUnop(Increment | Decrement, _, {eexpr: TArray(e1, e2)}):
				setStateRead(ir);
				setStateWrite(ir);
				loop(e1);
				loop(e2);
			// state
			case TCall({eexpr: TIdent(s)}, el) if (!AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el)):
				for (e in el) loop(e);
			case TNew(c, _, el) if (c.clConstructor != null && PurityStateTools.isPure(c, c.clConstructor)):
				setStateRead(ir);
				for (e in el) loop(e);
			case TCall({eexpr: TField(e1, FEnum(_, _))}, el):
				loop(e1);
				for (e in el) loop(e);
			case TCall({eexpr: TField(e1, fa)}, el) if (PurityStateTools.isPureFieldAccess(fa)):
				setStateRead(ir);
				loop(e1);
				for (e in el) loop(e);
			case TCall(e1, el):
				setStateRead(ir);
				setStateWrite(ir);
				loop(e1);
				for (e in el) loop(e);
			case TNew(_, _, el):
				setStateRead(ir);
				setStateWrite(ir);
				for (e in el) loop(e);
			case TBinop(OpAssign, e1, e2):
				setStateWrite(ir);
				loop(e1);
				loop(e2);
			case TBinop(OpAssignOp(_), e1, e2):
				setStateRead(ir);
				setStateWrite(ir);
				loop(e1);
				loop(e2);
			case TUnop(Increment | Decrement, _, e1):
				setStateRead(ir);
				setStateWrite(ir);
				loop(e1);
			case _:
				iter(loop, e);
		}
		loop(e);
		return ir;
	}

	public static function toString(ir:InterferenceReportData):String {
		inline function ints(map:haxe.ds.IntMap<Bool>):String {
			var keys = [for (k in map.keys()) k];
			keys.sort((a, b) -> b - a);
			return keys.map(Std.string).join(", ");
		}
		inline function strings(map:haxe.ds.StringMap<Bool>):String {
			var keys = [for (k in map.keys()) k];
			keys.sort((a, b) -> core.ds.Key.compareStrings(b, a));
			return keys.join(", ");
		}
		return core.TPrinting.Printer.sRecordFields("", [
			{name: "ir_var_reads", value: ints(ir.irVarReads)},
			{name: "ir_var_writes", value: ints(ir.irVarWrites)},
			{name: "ir_field_reads", value: strings(ir.irFieldReads)},
			{name: "ir_field_writes", value: strings(ir.irFieldWrites)},
			{name: "ir_state_read", value: Std.string(ir.irStateRead)},
			{name: "ir_state_write", value: Std.string(ir.irStateWrite)}
		]);
	}
}

class FusionState {
	var changed = false;
	var varReads = new haxe.ds.IntMap<Int>();
	var varWrites = new haxe.ds.IntMap<Int>();

	public function new() {}

	function change(map:haxe.ds.IntMap<Int>, v:TVar, delta:Int):Void map.set(v.vId, (map.exists(v.vId) ? map.get(v.vId) : 0) + delta);

	public function incReads(v:TVar):Void change(varReads, v, 1);

	public function decReads(v:TVar):Void change(varReads, v, -1);

	public function incWrites(v:TVar):Void change(varWrites, v, 1);

	public function decWrites(v:TVar):Void change(varWrites, v, -1);

	public function getReads(v:TVar):Int return varReads.exists(v.vId) ? varReads.get(v.vId) : 0;

	public function getWrites(v:TVar):Int return varWrites.exists(v.vId) ? varWrites.get(v.vId) : 0;

	public function changeWrites(v:TVar, delta:Int):Void change(varWrites, v, delta);

	public function markChanged():Void changed = true;

	public function reset():Void changed = false;

	public function didChange():Bool return changed;

	public function inferFromTexpr(e:TExpr):Void {
		function loop(e:TExpr):Void switch e.eexpr {
			case TLocal(v):
				incReads(v);
			case TBinop(OpAssign, {eexpr: TLocal(v)}, e2):
				incWrites(v);
				loop(e2);
			case _:
				iter(loop, e);
		}
		loop(e);
	}
}

/*
	Fusion tries to join expressions together in order to make the output "look nicer". To that end,
	several transformations occur:

	- `var x; x = e;` is transformed to `var x = e;`
	- `var x; if(e1) x = e2 else x = e3` is transformed to `var x = e1 ? e2 : e3` on targets that
	  deal well with that.
	- `var x = e;` is transformed to `e` if `x` is unused.
	- Some block-level increment/decrement unary operators are put back into value places and the
	  transformation of their postfix variant is reversed.
	- `x = x op y` is transformed (back) to `x op= y` on targets that deal well with that.

	Most importantly, any `var v = e;` might be fused into expressions that follow it in the same
	block if there is no interference.
*/
class Fusion {
	public static function isAssignOp(op:Binop):Bool return switch op {
		case OpAdd | OpMult | OpDiv | OpSub | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr | OpMod: true;
		case OpAssign | OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte | OpBoolAnd | OpBoolOr | OpAssignOp(_) | OpInterval | OpIn |
			OpNullCoal | OpArrow: false;
	};

	public static function useAssignOp(com:context.SafeCom.SafeContext, op:Binop, e1:TExpr, e2:TExpr, e3:TExpr):Bool {
		if (com.platform == Eval) {
			e1 = Texpr.skip(e1);
			e2 = Texpr.skip(e2);
		}
		return isAssignOp(op) && AnalyzerTexpr.targetHandlesAssignOps(com, e3) && Texpr.equal(e1, e2) && !hasSideEffect(e1);
	}

	public static function handleAssignedLocal(actx:AnalyzerContext, v1:TVar, value:TExpr, el:Array<TExpr>):Null<Array<TExpr>> {
		var config = actx.config;
		var com = actx.com;
		var found = false;
		var blocked = false;
		var ir = InterferenceReport.fromTexpr(value);
		if (config.fusionDebug) Sys.println("INTERFERENCE: "
			+ InterferenceReport.toString(ir)
			+ "\nINTO: "
			+ core.TPrinting.sExprPretty(true, "", false, core.TPrinting.sType.bind(core.TPrinting.printContext()),
				mk(TBlock(Vector.fromArrayCopy(el)), tDynamic, Globals.nullPos)));
		// This function walks the AST in order of evaluation and tries to find an occurrence of v1. If successful, that occurrence is
		// replaced with e1. If there's an interference "on the way" the replacement is canceled.
		function replace(e:TExpr):TExpr {
			inline function explore(e:TExpr):TExpr {
				var old = blocked;
				blocked = true;
				var e = replace(e);
				blocked = old;
				return e;
			}
			inline function handleEl(el:Vector<TExpr>):Vector<TExpr> {
				if (AnalyzerTexpr.targetHandlesSideEffectOrder(com)) return el.map(replace);
				// This mess deals with the fact that the order of evaluation is undefined for call
				// arguments on these targets. Even if we find a replacement, we pretend that we
				// didn't in order to find possible interferences in later call arguments.
				var reallyFound = found;
				var el = el.map(e -> {
					found = false;
					var e = replace(e);
					if (found) reallyFound = true;
					return e;
				});
				found = reallyFound;
				return el;
			}
			inline function handleCall(e:TExpr, el:Vector<TExpr>):{expr:TExpr, args:Vector<TExpr>}
				return switch com.platform {
					case Neko:
						// Neko has this reversed at the moment (issue #4787)
						var el = el.map(replace);
						var e = replace(e);
						{expr: e, args: el};
					case Cpp:
						var e = replace(e);
						{expr: e, args: handleEl(el)};
					case _:
						var e = replace(e);
						{expr: e, args: el.map(replace)};
				};
			if (found) return e;
			return switch e.eexpr {
				case TWhile(_, _, _) | TTry(_, _): throw new TypeExit();
				case TFunction(_): e;
				case TIf(e1, e2, eo):
					var e1 = replace(e1);
					if (!found
						&& (ir.irStateWrite
							|| InterferenceReport.hasAnyFieldWrite(ir)
							|| InterferenceReport.hasAnyVarWrite(ir))) throw new TypeExit();
					var e2 = replace(e2);
					withExpr(e, TIf(e1, e2, eo == null ? null : replace(eo)));
				case TSwitch(s):
					var subject = switch com.platform {
						case Lua | Python: explore(s.switchSubject);
						case _: replace(s.switchSubject);
					};
					if (!found) throw new TypeExit();
					withExpr(e, TSwitch(mkSwitch(subject, s.switchCases, s.switchDefault, s.switchExhaustive)));
				// locals
				case TLocal(v2) if (v1 == v2 && !blocked):
					found = true;
					AnalyzerTexpr.typeChangeOk(com, v1.vType, value.etype) ? value : mk(TCast(value, null), v1.vType, e.epos);
				case TLocal(v):
					if (ir.irVarWrites.exists(v.vId)
						|| (hasVarFlag(v, VCaptured) || core.TOther.ExtType.hasReferenceSemantics(v.vType))
						&& ir.irStateWrite) throw new TypeExit();
					e;
				case TBinop(OpAssign, e1 = {eexpr: TLocal(v)}, e2):
					var e2 = replace(e2);
					if (!found && ir.irVarReads.exists(v.vId)) throw new TypeExit();
					withExpr(e, TBinop(OpAssign, e1, e2));
				// Never fuse into write-positions (issue #7298)
				case TBinop(OpAssignOp(_), {eexpr: TLocal(v)},
					_) | TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}) if (v1 == v): throw new TypeExit();
				case TBinop(op = OpAssignOp(_), e1 = {eexpr: TLocal(v)}, e2):
					var e2 = replace(e2);
					if (!found && (ir.irVarReads.exists(v.vId) || ir.irVarWrites.exists(v.vId))) throw new TypeExit();
					withExpr(e, TBinop(op, e1, e2));
				case TUnop(Increment | Decrement, _,
					{eexpr: TLocal(v)}) if (ir.irVarReads.exists(v.vId) || ir.irVarWrites.exists(v.vId)): throw new TypeExit();
				// fields
				case TField(e1, fa):
					var e1 = replace(e1);
					if (!found
						&& !isReadOnlyFieldAccess(e1, fa)
						&& (ir.irFieldWrites.exists(fieldName(fa)) || ir.irStateWrite)) throw new TypeExit();
					withExpr(e, TField(e1, fa));
				case TBinop(OpAssign, ef = {eexpr: TField(e1, fa)}, e2):
					var e1 = replace(e1);
					var e2 = replace(e2);
					if (!found && (ir.irFieldReads.exists(fieldName(fa)) || ir.irStateRead)) throw new TypeExit();
					withExpr(e, TBinop(OpAssign, withExpr(ef, TField(e1, fa)), e2));
				case TBinop(op = OpAssignOp(_), ef = {eexpr: TField(e1, fa)}, e2):
					var e1 = replace(e1);
					var name = fieldName(fa);
					if (!found && (ir.irFieldWrites.exists(name) || ir.irStateWrite)) throw new TypeExit();
					var e2 = replace(e2);
					if (!found && (ir.irFieldReads.exists(name) || ir.irStateRead)) throw new TypeExit();
					withExpr(e, TBinop(op, withExpr(ef, TField(e1, fa)), e2));
				case TUnop(Increment | Decrement, _, {eexpr: TField(_, fa)})
					if (ir.irFieldReads.exists(fieldName(fa))
						|| ir.irStateRead
						|| ir.irFieldWrites.exists(fieldName(fa))
						|| ir.irStateWrite): throw new TypeExit();
				// array
				case TArray(e1, e2):
					var e1 = replace(e1);
					var e2 = replace(e2);
					if (!found && ir.irStateWrite) throw new TypeExit();
					withExpr(e, TArray(e1, e2));
				case TBinop(OpAssign, ef = {eexpr: TArray(e1, e2)}, e3):
					var e1 = replace(e1);
					var e2 = replace(e2);
					var e3 = replace(e3);
					if (!found && ir.irStateRead) throw new TypeExit();
					withExpr(e, TBinop(OpAssign, withExpr(ef, TArray(e1, e2)), e3));
				case TBinop(op = OpAssignOp(_), ef = {eexpr: TArray(e1, e2)}, e3):
					var e1 = replace(e1);
					var e2 = replace(e2);
					if (!found && ir.irStateWrite) throw new TypeExit();
					var e3 = replace(e3);
					if (!found && ir.irStateRead) throw new TypeExit();
					withExpr(e, TBinop(op, withExpr(ef, TArray(e1, e2)), e3));
				case TUnop(Increment | Decrement, _, {eexpr: TArray(_, _)}) if (ir.irStateRead || ir.irStateWrite): throw new TypeExit();
				// state
				case TCall({eexpr: TIdent(s)}, el) if (!AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el)): e;
				case TNew(c, tl, el) if (c.clConstructor != null && PurityStateTools.isPure(c, c.clConstructor)):
					var el = handleEl(el);
					if (!found && (ir.irStateWrite || InterferenceReport.hasAnyFieldWrite(ir))) throw new TypeExit();
					withExpr(e, TNew(c, tl, el));
				case TNew(c, tl, el):
					var el = handleEl(el);
					if (!found
						&& (ir.irStateWrite
							|| ir.irStateRead
							|| InterferenceReport.hasAnyFieldRead(ir)
							|| InterferenceReport.hasAnyFieldWrite(ir))) throw new TypeExit();
					withExpr(e, TNew(c, tl, el));
				case TCall(ef = {eexpr: TField(_, FEnum(_, _))}, el): withExpr(e, TCall(ef, handleEl(el)));
				case TCall(ef = {eexpr: TField(_, fa)}, el) if (PurityStateTools.isPureFieldAccess(fa)):
					var r = handleCall(ef, el);
					if (!found && (ir.irStateWrite || InterferenceReport.hasAnyFieldWrite(ir))) throw new TypeExit();
					withExpr(e, TCall(r.expr, r.args));
				case TCall(e1, el):
					var r = switch e1.eexpr {
						case TIdent(s) if (s != "`trace" && s != "__int__"): {expr: e1, args: el};
						case _: handleCall(e1, el);
					};
					if (!found
						&& (ir.irStateRead
							|| InterferenceReport.hasAnyFieldRead(ir)
							|| ir.irStateWrite
							|| InterferenceReport.hasAnyFieldWrite(ir))) throw new TypeExit();
					withExpr(e, TCall(r.expr, r.args));
				case TObjectDecl(fl):
					// TODO can something be cleaned up here?
					// The C# generator has trouble with evaluation order in structures (#7531).
					var el = handleEl(fl.map(f -> f.expr));
					if (!found && (ir.irStateWrite || InterferenceReport.hasAnyFieldWrite(ir))) throw new TypeExit();
					if (fl.length != el.length) throw "Invalid_argument: List.map2";
					withExpr(e, TObjectDecl(fl.mapi((i, f) -> {key: f.key, expr: el[i]})));
				case TArrayDecl(el): withExpr(e, TArrayDecl(handleEl(el))); // if not !found && (has_state_write ir || has_any_field_write ir) then raise Exit;
				case TBinop(op, e1, e2) if (com.platform == Cpp):
					var e1 = replace(e1);
					var temp = found;
					found = false;
					var e2 = replace(e2);
					found = found || temp;
					withExpr(e, TBinop(op, e1, e2));
				case _: mapExpr(replace, e);
			};
		}
		try {
			var out = [];
			for (i in 0...el.length) {
				var mapped:TExpr = optimization.Analyzer.Run.timed(actx, ["<-", "fusion", "fuse", "replace"],
					function() return replace(el[i]));
				out.push(mapped);
				if (found) {
					out = out.concat(el.slice(i + 1));
					break;
				}
			}
			if (!found) throw new TypeExit();
			if (config.fusionDebug) Sys.println("YES: " + AnalyzerTexpr.sExprPretty(mk(TBlock(Vector.fromArrayCopy(out)), tDynamic, Globals.nullPos)));
			return out;
		} catch (_:TypeExit) {
			if (config.fusionDebug) Sys.println("NO: " + haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			return null;
		}
	}

	// Handles block-level expressions, e.g. by removing side-effect-free ones and recursing into compound constructs like
	// array or object declarations. The resulting element list is reversed.
	// INFO: `el` is a reversed list of expressions in a block.
	public static function blockElement(config:AnalyzerConfigData, state:FusionState, loopBottom:Bool, acc:Array<TExpr>,
			el:Array<TExpr>):Array<TExpr> {
		// port: upstream walks OCaml lists (`e :: acc`, `e1 :: rest`); with arrays that is a
		// copy per step. Same order here: `stack` is the work list with its head at the
		// end, `accRev` the accumulator with its head at the end.
		var stack = el.copy();
		stack.reverse();
		var accRev = acc.copy();
		accRev.reverse();
		inline function pushAll(xs:Vector<TExpr>):Void {
			var i = xs.length;
			while (i > 0) stack.push(xs[--i]);
		}
		while (stack.length > 0) {
			var e = stack.pop();
			switch e.eexpr {
				case TBinop(OpAssign, {eexpr: TLocal(v1)}, {eexpr: TLocal(v2)}) if (v1 == v2):
				case TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _):
					accRev.push(e);
				case TLocal(_) if (!config.localDce):
					accRev.push(e);
				case TLocal(v):
					state.decReads(v);
				case TField(_, fa) if (PurityStateTools.isExplicitlyImpure(fa)):
					accRev.push(e);
				// no-side-effect
				case TFunction(_) | TConst(_) | TTypeExpr(_):
				case TMeta(meta = {meta: core.MetaList.StrictMeta.Pure}, _) if (PurityStateTools.getPurityFromMeta([meta]) == Pure):
				case TCall({eexpr: TField(e1, fa)}, args) if (PurityStateTools.isPureFieldAccess(fa) && config.localDce):
					pushAll(args);
					stack.push(e1);
				case TNew(c, tl, args) if (c.clConstructor != null && PurityStateTools.isPure(c, c.clConstructor) && config.localDce):
					pushAll(args);
				case TIf({eexpr: TConst(TBool(t))}, a, b):
					if (t) stack.push(a)
					else if (b != null) stack.push(b);
				case TSwitch(s):
					var folded = Optimizer.checkConstantSwitch(s);
					if (folded == null) accRev.push(e)
					else stack.push(folded);
				// no-side-effect composites
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null) | TField(e1, _) | TUnop(_, _, e1) | TEnumIndex(e1) |
					TEnumParameter(e1, _, _):
					stack.push(e1);
				case TArray(e1, e2) | TBinop(_, e1, e2):
					stack.push(e2);
					stack.push(e1);
				case TArrayDecl(args) | TCall({eexpr: TField(_, FEnum(_, _))}, args): // TODO: check e1 of FEnum
					pushAll(args);
				case TObjectDecl(fl):
					pushAll(fl.map(f -> f.expr));
				case TIf(e1, e2, null) if (!hasSideEffect(e2)):
					stack.push(e1);
				case TIf(e1, e2, e3) if (e3 != null && !hasSideEffect(e2) && !hasSideEffect(e3)):
					stack.push(e1);
				case TBlock([e1]):
					stack.push(e1);
				case TBlock([]):
				case TContinue if (loopBottom):
					accRev = [];
				case _:
					accRev.push(e);
			}
		}
		accRev.reverse();
		return accRev;
	}

	public static function apply(actx:AnalyzerContext, e:TExpr):TExpr {
		var config = actx.config;
		var com = actx.com;
		var state = new FusionState();
		optimization.Analyzer.Run.timed(actx, ["<-", "fusion", "infer_from_texpr"], function() state.inferFromTexpr(e));
		function blockElementTimed(bottom:Bool, acc:Array<TExpr>,
				el:Array<TExpr>):Array<TExpr> return optimization.Analyzer.Run.timed(actx, ["<-", "fusion", "block_element"],
				function() return blockElement(config, state, bottom, acc, el));
		function canBeFused(v:TVar, e:TExpr):Bool {
			var uses = state.getReads(v);
			var writes = state.getWrites(v);
			var asValue = AnalyzerTexpr.canBeUsedAsValue(com, e);
			var generated = switch v.vKind {
				case VUser(_) | VInlined | VInlinedConstructorVariable(_): false;
				case _: true;
			};
			var typeParams = v.vExtra != null && v.vExtra.vParams.length > 0;
			function impure(e:TExpr):Bool return switch e.eexpr {
				case TField(_,
					FStatic(cl,
						cf) | FInstance(cl, _,
						cf)) if (hasClassFlag(cl, CExtern)): !(Meta.has(CoreApi, cl.clMeta) || PurityStateTools.isPure(cl, cf));
				case _: checkExpr(impure, e);
			};
			var impureExtern = impure(e);
			var variableSemantics = core.TOther.ExtType.hasVariableSemantics(v.vType);
			var variableExpr = switch e.eexpr {
				case TLocal({vKind: VUser(_)}): false;
				case _: true;
			};
			var b = uses <= 1
				&& writes == 0
				&& asValue
				&& !(variableSemantics && variableExpr)
				// port: hxmc's struct values (AnalyzerTexpr.keepCopyHook)
				&& (generated || AnalyzerTexpr.keepCopyHook == null || !AnalyzerTexpr.keepCopyHook(v.vType, e))
				&& (generated || config.optimize && config.fusion && config.userVarFusion && !typeParams && !impureExtern);
			if (config.fusionDebug) {
				Sys.println('\nFUSION: $b\n\tvar ${v.vName}<${v.vId}> = ' + AnalyzerTexpr.sExprPretty(e));
				Sys.println('CONDITION:\n\tnum_uses:$uses <= 1 && num_writes:$writes = 0 && can_be_used_as_value:$asValue && not (has_variable_semantics:$variableSemantics && e.eexpr=TLocal:$variableExpr) (is_compiler_generated:$generated || config.optimize:${config.optimize} && config.fusion:${config.fusion} && config.user_var_fusion:${config.userVarFusion} && not has_type_params:$typeParams && not is_impuare_extern:$impureExtern)');
			}
			return b;
		}
		// port: upstream recurses over OCaml lists (`first :: rest`, `first :: acc`); slicing and
		// prepending arrays at each step was quadratic. Same steps here as a loop: the
		// accumulator is reversed (head at the end) and `rest` is arr[restOff..].
		function fuse(acc0:Array<TExpr>, el0:Array<TExpr>):Array<TExpr> {
			var accRev = acc0.copy();
			accRev.reverse();
			var arr = el0, off = 0;
			while (true) {
				if (off >= arr.length) {
					accRev.reverse();
					return accRev;
				}
				var first = arr[off];
				var restOff = off + 1;
				var restLength = arr.length - restOff;
				inline function rest0():TExpr return arr[restOff];
				inline function restArray():Array<TExpr> return arr.slice(restOff);
				inline function next(pushed:Null<TExpr>, newArr:Null<Array<TExpr>>, skip:Int):Void {
					if (pushed != null) accRev.push(pushed);
					if (newArr != null) {
						arr = newArr;
						off = 0;
					} else off = restOff + skip;
				}
				var handled = false;
				switch first.eexpr {
					case TVar(v1, null) if (restLength > 0):
						switch rest0().eexpr {
							case TBinop(OpAssign, {eexpr: TLocal(v2)}, e2) if (v1 == v2):
								state.markChanged();
								state.decWrites(v1);
								next(withExpr(first, TVar(v1, e2)), null, 1);
								handled = true;
							case _:
						}
					case _:
				}
				if (handled) continue;
				switch first.eexpr {
					case TIf(_, _, eelse)
						if (eelse != null
							&& AnalyzerTexpr.canBeUsedAsValue(com, first)
							&& !core.TOther.ExtType.isVoid(first.etype)
							&& !(com.platform == Cpp && !core.Define.defined(com.defines, core.Define.Cppia))):
						try {
							var count = 0;
							var lhs:Null<TExpr> = null;
							var wrap:TExpr->TExpr = null;
							function checkAssign(e:TExpr):TExpr return switch e.eexpr {
								case TBinop(OpAssign, e1, e2):
									count++;
									if (lhs == null) {
										lhs = e1;
										wrap = other -> withExpr(e, TBinop(OpAssign, e1, other));
										e2;
									} else if (Texpr.equal(lhs, e1)) e2; else throw new TypeExit();
								case _: throw new TypeExit();
							};
							var result = AnalyzerTexpr.mapValues(checkAssign, first).expr;
							if (lhs == null) throw "AnalyzerTexpr.fuse missing assignment";
							switch lhs.eexpr {
								case TLocal(v): state.changeWrites(v, -count + 1);
								case _:
							}
							result = wrap(result);
							state.markChanged();
							next(result, null, 0);
						} catch (_:TypeExit) next(first, null, 0);
						continue;
					case TVar(v, e1)
						if (e1 != null && config.optimize && config.localDce && state.getReads(v) == 0 && state.getWrites(v) == 0):
						next(null, [e1].concat(restArray()), 0);
						continue;
					case TVar(v1, null) if (!hasVarFlag(v1, VCaptured)):
						var found = false;
						function replace(deep:Bool, e:TExpr):TExpr return switch e.eexpr {
							case TBinop(OpAssign, {eexpr: TLocal(v2)}, e2) if (v1 == v2):
								if (deep) throw new TypeExit();
								found = true;
								withExpr(first, TVar(v1, e2));
							case TLocal(v2) if (v1 == v2): throw new TypeExit();
							case _: core.Texpr.mapExprWithBool(replace, true, e);
						};
						try {
							var out = [];
							for (i in 0...restLength) {
								out.push(replace(false, arr[restOff + i]));
								if (found) {
									out = out.concat(arr.slice(restOff + i + 1));
									break;
								}
							}
							if (!found) throw new TypeExit();
							state.markChanged();
							state.decWrites(v1);
							next(null, out, 0);
						} catch (_:TypeExit) next(first, null, 0);
						continue;
					case TVar(v1, e1) if (e1 != null && canBeFused(v1, e1)):
						if (restLength > 0) switch rest0().eexpr {
							// port: upstream's pattern rebinds v1 to this local, shadowing the declaration; v2 is that binding.
							case TUnop(op = Increment | Decrement, Prefix, {eexpr: TLocal(v2)}):
								var found = false;
								function replace(e:TExpr):TExpr return switch e.eexpr {
									case TLocal(v) if (v2 == v):
										if (found) throw new TypeExit();
										found = true;
										withExpr(e, TUnop(op, Postfix, e));
									case TIf(_, _, _) | TSwitch(_) | TTry(_, _) | TWhile(_, _, _): throw new TypeExit();
									case _: mapExpr(replace, e);
								};
								try {
									var ev = replace(first);
									if (!found) throw new TypeExit();
									state.markChanged();
									next(null, [ev].concat(arr.slice(restOff + 1)), 0);
								} catch (_:TypeExit) next(first, null, 0);
								continue;
							case _:
						}
						var result = handleAssignedLocal(actx, v1, e1, restArray());
						if (result != null) {
							state.markChanged();
							state.decReads(v1);
							next(null, result, 0);
						} else next(first, null, 0);
						continue;
					case TUnop(op = Increment | Decrement, Prefix, ev = {eexpr: TLocal(v)}) if (restLength > 0):
						try {
							var second = rest0();
							var inner:TExpr;
							var wrap:TExpr->TExpr;
							switch second.eexpr {
								case TReturn(e2) if (e2 != null):
									inner = e2;
									wrap = e -> withExpr(e2, TReturn(e));
								// This is not sound if e21 contains the variable (issue #7704)
								// | TBinop(OpAssign,e21,e22) -> e22,(fun e -> {e2 with eexpr = TBinop(OpAssign,e21,e)})
								case TVar(v, e2) if (e2 != null):
									inner = e2;
									wrap = e -> withExpr(e2, TVar(v, e));
								case _: throw new TypeExit();
							}
							var replacement = switch inner.eexpr {
								case TBinop(op2, {eexpr: TLocal(v2)}, {eexpr: TConst(TInt(1))})
									if (v == v2 && (op == Increment && op2 == OpSub || op == Decrement && op2 == OpAdd)):
									state.markChanged();
									state.decReads(v2);
									wrap(withExpr(first, TUnop(op, Postfix, ev)));
								case TLocal(v2) if (v == v2):
									state.markChanged();
									state.decReads(v2);
									wrap(withExpr(first, TUnop(op, Prefix, ev)));
								case _: throw new TypeExit();
							};
							next(replacement, null, 1);
						} catch (_:TypeExit) next(first, null, 0);
						continue;
					case TBinop(OpAssign, e1, {eexpr: TBinop(op, e2, e3)}) if (useAssignOp(com, op, e1, e2, e3)):
						function reads(e:TExpr):Void switch e.eexpr {
							case TLocal(v):
								state.decReads(v);
							case _:
								iter(reads, e);
						}
						reads(e1);
						state.markChanged();
						next(null, [withExpr(first, TBinop(OpAssignOp(op), e1, e3))].concat(restArray()), 0);
						continue;
					case TBinop(OpAssignOp(_), e1, _) if (restLength > 0):
						switch rest0().eexpr {
							case TVar(v, e2) if (e2 != null && Texpr.equal(e1, e2)):
								state.markChanged();
								next(withExpr(rest0(), TVar(v, first)), null, 1);
								continue;
							case _:
						}
					case _:
				}
				next(first, null, 0);
			}
		}
		function timedFuse(el:Array<TExpr>):Array<TExpr> return optimization.Analyzer.Run.timed(actx, ["<-", "fusion", "fuse"],
			function() return fuse([], el));
		var loop:TExpr->TExpr = null;
		function block(bottom:Bool, el:Vector<TExpr>, t:T, p:Pos):TExpr {
			var el = el.mapToArray(loop);
			el.reverse();
			el = blockElementTimed(bottom, [], el);
			// fuse flips element order, but block_element doesn't care and flips it back
			el = timedFuse(el);
			el = blockElementTimed(false, [], el);
			while (true) {
				state.reset();
				el = timedFuse(el);
				el = blockElementTimed(false, [], el);
				if (!state.didChange()) break;
			}
			return mk(TBlock(Vector.fromArrayCopy(el)), t, p);
		}
		loop = function(e:TExpr):TExpr return switch e.eexpr {
			case TWhile(cond, {eexpr: TBlock(el), etype: t, epos: p}, flag):
				var cond = loop(cond);
				var body = block(true, el, t, p);
				withExpr(e, TWhile(cond, body, flag));
			case TBlock(el): block(false, el, e.etype, e.epos);
			case TCall({eexpr: TIdent(s)}, _) if (AnalyzerTexpr.isReallyUnbound(s)): e;
			case _: mapExpr(loop, e);
		};
		return loop(e);
	}
}

class Cleanup {
	public static function apply(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		function ifOrOp(e:TExpr, e1:TExpr, e2:TExpr,
				e3:TExpr):TExpr return switch [Texpr.skip(e1).eexpr, Texpr.skip(e2).eexpr, Texpr.skip(e3).eexpr] {
				case [_, TReturn(b), TReturn({eexpr: TConst(TBool(false))})] if (b != null):
					var binop = optimizeBinop(scom, withExpr(e, TBinop(OpBoolAnd, e1, b)), OpBoolAnd, e1, b);
					withExpr(e, TReturn(binop));
				case [TUnop(Not, Prefix, inner), TReturn(b), TReturn({eexpr: TConst(TBool(true))})] if (b != null):
					var binop = optimizeBinop(scom, withExpr(e, TBinop(OpBoolOr, inner, b)), OpBoolOr, inner, b);
					withExpr(e, TReturn(binop));
				case [TUnop(Not, Prefix,
					inner), _, TConst(TBool(true))]: optimizeBinop(scom, withExpr(e, TBinop(OpBoolOr, inner, e2)), OpBoolOr, inner, e2);
				case [_, _, TConst(TBool(false))]: optimizeBinop(scom, withExpr(e, TBinop(OpBoolAnd, e1, e2)), OpBoolAnd, e1, e2);
				case [_, _, TBlock([])]: withExpr(e, TIf(e1, e2, null));
				case _: switch Texpr.skip(e2).eexpr {
						case TBlock([]):
							var not = mk(TUnop(Not, Prefix, e1), e1.etype, e1.epos);
							not = optimizeUnop(not, Not, Prefix, e1);
							withExpr(e, TIf(not, e3, null));
						case _: withExpr(e, TIf(e1, e2, e3));
					}
			};
		function loop(e:TExpr):TExpr return switch e.eexpr {
			case TIf(e1, e2, e3) if (e3 != null):
				var e1 = loop(e1);
				var e2 = loop(e2);
				var e3 = loop(e3);
				ifOrOp(e, e1, e2, e3);
			case TUnop(Increment | Decrement, _, e1) if (switch Texpr.skip(e1).eexpr {
					case TConst(_): true;
					case _: false;
				}): loop(e1);
			case TCall({eexpr: TIdent(s)}, _) if (AnalyzerTexpr.isReallyUnbound(s)): e;
			case TBlock(el): withExpr(e, TBlock(el.map(e -> {
					var e = loop(e);
					return switch e.eexpr {
						case TIf(_, _, _): ({eexpr: e.eexpr, etype: (scom.basic.tvoid : T), epos: e.epos} : TExpr);
						case _: e;
					};
				})));
			case TWhile(e1, e2, NormalWhile):
				var e1 = loop(e1);
				var e2 = loop(e2);
				function hasContinue(e:TExpr):Bool return switch e.eexpr {
					case TContinue: true;
					case _: checkExpr(hasContinue, e);
				};
				var continues = hasContinue(e2);
				switch e2.eexpr {
					case TBlock(el) if (el.length > 0 && switch el[0].eexpr {
							case TIf(_, {eexpr: TBlock([{eexpr: TBreak}])}, null): true;
							case _: false;
						}):
						switch el[0].eexpr {
							case TIf(cond, eb, null):
								var cond = Texpr.skip(cond);
								cond = switch cond.eexpr {
									case TUnop(_, _, inner): inner;
									case _: withExpr(cond, TUnop(Not, Prefix, cond));
								};
								withExpr(e, TWhile(cond, withExpr(eb, TBlock(el.slice(1))), NormalWhile));
							case _: throw "AnalyzerTexpr.cleanup loop header";
						}
					case TBlock(el):
						var doWhile = null;
						var locals = new haxe.ds.IntMap<Bool>();
						function collectVars(e:TExpr):Void switch e.eexpr {
							case TVar(v, e1):
								locals.set(v.vId, true);
								if (e1 != null) collectVars(e1);
							case _:
								iter(collectVars, e);
						}
						function referencesLocal(e:TExpr):Bool return switch e.eexpr {
							case TLocal(v) if (locals.exists(v.vId)): true;
							case _: checkExpr(referencesLocal, e);
						};
						// port: the list walked by index (upstream: loop2 on its tail), the
						// statements kept a prefix of el, copied once
						function loop2(el:Vector<TExpr>):Vector<TExpr> {
							for (i in 0...el.length) {
								var first = el[i];
								// (the last statement)
								if (i == el.length - 1) switch first.eexpr {
									case TBreak if (isTrueExpr(e1) && !continues):
										doWhile = Texpr.Builder.makeBool(scom.basic, true, e1.epos);
										return el.slice(0, i);
									case TIf(cond, {eexpr: TBlock([{eexpr: TBreak}])}, null) if (isTrueExpr(e1) && !referencesLocal(cond) && !continues):
										doWhile = cond;
										return el.slice(0, i);
									case _:
								}
								switch first.eexpr {
									case TBreak | TContinue | TReturn(_) | TThrow(_): return el.slice(0, i + 1);
									case _: collectVars(first);
								}
							}
							return el.slice(0, el.length);
						}
						var el = loop2(el);
						doWhile == null ? withExpr(e,
							TWhile(e1, withExpr(e2, TBlock(el)),
								NormalWhile)) : withExpr(e,
							TWhile(withExpr(doWhile, TUnop(Not, Prefix, doWhile)), withExpr(e2, TBlock(el)), DoWhile));
					case _: withExpr(e, TWhile(e1, e2, NormalWhile));
				}
			case TField(e1, FAnon({cfName: s}) | FDynamic(s)):
				var e1 = loop(e1);
				withExpr(e, TField(e1, quickFieldDynamic(e1.etype, s)));
			case TField({eexpr: TTypeExpr(_)}, _): e;
			case TTypeExpr(TClassDecl(_)): e;
			case TMeta({meta: core.MetaList.StrictMeta.Ast}, e1) if (switch e1.eexpr {
					case TSwitch(_): false;
					case _: true;
				}): loop(e1);
			case _: mapExpr(loop, e);
		};
		return loop(e);
	}
}

@:structInit class PurityNode {
	public var pnClass:TClass;
	public var pnField:TClassField;
	public var pnPurity:PurityState;
	public var pnDependents:Array<PurityNode>;

	public inline function new(pnClass:TClass, pnField:TClassField, pnPurity:PurityState, pnDependents:Array<PurityNode>) {
		this.pnClass = pnClass;
		this.pnField = pnField;
		this.pnPurity = pnPurity;
		this.pnDependents = pnDependents;
	}

	public inline function clone():PurityNode return new PurityNode(pnClass, pnField, pnPurity, pnDependents);
}

class PurityConflict {
	public var node:PurityNode;
	public var pos:Pos;

	public function new(node:PurityNode, pos:Pos) {
		this.node = node;
		this.pos = pos;
	}
}

class Purity {
	public static var nodeLut = new haxe.ds.StringMap<PurityNode>();

	public static function getFieldId(c:TClass, cf:TClassField):String return Globals.sTypePath(c.clPath) + "." + cf.cfName;

	public static function getNode(c:TClass, cf:TClassField):PurityNode {
		var id = getFieldId(c, cf);
		if (nodeLut.exists(id)) return nodeLut.get(id);
		var node:PurityNode = {
			pnClass: c,
			pnField: cf,
			pnPurity: PurityStateTools.getPurity(c, cf),
			pnDependents: []
		};
		nodeLut.set(id, node);
		return node;
	}

	public static function taint(node:PurityNode):Void switch node.pnPurity {
		case Impure:
		case ExpectPure(p):
			throw new PurityConflict(node, p);
		case MaybePure | Pure | InferredPure:
			node.pnPurity = Impure;
			for (n in node.pnDependents) taint(n);
			var c = node.pnClass;
			while (c.clSuper != null) {
				c = c.clSuper.cls;
				var cf = c.clFields.get(node.pnField.cfName);
				if (cf != null) taint(getNode(c, cf));
			}
	}

	public static function taintRaise(node:PurityNode):Dynamic {
		taint(node);
		throw new TypeExit();
	}

	public static function applyToField(isCtor:Bool, isStatic:Bool, c:TClass, cf:TClassField):Void {
		var node = getNode(c, cf);
		inline function checkField(c:TClass, cf:TClassField):Void {
			var other = getNode(c, cf);
			switch other.pnPurity {
				case Pure | InferredPure | ExpectPure(_):
				case Impure:
					taintRaise(node);
				case MaybePure:
					other.pnDependents.unshift(node);
			}
		}
		inline function checkWrite(e:TExpr):Void switch e.eexpr {
			case TLocal(v):
				if (core.TOther.ExtType.hasReferenceSemantics(v.vType)) taintRaise(node); // Writing to a ref type means impurity.
				// Writing to locals does not violate purity.
			case TField({eexpr: TConst(TThis)}, _) if (isCtor): // A constructor can write to its own fields without violating purity.
			case _:
				taintRaise(node);
		}
		function loop(e:TExpr):Void switch e.eexpr {
			case TMeta(m = {meta: core.MetaList.StrictMeta.Pure}, _):
				if (PurityStateTools.getPurityFromMeta([m]) == Impure) taintRaise(node);
			case TThrow(_):
				taintRaise(node);
			case TBinop(OpAssign | OpAssignOp(_), e1, e2):
				checkWrite(e1);
				loop(e2);
			case TUnop(Increment | Decrement, _, e1):
				checkWrite(e1);
			case TCall({eexpr: TField(_, FStatic(c, cf))}, el):
				for (e in el) loop(e);
				checkField(c, cf);
			case TNew(c, _, el):
				for (e in el) loop(e);
				if (c.clConstructor != null) checkField(c, c.clConstructor);
				else taintRaise(node);
			case TCall({eexpr: TConst(TSuper)}, el):
				if (c.clSuper != null && c.clSuper.cls.clConstructor != null) {
					checkField(c.clSuper.cls, c.clSuper.cls.clConstructor);
					for (e in el) loop(e);
				} else taintRaise(node); // Can that even happen?
			case TCall({eexpr: TIdent(s)}, el) if (!AnalyzerTexpr.isUnboundCallThatMightHaveSideEffects(s, el)):
				for (e in el) loop(e);
			case TCall(_, _):
				taintRaise(node);
			case _:
				iter(loop, e);
		}
		switch cf.cfKind {
			case Method(MethDynamic) | Var(_):
				taint(node);
			case Method(MethNormal) if (!(isStatic || isCtor || hasClassFieldFlag(cf, CfFinal))):
				taint(node);
			case _:
				if (cf.cfExpr == null) {
					if (!PurityStateTools.isPure(c, cf)) taint(node);
				}
				// TODO: The function code check shouldn't be here I guess.
				else if (hasClassFieldFlag(cf, CfExtern) || Meta.has(FunctionCode, cf.cfMeta) || Meta.has(HlNative, cf.cfMeta)
					|| Meta.has(HlNative, c.clMeta)) {
					if (!PurityStateTools.isPure(c, cf)) taint(node);
				} else try {
					switch node.pnPurity {
						case Impure: taintRaise(node);
						case Pure: throw new TypeExit();
						case _: loop(cf.cfExpr);
					}
				} catch (_:TypeExit) {}
		}
	}

	public static function applyToClass(c:TClass):Void {
		for (cf in c.clOrderedFields) applyToField(false, false, c, cf);
		for (cf in c.clOrderedStatics) applyToField(false, true, c, cf);
		if (c.clConstructor != null) applyToField(true, false, c, c.clConstructor);
	}

	public static function infer(types:Array<ModuleType>):Void {
		nodeLut.clear();
		for (mt in types) switch mt {
			case TClassDecl(c):
				try applyToClass(c)
				catch (conflict:PurityConflict) {
					core.Error.raiseTypingErrorExt(core.Error.makeError(core.Error.ErrorMsg.Custom("Impure field overrides/implements field which was explicitly marked as @:pure"),
						conflict.node.pnField.cfPos, [
							core.Error.makeError(core.Error.ErrorMsg.Custom(core.Error.complMsg("Pure field is here")), conflict.pos)
						]));
				}
			case _:
		}
		for (node in nodeLut) switch node.pnPurity {
			case Pure | MaybePure if (!exists((m:core.Ast.MetadataEntry) -> m.meta == core.MetaList.StrictMeta.Pure, node.pnField.cfMeta)):
				var p = Globals.mkZeroRangePos(node.pnField.cfPos);
				node.pnField.cfMeta = [
					({
						meta: core.MetaList.StrictMeta.Pure,
						exprs: vector({expr: EConst(Ident("inferredPure")), pos: p}),
						pos: p
					} : core.Ast.MetadataEntry)
				].concat(node.pnField.cfMeta);
			case _:
		}
	}
}
