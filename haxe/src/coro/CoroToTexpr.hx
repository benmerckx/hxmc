package coro;

import core.Texpr;
import core.Texpr.Builder;
import core.TOther;
import core.ds.AtomicLazy;
import core.ds.PMap;
import context.Common;
import core.TType;
import core.TFunctions.*;
import core.TOther.*;
import core.Ast;
import core.Globals;
import core.Globals.*;
import coro.CoroTypes;
import coro.CoroFunctions;
import coro.CoroFunctions.*;
import coro.ContTypes;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: IntSet iteration is descending, matching the upstream comparator b - a.
class CoroIntSet {
	var ids:Map<Int, Bool> = [];

	public function new() {}

	public function add(id:Int):CoroIntSet {
		ids.set(id, true);
		return this;
	}

	public function has(id:Int):Bool return ids.exists(id);

	public function elements():Array<Int> {
		var a = [for (id in ids.keys()) id];
		a.sort(function(a, b) return b - a);
		return a;
	}

	public function union(b:CoroIntSet):CoroIntSet {
		var c = new CoroIntSet();
		for (id in ids.keys()) c.add(id);
		for (id in b.ids.keys()) c.add(id);
		return c;
	}
}

typedef CoroState = {
	var csId:Int;
	var csElTail:Null<Array<TExpr>>;
	var csEl:Array<TExpr>;
	var csDeclarations:Array<TVar>;
	var csMappedLocal:Map<Int, TVar>;
	var csReads:CoroIntSet;
	var csWrites:CoroIntSet;
}

typedef CoroToTexprExprs = {var econtinuation:TExpr; var ecompletion:TExpr; var estate:TExpr; var eresult:TExpr; var egoto:TExpr; var eerror:TExpr; var etmpResult:AtomicLazy<TExpr>; var etmpError:TExpr; var etmpErrorUnwrapped:AtomicLazy<TExpr>;}

class SuspensionCalls {
	public static function makeSuspensionCallAndAssign(ctx:CoroCtx, cont:ContinuationApi, call:CoroSuspend,
			econtinuation:TExpr):{call:TExpr, result:TExpr} {
		var b = ctx.builder;
		var p = call.csPos;
		var create = CoroToTexpr.makeSuspendingCall(ctx.typer.com.basic, cont, call,
			{var recordCopy47 = core.ds.Record.copy(econtinuation); recordCopy47.epos = p; recordCopy47;});
		var v = allocVar(VGenerated, "_hx_tmp", cont.suspensionResult(ctx.typer.com.basic.tany), p);
		return {call: b.varInit(v, create), result: b.local(v, p)};
	}

	// Returns (esubject, eres, eerror) field accesses on ecororesult
	public static function unpackResultFields(ctx:CoroCtx, cont:ContinuationApi, result:TExpr):{subject:TExpr, result:TExpr, error:TExpr} {
		inline function base(cf:TClassField,
				t:T):TExpr return ctx.builder.instanceField(result, cont.suspensionResultClass, vector(ctx.typer.com.basic.tany), cf, t);
		return {
			subject: base(cont.state, cont.state.cfType),
			result: base(cont.result, ctx.typer.com.basic.tany),
			error: base(cont.error, cont.error.cfType)
		};
	}

	public static function makeSuspendedReturn(b:coro.CoroElsewhere.TexprBuilder, cont:ContinuationApi,
			p:Pos):TExpr return b.staticField(Builder.makeStaticThis(cont.suspensionResultClass, p), cont.suspensionResultClass,
			cont.suspended, cont.suspended.cfType);

	public static function makeSuspendingCall(ctx:CoroCtx, cont:ContinuationApi, exprs:CoroToTexprExprs,
			call:CoroSuspend):{call:TExpr, check:TExpr} {
		var b = ctx.builder;
		var p = call.csPos;
		var outcome = call.csKind;
		// Always-suspending: call + return suspended singleton
		if (outcome.noReturn && outcome.noThrow) return {
			call: b.voidBlock(vector(
				CoroToTexpr.makeSuspendingCall(ctx.typer.com.basic, cont, call,
					{var recordCopy46 = core.ds.Record.copy(exprs.econtinuation); recordCopy46.epos = p; recordCopy46;})
			)),
			check: b.voidBlock(vector(b.makeReturn(makeSuspendedReturn(b, cont, p))))
		};
		// Generic version: call + switch
		var assigned = makeSuspensionCallAndAssign(ctx, cont, call, exprs.econtinuation);
		var fields = unpackResultFields(ctx, cont, assigned.result);
		var suspended = b.voidBlock(vector(b.makeReturn(makeSuspendedReturn(b, cont, p))));
		var returned = switch call.csResult {
			case SusBlock: b.voidBlockAt(vector(), p);
			case SusResult: b.assign((exprs.etmpResult).force(), fields.result);
		};
		var thrown = b.voidBlock(vector(b.assign(exprs.etmpError, fields.error), b.makeBreak(p)));
		// Callee can't throw: skip the Thrown case entirely.
		var check = outcome.noThrow ? makeCustomControlSwitch(b, fields.subject,
			[{controls: [CoroPending], e: suspended}, {controls: [CoroReturned], e: returned}],
			p) : makeControlSwitch(b, fields.subject, suspended, returned, thrown, p);
		return {call: assigned.call, check: check};
	}

	public static function makeSuspendingTailCall(ctx:CoroCtx, cont:ContinuationApi, exprs:CoroToTexprExprs,
			call:CoroSuspend):{call:TExpr, check:TExpr} {
		var b = ctx.builder;
		var completion = b.instanceField(exprs.econtinuation, cont.baseContinuationClass, vector(ctx.typer.com.basic.tany), cont.completion,
			exprs.ecompletion.etype);
		var assigned = makeSuspensionCallAndAssign(ctx, cont, call, completion);
		return {call: assigned.call, check: b.makeReturn(assigned.result)};
	}

	// Generate an inline call+result check for a no_suspend callee.
	// Returns (call_stmt, check_stmt) — assembled into a void_block by the caller.
	// For single-state coroutines there is no enclosing while loop, so the Thrown
	// branch emits the full error-handler inline instead of using `break`.
	// If the callee also has no_throw, the result is set directly without any switch.
	public static function makeSyncCallAndCheck(ctx:CoroCtx, cont:ContinuationApi, exprs:CoroToTexprExprs, call:CoroSuspend,
			e:Null<TExpr>):{
		call:TExpr,
		check:TExpr
	} {
		var b = ctx.builder;
		var p = call.csPos;
		var assigned = makeSuspensionCallAndAssign(ctx, cont, call, exprs.econtinuation);
		var fields = unpackResultFields(ctx, cont, assigned.result);
		var returned = e == null ? b.voidBlockAt(vector(), p) : b.assign(e, fields.result);
		// Callee can't throw, and we know it can't suspend (no_suspend = true),
		// so the result is always Returned. No switch needed.
		if (call.csKind.noThrow) return {call: assigned.call, check: returned};
		// Single-state: no while loop to break out of.
		// Emit the error handler directly (equivalent to eexchandle).
		var thrown = ctx.numStates == 1 ? b.voidBlock(vector(
			b.assign(exprs.etmpError, fields.error),
			b.assign(exprs.eerror, exprs.etmpError),
			CoroToTexpr.buildCallStack(ctx, cont, exprs.econtinuation, p),
			b.assign(exprs.estate, b.int(CoroThrown, p)),
			b.makeReturn(exprs.econtinuation)
		)) : b.voidBlock(vector(b.assign(exprs.etmpError, fields.error), b.makeBreak(p)));
		return {
			call: assigned.call,
			check: makeCustomControlSwitch(b, fields.subject,
				[{controls: [CoroReturned], e: returned}, {controls: [CoroThrown], e: thrown}], p)
		};
	}
}

class CoroToTexpr {
	public static function makeSuspendingCall(basic:BasicTypes, cont:ContinuationApi, call:CoroSuspend, econtinuation:TExpr):TExpr {
		// lose Coroutine<T> type for the called function not to confuse further filters and generators
		var tfun = switch followWithCoro(call.csFun.etype) {
			case Coro({args: args, ret: ret}):
				var expanded = Common.expandCoroType(basic, args, ret);
				TFun({args: expanded.args, ret: expanded.ret});
			case NotCoro(_): throw "Unexpected coroutine type";
		};
		return mk(TCall({var recordCopy45 = core.ds.Record.copy(call.csFun); recordCopy45.etype = tfun; recordCopy45;},
			VectorTools.cons(econtinuation, call.csArgs)),
			cont.suspensionResult(basic.tany), call.csPos);
	}

	public static function handleLocals(ctx:CoroCtx, cls:TClass, params:core.TType.TParams, states:Array<CoroState>,
			tfArgs:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>, econtinuation:TExpr):Array<TClassField> {
		var b = ctx.builder;
		var first = states[0];
		var argStates = new CoroIntSet().add(first.csId);
		// Keep an extra table of all vars and what states they appear in, easier check if a var is used across states this way.
		var usages:Map<Int, CoroIntSet> = [];
		for (a in tfArgs) usages.set(a.variable.vId, argStates);
		for (state in states) {
			function loop(e:TExpr):Void switch e.eexpr {
				case TVar(v, eo):
					state.csDeclarations.unshift(v);
					usages.set(v.vId, new CoroIntSet().add(state.csId));
					if (eo != null) loop(eo);
				case TLocal(v) if (usages.exists(v.vId)):
					usages.get(v.vId).add(state.csId);
				case _:
					core.Texpr.iter(loop, e);
			};
			for (e in state.csEl) loop(e);
			if (state.csElTail != null) for (e in state.csElTail) loop(e);
		}
		/*
		 * Each variable which is used across multiple states is given a field in the continuation class to store it's value
		 * during suspension.
		 * TODO : Instead of giving each variable a field have a set of "slots" which can be used by a field if no other variable is currently using it.
		 */
		// port: `Hashtbl.create 0`: the result lists the fields in OCaml's bucket order (Hashtbl.to_seq_values)
		var fields = new core.ds.OcamlHashtbl<Int, TClassField>(core.ds.OcamlHashtbl.hashInt, function(a, b) return a == b);
		inline function setField(id:Int, field:TClassField):Void fields.replace(id, field);
		inline function across(id:Int):Bool {
			var set = usages.get(id);
			return set != null && set.elements().length != 1;
		}
		var forced:Map<Int, Bool> = [];
		for (a in tfArgs) {
			var v:TVar = a.variable;
			setField(v.vId, mkField('_hx_hoisted${v.vId}', v.vType, v.vPos, v.vPos));
			// Create a fresh restored var rather than reusing the original argument variable.
			// This prevents the same v_id appearing as both an outer function parameter and
			// a TVar declaration inside the state machine body (which confuses renameVars).
			first.csMappedLocal.set(v.vId, allocVar(VGenerated, '_hx_restored${v.vId}', v.vType, v.vPos));
			forced.set(v.vId, true);
		}
		for (state in states) {
			inline function localMapping(v:TVar):TVar {
				var n = state.csMappedLocal.get(v.vId);
				if (n == null) {
					n = allocVar(VGenerated, '_hx_restored${v.vId}', v.vType, v.vPos);
					state.csMappedLocal.set(v.vId, n);
				}
				return n;
			}
			function mapper(e:TExpr):TExpr return switch e.eexpr {
				case TVar(v, eo) if (across(v.vId)):
					if (eo != null) state.csWrites.add(v.vId);
					setField(v.vId, mkField('_hx_hoisted${v.vId}', v.vType, v.vPos, v.vPos));
					state.csMappedLocal.set(v.vId, v);
					{
						var recordCopy44 = core.ds.Record.copy(e);
						recordCopy44.eexpr = TVar(v, eo == null ? null : mapper(eo));
						recordCopy44;
					};
				case TBinop(op = (OpAssign | OpAssignOp(_)), lhs, rhs): switch Texpr.skip(lhs).eexpr {
						case TLocal(v) if (across(v.vId) || forced.exists(v.vId)):
							state.csWrites.add(v.vId);
							var lhs = {
								var recordCopy43 = core.ds.Record.copy(lhs);
								recordCopy43.eexpr = TLocal(localMapping(v));
								recordCopy43;
							};
							var rhs = mapper(rhs);
							{var recordCopy42 = core.ds.Record.copy(e); recordCopy42.eexpr = TBinop(op, lhs, rhs); recordCopy42;};
						case _: core.Texpr.mapExpr(mapper, e);
					}
				case TUnop(mode = (Increment | Decrement), flag, rhs): switch Texpr.skip(rhs).eexpr {
						case TLocal(v) if (across(v.vId) || forced.exists(v.vId)):
							state.csWrites.add(v.vId);
							{
								var recordCopy41 = core.ds.Record.copy(e);
								recordCopy41.eexpr = TUnop(mode, flag,
									{var recordCopy40 = core.ds.Record.copy(rhs); recordCopy40.eexpr = TLocal(localMapping(v)); recordCopy40;});
								recordCopy41;
							};
						case _: core.Texpr.mapExpr(mapper, e);
					}
				case TLocal(v) if (across(v.vId) || forced.exists(v.vId)):
					// Each state generates new local variables for variables which are used across states.
					// Here we generate and store those new variables and remap local access to them
					state.csReads.add(v.vId);
					{var recordCopy39 = core.ds.Record.copy(e); recordCopy39.eexpr = TLocal(localMapping(v)); recordCopy39;};
				case TCall({eexpr: TLocal(v)}, []) if (ctx.deferredExprs.exists(v.vId)): mapper(ctx.deferredExprs.get(v.vId)());
				case _: core.Texpr.mapExpr(mapper, e);
			};
			state.csEl = state.csEl.map(mapper);
			if (state.csElTail != null) state.csElTail = state.csElTail.map(mapper);
		}
		// Remove hoisted fields for variables that are never saved or restored:
		// - Force-hoisted function args that are never actually read in the state machine
		//   (e.g., a discarded `_` or an unused `node` parameter).
		// - Any cross-state field that ended up with no actual reads or writes.
		// Removing these avoids passing dead constructor parameters and emitting
		// prototype fields that are never accessed.
		var used = new CoroIntSet();
		for (s in states) used = used.union(s.csWrites.union(s.csReads));
		var unused = [];
		fields.iter(function(id, _) if (!used.has(id)) unused.push(id));
		for (id in unused) fields.remove(id);
		for (state in states) {
			var restoring = [];
			// We don't want to restore a variable which is declared in this state
			// Doing so would mean if the var is an argument the arguments value would be overwritten by whatever is in the hoisted field
			for (id in state.csWrites.union(state.csReads)
				.elements()) if (!core.ds.ArrayTools.exists(state.csDeclarations, function(v) return v.vId == id)) {
					var v = state.csMappedLocal.get(id);
					var field = fields.find(id);
					restoring.push(b.varInit(v, b.instanceField(econtinuation, cls, params, field, field.cfType)));
				}
			var saving = [
				for (id in state.csWrites.elements()) {
					var v = state.csMappedLocal.get(id);
					var field = fields.find(id);
					b.assign(b.instanceField(econtinuation, cls, params, field, field.cfType), b.local(v, v.vPos));
				}
			];
			state.csEl = restoring.concat(state.csEl).concat(saving).concat(state.csElTail == null ? [] : state.csElTail);
		}
		var out = [];
		fields.iter(function(_, f) out.push(f));
		return out;
	}

	public static function buildCallStack(ctx:CoroCtx, cont:ContinuationApi, econtinuation:TExpr, p:Pos):TExpr {
		var b = ctx.builder;
		if (!ctx.typer.com.debug) return b.voidBlockAt(vector(), p);
		var cf = PMap.find("buildCallStack", cont.baseContinuationClass.clFields);
		return mk(TCall(b.instanceField(econtinuation, cont.baseContinuationClass, vector(ctx.typer.t.tany), cf, cf.cfType), vector()),
			ctx.typer.t.tvoid, p);
	}

	public static function blockToTexprCoroutine(ctx:CoroCtx, root:CoroBlock, cont:ContinuationApi, cls:TClass, params:core.TType.TParams,
			tfArgs:haxe.ds.Vector<{
			variable:TVar,
			defaultValue:Null<TExpr>
		}>, exprs:CoroToTexprExprs, p:Pos,
			stackItemInserter:Pos->TExpr, startException:TExpr->TExpr):{
		expr:TExpr,
		initialState:Int,
		fields:Array<TClassField>,
		numStates:Int
	} {
		var com = ctx.typer.com;
		var b = ctx.builder;
		// In a single-state coroutine there is no while/switch dispatch loop, so
		// gotoLabel is never read.
		var single = ctx.numStates == 1;
		inline function setState(id:Int):TExpr return b.assign(exprs.egoto, b.int(id, p));
		inline function setControl(c:CoroControl):TExpr return b.assign(exprs.estate, b.int(c, p));
		inline function stdIs(e:TExpr,
				t:T):TExpr return Builder.resolveAndMakeStaticCall(com.std, "isOfType",
				vector(e, mk(TTypeExpr(moduleTypeOfType(t)), tDynamic, p)),
				p);
		var ereturn = b.makeReturn(exprs.econtinuation);
		var states:Array<CoroState> = [];
		var initialState = root.cbId;
		inline function makeState(id:Int, el:Array<TExpr>, tail:Null<Array<TExpr>>):CoroState return {
			csId: id,
			csEl: el,
			csElTail: tail,
			csDeclarations: [],
			csMappedLocal: [],
			csReads: new CoroIntSet(),
			csWrites: new CoroIntSet()
		};
		var getCaught:TExpr->TExpr;
		var unwrap:TExpr->TExpr;
		switch (com.basic.texception : T) {
			case TInst(c, _):
				var cf = PMap.find("unwrap", c.clFields);
				unwrap = function(e) return b.call(b.instanceField(e, c, vector(), cf, cf.cfType), vector(), com.basic.tany);
				getCaught = function(e) return Builder.resolveAndMakeStaticCall(c, "caught", vector(e), e.epos);
			case _:
				throw "assert";
		}
		inline function ifError(cb:CoroBlock):TExpr {
			var thenE = b.voidBlock(vector(b.assign(exprs.etmpError, exprs.eerror), b.makeBreak(p)));
			var cond = b.binop(OpNotEq, exprs.eerror, b.makeNull(exprs.eerror.etype, p), com.basic.tbool);
			if (cb.cbStackValue == null) return b.ifThen(cond, thenE);
			var e = cb.cbStackValue;
			return b.ifThenElse(cond, thenE,
				b.assign(e,
					{var recordCopy38 = core.ds.Record.copy((exprs.etmpResult).force()); recordCopy38.epos = e.epos; recordCopy38;}),
				com.basic.tvoid);
		}
		var excStateMap = new Vector<Array<Int>>(ctx.nextBlockId);
		for (i in 0...excStateMap.length) excStateMap[i] = [];
		inline function generate(cb:CoroBlock):Int {
			var el = getBlockExprs(cb);
			inline function addState(next:Null<Int>, extra:Array<TExpr>, tail:Null<Array<TExpr>>):Int {
				var el = el.copy();
				if (!single && next != null) el.push(setState(next));
				if (hasBlockFlag(cb, CbResumeState)) el.unshift(ifError(cb));
				el = el.concat(extra);
				states.unshift(makeState(cb.cbId, el, tail));
				if (cb.cbCatch != null) excStateMap[cb.cbCatch.cbId].unshift(cb.cbId);
				return cb.cbId;
			}
			return switch cb.cbNext {
				case NextSuspend(call, null):
					var r = SuspensionCalls.makeSuspendingTailCall(ctx, cont, exprs, call);
					addState(null, [stackItemInserter(call.csPos)], [r.call, r.check]);
				case NextSuspend(call, n):
					var r = SuspensionCalls.makeSuspendingCall(ctx, cont, exprs, call);
					addState(n.cbId, [stackItemInserter(call.csPos)], [r.call, r.check]);
				case NextUnknown: addState(-1, [setControl(CoroReturned), ereturn], null);
				case NextFallThrough(n) | NextGoto(n) | NextBreak(n) | NextContinue(n): addState(n.cbId, [], null);
				case NextReturnVoid: addState(-1, [setControl(CoroReturned), ereturn], null);
				case NextReturn(e): addState(-1, [setControl(CoroReturned), b.assign(exprs.eresult, e), ereturn], null);
				case NextThrow(e1):
					// In multi-state mode the break exits the while/switch loop to reach the
					// outer error handler.  In single-state mode there is no loop, so no break
					// is needed — the error handler follows the body naturally.
					var tmp = {
						var recordCopy37 = core.ds.Record.copy(exprs.etmpError);
						recordCopy37.epos = e1.epos;
						recordCopy37;
					};
					addState(null, [
						b.assign(tmp, getCaught(e1)),
						stackItemInserter(e1.epos),
						b.assign(tmp, startException(tmp))
					], single ? null : [b.makeBreak(p)]);
				case NextIfThen(cond, a, n): addState(null, [b.ifThenElse(cond, setState(a.cbId), setState(n.cbId), com.basic.tint)], null);
				case NextIfThenElse(cond, a, z,
					_): addState(null, [b.ifThenElse(cond, setState(a.cbId), setState(z.cbId), com.basic.tint)], null);
				case NextSwitch(s, n):
					var cases = s.csCases.map(function(c) return ({
						casePatterns: c.el,
						caseExpr: setState(c.cb.cbId)
					} : core.TType.TSwitchCase));
					var def = s.csDefault != null ? setState(s.csDefault.cbId) : n == null ? null : setState(n.cbId);
					addState(null, [mk(TSwitch(Texpr.mkSwitch(s.csSubject, cases, def, true)), com.basic.tvoid, p)], null);
				case NextWhile(_, body, _): addState(body.cbId, [], null);
				case NextTry(body, c, _):
					var rethrow = c.ccCb.cbCatch != null ? setState(c.ccCb.cbCatch.cbId) : b.voidBlock(vector(b.makeBreak(p)));
					var cond = rethrow;
					var catches = c.ccCatches.copy();
					catches.reverse();
					for (ca in catches) cond = switch follow(ca.v.vType) {
						case TDynamic(_): setState(ca.cb.cbId); // no next
						case _: b.ifThenElse(stdIs((exprs.etmpErrorUnwrapped).force(), ca.v.vType), setState(ca.cb.cbId), cond,
								com.basic.tvoid);
					};
					var el = (exprs.etmpErrorUnwrapped).isVal() ? [b.assign((exprs.etmpErrorUnwrapped).force(),
						unwrap(exprs.etmpError)), cond] : [cond];
					states.unshift(makeState(c.ccCb.cbId, el, null));
					addState(body.cbId, [], null);
			};
		}
		function loop(cb:CoroBlock):Void if (!hasBlockFlag(cb, CbGenerated)) {
			addBlockFlag(cb, CbGenerated);
			generate(cb);
			coroIter(loop, cb);
		}
		loop(root);
		states.sort(function(a, b) return a.csId - b.csId);
		var fields = handleLocals(ctx, cls, params, states, tfArgs, exprs.econtinuation);
		var eloop:TExpr;
		if (states.length == 1) eloop = b.voidBlockAt(Vector.fromArrayCopy(states[0].csEl), Texpr.punionEl(p, states[0].csEl));
		else {
			var thrown = b.voidBlock(vector(
				b.assign(exprs.etmpError, getCaught(b.string("Invalid coroutine state", p))),
				b.makeBreak(p)
			));
			var cases = states.mapToVector(function(s) return ({
				casePatterns: vector(b.int(s.csId, p)),
				caseExpr: b.voidBlockAt(Vector.fromArrayCopy(s.csEl), Texpr.punionEl(p, s.csEl))
			} : core.TType.TSwitchCase));
			var eswitch = mk(TSwitch(Texpr.mkSwitch(exprs.egoto, cases, thrown, true)), com.basic.tvoid, p);
			eloop = mk(TWhile(b.bool(true, p), eswitch, NormalWhile), com.basic.tvoid, p);
		}
		var etry = eloop;
		if (!ctx.config.outcome.noThrow) {
			var v = allocVar(VGenerated, "e", tDynamic, p);
			var caught = getCaught(b.local(v, p));
			etry = mk(TTry(eloop, vector(
				{variable: v, expr: b.voidBlock(vector(b.assign(exprs.etmpError, startException(caught))))}
			)), com.basic.tvoid, p);
		}
		var cases = [];
		for (i in 0...excStateMap.length) if (excStateMap[i].length > 0) cases.push(({
			casePatterns: excStateMap[i].mapToVector(function(i) return b.int(i, p)),
			caseExpr: b.voidBlock(vector(setState(i)))
		} : core.TType.TSwitchCase));
		var def = b.voidBlock(vector(
			b.assign(exprs.eerror, exprs.etmpError),
			buildCallStack(ctx, cont, exprs.econtinuation, p),
			setControl(CoroThrown),
			ereturn
		));
		var handler = cases.length == 0 ? def : mk(TSwitch({
			switchSubject: exprs.egoto,
			switchCases: Vector.fromArrayCopy(cases),
			switchDefault: def,
			switchExhaustive: true
		}), com.basic.tvoid, p);
		etry = b.voidBlock(vector(etry, handler));
		// If there is no catch we don't need to pseudo-goto back into the state loop, so we don't need a control loop.
		eloop = ctx.hasCatch ? mk(TWhile(b.bool(true, p), etry, NormalWhile), com.basic.tvoid, p) : etry;
		return {
			expr: eloop,
			initialState: initialState,
			fields: fields,
			numStates: states.length
		};
	}
}
