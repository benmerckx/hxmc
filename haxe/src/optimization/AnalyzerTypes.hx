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
import core.TFunctions.NotFound;
import core.TPrinting;
import context.SafeCom;
import optimization.AnalyzerConfig;

/*
	A BasicBlock represents a node in the control flow. It has expression elements similar to TBlock in the AST,
	but also holds additional information related to control flow and variables.

	Basic blocks are created whenever it is relevant for control flow. They differ from TBlock in that only their
	final element can be a control flow expression (the terminator). As a consequence, a given TBlock is split up
	into several basic blocks when control flow expressions are encountered.
*/
enum BlockKind {
	BKRoot; // The unique root block of the graph
	BKNormal; // A normal block
	BKFunctionBegin(tf:TFunc); // Entry block of a function
	BKFunctionEnd; // Exit block of a function
	BKSub; // A sub block
	BKConditional; // A "then", "else" or "case" block
	BKLoopHead; // Header block of a loop
	BKException; // Relay block for exceptions
	BKUnreachable; // The unique unreachable block
	BKCatch(v:TVar); // A catch block
}

enum FlagBlock {
	BlockDce;
}

enum CfgEdgeFlag {
	FlagExecutable; // Used by constant propagation to handle live edges
	FlagDce; // Used by DCE to keep track of handled edges
	FlagCopyPropagation; // Used by copy propagation to track handled eges
}

enum CfgEdgeKind {
	CFGGoto; // An unconditional branch
	CFGFunction; // Link to a function
	CFGMaybeThrow; // The block may or may not throw an exception
	CFGCondBranch(e:TExpr); // A conditional branch
	CFGCondElse; // A conditional alternative (else,default)
}

@:structInit class CfgEdge {
	public var cfgFrom:BasicBlockData; // The source block
	public var cfgTo:BasicBlockData; // The target block
	public var cfgKind:CfgEdgeKind; // The edge kind
	public var cfgFlags:Array<CfgEdgeFlag>; // Edge flags

	public inline function new(cfgFrom:BasicBlockData, cfgTo:BasicBlockData, cfgKind:CfgEdgeKind, cfgFlags:Array<CfgEdgeFlag>) {
		this.cfgFrom = cfgFrom;
		this.cfgTo = cfgTo;
		this.cfgKind = cfgKind;
		this.cfgFlags = cfgFlags;
	}

	public inline function clone():CfgEdge return new CfgEdge(cfgFrom, cfgTo, cfgKind, cfgFlags);
}

enum SyntaxEdge {
	SEIfThen(bbThen:BasicBlockData, bbNext:BasicBlockData, p:Pos); // `if` with "then" and "next"
	SEIfThenElse(bbThen:BasicBlockData, bbElse:BasicBlockData, bbNext:BasicBlockData, t:T, p:Pos); // `if` with "then", "else" and "next"
	SESwitch(ss:SyntaxSwitch); // `switch` with cases, "default" and "next"
	SETry(bbTry:BasicBlockData, bbExc:BasicBlockData, catches:Array<{v:TVar, bb:BasicBlockData}>, bbNext:BasicBlockData, p:Pos); // `try` with "exc", catches and "next"
	SEWhile(bbBody:BasicBlockData, bbNext:BasicBlockData, p:Pos); // `while` with "body" and "next"
	SESubBlock(bbSub:BasicBlockData, bbNext:BasicBlockData); // "sub" with "next"
	SEMerge(bb:BasicBlockData); // Merge to same block
	SENone; // No syntax exit
}

@:structInit class SyntaxSwitch {
	public var ssCases:Array<{values:Array<TExpr>, bb:BasicBlockData}>;
	public var ssDefault:Null<BasicBlockData>;
	public var ssNext:BasicBlockData;
	public var ssPos:Pos;
	public var ssExhaustive:Bool;

	public inline function new(ssCases:Array<{values:Array<TExpr>, bb:BasicBlockData}>, ssDefault:Null<BasicBlockData>,
			ssNext:BasicBlockData, ssPos:Pos, ssExhaustive:Bool) {
		this.ssCases = ssCases;
		this.ssDefault = ssDefault;
		this.ssNext = ssNext;
		this.ssPos = ssPos;
		this.ssExhaustive = ssExhaustive;
	}

	public inline function clone():SyntaxSwitch return new SyntaxSwitch(ssCases, ssDefault, ssNext, ssPos, ssExhaustive);
}

enum TerminatorKind {
	TermNone;
	TermCondBranch(e:TExpr);
	TermReturn(p:Pos);
	TermReturnValue(e:TExpr, p:Pos);
	TermBreak(p:Pos);
	TermContinue(p:Pos);
	TermThrow(e:TExpr, p:Pos);
}

@:structInit class BasicBlockData {
	public var bbId:Int; // The unique ID of the block
	public var bbType:T; // The block type
	public var bbPos:Pos; // The block position
	public var bbKind:BlockKind; // The block kind
	public var bbClosed:Bool; // Whether or not the block has been closed
	public var bbFlags:Int;
	// elements
	public var bbEl:Array<TExpr>; // The block expressions
	public var bbPhi:Array<TExpr>; // SSA-phi expressions
	public var bbTerminator:TerminatorKind;
	// relations
	public var bbOutgoing:Array<CfgEdge>; // Outgoing edges
	public var bbIncoming:Array<CfgEdge>; // Incoming edges
	public var bbDominator:BasicBlockData; // The block's dominator
	public var bbDominated:Array<BasicBlockData>; // The dominated blocks
	public var bbDf:Array<BasicBlockData>; // The dominance frontier
	public var bbSyntaxEdge:SyntaxEdge; // The syntactic edge
	public var bbLoopGroups:Array<Int>; // The loop groups this block belongs to
	public var bbScopes:Array<Int>; // The scopes this block belongs to
	// variables
	public var bbVarWrites:Array<TVar>; // List of assigned variables

	public inline function new(bbId:Int, bbType:T, bbPos:Pos, bbKind:BlockKind, bbClosed:Bool, bbFlags:Int, bbEl:Array<TExpr>,
			bbPhi:Array<TExpr>, bbTerminator:TerminatorKind, bbOutgoing:Array<CfgEdge>, bbIncoming:Array<CfgEdge>,
			bbDominator:BasicBlockData, bbDominated:Array<BasicBlockData>, bbDf:Array<BasicBlockData>, bbSyntaxEdge:SyntaxEdge,
			bbLoopGroups:Array<Int>, bbScopes:Array<Int>, bbVarWrites:Array<TVar>) {
		this.bbId = bbId;
		this.bbType = bbType;
		this.bbPos = bbPos;
		this.bbKind = bbKind;
		this.bbClosed = bbClosed;
		this.bbFlags = bbFlags;
		this.bbEl = bbEl;
		this.bbPhi = bbPhi;
		this.bbTerminator = bbTerminator;
		this.bbOutgoing = bbOutgoing;
		this.bbIncoming = bbIncoming;
		this.bbDominator = bbDominator;
		this.bbDominated = bbDominated;
		this.bbDf = bbDf;
		this.bbSyntaxEdge = bbSyntaxEdge;
		this.bbLoopGroups = bbLoopGroups;
		this.bbScopes = bbScopes;
		this.bbVarWrites = bbVarWrites;
	}

	public inline function clone():BasicBlockData return new BasicBlockData(bbId, bbType, bbPos, bbKind, bbClosed, bbFlags, bbEl, bbPhi,
		bbTerminator, bbOutgoing, bbIncoming, bbDominator, bbDominated, bbDf, bbSyntaxEdge, bbLoopGroups, bbScopes, bbVarWrites);
}

enum TExprLookupTarget {
	LUPhi(i:Int);
	LUEl(i:Int);
	LUTerm;
}

class BasicBlock {
	public static function intOfBlockFlag(flag:FlagBlock):Int return std.Type.enumIndex(flag);

	public static function addBlockFlag(bb:BasicBlockData, flag:FlagBlock) bb.bbFlags = setFlag(bb.bbFlags, intOfBlockFlag(flag));

	public static function removeBlockFlag(bb:BasicBlockData, flag:FlagBlock) bb.bbFlags = unsetFlag(bb.bbFlags, intOfBlockFlag(flag));

	public static function hasBlockFlag(bb:BasicBlockData,
			flag:FlagBlock):Bool return core.TFunctions.hasFlag(bb.bbFlags, intOfBlockFlag(flag));

	public static function sBlockKind(kind:BlockKind):String return switch kind {
		case BKRoot: "BKRoot";
		case BKNormal: "BKNormal";
		case BKFunctionBegin(_): "BKFunctionBegin";
		case BKFunctionEnd: "BKFunctionEnd";
		case BKSub: "BKSub";
		case BKConditional: "BKConditional";
		case BKLoopHead: "BKLoopHead";
		case BKException: "BKException";
		case BKUnreachable: "BKUnreachable";
		case BKCatch(_): "BKCatch";
	};

	public static function sCfgEdgeKind(kind:CfgEdgeKind):String return switch kind {
		case CFGGoto: "CFGGoto";
		case CFGFunction: "CFGFunction";
		case CFGMaybeThrow: "CFGMaybeThrow";
		case CFGCondBranch(e): "CFGCondBranch "
			+ TPrinting.sExprPretty(false, "", false, TPrinting.sType.bind(TPrinting.printContext()), e);
		case CFGCondElse: "CFGCondElse";
	};

	public static function hasFlag(edge:CfgEdge, flag:CfgEdgeFlag):Bool return edge.cfgFlags.contains(flag);

	// expressions

	public static function addTexpr(bb:BasicBlockData, e:TExpr) bb.bbEl.push(e);

	public static function getTexpr(bb:BasicBlockData, luk:TExprLookupTarget):TExpr return switch luk {
		case LUPhi(i): bb.bbPhi[i];
		case LUEl(i): bb.bbEl[i];
		case LUTerm: switch bb.bbTerminator {
				case TermCondBranch(e) | TermReturnValue(e, _) | TermThrow(e, _): e;
				case TermNone | TermReturn(_) | TermBreak(_) | TermContinue(_): throw "AnalyzerTypes.getTexpr";
			}
	};

	// edges

	public static function setSyntaxEdge(bb:BasicBlockData, se:SyntaxEdge) bb.bbSyntaxEdge = se;

	public static function addCfgEdge(from:BasicBlockData, to:BasicBlockData, kind:CfgEdgeKind) {
		if (from.bbKind != BKUnreachable) {
			var edge:CfgEdge = {
				cfgFrom: from,
				cfgTo: to,
				cfgKind: kind,
				cfgFlags: []
			};
			from.bbOutgoing.unshift(edge);
			to.bbIncoming.unshift(edge);
		}
	}

	public static function create(id:Int, kind:BlockKind, t:T, p:Pos):BasicBlockData {
		var bb:BasicBlockData = {
			bbKind: kind,
			bbId: id,
			bbType: t,
			bbPos: p,
			bbClosed: false,
			bbFlags: 0,
			bbEl: [],
			bbPhi: [],
			bbTerminator: TermNone,
			bbOutgoing: [],
			bbIncoming: [],
			bbDominator: null,
			bbDominated: [],
			bbDf: [],
			bbSyntaxEdge: SENone,
			bbLoopGroups: [],
			bbVarWrites: [],
			bbScopes: []
		};
		bb.bbDominator = bb;
		return bb;
	}

	public static function inScope(bb:BasicBlockData, other:BasicBlockData):Bool {
		if (other.bbScopes.length == 0) core.Error.abort("Scope-less block (kind: " + sBlockKind(other.bbKind) + ")", other.bbPos);
		return bb.bbScopes.contains(other.bbScopes[0]);
	}

	public static function terminatorMap(f:TExpr->TExpr, term:TerminatorKind):TerminatorKind return switch term {
		case TermCondBranch(e): TermCondBranch(f(e));
		case TermReturnValue(e, p): TermReturnValue(f(e), p);
		case TermThrow(e, p): TermThrow(f(e), p);
		case TermNone | TermReturn(_) | TermBreak(_) | TermContinue(_): term;
	};

	public static function terminatorIter(f:TExpr->Void, term:TerminatorKind):Void switch term {
		case TermCondBranch(e) | TermReturnValue(e, _) | TermThrow(e, _):
			f(e);
		case TermNone | TermReturn(_) | TermBreak(_) | TermContinue(_):
	}
}

/*
	A Graph contains all relevant information for a given method. It is built from the field expression
	and then refined in subsequent modules such as Ssa.
*/
@:structInit class TFuncInfo {
	public var bb:BasicBlockData;
	public var type:T;
	public var pos:Pos;
	public var tf:TFunc;

	public inline function new(bb:BasicBlockData, type:T, pos:Pos, tf:TFunc) {
		this.bb = bb;
		this.type = type;
		this.pos = pos;
		this.tf = tf;
	}

	public inline function clone():TFuncInfo return new TFuncInfo(bb, type, pos, tf);
}

@:structInit class TExprLookup {
	public var bb:BasicBlockData;
	public var target:TExprLookupTarget;

	public inline function new(bb:BasicBlockData, target:TExprLookupTarget) {
		this.bb = bb;
		this.target = target;
	}

	public inline function clone():TExprLookup return new TExprLookup(bb, target);
}

@:structInit class VarInfo {
	public var viVar:TVar; // The variable itself
	public var viExtra:Null<TVarExtra>; // The original v_extra
	public var viBbDeclare:BasicBlockData; // The block where this variable was declared
	public var viOrigin:TVar; // The origin variable of this variable
	public var viWrites:Array<BasicBlockData>; // A list of blocks that assign to this variable
	public var viValue:Null<TExprLookup>; // The value of this variable, if known
	public var viSsaEdges:Array<TExprLookup>; // The expressions this variable influences
	public var viReachingDef:Null<TVar>; // The current reaching definition variable of this variable

	public inline function new(viVar:TVar, viExtra:Null<TVarExtra>, viBbDeclare:BasicBlockData, viOrigin:TVar,
			viWrites:Array<BasicBlockData>, viValue:Null<TExprLookup>, viSsaEdges:Array<TExprLookup>, viReachingDef:Null<TVar>) {
		this.viVar = viVar;
		this.viExtra = viExtra;
		this.viBbDeclare = viBbDeclare;
		this.viOrigin = viOrigin;
		this.viWrites = viWrites;
		this.viValue = viValue;
		this.viSsaEdges = viSsaEdges;
		this.viReachingDef = viReachingDef;
	}

	public inline function clone():VarInfo return new VarInfo(viVar, viExtra, viBbDeclare, viOrigin, viWrites, viValue, viSsaEdges,
		viReachingDef);
}

@:structInit class GraphData {
	public var gRoot:BasicBlockData; // The unique root block
	public var gExit:BasicBlockData; // The unique exit block
	public var gUnreachable:BasicBlockData; // The unique unreachable block
	public var gFunctions:haxe.ds.IntMap<TFuncInfo>; // A map of functions, indexed by their block IDs
	public var gNodes:Array<BasicBlockData>; // A list of all blocks
	public var gVarInfos:Array<VarInfo>; // A map of variable information
	public var gLoops:haxe.ds.IntMap<BasicBlockData>; // A map containing loop information

	public inline function new(gRoot:BasicBlockData, gExit:BasicBlockData, gUnreachable:BasicBlockData,
			gFunctions:haxe.ds.IntMap<TFuncInfo>, gNodes:Array<BasicBlockData>, gVarInfos:Array<VarInfo>,
			gLoops:haxe.ds.IntMap<BasicBlockData>) {
		this.gRoot = gRoot;
		this.gExit = gExit;
		this.gUnreachable = gUnreachable;
		this.gFunctions = gFunctions;
		this.gNodes = gNodes;
		this.gVarInfos = gVarInfos;
		this.gLoops = gLoops;
	}

	public inline function clone():GraphData return new GraphData(gRoot, gExit, gUnreachable, gFunctions, gNodes, gVarInfos, gLoops);
}

// inference

// port: a class rather than a structure: HashLink accesses structures through
// virtual tables (a conversion per IntMap lookup).
@:structInit private class DomBbInfo {
	public var bb:BasicBlockData;
	public var parent:DomBbInfo;
	public var idom:DomBbInfo;
	public var semi:Int;
	public var label:DomBbInfo;
	public var ancestor:DomBbInfo;
	public var bucket:Array<DomBbInfo>;

	public inline function new(bb:BasicBlockData, parent:DomBbInfo, idom:DomBbInfo, semi:Int, label:DomBbInfo, ancestor:DomBbInfo,
			bucket:Array<DomBbInfo>) {
		this.bb = bb;
		this.parent = parent;
		this.idom = idom;
		this.semi = semi;
		this.label = label;
		this.ancestor = ancestor;
		this.bucket = bucket;
	}

	public inline function clone():DomBbInfo return new DomBbInfo(bb, parent, idom, semi, label, ancestor, bucket);
}

class Graph {
	// variables

	public static function createVarInfo(g:GraphData, bb:BasicBlockData, v:TVar):VarInfo {
		var vi:VarInfo = {
			viVar: v,
			viExtra: v.vExtra,
			viBbDeclare: bb,
			viOrigin: v,
			viWrites: [],
			viValue: null,
			viSsaEdges: [],
			viReachingDef: null
		};
		g.gVarInfos.push(vi);
		var i = g.gVarInfos.length - 1;
		v.vExtra = varExtra([], mk(TConst(TInt(i)), tDynamic, Globals.nullPos));
		return vi;
	}

	public static function getVarInfo(g:GraphData, v:TVar):VarInfo return switch v.vExtra {
		case {vExpr: {eexpr: TConst(TInt(i))}}: g.gVarInfos[i];
		case _:
			Sys.println("Unbound variable, please report this");
			Sys.println(TPrinting.Printer.sTvar(v));
			createVarInfo(g, g.gUnreachable, v);
	};

	public static function declareVar(g:GraphData, v:TVar, bb:BasicBlockData):Void {
		createVarInfo(g, bb, v);
	}

	// port: `x :: l` as pushes: bbVarWrites and viWrites are read from the end where the order matters
	public static function addVarDef(g:GraphData, bb:BasicBlockData, v:TVar):Void if (bb.bbId > 0) {
		bb.bbVarWrites.push(v);
		getVarInfo(g, v).viWrites.push(bb);
	}

	public static function setVarValue(g:GraphData, v:TVar, bb:BasicBlockData,
			luk:TExprLookupTarget) getVarInfo(g, v).viValue = {bb: bb, target: luk};

	public static function getVarValue(g:GraphData, v:TVar):TExpr {
		var value = getVarInfo(g, v).viValue;
		if (value == null) throw NotFound.raise();
		return switch BasicBlock.getTexpr(value.bb, value.target).eexpr {
			case TVar(_, e) if (e != null): e;
			case TBinop(OpAssign, _, e): e;
			case _: throw "AnalyzerTypes.getVarValue";
		};
	}

	public static function addVarOrigin(g:GraphData, v:TVar, origin:TVar) getVarInfo(g, v).viOrigin = origin;

	public static function getVarOrigin(g:GraphData, v:TVar):TVar return getVarInfo(g, v).viOrigin;

	public static function addSsaEdge(g:GraphData, v:TVar, bb:BasicBlockData,
			luk:TExprLookupTarget) getVarInfo(g, v).viSsaEdges.unshift({bb: bb, target: luk});

	// nodes

	public static function addFunction(g:GraphData, tf:TFunc, t:T, p:Pos, bb:BasicBlockData) g.gFunctions.set(bb.bbId, {
		bb: bb,
		type: t,
		pos: p,
		tf: tf
	});

	static var nextId = 1;
	static final idMutex = new sys.thread.Mutex();

	public static function allocId():Int {
		idMutex.acquire();
		var id = ++nextId;
		idMutex.release();
		return id;
	}

	public static function createNode(g:GraphData, kind:BlockKind, t:T, p:Pos):BasicBlockData {
		var bb = BasicBlock.create(allocId(), kind, t, p);
		// port: `bb :: g.g_nodes` as a push: gNodes is in creation order, `nodes` gives upstream's
		g.gNodes.push(bb);
		return bb;
	}

	// port: g.g_nodes, the most recent block first (gNodes reversed)
	public static function nodes(g:GraphData):Array<BasicBlockData> {
		var l = g.gNodes.copy();
		l.reverse();
		return l;
	}

	public static function closeNode(bb:BasicBlockData):Void if (bb.bbId > 0) {
		if (bb.bbClosed) throw "assert: block already closed";
		bb.bbClosed = true;
	}

	public static function iterDomTreeFrom(g:GraphData, bb:BasicBlockData, f:BasicBlockData->Void):Void {
		f(bb);
		// port: bbDominated is in push order (inferImmediateDominators)
		var i = bb.bbDominated.length;
		while (i > 0) iterDomTreeFrom(g, bb.bbDominated[--i], f);
	}

	public static function iterDomTree(g:GraphData, f:BasicBlockData->Void):Void iterDomTreeFrom(g, g.gRoot, f);

	public static function iterEdgesFrom(g:GraphData, bb:BasicBlockData, f:CfgEdge->Void):Void iterDomTreeFrom(g, bb, function(bb) {
		for (edge in bb.bbOutgoing) f(edge);
	});

	public static function iterEdges(g:GraphData, f:CfgEdge->Void):Void iterEdgesFrom(g, g.gRoot, f);

	// graph

	public static function create(t:T, p:Pos):GraphData {
		var root = BasicBlock.create(1, BKRoot, t, p);
		var unreachable = BasicBlock.create(0, BKUnreachable, tDynamic, Globals.nullPos);
		return {
			gRoot: root,
			gExit: unreachable,
			gUnreachable: unreachable,
			gFunctions: new haxe.ds.IntMap(),
			gNodes: [root],
			gVarInfos: [],
			gLoops: new haxe.ds.IntMap()
		};
	}

	public static function checkIntegrity(g:GraphData):Void for (bb in nodes(g)) {
		for (edge in bb.bbOutgoing) if (edge.cfgTo == g.gUnreachable) Sys.println('Outgoing edge from ${bb.bbId} to the unreachable block');
		else if (!edge.cfgTo.bbIncoming.contains(edge))
			Sys.println('Outgoing edge ${edge.cfgFrom.bbId} -> ${edge.cfgTo.bbId} has no matching incoming edge');
		for (edge in bb.bbIncoming) if (edge.cfgFrom == g.gUnreachable)
			Sys.println('Incoming edge to ${bb.bbId} from the unreachable block');
		else if (!edge.cfgFrom.bbOutgoing.contains(edge))
			Sys.println('Incoming edge ${edge.cfgTo.bbId} <- ${edge.cfgFrom.bbId} has no matching outgoing edge');
	}

	// Infers the immediate dominators for all reachable blocks. This function can be run multiple times
	// in case an update is necessary.
	public static function inferImmediateDominators(g:GraphData):Void {
		var info = new haxe.ds.IntMap<DomBbInfo>();
		var nodes:Array<DomBbInfo> = [];
		inline function addInfo(bb:BasicBlockData, parent:BasicBlockData):Void {
			var bbi:DomBbInfo = {
				bb: bb,
				parent: null,
				idom: null,
				semi: nodes.length,
				label: null,
				ancestor: null,
				bucket: []
			};
			bbi.parent = bbi;
			bbi.idom = bbi;
			bbi.label = bbi;
			bbi.ancestor = bbi;
			// port: the OCaml record update keeps the original self-references for a non-root node.
			if (bb != parent) {
				var copy:DomBbInfo = core.ds.Record.copy(bbi);
				copy.parent = info.get(parent.bbId);
				bbi = copy;
			}
			info.set(bb.bbId, bbi);
			nodes.push(bbi);
		}
		function visit(parent:BasicBlockData, bb:BasicBlockData):Void {
			bb.bbDominated = [];
			addInfo(bb, parent);
			for (edge in bb.bbOutgoing) if (!info.exists(edge.cfgTo.bbId)) visit(bb, edge.cfgTo);
		}
		visit(g.gRoot, g.gRoot);
		function compress(bbi:DomBbInfo):Void {
			// port: `bbi :: l` as a push: the worklist is read from the end
			var worklist = [bbi];
			var ancestor = bbi.ancestor;
			while (ancestor.ancestor != ancestor) {
				worklist.push(ancestor);
				ancestor = ancestor.ancestor;
			}
			if (worklist.length == 0) throw "AnalyzerTypes.compress";
			var i = worklist.length - 1;
			var a = worklist[i];
			var minSemi = a.label.semi;
			while (i > 0) {
				var desc = worklist[--i];
				var label = desc.label;
				if (label.semi > minSemi) desc.label = a.label;
				else minSemi = label.semi;
				a = desc;
			}
		}
		inline function eval(id:Int):DomBbInfo {
			var bbi = info.get(id);
			if (bbi.ancestor != bbi) {
				compress(bbi);
				return bbi.label;
			}
			return bbi;
		}
		var i = nodes.length - 1;
		while (i > 0) {
			var w = nodes[i--];
			var semi = w.semi;
			for (edge in w.bb.bbIncoming) {
				var s = eval(edge.cfgFrom.bbId).semi;
				if (s < semi) semi = s;
			}
			w.semi = semi;
			// port: `w :: bbi.bucket` as a push: buckets are read from the end
			nodes[semi].bucket.push(w);
			var parent = w.parent;
			w.ancestor = parent;
			var bucket = parent.bucket;
			var j = bucket.length;
			while (j > 0) {
				var v = bucket[--j];
				var u = eval(v.bb.bbId);
				v.idom = u.semi < v.semi ? u : parent;
			}
			parent.bucket = [];
		}
		if (nodes.length == 0) throw "AnalyzerTypes.inferImmediateDominators";
		for (w in nodes.slice(1)) if (w.idom != nodes[w.semi]) w.idom = w.idom.idom;
		for (bbi in nodes) if (bbi.idom != bbi) {
			var bb = bbi.bb;
			var other = bbi.idom.bb;
			if (bb != other) {
				bb.bbDominator = other;
				// port: `bb :: bb'.bb_dominated` as a push: bbDominated is read from the end
				other.bbDominated.push(bb);
			}
		}
	}

	// Infers the dominance frontier for all reachable blocks. This function should only be run once.
	public static function inferDominanceFrontier(g:GraphData):Void iterEdges(g, function(edge) {
		var bb = edge.cfgFrom;
		while (bb != g.gUnreachable && bb != edge.cfgTo && bb != edge.cfgTo.bbDominator) {
			if (edge.cfgTo != g.gExit) bb.bbDf.unshift(edge.cfgTo);
			if (bb.bbDominator == bb) break;
			bb = bb.bbDominator;
		}
	});

	// Infers variable declarations and definitions. This function should only be run once.
	public static function inferVarWrites(g:GraphData):Void iterDomTree(g, function(bb) {
		switch bb.bbKind {
			case BKCatch(v):
				declareVar(g, v, bb);
				addVarDef(g, bb, v);
			case BKFunctionBegin(tf):
				for (arg in tf.tfArgs) {
					declareVar(g, arg.variable, bb);
					addVarDef(g, bb, arg.variable);
				}
			case _:
		}
		function infer(e:TExpr):Void switch e.eexpr {
			case TVar(v, eo):
				declareVar(g, v, bb);
				if (eo != null) addVarDef(g, bb, v);
			case TBinop(OpAssign, {eexpr: TLocal(v)}, _):
				addVarDef(g, bb, v);
			case _:
		}
		for (e in bb.bbEl) infer(e);
		BasicBlock.terminatorIter(infer, bb.bbTerminator);
	});

	// Infers the scopes of all reachable blocks. This function can be run multiple times
	// in case an update is necessary
	public static function inferScopes(g:GraphData):Void {
		var nextScopeId = 0;
		inline function nextScope(scopes:Array<Int>):Array<Int> return [++nextScopeId].concat(scopes);
		function loop(scopes:Array<Int>, bb:BasicBlockData):Void {
			bb.bbScopes = scopes;
			switch bb.bbSyntaxEdge {
				case SEIfThen(bt, bn, _):
					loop(nextScope(scopes), bt);
					loop(scopes, bn);
				case SEIfThenElse(bt, be, bn, _, _):
					loop(nextScope(scopes), bt);
					loop(nextScope(scopes), be);
					loop(scopes, bn);
				case SESwitch(ss):
					for (c in ss.ssCases) loop(nextScope(scopes), c.bb);
					if (ss.ssDefault != null) loop(nextScope(scopes), ss.ssDefault);
					loop(scopes, ss.ssNext);
				case SETry(bt, bx, catches, bn, _):
					var inner = nextScope(scopes);
					loop(inner, bt);
					loop(inner, bx);
					for (c in catches) loop(nextScope(scopes), c.bb);
					loop(scopes, bn);
				case SEWhile(body, next, _):
					loop(nextScope(scopes), body);
					loop(scopes, next);
				case SESubBlock(sub, next):
					loop(nextScope(scopes), sub);
					loop(scopes, next);
				case SEMerge(other):
					loop(scopes, other);
				case SENone:
			}
		}
		for (fn in g.gFunctions) loop([0], fn.bb);
	}
}

@:structInit class AnalyzerContext {
	public var com:context.SafeCom.SafeContext;
	public var config:AnalyzerConfigData;
	public var graph:GraphData;
	public var tempVarName:String;
	public var withTimer:Dynamic;
	public var identifier:String;
	public var entry:BasicBlockData;
	public var hasUnbound:Bool;
	public var loopCounter:Int;
	public var loopStack:Array<Int>;
	public var debugExprs:Array<{name:String, expr:TExpr}>;
	public var nameStack:Array<String>;
	public var didOptimize:Bool;

	public inline function new(com:context.SafeCom.SafeContext, config:AnalyzerConfigData, graph:GraphData, tempVarName:String,
			withTimer:Dynamic, identifier:String, entry:BasicBlockData, hasUnbound:Bool, loopCounter:Int, loopStack:Array<Int>,
			debugExprs:Array<{
			name:String,
			expr:TExpr
		}>, nameStack:Array<String>, didOptimize:Bool) {
		this.com = com;
		this.config = config;
		this.graph = graph;
		this.tempVarName = tempVarName;
		this.withTimer = withTimer;
		this.identifier = identifier;
		this.entry = entry;
		this.hasUnbound = hasUnbound;
		this.loopCounter = loopCounter;
		this.loopStack = loopStack;
		this.debugExprs = debugExprs;
		this.nameStack = nameStack;
		this.didOptimize = didOptimize;
		}

	public inline function clone():AnalyzerContext return new AnalyzerContext(com, config, graph, tempVarName, withTimer, identifier,
		entry, hasUnbound, loopCounter, loopStack, debugExprs, nameStack, didOptimize);
}

class AnalyzerTypes {}
