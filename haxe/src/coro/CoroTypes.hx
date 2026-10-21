package coro;

import core.TType;
import core.Globals.Pos;
import coro.CoroConfig;
import coro.CoroElsewhere.TexprBuilder;

enum CoroFor {
	LocalFunc(tf:TFunc, v:TVar);
	ClassField(c:TClass, cf:TClassField, tf:TFunc, p:Pos); // expr pos
}

enum SuspendExpr {
	SusBlock;
	SusResult;
}

@:structInit class CoroBlock {
	public var cbId:Int;
	public var cbEl:Array<TExpr>;
	public var cbTypepos:Null<{t:T, p:Pos}>;
	public var cbCatch:Null<CoroBlock>;
	public var cbNext:CoroNext;
	public var cbFlags:Int;
	public var cbStackValue:Null<TExpr>;

	public inline function new(cbId:Int, cbEl:Array<TExpr>, cbTypepos:Null<{t:T, p:Pos}>, cbCatch:Null<CoroBlock>, cbNext:CoroNext,
			cbFlags:Int, cbStackValue:Null<TExpr>) {
		this.cbId = cbId;
		this.cbEl = cbEl;
		this.cbTypepos = cbTypepos;
		this.cbCatch = cbCatch;
		this.cbNext = cbNext;
		this.cbFlags = cbFlags;
		this.cbStackValue = cbStackValue;
	}

	public inline function clone():CoroBlock return new CoroBlock(cbId, cbEl, cbTypepos, cbCatch, cbNext, cbFlags, cbStackValue);
}

typedef CoroBlockNext = Null<CoroBlock>;

enum CoroNext {
	NextUnknown;
	NextReturnVoid;
	NextReturn(e:TExpr);
	NextThrow(e:TExpr);
	NextIfThen(e:TExpr, thenBlock:CoroBlock, next:CoroBlock);
	NextIfThenElse(e:TExpr, thenBlock:CoroBlock, elseBlock:CoroBlock, next:CoroBlockNext);
	NextSwitch(s:CoroSwitch, next:CoroBlockNext);
	NextWhile(e:TExpr, body:CoroBlock, next:CoroBlockNext);
	NextTry(body:CoroBlock, catches:CoroCatch, next:CoroBlockNext);
	NextSuspend(s:CoroSuspend, next:CoroBlockNext); // None = tail call
	// graph connections from here on, careful with traversal
	NextBreak(next:CoroBlock);
	NextContinue(next:CoroBlock);
	NextFallThrough(next:CoroBlock);
	NextGoto(next:CoroBlock);
}

@:structInit class CoroSwitch {
	public var csSubject:TExpr;
	public var csCases:haxe.ds.Vector<{el:haxe.ds.Vector<TExpr>, cb:CoroBlock}>;
	public var csDefault:Null<CoroBlock>;
	public var csExhaustive:Bool;

	public inline function new(csSubject:TExpr, csCases:haxe.ds.Vector<{el:haxe.ds.Vector<TExpr>, cb:CoroBlock}>, csDefault:Null<CoroBlock>,
			csExhaustive:Bool) {
		this.csSubject = csSubject;
		this.csCases = csCases;
		this.csDefault = csDefault;
		this.csExhaustive = csExhaustive;
	}

	public inline function clone():CoroSwitch return new CoroSwitch(csSubject, csCases, csDefault, csExhaustive);
}

@:structInit class CoroCatch {
	public var ccCb:CoroBlock;
	public var ccCatches:haxe.ds.Vector<{v:TVar, cb:CoroBlock}>;

	public inline function new(ccCb:CoroBlock, ccCatches:haxe.ds.Vector<{v:TVar, cb:CoroBlock}>) {
		this.ccCb = ccCb;
		this.ccCatches = ccCatches;
	}

	public inline function clone():CoroCatch return new CoroCatch(ccCb, ccCatches);
}

@:structInit class CoroSuspend {
	public var csFun:TExpr;
	public var csArgs:haxe.ds.Vector<TExpr>;
	public var csPos:Pos;
	public var csResult:SuspendExpr;
	public var csKind:CoroOutcome;

	public inline function new(csFun:TExpr, csArgs:haxe.ds.Vector<TExpr>, csPos:Pos, csResult:SuspendExpr, csKind:CoroOutcome) {
		this.csFun = csFun;
		this.csArgs = csArgs;
		this.csPos = csPos;
		this.csResult = csResult;
		this.csKind = csKind;
	}

	public inline function clone():CoroSuspend return new CoroSuspend(csFun, csArgs, csPos, csResult, csKind);
}

@:structInit class CoroDeferredApi {
	public var makeInlineReturn:Null<TExpr>->Pos->TExpr;
	public var makeInlineTailCall:CoroSuspend->TExpr;
	public var makeSyncCall:CoroSuspend->Null<TExpr>->TExpr;
	public var makeThis:TExpr->TExpr;
	public var makeSuperField:TExpr->TExpr;

	public inline function new(makeInlineReturn:Null<TExpr>->Pos->TExpr, makeInlineTailCall:CoroSuspend->TExpr,
			makeSyncCall:CoroSuspend->Null<TExpr>->TExpr, makeThis:TExpr->TExpr, makeSuperField:TExpr->TExpr) {
		this.makeInlineReturn = makeInlineReturn;
		this.makeInlineTailCall = makeInlineTailCall;
		this.makeSyncCall = makeSyncCall;
		this.makeThis = makeThis;
		this.makeSuperField = makeSuperField;
	}

	public inline function clone():CoroDeferredApi return new CoroDeferredApi(makeInlineReturn, makeInlineTailCall, makeSyncCall,
		makeThis, makeSuperField);
}

@:structInit class CoroCtx {
	public var builder:TexprBuilder;
	public var typer:context.Typecore.Typer;
	public var config:CoroConfigData;
	public var coroType:CoroFor;
	public var classNamePos:Pos;
	public var deferredExprs:Map<Int, Void->TExpr>;
	public var hasCaptureVars:Bool;
	public var capturesThis:Bool;
	public var nextBlockId:Int;
	public var currentCatch:Null<CoroBlock>;
	public var hasCatch:Bool;
	public var numStates:Int;

	public inline function new(builder:TexprBuilder, typer:context.Typecore.Typer, config:CoroConfigData, coroType:CoroFor,
			classNamePos:Pos, deferredExprs:Map<Int, Void->TExpr>, hasCaptureVars:Bool, capturesThis:Bool, nextBlockId:Int,
			currentCatch:Null<CoroBlock>, hasCatch:Bool, numStates:Int) {
		this.builder = builder;
		this.typer = typer;
		this.config = config;
		this.coroType = coroType;
		this.classNamePos = classNamePos;
		this.deferredExprs = deferredExprs;
		this.hasCaptureVars = hasCaptureVars;
		this.capturesThis = capturesThis;
		this.nextBlockId = nextBlockId;
		this.currentCatch = currentCatch;
		this.hasCatch = hasCatch;
		this.numStates = numStates;
	}

	public inline function clone():CoroCtx return new CoroCtx(builder, typer, config, coroType, classNamePos, deferredExprs,
		hasCaptureVars, capturesThis, nextBlockId, currentCatch, hasCatch, numStates);
}

enum abstract CbFlag(Int) to Int {
	var CbGenerated = 0;
	var CbSuspendState = 1;
	var CbResumeState = 2;
}

@:structInit class CoroScope {
	public var scopeVar:TVar;
	public var restrictedSuspension:Bool;

	public inline function new(scopeVar:TVar, restrictedSuspension:Bool) {
		this.scopeVar = scopeVar;
		this.restrictedSuspension = restrictedSuspension;
	}

	public inline function clone():CoroScope return new CoroScope(scopeVar, restrictedSuspension);
}

enum CoroGenMode {
	GenThunk(cf:TClassField);
	GenInline(field:Null<{e:TExpr, cf:TClassField}>);
}
