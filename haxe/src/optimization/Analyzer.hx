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

import context.PurityState.PurityStateTools as PurityState;
import optimization.Inline as InlineOps;
import core.Ast;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.TFunctions.TypeExit;
import core.TFunctions.NotFound;
import core.Texpr;
import core.Texpr.*;
import core.Meta;
import optimization.AnalyzerTypes;
import optimization.AnalyzerTypes.BasicBlock.*;
import optimization.AnalyzerTypes.Graph.*;
import optimization.AnalyzerTexpr;
import optimization.AnalyzerTexpr.*;
import optimization.AnalyzerConfig;
import optimization.OptimizerTexpr.*;

/* File organization:
	* analyzer.ml: The controlling file with all graph-based optimizations
	* analyzerConfig.ml: The general configuration which is used in multiple modules
	* analyzerTexpr.ml: Transformations and query functions on texpr, independent of graph/blocks
	* analyzerTexprTransformer.ml: Translation of texpr to graph/blocks
	* analyzerTypes.ml: Definition of graph, block and the analyzer context
*/
class Analyzer {
	public static function initHooks():Void context.Typecore.analyzerRunOnExprRef = function(com, identifier, e) {
		var scom = context.SafeCom.ofCom(com);
		var config = AnalyzerConfig.getBaseConfig(scom);
		// We always want to optimize because const propagation might be required to obtain
		// a constant expression for inline field initializations (see issue #4977).
		config.optimize = true;
		return Run.runOnExpr(Run.createAnalyzerContext(scom, config, identifier, e), e);
	};

	static function __init__():Void initHooks();
}

/*
	Ssa changes the expressions of a graph to conform to SSA rules. All variables are assigned to only once
	and SSA-phi expressions are created where necessary.

	The first pass inserts SSA-phi expressions for each variable in the dominance frontier of all its defining
	blocks.

	The second pass then creates and renames variables to ensure SSA property.
*/
class Ssa {
	public static function addPhi(g:GraphData, bb:BasicBlockData, v:TVar):Void {
		var p = bb.bbPos;
		var ev = mk(TLocal(v), v.vType, p);
		var el = bb.bbIncoming.map(_ -> ev);
		var phi = mk(TConst(TString("phi")), tDynamic, p);
		var call = mk(TCall(phi, el), tDynamic, p);
		bb.bbPhi.push(mk(TBinop(OpAssign, ev, call), tDynamic, p));
	}

	public static function insertPhi(ctx:AnalyzerContext):Void for (vi in ctx.graph.gVarInfos)
		if (vi.viBbDeclare != ctx.graph.gUnreachable) {
			var done = new haxe.ds.IntMap<Bool>();
			// port: viWrites is in push order (Graph.addVarDef): the worklist is a stack with its top at the end
			var work = vi.viWrites.copy();
			while (work.length > 0) {
				var x = work.pop();
				for (y in x.bbDf) if (!done.exists(y.bbId)) {
					done.set(y.bbId, true);
					if (inScope(y, vi.viBbDeclare)) {
						addPhi(ctx.graph, y, vi.viVar);
						if (!vi.viWrites.contains(y)) work.push(y);
					}
				}
			}
		}

	public static function setReachingDef(g:GraphData, v:TVar, vo:Null<TVar>):Void getVarInfo(g, v).viReachingDef = vo;

	public static function getReachingDef(g:GraphData, v:TVar):Null<TVar> return getVarInfo(g, v).viReachingDef;

	public static function blockDominates(dom:BasicBlockData, bb:BasicBlockData):Bool
		return dom == bb || bb.bbDominator == dom || bb.bbDominator != bb && blockDominates(dom, bb.bbDominator);

	public static function dominates(ctx:AnalyzerContext, r:TVar,
			bb:BasicBlockData):Bool return exists(other -> blockDominates(other, bb), getVarInfo(ctx.graph, r).viWrites);

	public static function updateReachingDef(ctx:AnalyzerContext, v:TVar, bb:BasicBlockData):Void {
		var r = getReachingDef(ctx.graph, v);
		while (r != null && !dominates(ctx, r, bb)) r = getReachingDef(ctx.graph, r);
		setReachingDef(ctx.graph, v, r);
	}

	public static function local(ctx:AnalyzerContext, e:TExpr, v:TVar, bb:BasicBlockData):TVar {
		updateReachingDef(ctx, v, bb);
		var r = getReachingDef(ctx.graph, v);
		return r == null ? v : r;
	}

	public static function updatePhi(ctx:AnalyzerContext, edge:CfgEdge):Void {
		var bb = edge.cfgTo;
		function loop(i:Int, e:TExpr):TExpr return switch e.eexpr {
			case TBinop(OpAssign, e1 = {eexpr: TLocal(v0)}, ecall = {eexpr: TCall(ephi = {eexpr: TConst(TString("phi"))}, el)}):
				if (el.length != bb.bbIncoming.length) throw "Invalid_argument: List.map2";
				var values = [
					for (j in 0...el.length) {
						var e = el[j];
						var pred = bb.bbIncoming[j].cfgFrom;
						if (pred != edge.cfgFrom) e; else switch e.eexpr {
							case TLocal(v):
								var replacement = local(ctx, e, v, edge.cfgFrom);
								addSsaEdge(ctx.graph, replacement, bb, LUPhi(i));
								withExpr(e, TLocal(replacement));
							case _:
								throw "Analyzer.updatePhi";
						}
					}
				];
				var phi = withExpr(ecall, TCall(ephi, values));
				setVarValue(ctx.graph, v0, bb, LUPhi(i));
				withExpr(e, TBinop(OpAssign, e1, phi));
			case _: mapExprWith(loop, i, e);
		};
		dynarrayMapi(loop, bb.bbPhi);
	}

	public static function renameInBlock(ctx:AnalyzerContext, bb:BasicBlockData):Void {
		inline function writeVar(v:TVar, luk:TExprLookupTarget):TVar {
			updateReachingDef(ctx, v, bb);
			var w = allocVar(v.vKind, v.vName, v.vType, v.vPos);
			declareVar(ctx.graph, w, bb);
			w.vMeta = v.vMeta;
			if (hasVarFlag(v, VCaptured)) addVarFlag(w, VCaptured);
			addVarDef(ctx.graph, bb, w);
			setReachingDef(ctx.graph, w, getReachingDef(ctx.graph, v));
			setReachingDef(ctx.graph, v, w);
			setVarValue(ctx.graph, w, bb, luk);
			addVarOrigin(ctx.graph, w, v);
			return w;
		}
		function loop(luk:TExprLookupTarget, e:TExpr):TExpr return switch e.eexpr {
			case TLocal(v):
				var w = local(ctx, e, v, bb);
				addSsaEdge(ctx.graph, w, bb, luk);
				withExpr(e, TLocal(w));
			case TVar(v, e1) if (e1 != null):
				var e1 = loop(luk, e1);
				var w = writeVar(v, luk);
				withExpr(e, TVar(w, e1));
			case TBinop(OpAssign, e1 = {eexpr: TLocal(v)}, e2):
				var e2 = loop(luk, e2);
				var w = writeVar(v, luk);
				withExpr(e, TBinop(OpAssign, withExpr(e1, TLocal(w)), e2));
			case TCall({eexpr: TConst(TString("phi"))}, _): e;
			case _: mapExprWith(loop, luk, e);
		};
		dynarrayMapi((i, e) -> loop(LUPhi(i), e), bb.bbPhi);
		dynarrayMapi((i, e) -> loop(LUEl(i), e), bb.bbEl);
		bb.bbTerminator = terminatorMap(e -> loop(LUTerm, e), bb.bbTerminator);
		for (edge in bb.bbOutgoing) updatePhi(ctx, edge);
		// port: bbDominated is in push order (Graph.inferImmediateDominators)
		var i = bb.bbDominated.length;
		while (i > 0) renameInBlock(ctx, bb.bbDominated[--i]);
	}

	public static function apply(ctx:AnalyzerContext):Void {
		Graph.inferDominanceFrontier(ctx.graph);
		insertPhi(ctx);
		renameInBlock(ctx, ctx.graph.gRoot);
	}
}

interface DataFlowApi<L, C> {
	public var flag(default, null):CfgEdgeFlag;
	// The bottom element of the lattice
	public var bottom(default, null):L;
	// The top element of the lattice
	public var top(default, null):L;
	// Whether or not conditional branches are checked
	public var conditional(default, null):Bool;
	public function toString(t:L):String;
	// The transfer function
	public function transfer(actx:AnalyzerContext, ctx:C, bb:BasicBlockData, e:TExpr):L;
	// The equality function
	public function equals(a:L, b:L):Bool;
	// Lattice cell getter
	public function getCell(ctx:C, id:Int):L;
	// Lattice cell setter
	public function setCell(ctx:C, id:Int, t:L):Void;
	// The initialization function which is called at the start
	public function init(ctx:AnalyzerContext):C;
	// The commit function which is called at the end
	public function commit(actx:AnalyzerContext, ctx:C):Void;
}

/*
	DataFlow provides a framework for data flow analysis. It follows CFG edges from the root of the graph
	and visits the expressions and SSA-phi expressions of blocks on its way.

	If such an expression assigns to a variable (TVar or TBinop(OpAsssign)), all uses of that variable are
	checked by following the variable's SSA edges.

	A conditional branch edge (CFGCondBranch and CFGCondElse) is only followed if the available information
	suggests that it might be executable. This causes information from dead branches to not be taken into
	account.

	For SSA-phi nodes, only those incoming edges which are considered to be executable are processed.

	The algorithm continues until no further changes occur.
*/
class DataFlow<L, C> {
	var api:DataFlowApi<L, C>;

	public function new(api:DataFlowApi<L, C>) this.api = api;

	public static function getSsaEdgesFrom(g:GraphData, v:TVar):Array<TExprLookup> return getVarInfo(g, v).viSsaEdges;

	public function run(actx:AnalyzerContext, ctx:C):Void {
		var g = actx.graph;
		var ssaWork:Array<TExprLookup> = [];
		var cfgWork = g.gRoot.bbOutgoing.copy();
		inline function addCfg(edge:CfgEdge):Void cfgWork.unshift(edge);
		inline function visitPhi(bb:BasicBlockData, v:TVar, el:Array<TExpr>):L {
			if (el.length != bb.bbIncoming.length) throw "Invalid_argument: List.fold_left2";
			var expressions = [];
			for (i in 0...el.length) if (BasicBlock.hasFlag(bb.bbIncoming[i], api.flag)) expressions.unshift(el[i]);
			var values = expressions.map(e -> api.transfer(actx, ctx, bb, e));
			return values.length > 0 && all(e -> api.equals(values[0], e), values.slice(1)) ? values[0] : api.bottom;
		}
		inline function setCell(v:TVar, e:L):Void {
			var old = api.getCell(ctx, v.vId);
			api.setCell(ctx, v.vId, e);
			if (!api.equals(e, old)) for (edge in getSsaEdgesFrom(g, v)) ssaWork.unshift(edge);
		}
		inline function visitAssignment(bb:BasicBlockData, v:TVar, e:TExpr):Void switch e.eexpr {
			case TCall({eexpr: TConst(TString("phi"))}, el):
				setCell(v, visitPhi(bb, v, el));
			case _:
				if (exists(edge -> BasicBlock.hasFlag(edge, api.flag), bb.bbIncoming)) setCell(v, api.transfer(actx, ctx, bb, e));
		}
		inline function visitExpression(bb:BasicBlockData, condBranch:Bool, e:TExpr):Bool return switch e.eexpr {
			case TBinop(OpAssign, {eexpr: TLocal(v)}, e2) | TVar(v, e2) if (e2 != null):
				visitAssignment(bb, v, e2);
				false;
			case _ if (api.conditional && condBranch):
				var value = api.transfer(actx, ctx, bb, e);
				var edges:Array<CfgEdge>;
				if (value == api.bottom || value == api.top) edges = bb.bbOutgoing;
				else {
					var yes = [];
					var maybe = [];
					var also = [];
					for (edge in bb.bbOutgoing) switch edge.cfgKind {
						case CFGCondBranch(e): if (api.equals(api.transfer(actx, ctx, bb, e), value)) yes.unshift(edge);
						case CFGCondElse: maybe.unshift(edge);
						case CFGGoto | CFGFunction | CFGMaybeThrow: also.unshift(edge);
					}
					edges = yes.length == 0 ? (maybe.length == 0 ? bb.bbOutgoing : maybe.concat(also)) : yes.concat(also);
				}
				for (edge in edges) addCfg(edge);
				true;
			case _: false;
		};
		inline function visitExpressions(bb:BasicBlockData):Void {
			var handled = false;
			for (e in bb.bbEl) handled = visitExpression(bb, false, e) || handled;
			handled = switch bb.bbTerminator {
				case TermCondBranch(e): visitExpression(bb, true, e) || handled;
				case TermReturnValue(e, _) | TermThrow(e, _): visitExpression(bb, false, e);
				case _: handled;
			};
			if (!handled) for (edge in bb.bbOutgoing) addCfg(edge);
		}
		function visitPhis(bb:BasicBlockData):Void for (e in bb.bbPhi) switch e.eexpr {
			case TBinop(OpAssign, {eexpr: TLocal(v)}, {eexpr: TCall({eexpr: TConst(TString("phi"))}, el)}):
				setCell(v, visitPhi(bb, v, el));
			case _:
				throw "Analyzer.DataFlow.visitPhis";
		}
		while (cfgWork.length > 0 || ssaWork.length > 0) {
			if (cfgWork.length > 0) {
				var edge = cfgWork.shift();
				if (!BasicBlock.hasFlag(edge, api.flag)) {
					edge.cfgFlags.unshift(api.flag);
					visitPhis(edge.cfgTo);
					var count = 0;
					for (incoming in edge.cfgTo.bbIncoming) if (BasicBlock.hasFlag(incoming, api.flag)) count++;
					if (count == 1 || edge.cfgTo == g.gRoot) visitExpressions(edge.cfgTo);
					if (edge.cfgTo.bbOutgoing.length == 1) addCfg(edge.cfgTo.bbOutgoing[0]);
				}
			} else {
				var edge = ssaWork.shift();
				visitExpression(edge.bb, edge.target == LUTerm, getTexpr(edge.bb, edge.target));
			}
		}
	}

	public function apply(actx:AnalyzerContext):Void {
		var ctx = api.init(actx);
		run(actx, ctx);
		api.commit(actx, ctx);
	}
}

/*
	ConstPropagation implements sparse conditional constant propagation using the DataFlow algorithm. Its lattice consists of
	constants and enum values, but only the former are propagated. Enum values are treated as immutable data tuples and allow
	extracting constants, their index or other enum values.

	This module also deals with binop/unop optimization and standard API inlining.
*/
enum ConstLattice {
	Top;
	Bottom;
	NullValue(t:T);
	ConstValue(ct:TConstant, t:T);
	EnumValue(index:Int, args:Array<ConstLattice>);
	ModuleValue(mt:ModuleType, t:T);
}

class ConstPropagationImpl implements DataFlowApi<ConstLattice, haxe.ds.IntMap<ConstLattice>> {
	public var conditional(default, null) = true;
	public var flag(default, null) = FlagExecutable;
	public var top(default, null):ConstLattice = Top;
	public var bottom(default, null):ConstLattice = Bottom;

	public function new() {}

	public function toString(t:ConstLattice):String {
		function st(t:T):String return core.TPrinting.sType(core.TPrinting.printContext(), t);
		return switch t {
			case Top: "Top";
			case Bottom: "Bottom";
			case NullValue(t): "Null(" + st(t) + ")";
			case ConstValue(ct, t): "Const(" + core.TPrinting.sConst(ct) + "," + st(t) + ")";
			case EnumValue(i, tl): 'EnumValue($i, ' + tl.map(toString).join(", ") + ")";
			case ModuleValue(mt, t): "ModuleType(" + core.TPrinting.sModuleTypeKind(mt) + "," + st(t) + ")";
		};
	}

	public function getCell(ctx:haxe.ds.IntMap<ConstLattice>, id:Int):ConstLattice return ctx.exists(id) ? ctx.get(id) : Top;

	public function setCell(ctx:haxe.ds.IntMap<ConstLattice>, id:Int, t:ConstLattice):Void ctx.set(id, t);

	public function equals(a:ConstLattice, b:ConstLattice):Bool return switch [a, b] {
		case [Top, Top] | [Bottom, Bottom]: true;
		case [ConstValue(c, t), ConstValue(d, u)]: std.Type.enumEq(c, d) && typeIseq(t, u);
		case [NullValue(t), NullValue(u)]: t == u;
		case [EnumValue(i, []), EnumValue(j, [])]: i == j;
		case [ModuleValue(mt, _), ModuleValue(nt, _)]: mt == nt;
		case _: false;
	};

	public function transfer(actx:AnalyzerContext, ctx:haxe.ds.IntMap<ConstLattice>, bb:BasicBlockData, e:TExpr):ConstLattice {
		function eval(e:TExpr):ConstLattice {
			function wrap(t:ConstLattice):TExpr return switch t {
				case ConstValue(ct, t): mk(TConst(ct), t, Globals.nullPos);
				case NullValue(t): mk(TConst(TNull), t, e.epos);
				case _: throw new TypeExit();
			};
			inline function unwrap(e:TExpr):ConstLattice return switch e.eexpr {
				case TConst(ct): ConstValue(ct, e.etype);
				case _: throw new TypeExit();
			};
			return switch e.eexpr {
				case TConst(TSuper | TThis): Bottom;
				case TConst(TNull): NullValue(e.etype);
				case TConst(ct): ConstValue(ct, e.etype);
				case TTypeExpr(mt): ModuleValue(mt, e.etype);
				case TLocal(v): if (follow(v.vType) == tDynamic || hasVarFlag(v, VCaptured)) Bottom; else switch getCell(ctx, v.vId) {
						case NullValue(_) if (!isNullable(v.vType)): Bottom;
						case ct: ct;
					}
				case TBinop(OpAssign, _, e2): eval(e2);
				case TBinop(op, e1, e2):
					var c1 = eval(e1);
					var c2 = eval(e2);
					var e1 = wrap(c1);
					var e2 = wrap(c2);
					var input = withExpr(e, TBinop(op, e1, e2));
					var result = optimizeBinop(actx.com, input, op, e1, e2);
					input != result ? eval(result) : unwrap(result);
				case TUnop(op, flag, e1):
					var c1 = eval(e1);
					var e1 = wrap(c1);
					var input = withExpr(e, TUnop(op, flag, e1));
					var result = optimizeUnop(input, op, flag, e1);
					input != result ? eval(result) : unwrap(result);
				case TField(_, FEnum(_, ef)): EnumValue(ef.efIndex, []);
				case TCall({eexpr: TField(_, FEnum(_, ef))}, el): EnumValue(ef.efIndex, el.map(e -> try eval(e) catch (_:TypeExit) Bottom));
				case TEnumParameter(e1, _, i): switch eval(e1) {
						case EnumValue(_, el):
							if (i < 0 || i >= el.length) throw new TypeExit();
							el[i];
						case _: throw new TypeExit();
					}
				case TEnumIndex(e1): switch eval(e1) {
						case EnumValue(i, _): ConstValue(TInt(i), actx.com.basic.tint);
						case _: throw new TypeExit();
					}
				case TCall({eexpr: TField(_, FStatic(c = {clPath: {pack: [], name: "Type"}}, cf = {cfName: "enumIndex"}))}, [e1])
					if (actx.com.platform == Eval): switch [follow(e1.etype), eval(e1)] {
						case [TEnum(_, _), EnumValue(i, _)]: ConstValue(TInt(i), actx.com.basic.tint);
						case [_, value]:
							var result = InlineOps.apiInline2(actx.com.basic, actx.com.platform, c, cf.cfName, [wrap(value)], e.epos);
							if (result == null) throw new TypeExit();
							eval(result);
					}
				case TCall({eexpr: TField(_, FStatic(c, cf))}, el):
					var values = el.map(eval);
					var el = values.map(wrap);
					var result = InlineOps.apiInline2(actx.com.basic, actx.com.platform, c, cf.cfName, el, e.epos);
					if (result == null) throw new TypeExit();
					eval(result);
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): eval(e1);
				case _:
					var e1 = switch [actx.com.platform, e.eexpr] {
						case [Js, TArray(e1, {eexpr: TConst(TInt(1))})]
							if (core.Define.defined(actx.com.defines, core.Define.JsEnumsAsArrays)): e1;
						case [Js, TField(e1, FDynamic("_hx_index"))]
							if (!core.Define.defined(actx.com.defines, core.Define.JsEnumsAsArrays)): e1;
						case [Cpp, TCall({eexpr: TField(e1, FDynamic("__Index"))}, [])]: e1;
						case [Neko, TField(e1, FDynamic("index"))]: e1;
						case _: throw new TypeExit();
					};
					switch [follow(e1.etype), eval(e1)] {
						case [TEnum(_, _), EnumValue(i, _)]: ConstValue(TInt(i), actx.com.basic.tint);
						case _: throw new TypeExit();
					}
			};
		}
		try return eval(e)
		catch (_:TypeExit) return Bottom;
	}

	public function init(ctx:AnalyzerContext):haxe.ds.IntMap<ConstLattice> return new haxe.ds.IntMap();

	public function commit(actx:AnalyzerContext, ctx:haxe.ds.IntMap<ConstLattice>):Void {
		function inlineValue(e:TExpr, id:Int):TExpr return switch getCell(ctx, id) {
			case Top | Bottom | EnumValue(_, _) | NullValue(_): throw NotFound.raise();
			case ConstValue(ct, t):
				var replacement = Texpr.typeConstant(actx.com.basic, tconstToConst(ct), e.epos);
				replacement = {eexpr: replacement.eexpr, etype: t, epos: replacement.epos};
				if (!typeChangeOk(actx.com, replacement.etype, e.etype)) throw NotFound.raise();
				replacement;
			case ModuleValue(mt, t):
				if (!typeChangeOk(actx.com, t, e.etype)) throw NotFound.raise();
				mk(TTypeExpr(mt), t, e.epos);
		};
		function commit(e:TExpr):TExpr return switch e.eexpr {
			case TLocal(v) if (!(hasVarFlag(v, VCaptured)
				|| core.TOther.ExtType.hasVariableSemantics(v.vType))): try inlineValue(e, v.vId) catch (_:NotFound) e;
			case TBinop(op = OpAssign | OpAssignOp(_), e1 = {eexpr: TLocal(v)}, e2):
				var e2 = try {
					if (hasSideEffect(e2)) throw NotFound.raise();
					inlineValue(e2, v.vId);
				} catch (_:NotFound) {
					commit(e2);
				};
				withExpr(e, TBinop(op, e1, e2));
			case TVar(v, e1) if (e1 != null && !hasSideEffect(e1)):
				var e1 = try inlineValue(e1, v.vId) catch (_:NotFound) commit(e1);
				withExpr(e, TVar(v, e1));
			case _: mapExpr(commit, e);
		};
		Graph.iterDomTree(actx.graph, function(bb) {
			if (!exists(edge -> BasicBlock.hasFlag(edge, FlagExecutable), bb.bbIncoming)) bb.bbDominator = actx.graph.gUnreachable;
			dynarrayMap(commit, bb.bbEl);
			bb.bbTerminator = terminatorMap(commit, bb.bbTerminator);
		});
	}
}

class ConstPropagation {
	public static function apply(actx:AnalyzerContext):Void new DataFlow(new ConstPropagationImpl()).apply(actx);
}

/*
	Propagates local variables to other local variables.

	Respects scopes on targets where it matters (all except JS).
*/
enum CopyLattice {
	CopyTop;
	CopyBottom;
	Local(v:TVar);
	ThisValue(t:T);
}

class CopyPropagationImpl implements DataFlowApi<CopyLattice, haxe.ds.IntMap<CopyLattice>> {
	public var conditional(default, null) = false;
	public var flag(default, null) = FlagCopyPropagation;
	public var top(default, null):CopyLattice = CopyTop;
	public var bottom(default, null):CopyLattice = CopyBottom;

	public function new() {}

	public function toString(t:CopyLattice):String return switch t {
		case CopyTop: "Top";
		case CopyBottom: "Bottom";
		case Local(v): '${v.vName}<${v.vId}>';
		case ThisValue(_): "this";
	};

	public function getCell(ctx:haxe.ds.IntMap<CopyLattice>, id:Int):CopyLattice return ctx.exists(id) ? ctx.get(id) : CopyTop;

	public function setCell(ctx:haxe.ds.IntMap<CopyLattice>, id:Int, t:CopyLattice):Void ctx.set(id, t);

	public function equals(a:CopyLattice, b:CopyLattice):Bool return switch [a, b] {
		case [CopyTop, CopyTop] | [CopyBottom, CopyBottom]: true;
		case [Local(v), Local(w)]: v.vId == w.vId;
		case [ThisValue(t), ThisValue(u)]: t == u;
		case _: false;
	};

	public function transfer(actx:AnalyzerContext, ctx:haxe.ds.IntMap<CopyLattice>, bb:BasicBlockData, e:TExpr):CopyLattice {
		function loop(e:TExpr):CopyLattice return switch e.eexpr {
			case TLocal(v) if (!hasVarFlag(v, VCaptured)): Local(v);
			case TConst(TThis): ThisValue(e.etype);
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): loop(e1);
			case _: CopyBottom;
		};
		return loop(e);
	}

	public function init(ctx:AnalyzerContext):haxe.ds.IntMap<CopyLattice> return new haxe.ds.IntMap();

	public function commit(actx:AnalyzerContext, ctx:haxe.ds.IntMap<CopyLattice>):Void {
		function commit(bb:BasicBlockData, e:TExpr):TExpr return switch e.eexpr {
			case TLocal(v) if (!hasVarFlag(v, VCaptured)): try {
					function leave():Dynamic {
						ctx.remove(v.vId);
						throw NotFound.raise();
					}
					switch getCell(ctx, v.vId) {
						case Local(w):
							if (!typeChangeOk(actx.com, w.vType, v.vType)) leave();
							// port: hxmc's struct values (AnalyzerTexpr.keepCopyHook)
							if (AnalyzerTexpr.keepCopyHook != null && !v.vKind.match(VGenerated)
								&& AnalyzerTexpr.keepCopyHook(v.vType, withExpr(e, TLocal(w)))) leave();
							// This restriction is in place due to how we currently reconstruct the AST. Multiple SSA-vars may be turned back to
							// the same origin var, which creates interference that is not tracked in the analysis. We address this by only
							// considering variables whose origin-variables are assigned to at most once.
							var origin = getVarOrigin(actx.graph, w);
							switch getVarInfo(actx.graph, origin).viWrites {
								case [decl] if (inScope(bb, decl)):
								case _: leave();
							}
							maybeInheritVarName(w, v);
							commit(bb, withExpr(e, TLocal(w)));
						case ThisValue(t):
							if (!typeChangeOk(actx.com, t, v.vType)) leave();
							mk(TConst(TThis), t, e.epos);
						case CopyTop | CopyBottom: leave();
					}
				} catch (_:NotFound) {
					e;
				}
			case TBinop(op = OpAssign | OpAssignOp(_), e1 = {eexpr: TLocal(_)}, e2): withExpr(e, TBinop(op, e1, commit(bb, e2)));
			case _: mapExprWith(commit, bb, e);
		};
		Graph.iterDomTree(actx.graph, function(bb) {
			dynarrayMap(e -> commit(bb, e), bb.bbEl);
			bb.bbTerminator = terminatorMap(e -> commit(bb, e), bb.bbTerminator);
		});
	}
}

class CopyPropagation {
	public static function apply(actx:AnalyzerContext):Void new DataFlow(new CopyPropagationImpl()).apply(actx);
}

/*
	LocalDce implements a mark & sweep dead code elimination. The mark phase follows the CFG edges of the graphs to find
	variable usages and marks variables accordingly. If ConstPropagation was run before, only CFG edges which are
	considered executable are processed.

	If a variable is marked as used, its reaching definition is recursively marked as used too. Furthermore its
	value is processed as an expression.

	The sweep phase removes all variable declarations and assignments of unused variables, keeping only the assigned
	expression in case of side-effects.
*/
class LocalDce {
	public static function hasSideEffect(e:TExpr):Bool return switch e.eexpr {
		case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): false;
		case TCall({eexpr: TField(_, FStatic({clPath: {pack: [], name: "Std"}}, {cfName: "string"}))}, _): checkExpr(hasSideEffect, e);
		case TCall({eexpr: TField(_, FEnum(_, _))}, _): checkExpr(hasSideEffect, e);
		case TCall({eexpr: TConst(TString("phi" | "fun"))}, _): false;
		case TCall({eexpr: TField(e1, fa)}, el) if (PurityState.isPureFieldAccess(fa)): hasSideEffect(e1) || exists(hasSideEffect, el);
		case TField(_, fa) if (PurityState.isExplicitlyImpure(fa)): true;
		case TNew(_, _, _) | TCall(_, _) | TBinop(OpAssignOp(_) | OpAssign, _, _) | TUnop(Increment | Decrement, _, _) | TReturn(_) |
			TBreak | TContinue | TThrow(_): true;
		case TCast(_, mt) if (mt != null): true;
		case _: checkExpr(hasSideEffect, e);
	};

	public static function apply(ctx:AnalyzerContext):Void {
		function used(v:TVar):Bool return hasVarFlag(v, VAnalyzed);
		function keep(v:TVar):Bool return used(v)
			|| (switch v.vKind {
				case VUser(_) | VInlined | VInlinedConstructorVariable(_): true;
				case _: false;
			})
			&& !ctx.config.localDce
			|| core.TOther.ExtType.hasReferenceSemantics(v.vType)
			|| hasVarFlag(v, VCaptured)
			|| Meta.has(This, v.vMeta);
		var expr:TExpr->Void = null;
		function use(v:TVar):Void if (!used(v)) {
			addVarFlag(v, VAnalyzed);
			try expr(getVarValue(ctx.graph, v))
			catch (_:NotFound) {}
			var reaching = Ssa.getReachingDef(ctx.graph, v);
			if (reaching == null) {
				// We don't want to fully recurse for the origin variable because we don't care about its
				// reaching definition (issue #10972). Simply marking it as being used should be sufficient.
				var origin = getVarOrigin(ctx.graph, v);
				if (!used(origin)) addVarFlag(origin, VAnalyzed);
			} else use(reaching);
		}
		expr = function(e:TExpr):Void switch e.eexpr {
			case TLocal(v):
				use(v);
			case TBinop(OpAssign, {eexpr: TLocal(v)}, e1) | TVar(v, e1) if (e1 != null):
				if (hasSideEffect(e1) || keep(v)) expr(e1);
			case _:
				iter(expr, e);
		};
		function mark(bb:BasicBlockData):Void {
			addBlockFlag(bb, BlockDce);
			for (e in bb.bbEl) expr(e);
			for (e in bb.bbPhi) expr(e);
			terminatorIter(expr, bb.bbTerminator);
			for (edge in bb.bbOutgoing) if (!BasicBlock.hasFlag(edge, FlagDce)) {
				edge.cfgFlags.unshift(FlagDce);
				if (!ctx.config.constPropagation || BasicBlock.hasFlag(edge, FlagExecutable)) mark(edge.cfgTo);
			}
		}
		mark(ctx.graph.gRoot);
		function sweep(e:TExpr):TExpr return switch e.eexpr {
			case TBinop(OpAssign, {eexpr: TLocal(v)},
				e2) | TVar(v, e2) if (e2 != null && !keep(v)): hasSideEffect(e2) ? e2 : mk(TConst(TNull), e.etype, e.epos);
			case TVar(v, null) if (!keep(v)): mk(TConst(TNull), e.etype, e.epos);
			case _: mapExpr(sweep, e);
		};
		Graph.iterDomTree(ctx.graph, function(bb) {
			if (hasBlockFlag(bb, BlockDce)) {
				dynarrayMap(sweep, bb.bbEl);
				bb.bbTerminator = terminatorMap(sweep, bb.bbTerminator);
			}
		});
	}
}

enum NodeInfo {
	NIExpr;
	NIVars;
	NIPhi;
	NILoopGroups;
	NIScopes;
}

class Debug {
	public static function sVar(v:TVar):String return '${v.vName}<${v.vId}>';

	static function escape(s:String):String return core.StringHelper.sEscape(s);

	public static function dotDebugNode(g:GraphData, ch:haxe.io.Output, nil:Array<NodeInfo>, bb:BasicBlockData):Void {
		var s = '(${bb.bbId})';
		for (ni in nil) s += switch ni {
			case NIExpr: bb.bbEl.length == 0 ? "" : "\n" + bb.bbEl.map(sExprPretty).join("\n");
			case NIPhi: bb.bbPhi.length == 0 ? "" : "\n" + bb.bbPhi.map(sExprPretty).join("\n");
			// port: bbVarWrites is in push order (Graph.addVarDef)
			case NIVars: bb.bbVarWrites.length == 0 ? "" : "\n" + [
					for (i in 0...bb.bbVarWrites.length) sVar(bb.bbVarWrites[bb.bbVarWrites.length - 1 - i])
				].join(", ");
			case NILoopGroups: bb.bbLoopGroups.length == 0 ? "" : "\nLoops: " + bb.bbLoopGroups.map(Std.string).join(", ");
			case NIScopes: bb.bbScopes.length == 0 ? "" : "\nScopes: " + bb.bbScopes.map(Std.string).join(", ");
		};
		var kind = switch bb.bbKind {
			case BKRoot: "<root>\n";
			case BKFunctionBegin(_): "<function-begin>\n";
			case BKFunctionEnd: "<function-end>\n";
			case BKLoopHead: "<loop-head>\n";
			case BKCatch(v): '<catch ${v.vName}<${v.vId}>>';
			case BKException: "<exc>";
			case _: "";
		};
		ch.writeString('n${bb.bbId} [shape=box,label="$kind${escape(s)}"];\n');
	}

	public static function dotDebugCfgEdge(ch:haxe.io.Output, edge:CfgEdge):Void {
		var label = switch edge.cfgKind {
			case CFGGoto: "goto";
			case CFGFunction: "function";
			case CFGMaybeThrow: "throw?";
			case CFGCondBranch(_): "branch";
			case CFGCondElse: "else";
		};
		if (edge.cfgFlags.length > 0) label += " [" + edge.cfgFlags.map(flag -> switch flag {
			case FlagExecutable: "exe";
			case FlagDce: "dce";
			case FlagCopyPropagation: "copy";
		}).join(", ") + "]";
		ch.writeString('n${edge.cfgFrom.bbId} -> n${edge.cfgTo.bbId}[label="${escape(label)}"];\n');
	}

	public static function dotDebugSyntaxEdge(ch:haxe.io.Output, bb:BasicBlockData, se:SyntaxEdge):Void {
		inline function edge(other:BasicBlockData,
				label:String):Void ch.writeString('n${bb.bbId} -> n${other.bbId}[style="dashed",color="gray",label="$label"];\n');
		switch se {
			case SESubBlock(sub, next):
				edge(sub, "sub");
				edge(next, "next");
			case SEIfThen(bt, next, _):
				edge(bt, "then");
				edge(next, "next");
			case SEIfThenElse(bt, be, next, _, _):
				edge(bt, "then");
				edge(be, "else");
				edge(next, "next");
			case SEWhile(body, next, _):
				edge(body, "loop-body");
				edge(next, "next");
			case SEMerge(next):
				edge(next, "merge");
			case SESwitch(ss):
				for (c in ss.ssCases) edge(c.bb, "case " + c.values.map(sExprPretty).join(" | "));
				if (ss.ssDefault != null) edge(ss.ssDefault, "default");
				edge(ss.ssNext, "next");
			case SETry(bt, _, catches, next, _):
				edge(bt, "try");
				for (c in catches) edge(c.bb, "catch");
				edge(next, "next");
			case SENone:
		}
	}

	public static function htmlescape(s:String):String return s.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;");

	public static function generateCfgSsa(ch:haxe.io.Output, g:GraphData):Void {
		ch.writeString("\tnode [shape=plaintext];\n");
		inline function exprName(luk:TExprLookupTarget):String return "e" + switch luk {
			case LUPhi(i): "p" + i;
			case LUEl(i): Std.string(i);
			case LUTerm: "t";
		};
		for (bb in Graph.nodes(g)) {
			ch.writeString('n${bb.bbId}[label=<<table BORDER="0" CELLBORDER="1" CELLSPACING="0">\n\t<tr><td port="in" bgcolor="lightgray">(${bb.bbId}) ${BasicBlock.sBlockKind(bb.bbKind)}</td></tr>\n');
			inline function row(luk:TExprLookupTarget, e:TExpr):Void
				ch.writeString('\t<tr><td port="${exprName(luk)}" align="left">${escape(htmlescape(sExprPretty(e)))}</td></tr>\n');
			for (i in 0...bb.bbPhi.length) row(LUPhi(i), bb.bbPhi[i]);
			for (i in 0...bb.bbEl.length) row(LUEl(i), bb.bbEl[i]);
			ch.writeString('\t<tr><td port="out"></td></tr>\n</table>>];\n');
		}
		Graph.iterEdges(g,
			function(edge)
				ch.writeString('n${edge.cfgFrom.bbId}:out -> n${edge.cfgTo.bbId}:in[label="${BasicBlock.sCfgEdgeKind(edge.cfgKind)}"];\n'));
		for (vi in g.gVarInfos) if (vi.viValue != null) {
			var value = vi.viValue;
			var n1 = 'n${value.bb.bbId}:${exprName(value.target)}';
			for (edge in vi.viSsaEdges) if (value.bb != edge.bb) // intra-node edges look stupid in dot
				ch.writeString('$n1 -> n${edge.bb.bbId}:${exprName(edge.target)}[color=lightblue,constraint=false];\n');
		}
	}

	public static function platformNameMacro(com:context.SafeCom.SafeContext):String return core.Define.defined(com.defines,
		core.Define.Macro) ? "macro" : core.Globals.platformName(com.platform);

	public static function getDumpPath(ctx:AnalyzerContext, c:TClass,
			cf:TClassField):Array<String> return [ctx.com.dumpConfig.dumpPath, platformNameMacro(ctx.com)].concat(c.clPath.pack)
			.concat([c.clPath.name + "." + cf.cfName]);

	public static function dotDebug(ctx:AnalyzerContext, c:GlobalTypePath, cf:String):Void {
		var g = ctx.graph;
		inline function start(suffix:String):Dynamic return context.DotGraph.startGraph(context.DotGraph.getDumpPath(ctx.com, c, cf),
			suffix, []);
		var graph = start("-cfg.dot");
		for (bb in Graph.nodes(g)) dotDebugNode(g, graph.channel, [NILoopGroups, NIScopes, NIPhi, NIExpr], bb);
		Graph.iterEdges(g, dotDebugCfgEdge.bind(graph.channel));
		graph.close();
		graph = start("-cfg-ssa.dot");
		generateCfgSsa(graph.channel, g);
		graph.close();
		graph = start("-dj.dot");
		for (bb in Graph.nodes(g)) {
			dotDebugNode(g, graph.channel, [], bb);
			for (inc in bb.bbIncoming) {
				var pred = inc.cfgFrom;
				var style = pred == bb.bbDominator ? "solid" : "dashed";
				graph.channel.writeString('n${pred.bbId} -> n${bb.bbId}[style="$style"];\n');
			}
		}
		graph.close();
		graph = start("-df.dot");
		for (bb in Graph.nodes(g)) {
			dotDebugNode(g, graph.channel, [NIVars], bb);
			for (other in bb.bbDf) graph.channel.writeString('n${bb.bbId} -> n${other.bbId};\n');
		}
		graph.close();
		graph = start("-dom.dot");
		for (bb in Graph.nodes(g)) {
			dotDebugNode(g, graph.channel, [NIVars], bb);
			// port: bbDominated is in push order (Graph.inferImmediateDominators)
			var i = bb.bbDominated.length;
			while (i > 0) graph.channel.writeString('n${bb.bbId} -> n${bb.bbDominated[--i].bbId};\n');
		}
		graph.close();
		graph = start("-syntax.dot");
		for (bb in Graph.nodes(g)) {
			dotDebugNode(g, graph.channel, [NIExpr], bb);
			dotDebugSyntaxEdge(graph.channel, bb, bb.bbSyntaxEdge);
		}
		graph.close();
		graph = start("-ssa-edges.dot");
		var nodes = new haxe.ds.StringMap<Bool>();
		inline function nodeName(bb:BasicBlockData, luk:TExprLookupTarget):String return 'e${bb.bbId}_' + switch luk {
			case LUPhi(i): "phi_" + i;
			case LUEl(i): "el" + i;
			case LUTerm: "term";
		};
		inline function activeName(bb:BasicBlockData, luk:TExprLookupTarget):String {
			var n = nodeName(bb, luk);
			nodes.set(n, true);
			return n;
		}
		for (vi in g.gVarInfos) if (vi.viValue != null) {
			var value = vi.viValue;
			var n1 = activeName(value.bb, value.target);
			for (edge in vi.viSsaEdges) {
				var n2 = activeName(edge.bb, edge.target);
				graph.channel.writeString('$n1 -> $n2;\n');
			}
		}
		for (bb in Graph.nodes(g)) {
			var active = [];
			inline function add(luk:TExprLookupTarget, e:TExpr):Void {
				var n = nodeName(bb, luk);
				if (nodes.exists(n)) active.unshift({name: n, label: sExprPretty(e)});
			}
			for (i in 0...bb.bbPhi.length) add(LUPhi(i), bb.bbPhi[i]);
			for (i in 0...bb.bbEl.length) add(LUEl(i), bb.bbEl[i]);
			if (active.length > 0) {
				graph.channel.writeString('subgraph cluster_${bb.bbId} {\nlabel=${bb.bbId};\nstyle=filled;\ncolor=lightblue;\n');
				for (item in active) graph.channel.writeString('${item.name}[shape=box,label="${escape(item.label)}"];\n');
				graph.channel.writeString("}\n");
			}
		}
		graph.close();
	}
}

private typedef ExceptionOutput = {var value:Dynamic; var mutex:sys.thread.Mutex;}

class Run {
	// port: actx.withTimer without the dynamic call (the field holds a polymorphic
	// function, which Haxe can only type as Dynamic)
	public static inline function timed<A>(actx:AnalyzerContext, s:Array<String>,
			f:Void->A):A return withTimer(actx.com.timerCtx, actx.config.detailTimes, actx.identifier, s, f);

	public static function withTimer<A>(timerCtx:core.Timer.TimerContext, level:Int, identifier:Null<String>, s:Array<String>,
			f:Void->A):A {
		// port: Timer.time only calls f when times are not measured; skip building the id and wrapper.
		if (timerCtx.measureTimes == core.Timer.MeasureTimes.No) return f();
		var id = core.Timer.determineId(level, ["analyzer"], s, identifier);
		return core.Timer.time(timerCtx, id, function(_:Null<Bool>) return f(), null);
	}

	public static function createAnalyzerContext(com:context.SafeCom.SafeContext, config:AnalyzerConfigData, identifier:String,
			e:TExpr):AnalyzerContext {
		var g = Graph.create(e.etype, e.epos);
		return {
			com: com,
			config: config,
			graph: g,
			// For CPP we want to use variable names which are "probably" not used by users in order to
			// avoid problems with the debugger, see https://github.com/HaxeFoundation/hxcpp/issues/365
			tempVarName: com.platform == Cpp ? "_hx_tmp" : "tmp",
			withTimer: function(s, f) return withTimer(com.timerCtx, config.detailTimes, identifier, s, f),
			identifier: identifier,
			entry: g.gUnreachable,
			hasUnbound: false,
			loopCounter: 0,
			loopStack: [],
			debugExprs: [],
			nameStack: [],
			didOptimize: false
		};
	}

	public static function addDebugExpr(ctx:AnalyzerContext, s:String, e:TExpr):Void ctx.debugExprs.unshift({name: s, expr: e});

	public static function there(actx:AnalyzerContext, e:TExpr):Bool {
		if (actx.com.debug) addDebugExpr(actx, "initial", e);
		e = optimization.Analyzer.Run.timed(actx, ["->", "filter-apply"], function() return TexprFilter.apply(actx.com, e));
		if (actx.com.debug) addDebugExpr(actx, "after filter-apply", e);
		var tf:TFunc;
		var t:T;
		var real:Bool;
		switch e.eexpr {
			case TFunction(f):
				tf = f;
				t = e.etype;
				real = true;
			case _:
				// Wrap expression in a function so we don't have to treat it as a special case throughout.
				var ret = e.etype;
				tf = {tfArgs: [], tfType: ret, tfExpr: mk(TReturn(e), tDynamic, e.epos)};
				t = tfun([], ret);
				real = false;
		}
		optimization.Analyzer.Run.timed(actx, ["->", "from-texpr"], function() AnalyzerTexprTransformer.fromTfunction(actx, tf, t, e.epos));
		return real;
	}

	public static function backAgain(actx:AnalyzerContext, isRealFunction:Bool):TExpr {
		var e:TExpr = optimization.Analyzer.Run.timed(actx, ["<-", "to-texpr"], function() return AnalyzerTexprTransformer.toTexpr(actx));
		if (actx.com.debug) addDebugExpr(actx, "after to-texpr", e);
		for (vi in actx.graph.gVarInfos) vi.viVar.vExtra = vi.viExtra;
		if (actx.config.fusion) e = optimization.Analyzer.Run.timed(actx, ["<-", "fusion"], function() return Fusion.apply(actx, e));
		if (actx.com.debug) addDebugExpr(actx, "after fusion", e);
		e = optimization.Analyzer.Run.timed(actx, ["<-", "cleanup"], function() return Cleanup.apply(actx.com, e));
		if (actx.com.debug) addDebugExpr(actx, "after cleanup", e);
		if (isRealFunction) return e;
		// Get rid of the wrapping function and its return expressions.
		return switch e.eexpr {
			case TFunction(tf):
				inline function getT(t:T):T return core.TOther.ExtType.isVoid(t) ? tf.tfType : t;
				var dislikesComplex = switch actx.com.platform {
					case Cpp | Hl | Jvm | Php | Flash: true;
					case _: false;
				};
				function loop(e:TExpr):TExpr return switch e.eexpr {
					case TBlock([e1]): loop(e1);
					// If there's a complex expression, keep the function and generate a call to it.
					case TBlock(_) | TIf(_, _, _) | TSwitch(_) | TTry(_, _) if (dislikesComplex): throw new TypeExit();
					// Remove generated return
					case TReturn(inner) if (inner != null): inner;
					case TBlock(el): if (el.length == 0) e; else {
							var last = loop(el[el.length - 1]);
							withExpr(e, TBlock(el.slice(0, el.length - 1).concat([last])));
						}
					case TIf(e1, e2, e3) if (e3 != null):
						var e2 = loop(e2);
						var e3 = loop(e3);
						{eexpr: TIf(e1, e2, e3), etype: getT(e.etype), epos: e.epos};
					case TSwitch(s):
						var cases = s.switchCases.map(c -> ({
							casePatterns: c.casePatterns,
							caseExpr: loop(c.caseExpr)
						} : core.TType.TSwitchCase));
						var def = s.switchDefault == null ? null : loop(s.switchDefault);
						{eexpr: TSwitch(mkSwitch(s.switchSubject, cases, def, s.switchExhaustive)), etype: getT(e.etype), epos: e.epos};
					case TTry(e1, catches):
						var e1 = loop(e1);
						var catches = catches.map(c -> {variable: c.variable, expr: loop(c.expr)});
						{eexpr: TTry(e1, catches), etype: getT(e.etype), epos: e.epos};
					case TMeta(m, e1): withExpr(e, TMeta(m, loop(e1)));
					case TParenthesis(e1): withExpr(e, TParenthesis(loop(e1)));
					case _: e;
				};
				try loop(tf.tfExpr) catch (_:TypeExit) mk(TCall(e, []), tf.tfType, e.epos);
			case _: throw "Analyzer.backAgain expected function";
		};
	}

	public static function runOnExpr(actx:AnalyzerContext, e:TExpr):TExpr {
		var real = there(actx, e);
		optimization.Analyzer.Run.timed(actx, ["->", "idom"], function() Graph.inferImmediateDominators(actx.graph));
		optimization.Analyzer.Run.timed(actx, ["->", "infer_scopes"], function() Graph.inferScopes(actx.graph));
		optimization.Analyzer.Run.timed(actx, ["->", "var writes"], function() Graph.inferVarWrites(actx.graph));
		if (actx.com.debug) Graph.checkIntegrity(actx.graph);
		if (actx.config.optimize && !actx.hasUnbound) {
			actx.didOptimize = true;
			optimization.Analyzer.Run.timed(actx, ["optimize", "ssa-apply"], function() Ssa.apply(actx));
			if (actx.config.constPropagation) optimization.Analyzer.Run.timed(actx, ["optimize", "const-propagation"],
				function() ConstPropagation.apply(actx));
			if (actx.config.copyPropagation) optimization.Analyzer.Run.timed(actx, ["optimize", "copy-propagation"],
				function() CopyPropagation.apply(actx));
			optimization.Analyzer.Run.timed(actx, ["optimize", "local-dce"], function() LocalDce.apply(actx));
		}
		return backAgain(actx, real);
	}

	public static function reduceControlFlow(com:context.SafeCom.SafeContext,
			e:TExpr):TExpr return Optimizer.reduceControlFlow(com, core.Texpr.mapExprWithScom(reduceControlFlow, com, e));

	public static function runOnFieldInternal(com:context.SafeCom.SafeContext, excOut:ExceptionOutput, config:AnalyzerConfigData,
			c:TClass, cf:TClassField):Void {
		if (cf.cfExpr == null
			|| AnalyzerConfig.isIgnored(cf.cfMeta)
			|| filters.FilterContext.isRemovableField(com.isMacroContext, cf)
			|| hasClassFieldFlag(cf, CfPostProcessed)) return;
		var e = cf.cfExpr;
		config = AnalyzerConfig.updateConfigFromMeta(com, config, cf.cfMeta);
		var actx = createAnalyzerContext(com, config, Globals.sTypePath(c.clPath) + "." + cf.cfName, e);
		inline function debug():Void {
			Sys.println("While analyzing " + Globals.sTypePath(c.clPath) + "." + cf.cfName);
			var expressions = actx.debugExprs.copy();
			expressions.reverse();
			for (item in expressions) {
				Sys.println("<" + item.name + ">");
				Sys.println(core.TPrinting.sExprPretty(true, "", false, core.TPrinting.sType.bind(core.TPrinting.printContext()),
					item.expr));
				Sys.println("</" + item.name + ">");
			}
			Debug.dotDebug(actx, c.clPath, cf.cfName);
			Sys.println("dot graph written to " + context.DotGraph.getDumpPath(actx.com, c.clPath, cf.cfName).join("/"));
		}
		inline function maybeDebug():Void switch config.debugKind {
			case DebugNone:
			case DebugDot:
				Debug.dotDebug(actx, c.clPath, cf.cfName);
			case DebugFull:
				debug();
		}
		inline function save(exc:Dynamic):Void {
			excOut.mutex.acquire();
			excOut.value = exc;
			excOut.mutex.release();
		}
		try {
			e = runOnExpr(actx, e);
			e = reduceControlFlow(com, e);
			maybeDebug();
			cf.cfExpr = e;
		} catch (exc:core.Error.TypingError) {
			maybeDebug();
			save(exc);
		} catch (exc:core.ds.Cancelled) {
			maybeDebug();
			save(exc);
		} catch (exc:Dynamic) {
			debug();
			save(exc);
		}
	}

	public static function checkExcOut(out:ExceptionOutput):Void {
		out.mutex.acquire();
		var exc = out.value;
		out.mutex.release();
		if (exc != null) throw exc;
	}

	public static function runOnField(com:context.SafeCom.SafeContext, config:AnalyzerConfigData, c:TClass, cf:TClassField):Void {
		var out:ExceptionOutput = {value: null, mutex: new sys.thread.Mutex()};
		runOnFieldInternal(com, out, config, c, cf);
		checkExcOut(out);
	}

	public static function runOnClass(com:context.SafeCom.SafeContext, out:ExceptionOutput, pool:Null<core.ds.TaskPool>,
			config:AnalyzerConfigData, c:TClass):Void {
		config = AnalyzerConfig.updateConfigFromMeta(com, config, c.clMeta);
		var fields = [];
		inline function processField(stat:Bool, cf:TClassField):Void switch cf.cfKind {
			case Var({vRead: _, vWrite: _}) if (!stat):
			case _:
				fields.push(cf);
				for (overloadedField in cf.cfOverloads) fields.push(overloadedField);
		}
		for (cf in c.clOrderedFields) processField(false, cf);
		for (cf in c.clOrderedStatics) processField(true, cf);
		if (c.clConstructor != null) processField(false, c.clConstructor);
		context.Parallel.ParallelArray.iter(pool, function(cf) runOnFieldInternal(com, out, config, c, cf), fields);
		var init = core.TOther.TClassTools.getClInit(c);
		if (init != null) {
			var tf:TFunc = {tfArgs: [], tfType: init.etype, tfExpr: init};
			var e = mk(TFunction(tf), tfun([], init.etype), init.epos);
			var config:AnalyzerConfigData = core.ds.Record.copy(config);
			config.optimize = false;
			var actx = createAnalyzerContext(com, config, Globals.sTypePath(c.clPath) + ".__init__", e);
			var e = runOnExpr(actx, e);
			var body = switch e.eexpr {
				case TFunction(tf): tf.tfExpr;
				case _: throw "Analyzer.runOnClass expected function";
			};
			core.TOther.TClassTools.setClInit(c, body);
		}
	}

	public static function runOnType(com:context.SafeCom.SafeContext, out:ExceptionOutput, pool:Null<core.ds.TaskPool>,
			config:AnalyzerConfigData, t:ModuleType):Void switch t {
			case TClassDecl(c) if (AnalyzerConfig.isIgnored(c.clMeta)):
			case TClassDecl(c):
				runOnClass(com, out, pool, config, c);
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}

	public static function runOnTypes(scom:context.SafeCom.SafeContext, pool:Null<core.ds.TaskPool>, allTypes:Array<ModuleType>,
			newTypes:Array<ModuleType>):Void {
		var config = AnalyzerConfig.getBaseConfig(scom);
		withTimer(scom.timerCtx, config.detailTimes, null, ["other"], function() {
			if (config.optimize && config.purityInference) withTimer(scom.timerCtx, config.detailTimes, null,
				["optimize", "purity-inference"], function() Purity.infer(allTypes));
			var out:ExceptionOutput = {value: null, mutex: new sys.thread.Mutex()};
			context.Parallel.ParallelArray.iter(pool, function(t) runOnType(scom, out, pool, config, t), newTypes);
			checkExcOut(out);
		});
	}
}
