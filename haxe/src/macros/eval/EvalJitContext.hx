package macros.eval;

import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.ds.NotFound;
import core.ds.OcamlHashtbl;
import macros.eval.EvalContext;

// port: deviations:
// - The scope stack is an array whose top is its last element (upstream: list
//   head). `IntHashtbl.length scope.locals` counts every `add`, including
//   repeated keys; `Scope.locals` is a `Map`, so the add count of each scope is
//   kept in the parallel array `scopeSizes`.
enum Varacc {
	Local(i:Int);
	Env(i:Int);
}

/**
	JitContext keeps track of allocated local variables and closures. Scopes can be pushed
	and popped and influence the "slots" of variables. It also manages the maximum number
	of locals allocated at the same time, which the run-time can use to allocate a fixed
	array.
**/
class JitContext {
	public final ctx:Context;
	// The scope stack.
	// port: top = last element
	public var scopes:Array<Scope>;
	// port: number of `add`s into each scope's `locals` (IntHashtbl.length), parallel to `scopes`.
	public var scopeSizes:Array<Int>;
	// The captured variables declared in this context. Maps variable IDs to capture slots.
	public var captures:OcamlHashtbl<Int, CaptureSlot>;
	// The current number of locals.
	public var numLocals:Int;
	// The maximum number of locals.
	public var maxNumLocals:Int;
	// The number of closures in this context.
	public var numClosures:Int;
	// Whether or not this function has a return that's not at the end of control flow.
	public var hasNonfinalReturn:Bool;
	// The name of capture variables. Maps local slots to variable names. Only filled in debug mode.
	public var captureInfos:OcamlHashtbl<Int, VarInfo>;
	// Variables which are accessed but not declared in this scope.
	// port: list order: newest first
	public var capturesOutsideScope:Array<TVar>;
	// port: not upstream: the class whose static initialisation (a static
	// variable's expression, __init__) this context compiles, its own closures
	// left out (EvalJit.hookStatic: no macro state)
	public var initOf:Null<core.TType.TClass> = null;

	public function new(ctx:Context) {
		this.ctx = ctx;
		this.scopes = [];
		this.scopeSizes = [];
		this.captures = new OcamlHashtbl(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
		this.numLocals = 0;
		this.maxNumLocals = 0;
		this.numClosures = 0;
		this.hasNonfinalReturn = false;
		this.captureInfos = new OcamlHashtbl(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
		this.capturesOutsideScope = [];
	}
}

// port: `(int * bool)`: capture slot and whether the variable is declared in this context.
class CaptureSlot {
	public final slot:Int;
	public final declared:Bool;

	public inline function new(slot:Int, declared:Bool) {
		this.slot = slot;
		this.declared = declared;
	}
}

class EvalJitContext {
	public static function varInfoOfVar(v:TVar):VarInfo {
		return new VarInfo(v.vName, v.vPos, switch v.vKind {
			case VUser(_): false;
			case _: true;
		});
	}

	/** Creates a new context **/
	public static function create(ctx:Context):JitContext return new JitContext(ctx);

	// port: takes the top scope of [jit] and reads its add count from `scopeSizes`.
	/** Returns the number of locals in [scope]. **/
	static inline function numLocalsOfTop(jit:JitContext):Int return jit.scopeSizes[jit.scopeSizes.length - 1];

	/** Pushes a new scope onto context [jit]. **/
	public static function pushScope(jit:JitContext, pos:Pos):Void {
		var scope = new Scope(pos, jit.numLocals, new Map(), new OcamlHashtbl(OcamlHashtbl.hashInt, (a, b) -> a == b, 0),
			new OcamlHashtbl(core.ds.OcamlHash.hashString, (a, b) -> a == b, 0));
		jit.scopes.push(scope);
		jit.scopeSizes.push(0);
	}

	/** Pops the top scope from context [jit]. **/
	public static function popScope(jit:JitContext):Void {
		if (jit.scopes.length == 0) {
			Globals.die("", "evalJitContext.ml:popScope");
			return;
		}
		var n = numLocalsOfTop(jit);
		jit.scopes.pop();
		jit.scopeSizes.pop();
		jit.numLocals = jit.numLocals - n;
	}

	/** Increases number of locals and updates maximum number of locals if necessary **/
	public static inline function increaseNumLocals(jit:JitContext):Void {
		jit.numLocals = jit.numLocals + 1;
		if (jit.numLocals > jit.maxNumLocals) jit.maxNumLocals = jit.numLocals;
	}

	/** Adds capture variable [var] to context [jit]. **/
	public static function addCapture(jit:JitContext, v:TVar, declared:Bool):Int {
		var i = jit.captures.length();
		jit.captures.add(v.vId, new CaptureSlot(i, declared));
		if (jit.ctx.debug.supportDebugger) {
			jit.captureInfos.replace(i, varInfoOfVar(v));
		}
		return i;
	}

	/** Adds variable [var] to the current top scope of context [jit]. **/
	public static function addLocal(jit:JitContext, v:TVar):Int {
		if (jit.scopes.length == 0) return Globals.die("", "evalJitContext.ml:addLocal");
		var top = jit.scopes.length - 1;
		var scope = jit.scopes[top];
		var i = jit.scopeSizes[top];
		scope.locals.set(v.vId, i);
		jit.scopeSizes[top] = i + 1;
		increaseNumLocals(jit);
		var slot = scope.localOffset + i;
		if (jit.ctx.debug.supportDebugger) {
			scope.localIds.replace(v.vName, v.vId);
			scope.localInfos.replace(i, varInfoOfVar(v));
		}
		return slot;
	}

	/**
		Declares variable [var] in context [jit]. If the variable is captured, it is added to
		the capture hash table. Otherwise it is added to the local hash table of the top scope.

		Returns either [Env slot] if the variable is captured or [Local slot] otherwise.
	**/
	public static function declareLocal(jit:JitContext, v:TVar):Varacc {
		if (TFunctions.hasVarFlag(v, VCaptured)) return Varacc.Env(addCapture(jit, v, true));
		else return Varacc.Local(addLocal(jit, v));
	}

	/**
		Declares function argument [var] in context [jit].

		All function arguments are added as local variables. If the variable is captured, it
		is also added as a capture variable. This is handled by [EvalEmitter.handle_capture_arguments].
	**/
	public static function declareArg(jit:JitContext, v:TVar):{slot:Int, local:Null<Int>} {
		var varacc = addLocal(jit, v);
		if (TFunctions.hasVarFlag(v, VCaptured)) return {slot: addCapture(jit, v, true), local: varacc};
		else return {slot: varacc, local: null};
	}

	/** Declares a variable for `this` in context [jit]. **/
	public static function declareLocalThis(jit:JitContext):Varacc {
		if (jit.scopes.length == 0) return Globals.die("", "evalJitContext.ml:declareLocalThis");
		var top = jit.scopes.length - 1;
		var scope = jit.scopes[top];
		var i = jit.scopeSizes[top];
		scope.locals.set(0, i);
		jit.scopeSizes[top] = i + 1;
		increaseNumLocals(jit);
		if (jit.ctx.debug.supportDebugger) {
			scope.localIds.replace("this", 0);
			scope.localInfos.replace(0, new VarInfo("this", Globals.nullPos, false));
		}
		return Varacc.Local(i);
	}

	/** Gets the slot of variable id [vid] in context [jit]. **/
	public static function getSlotRaise(jit:JitContext, vid:Int):Int {
		var k = jit.scopes.length - 1;
		while (k >= 0) {
			var scope = jit.scopes[k];
			var i = scope.locals.get(vid);
			if (i != null) return scope.localOffset + i;
			k--;
		}
		throw NotFound.raise();
	}

	public static function getSlot(jit:JitContext, vid:Int, p:Pos):Int {
		try
			return getSlotRaise(jit, vid)
		catch (_:NotFound)
			return EvalMisc.throwString("Unbound variable", p);
	}

	/** Gets the slot of captured variable id [vid] in context [jit]. **/
	public static function getCaptureSlot(jit:JitContext, v:TVar):Int {
		var c = jit.captures.findOpt(v.vId);
		if (c != null) return c.slot;
		jit.capturesOutsideScope.unshift(v);
		return addCapture(jit, v, false);
	}
}
