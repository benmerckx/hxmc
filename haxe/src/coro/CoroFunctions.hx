package coro;

import core.TType;
import core.TFunctions.*;
import coro.CoroTypes;
import coro.CoroElsewhere.TexprBuilder;

using core.ds.VectorTools;

enum abstract CoroControl(Int) to Int {
	var CoroPending = 0;
	var CoroReturned = 1;
	var CoroThrown = 2;
}

class CoroFunctions {
	public static function makeCustomControlSwitch(b:TexprBuilder, eSubject:TExpr, cases:Array<{controls:Array<CoroControl>, e:TExpr}>,
			p:core.Globals.Pos):TExpr {
		var cases = cases.mapToVector(function(c) return ({
			casePatterns: c.controls.mapToVector(function(k) return b.int(k, p)),
			caseExpr: c.e
		} : core.TType.TSwitchCase));
		return mk(TSwitch({
			switchSubject: eSubject,
			switchCases: cases,
			switchDefault: null,
			switchExhaustive: true
		}), b.tvoid, p);
	}

	public static function makeControlSwitch(b:TexprBuilder, eSubject:TExpr, ePending:TExpr, eReturned:TExpr, eThrown:TExpr,
			p:core.Globals.Pos):TExpr return makeCustomControlSwitch(b, eSubject, [
			{
				controls: [CoroPending],
				e: ePending
			},
			{controls: [CoroReturned], e: eReturned},
			{controls: [CoroThrown], e: eThrown}
		], p);

	public static function makeBlock(ctx:CoroCtx, typepos:Null<{t:T, p:core.Globals.Pos}>):CoroBlock {
		var id = ctx.nextBlockId++;
		return {
			cbId: id,
			cbEl: [],
			cbTypepos: typepos,
			cbNext: NextUnknown,
			cbCatch: ctx.currentCatch,
			cbFlags: 0,
			cbStackValue: null
		};
	}

	public static function addBlockFlag(cb:CoroBlock, flag:CbFlag):Void cb.cbFlags |= 1 << (cast flag : Int);

	public static function hasBlockFlag(cb:CoroBlock, flag:CbFlag):Bool return cb.cbFlags & (1 << (cast flag : Int)) != 0;

	public static function getBlockExprs(cb:CoroBlock):Array<TExpr> {
		var acc = [];
		var i = cb.cbEl.length;
		while (i-- > 0) switch cb.cbEl[i].eexpr {
			case TBlock(el):
				acc = el.toArray().concat(acc);
			case _:
				acc.unshift(cb.cbEl[i]);
		}
		return acc;
	}

	public static function coroIter(f:CoroBlock->Void, cb:CoroBlock):Void {
		inline function fo(c:Null<CoroBlock>):Void if (c != null) f(c);
		fo(cb.cbCatch);
		switch cb.cbNext {
			case NextIfThen(_, a, n):
				f(a);
				f(n);
			case NextIfThenElse(_, a, b, n):
				f(a);
				f(b);
				fo(n);
			case NextSwitch(s, n):
				for (c in s.csCases) f(c.cb);
				fo(s.csDefault);
				fo(n);
			case NextWhile(_, b, n):
				f(b);
				fo(n);
			case NextTry(b, c, n):
				f(b);
				f(c.ccCb);
				for (c in c.ccCatches) f(c.cb);
				fo(n);
			case NextSuspend(_, n):
				fo(n);
			case NextBreak(n) | NextContinue(n) | NextFallThrough(n) | NextGoto(n):
				f(n);
			case NextUnknown | NextReturnVoid | NextReturn(_) | NextThrow(_):
		}
	}

	/** Walk all blocks reachable from [cb], calling [f] exactly once per block.
		Uses a local visited table to handle back-edges (NextBreak/Continue/etc.)
		safely without cycles.  The number of times [f] is called equals the number
		of states the coroutine will produce. **/
	public static function coroWalk(f:CoroBlock->Void, cb:CoroBlock):Void {
		var visited:Map<Int, Bool> = [];
		function loop(cb:CoroBlock):Void if (!visited.exists(cb.cbId)) {
			visited.set(cb.cbId, true);
			f(cb);
			coroIter(loop, cb);
		}
		loop(cb);
	}

	public static function coroNextMap(f:CoroBlock->CoroBlock, cb:CoroBlock):Void {
		inline function fo(c:Null<CoroBlock>):Null<CoroBlock> return c == null ? null : f(c);
		cb.cbCatch = fo(cb.cbCatch);
		cb.cbNext = switch cb.cbNext {
			case NextIfThen(e, a, n):
				var a = f(a);
				var n = f(n);
				NextIfThen(e, a, n);
			case NextIfThenElse(e, a, b, n):
				var a = f(a);
				var b = f(b);
				var n = fo(n);
				NextIfThenElse(e, a, b, n);
			case NextSwitch(s, n):
				var cases = s.csCases.map(function(c) return {el: c.el, cb: f(c.cb)});
				var def = fo(s.csDefault);
				var s = ({
					csSubject: s.csSubject,
					csCases: cases,
					csDefault: def,
					csExhaustive: s.csExhaustive
				} : coro.CoroTypes.CoroSwitch);
				var n = fo(n);
				NextSwitch(s, n);
			case NextWhile(e, b, n):
				var b = f(b);
				var n = fo(n);
				NextWhile(e, b, n);
			case NextTry(b, c, n):
				var b = f(b);
				var cc = f(c.ccCb);
				var catches = c.ccCatches.map(function(c) return {v: c.v, cb: f(c.cb)});
				var n = fo(n);
				NextTry(b, {ccCb: cc, ccCatches: catches}, n);
			case NextSuspend(s, n): NextSuspend(s, fo(n));
			case NextBreak(n): NextBreak(f(n));
			case NextContinue(n): NextContinue(f(n));
			case NextGoto(n): NextGoto(f(n));
			case NextFallThrough(n): NextFallThrough(f(n));
			case n: n;
		};
	}
}
