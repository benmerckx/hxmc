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

package macros.eval;

import core.Globals;
import core.Globals.Pos;
import core.ds.AtomicLazy;
import core.ds.GlobalsIntMap;
import core.ds.NotFound;
import core.ds.OcamlHashtbl;
import macros.eval.EvalValue;
import macros.eval.EvalHash;

using macros.eval.EvalValue.EvalValueTools;

// port: per-thread `eval` state is a host thread-local (`sys.thread.Tls`).
@:structInit class VarInfo {
	public var viName:String;
	public var viPos:Pos;
	public var viGenerated:Bool;

	public inline function new(viName:String, viPos:Pos, viGenerated:Bool) {
		this.viName = viName;
		this.viPos = viPos;
		this.viGenerated = viGenerated;
	}
}

@:structInit class Scope {
	// The position of the current scope.
	public var pos:Pos;
	// The local start offset of the current scope.
	public var localOffset:Int;
	// The locals declared in the current scope. Maps variable IDs to local slots.
	public var locals:Map<Int, Int>;
	// The name of local variables. Maps local slots to variable names. Only filled in debug mode.
	public var localInfos:OcamlHashtbl<Int, VarInfo>;
	// The IDs of local variables. Maps variable names to variable IDs.
	public var localIds:OcamlHashtbl<String, Int>;

	public inline function new(pos:Pos, localOffset:Int, locals:Map<Int, Int>, localInfos:OcamlHashtbl<Int, VarInfo>,
			localIds:OcamlHashtbl<String, Int>) {
		this.pos = pos;
		this.localOffset = localOffset;
		this.locals = locals;
		this.localInfos = localInfos;
		this.localIds = localIds;
	}
}

enum EnvKind {
	EKLocalFunction(i:Int);
	EKMethod(type:Int, field:Int);
	EKMacro(type:Int, field:Int);
	EKEntrypoint;
}

/**
	Compile-time information for environments. This information is static for
	all environments of the same kind, e.g. all environments of a specific method.
**/
@:structInit class EnvInfo {
	// If false, the environment has a this-context.
	public var isStatic:Bool;
	// Hash of the source file of this environment.
	public var pfile:Int;
	// Hash of the unique source file of this environment.
	public var pfileUnique:Int;
	// The environment kind.
	public var kind:EnvKind;
	// The name of capture variables. Maps local slots to variable names. Only filled in debug mode.
	public var captureInfos:OcamlHashtbl<Int, VarInfo>;
	// The number of local variables.
	public var numLocals:Int;
	// The number of capture variables.
	public var numCaptures:Int;

	public inline function new(isStatic:Bool, pfile:Int, pfileUnique:Int, kind:EnvKind, captureInfos:OcamlHashtbl<Int, VarInfo>, numLocals:Int,
			numCaptures:Int) {
		this.isStatic = isStatic;
		this.pfile = pfile;
		this.pfileUnique = pfileUnique;
		this.kind = kind;
		this.captureInfos = captureInfos;
		this.numLocals = numLocals;
		this.numCaptures = numCaptures;
	}
}

// port: environment slots: a bare native array on HashLink (haxe.ds.Vector is an Array there).
typedef ValueSlots = #if hl hl.NativeArray<Value> #else haxe.ds.Vector<Value> #end;

/** Per-environment debug information. These values are only modified while debugging. **/
class EnvDebug {
	// The timer function to execute when the environment finishes executing
	public final timer:Void->Void;
	// The current scope stack.
	public var scopes:Array<Scope>;
	// The current line being executed. This in conjunction with `env_info.pfile` is used to find breakpoints.
	public var line:Int;
	// The current expression being executed
	public var debugExpr:String;
	// The current expression position being executed
	public var debugPos:Pos;

	public function new(timer:Void->Void, scopes:Array<Scope>, line:Int, debugExpr:String, debugPos:Pos) {
		this.timer = timer;
		this.scopes = scopes;
		this.line = line;
		this.debugExpr = debugExpr;
		this.debugPos = debugPos;
	}
}

/**
	An environment in which code is executed. Environments are created whenever
	a function is called and when evaluating static inits.
**/
class Env {
	// The compile-time information for the current environment
	public final envInfo:EnvInfo;
	// The debug information for the current environment
	public final envDebug:EnvDebug;
	// The position at which the current environment was left, e.g. by a call.
	public var envLeavePmin:Int = 0;
	// The position at which the current environment was left, e.g. by a call.
	public var envLeavePmax:Int = 0;
	// The environment's local variables. Indices are determined during compile-time, or can be obtained
	// through `scope.locals` when debugging.
	// port: vectors (native arrays on HashLink): one allocation, unchecked access.
	public final envLocals:ValueSlots;
	// The reference to the environment's captured local variables. Indices are determined during compile-time,
	// or can be obtained through `env_info.capture_infos`.
	public final envCaptures:ValueSlots;
	// Map of extra variables added while debugging. Keys are hashed variable names.
	public var envExtraLocals:GlobalsIntMap<Value>;
	// The parent of the current environment, if exists.
	public final envParent:Null<Env>;
	// Execution stack depth
	public final envStackDepth:Int;
	public final envEval:Eval;

	public function new(envInfo:EnvInfo, envDebug:EnvDebug, envLocals:ValueSlots, envCaptures:ValueSlots,
			envExtraLocals:GlobalsIntMap<Value>, envParent:Null<Env>, envStackDepth:Int, envEval:Eval) {
		this.envInfo = envInfo;
		this.envDebug = envDebug;
		this.envLocals = envLocals;
		this.envCaptures = envCaptures;
		this.envExtraLocals = envExtraLocals;
		this.envParent = envParent;
		this.envStackDepth = envStackDepth;
		this.envEval = envEval;
	}
}

class Eval {
	public var env:Null<Env> = null;
	public final thread:Vthread;
	public var exceptionStack:Array<{pos:Pos, kind:EnvKind}> = [];
	// The threads current debug state
	public var debugState:DebugState = DbgRunning;
	// The currently active breakpoint. Set to a dummy value initially.
	public var breakpoint:Breakpoint;
	// Map of all types that are currently being caught. Updated by `emitTry`.
	public final caughtTypes:Map<Int, Bool> = new Map();
	// The most recently caught exception. Used by `debug_loop` to avoid getting stuck.
	public var caughtException:Value = VNull;
	// The value which was last returned.
	public var lastReturn:Null<Value> = null;
	// The debug channel used to synchronize with the debugger.
	public final debugChannel:EventChannel<Bool> = new EventChannel();
	// port: thread-local storage (sys.thread.Tls), keyed by tls id
	public final evalStorage:Map<Int, Value> = new Map();

	public function new(thread:Vthread, breakpoint:Breakpoint) {
		this.thread = thread;
		this.breakpoint = breakpoint;
	}
}

enum DebugState {
	DbgRunning;
	DbgWaiting;
	DbgStep;
	DbgNext(env:Env, p:Pos);
	DbgFinish(env:Env); // parent env
}

enum BreakpointState {
	BPEnabled;
	BPDisabled;
	BPHit;
}

enum BreakpointColumn {
	BPAny;
	BPColumn(i:Int);
}

class Breakpoint {
	public final bpid:Int;
	public final bpfile:Int;
	public final bpline:Int;
	public final bpcolumn:BreakpointColumn;
	public final bpcondition:Null<core.Ast.Expr>;
	public var bpstate:BreakpointState;

	public function new(bpid:Int, bpfile:Int, bpline:Int, bpcolumn:BreakpointColumn, bpcondition:Null<core.Ast.Expr>,
			bpstate:BreakpointState) {
		this.bpid = bpid;
		this.bpfile = bpfile;
		this.bpline = bpline;
		this.bpcolumn = bpcolumn;
		this.bpcondition = bpcondition;
		this.bpstate = bpstate;
	}
}

class FunctionBreakpoint {
	public final fbpid:Int;
	public var fbpstate:BreakpointState;

	public function new(fbpid:Int, fbpstate:BreakpointState) {
		this.fbpid = fbpid;
		this.fbpstate = fbpstate;
	}
}

class Builtins {
	public var instanceBuiltins:GlobalsIntMap<Array<{name:Int, value:Value}>>;
	public var staticBuiltins:GlobalsIntMap<Array<{name:Int, value:Value}>>;
	public final constructorBuiltins:Map<Int, Array<Value>->Value>;
	public final emptyConstructorBuiltins:Map<Int, Void->Value>;

	public function new(instanceBuiltins, staticBuiltins, constructorBuiltins, emptyConstructorBuiltins) {
		this.instanceBuiltins = instanceBuiltins;
		this.staticBuiltins = staticBuiltins;
		this.constructorBuiltins = constructorBuiltins;
		this.emptyConstructorBuiltins = emptyConstructorBuiltins;
	}
}

class StaticPrototypes {
	var prototypes:GlobalsIntMap<Vprototype> = GlobalsIntMap.empty();
	var inits:GlobalsIntMap<{proto:Vprototype, delays:Array<Vprototype->Void>}> = GlobalsIntMap.empty();

	public function new() {}

	public function add(proto:Vprototype):Void prototypes = prototypes.add(proto.ppath, proto);

	public function remove(path:Int):Void {
		inits = inits.remove(path);
		prototypes = prototypes.remove(path);
	}

	public function reset():Void inits.iter((_, e) -> for (f in e.delays) f(e.proto));

	public function addInit(proto:Vprototype,
			delays:Array<Vprototype->Void>):Void inits = inits.add(proto.ppath, {proto: proto, delays: delays});

	public function get(path:Int):Vprototype return prototypes.find(path);
}

enum ExceptionMode {
	CatchAll;
	CatchUncaught;
	CatchNone;
}

@:structInit class DebugScopeInfo {
	public var dsExpr:String;
	public var dsReturn:Null<Value>;

	public inline function new(dsExpr:String, dsReturn:Null<Value>) {
		this.dsExpr = dsExpr;
		this.dsReturn = dsReturn;
	}
}

enum ContextReference {
	StackFrame(env:Env);
	Scope(scope:Scope, env:Env);
	CaptureScope(infos:OcamlHashtbl<Int, VarInfo>, env:Env);
	DebugScope(info:DebugScopeInfo, env:Env);
	Value(value:Value, env:Env);
	Toplevel;
	NoSuchReference;
}

class EvalDebugContext {
	final lut:Array<ContextReference> = {
		var d = [];
		d.push(Toplevel);
		d;
	}

	final mutex = new sys.thread.Mutex();

	public function new() {}

	function add(reference:ContextReference):Int {
		mutex.acquire();
		lut.push(reference);
		var i = lut.length - 1;
		mutex.release();
		return i;
	}

	public function addStackFrame(env:Env):Int return add(StackFrame(env));

	public function addScope(scope:Scope, env:Env):Int return add(Scope(scope, env));

	public function addCaptureScope(h:OcamlHashtbl<Int, VarInfo>, env:Env):Int return add(CaptureScope(h, env));

	public function addValue(v:Value, env:Env):Int return add(Value(v, env));

	public function addDebugScope(scope:DebugScopeInfo, env:Env):Int return add(DebugScope(scope, env));

	public function get(id:Int):ContextReference {
		return if (id >= 0 && id < lut.length) lut[id] else NoSuchReference;
	}
}

class DebugConnection {
	public final bpStop:Debug->Void;
	public final excStop:Debug->Value->Pos->Void;
	public final sendThreadEvent:Int->String->Void;

	public function new(bpStop, excStop, sendThreadEvent) {
		this.bpStop = bpStop;
		this.excStop = excStop;
		this.sendThreadEvent = sendThreadEvent;
	}
}

class DebugSocket {
	public final socket:core.Socket;
	public final connection:DebugConnection;

	public function new(socket, connection) {
		this.socket = socket;
		this.connection = connection;
	}
}

/** Per-context debug information **/
class Debug {
	// The registered breakpoints
	public final breakpoints:OcamlHashtbl<Int, OcamlHashtbl<Int, Breakpoint>>;
	// The registered function breakpoints
	// port: keyed by `(type, field)`
	public final functionBreakpoints:OcamlHashtbl<{type:Int, field:Int}, FunctionBreakpoint>;
	// Whether or not debugging is supported. Has various effects on the amount of
	// data being retained at run-time.
	public var supportDebugger:Bool;
	// The debugger socket
	public var debugSocket:Null<DebugSocket>;
	// The current exception mode
	public var exceptionMode:ExceptionMode;
	// The debug context which manages scopes and variables.
	public var debugContext:EvalDebugContext;

	public function new(breakpoints, functionBreakpoints, supportDebugger, debugSocket, exceptionMode, debugContext) {
		this.breakpoints = breakpoints;
		this.functionBreakpoints = functionBreakpoints;
		this.supportDebugger = supportDebugger;
		this.debugSocket = debugSocket;
		this.exceptionMode = exceptionMode;
		this.debugContext = debugContext;
	}
}

// port: OCaml's `unit Event.channel` as the debugger uses it: `receive` (Event.sync
// (Event.receive c)) waits for a value, `poll` (Event.poll (Event.send c v))
// hands one over only to a thread already waiting in `receive`. The waiting
// thread gives up the Eval lock (EvalLock) while it waits.
class EventChannel<T> {
	final mutex = new sys.thread.Mutex();
	final waiters:Array<EventWaiter<T>> = [];

	public function new() {}

	public function receive():T {
		var w = new EventWaiter<T>();
		mutex.acquire();
		waiters.push(w);
		mutex.release();
		EvalLock.blocking(() -> w.lock.wait());
		return w.value;
	}

	public function poll(v:T):Bool {
		mutex.acquire();
		var w = waiters.shift();
		mutex.release();
		if (w == null) return false;
		w.value = v;
		w.lock.release();
		return true;
	}
}

private class EventWaiter<T> {
	public final lock = new sys.thread.Lock();
	public var value:Null<T> = null;

	public function new() {}
}

// port: `object_name_cache` (a Hashtbl keyed by the sorted hashed names) as a
// trie: a node per prefix of names, with the object name of its exact list
// (-1 until computed; hashes are 30-bit), so a lookup allocates nothing.
class ObjectNameCache {
	public var name:Int = -1;
	public final children:Map<Int, ObjectNameCache> = new Map();

	public function new() {}
}

class Context {
	public final ctxId:Int;
	public final isMacro:Bool;
	public final detailTimes:Bool;
	public final builtins:Builtins;
	public final debug:Debug;
	public var hadError:Bool = false;
	public var curapi:macros.MacroApi.CompilerApi;
	public var typeCache:GlobalsIntMap<core.TType.ModuleType> = GlobalsIntMap.empty();
	public final overrides:Map<String, Bool> = new Map(); // port: keyed by "path.field"
	public final timerCtx:core.Timer.TimerContext;
	public var args:Array<String> = [];
	// prototypes
	public var arrayPrototype:Vprototype;
	public var stringPrototype:Vprototype;
	public var vectorPrototype:Vprototype;
	public var instancePrototypes:GlobalsIntMap<Vprototype> = GlobalsIntMap.empty();
	public var staticPrototypes:StaticPrototypes = new StaticPrototypes();
	public var constructors:GlobalsIntMap<AtomicLazy<Value>> = GlobalsIntMap.empty();
	public final fakeProtoCache:Map<Int, Vprototype> = new Map();
	public final fileKeys:context.Common.FileKeys;
	public final objectNameCache:ObjectNameCache = new ObjectNameCache(); // port: a trie on the sorted hashed names
	public var getObjectPrototype:(ctx:Context, fields:Array<Int>) -> Vprototype;
	// eval
	public var nextThreadId:Int = 0;
	public final toplevel:Value;
	public final evals:OcamlHashtbl<Int, Eval> = new OcamlHashtbl(OcamlHashtbl.hashInt, (a, b) -> a == b, 1);
	public final maxStackDepth:Int;
	public final maxPrintDepth:Int;
	public final printIndentation:Null<String>;

	public function new(ctxId, isMacro, detailTimes, builtins, debug, curapi, timerCtx, arrayPrototype, stringPrototype, vectorPrototype,
			fileKeys, getObjectPrototype, toplevel, maxStackDepth, maxPrintDepth, printIndentation) {
		this.ctxId = ctxId;
		this.isMacro = isMacro;
		this.detailTimes = detailTimes;
		this.builtins = builtins;
		this.debug = debug;
		this.curapi = curapi;
		this.timerCtx = timerCtx;
		this.arrayPrototype = arrayPrototype;
		this.stringPrototype = stringPrototype;
		this.vectorPrototype = vectorPrototype;
		this.fileKeys = fileKeys;
		this.getObjectPrototype = getObjectPrototype;
		this.toplevel = toplevel;
		this.maxStackDepth = maxStackDepth;
		this.maxPrintDepth = maxPrintDepth;
		this.printIndentation = printIndentation;
	}
}

class GlobalState {
	public static var getCtxRef:Void->Context = () -> throw "GlobalState.get_ctx_ref called before initialization";
	public static var initialized = false;
	public static var sid = -1;
	public static var debug:Null<Debug> = null;
	public static var debuggerInitialized = false;
	public static var stdlib:Null<Builtins> = null;
	public static final macroLib:Map<String, Value> = new Map();
}

// port: RunTimeException upstream: an exception value thrown by interpreted code.
class RunTimeException extends haxe.Exception {
	public final value:Value;
	public final envs:Array<Env>;
	public final pos:Pos;

	public function new(value:Value, envs:Array<Env>, pos:Pos) {
		super("RunTimeException");
		this.value = value;
		this.envs = envs;
		this.pos = pos;
	}
}

class EvalContext {
	public static function getCtx():Context return GlobalState.getCtxRef();

	public static function select(ctx:Context):Void {
		GlobalState.initialized = true;
		GlobalState.getCtxRef = () -> ctx;
	}

	public static function sDebugState(s:DebugState):String {
		return switch s {
			case DbgRunning: "DbgRunning";
			case DbgWaiting: "DbgWaiting";
			case DbgStep: "DbgStep";
			case DbgNext(_): "DbgNext";
			case DbgFinish(_): "DbgFinish";
		}
	}

	// Misc
	static final currentEval = new sys.thread.Tls<Eval>();

	// port: thread-local reads are a native call and a cast on HashLink. While a single
	// thread has set an eval, it is also kept in a static; a second thread switches
	// to the thread-local value for good (which is always set).
	static var singleEval:Null<Eval> = null;

	static var singleThread:Null<sys.thread.Thread> = null;
	static var multiThreaded = false;

	// port: `Thread_local_storage.get_exn ctx.eval`
	public static function getEval(ctx:Context):Eval {
		var e = multiThreaded ? currentEval.value : singleEval;
		if (e == null) throw NotFound.raise();
		return e;
	}

	// port: `Thread_local_storage.get_opt ctx.eval`: the current host thread's own eval, if set.
	public static function getEvalOpt(ctx:Context):Null<Eval> return currentEval.value;

	public static function setEval(ctx:Context, e:Eval):Void {
		currentEval.value = e;
		if (!multiThreaded) {
			var t = sys.thread.Thread.current();
			if (singleThread == null) singleThread = t;
			if (singleThread == t) singleEval = e
			else multiThreaded = true;
		}
	}

	public static function currentThreadId(ctx:Context):Int return getEval(ctx).thread.threadId;

	public static function kindName(eval:Eval, kind:EnvKind):String {
		function loop(kind:EnvKind, env:Null<Env>):String {
			return switch kind {
				case EKMethod(i1, i2): EvalHash.revHash(i1) + "." + EvalHash.revHash(i2);
				case EKMacro(i1, i2): "Macro call: " + EvalHash.revHash(i1) + "." + EvalHash.revHash(i2);
				case EKLocalFunction(i):
					env == null ? 'localFunction$i' : loop(env.envInfo.kind, env.envParent) + '.localFunction$i';
				case EKEntrypoint:
					env == null ? "entrypoint" : EvalHash.revHash(env.envInfo.pfile);
			}
		}
		return eval.env == null ? "toplevel" : loop(kind, eval.env);
	}

	public static inline function callFunction(f:Vfunc, vl:Array<Value>):Value return f(vl);

	// port: (hashed name, value) pairs; the list order of the upstream folds.
	public static function objectFields(o:Vobject):Array<{name:Int, value:Value}> {
		return switch o.oproto {
			case OProto(proto):
				proto.pinstanceNames.fold((key, index, acc:Array<{name:Int, value:Value}>) -> {
					acc.unshift({name: key, value: o.ofields[index]});
					acc;
				}, []);
			case ODictionary(d):
				d.fold((k, v, acc:Array<{name:Int, value:Value}>) -> {
					acc.unshift({name: k, value: v});
					acc;
				}, []);
		}
	}

	public static function instanceFields(i:Vinstance):Array<{name:Int, value:Value}> {
		return i.iproto.pinstanceNames.fold((name, key, acc:Array<{name:Int, value:Value}>) -> {
			acc.unshift({name: name, value: i.ifields[key]});
			acc;
		}, []);
	}

	public static function protoFields(proto:Vprototype):Array<{name:Int, value:Value}> {
		return proto.pnames.fold((name, key, acc:Array<{name:Int, value:Value}>) -> {
			acc.unshift({name: name, value: proto.pfields[key]});
			acc;
		}, []);
	}

	// Exceptions

	public static function callStack(eval:Eval):Array<Env> {
		var acc = [];
		var env = eval.env;
		while (env != null) {
			acc.push(env);
			env = env.envParent;
		}
		return acc;
	}

	public static function throwValue(v:Value, p:Pos):Dynamic {
		var ctx = getCtx();
		var eval = getEval(ctx);
		var env = eval.env;
		if (env != null) {
			if (p.pfile != Globals.nullPos.pfile || p.pmin != Globals.nullPos.pmin || p.pmax != Globals.nullPos.pmax) {
				env.envLeavePmin = p.pmin;
				env.envLeavePmax = p.pmax;
			}
			throw core.ds.FastThrow.of(new RunTimeException(v, callStack(eval), p));
		}
		throw core.ds.FastThrow.of(new RunTimeException(v, [], p));
	}

	public static function exc(v:Value):Dynamic return throwValue(v, Globals.nullPos);

	public static function excString(str:String):Dynamic return exc(VString(EvalString.createAscii(str)));

	public static function excStringP(str:String, p:Pos):Dynamic return throwValue(VString(EvalString.createAscii(str)), p);

	public static function errorMessage(str:String):Dynamic return excString(str);

	// Environment handling
	public static final noTimer:Void->Void = () -> {};
	public static final emptyArray:haxe.ds.Vector<Value> = new haxe.ds.Vector(0);
	static final emptyVector = new ValueSlots(0);
	public static final noExpr = "";
	public static final noDebug = new EnvDebug(noTimer, [], 0, noExpr, Globals.nullPos);

	public static function createEnvInfo(isStatic:Bool, pfile:String, pfileKey:String, kind:EnvKind, captureInfos:OcamlHashtbl<Int, VarInfo>,
			numLocals:Int, numCaptures:Int):EnvInfo {
		return {
			isStatic: isStatic,
			kind: kind,
			pfile: EvalHash.hash(pfile),
			pfileUnique: EvalHash.hash(core.Path.UniqueKey.toString(pfileKey)),
			captureInfos: captureInfos,
			numLocals: numLocals,
			numCaptures: numCaptures
		};
	}

	// port: Array.make n vnull: one allocation instead of growing a comprehension.
	static function makeNullArray(n:Int):ValueSlots {
		var a = new ValueSlots(n);
		for (i in 0...n) a[i] = VNull;
		return a;
	}

	public static function pushEnvironment(ctx:Context, info:EnvInfo):Env {
		core.ds.GcPolicy.tick(); // port: macro code allocates without typing anything
		EvalLock.tick();
		var eval = getEval(ctx);
		var timer = if (ctx.detailTimes) core.Timer.startTimer(ctx.timerCtx,
			["macro", "execution", kindName(eval, info.kind)]) else noTimer;
		var debug = if (ctx.debug.supportDebugger || ctx.detailTimes) new EnvDebug(timer, [], 0, noExpr, Globals.nullPos) else noDebug;
		var locals = info.numLocals == 0 ? emptyVector : makeNullArray(info.numLocals);
		var captures = info.numCaptures == 0 ? emptyVector : makeNullArray(info.numCaptures);
		var stackDepth = eval.env == null ? 1 : eval.env.envStackDepth + 1;
		var env = new Env(info, debug, locals, captures, GlobalsIntMap.empty(), info.kind == EKEntrypoint ? null : eval.env, stackDepth,
			eval);
		eval.env = env;
		switch [ctx.debug.debugSocket, env.envInfo.kind] {
			case [socket, EKMethod(keyType, keyField)] if (socket != null):
				try {
					var bp = ctx.debug.functionBreakpoints.find({type: keyType, field: keyField});
					if (bp.fbpstate != BPEnabled) throw NotFound.raise();
					socket.connection.bpStop(ctx.debug);
					eval.debugState = DbgWaiting;
				} catch (_:NotFound) {}
			case _:
		}
		return env;
	}

	public static function popEnvironment(ctx:Context, env:Env):Void {
		var eval = env.envEval;
		eval.env = env.envParent;
		env.envDebug.timer();
	}

	// Prototypes

	public static function getStaticPrototypeRaise(ctx:Context, path:Int):Vprototype return ctx.staticPrototypes.get(path);

	public static function getStaticPrototype(ctx:Context, path:Int, p:Pos):Vprototype {
		try
			return getStaticPrototypeRaise(ctx, path)
		catch (_:NotFound)
			return core.Error.raiseTypingError('[${ctx.ctxId}] Type not found: ${EvalHash.revHash(path)}', p);
	}

	public static function getStaticPrototypeAsValue(ctx:Context, path:Int, p:Pos):Value return getStaticPrototype(ctx, path, p).pvalue;

	public static function getInstancePrototypeRaise(ctx:Context, path:Int):Vprototype return ctx.instancePrototypes.find(path);

	public static function getInstancePrototype(ctx:Context, path:Int, p:Pos):Vprototype {
		try
			return getInstancePrototypeRaise(ctx, path)
		catch (_:NotFound)
			return core.Error.raiseTypingError('[${ctx.ctxId}] Instance prototype not found: ${EvalHash.revHash(path)}', p);
	}

	public static function getInstanceConstructorRaise(ctx:Context, path:Int):AtomicLazy<Value> return ctx.constructors.find(path);

	public static function getInstanceConstructor(ctx:Context, path:Int, p:Pos):AtomicLazy<Value> {
		try
			return getInstanceConstructorRaise(ctx, path)
		catch (_:NotFound)
			return core.Error.raiseTypingError('[${ctx.ctxId}] Instance constructor not found: ${EvalHash.revHash(path)}', p);
	}

	public static function getSpecialInstanceConstructorRaise(ctx:Context, path:Int):Array<Value>->Value {
		var f = getCtx().builtins.constructorBuiltins.get(path);
		if (f == null) throw NotFound.raise();
		return f;
	}

	public static function getProtoFieldIndexRaise(proto:Vprototype, name:Int):Int return proto.pnames.find(name);

	public static function getProtoFieldIndex(proto:Vprototype, name:Int):Int {
		try
			return getProtoFieldIndexRaise(proto, name)
		catch (_:NotFound)
			return
				core.Error.raiseTypingError('Field index for ${EvalHash.revHash(name)} not found on prototype ${EvalHash.revHash(proto.ppath)}',
					Globals.nullPos);
	}

	public static function getInstanceFieldIndexRaise(proto:Vprototype, name:Int):Int return proto.pinstanceNames.find(name);

	public static function getInstanceFieldIndex(proto:Vprototype, name:Int, p:Pos):Int {
		try
			return getInstanceFieldIndexRaise(proto, name)
		catch (_:NotFound)
			return
				core.Error.raiseTypingError('Field index for ${EvalHash.revHash(name)} not found on prototype ${EvalHash.revHash(proto.ppath)}',
					p);
	}

	public static function is(v:Value, path:Int):Bool {
		if (path == EvalHash.key_Dynamic) return v != VNull;
		return switch v {
			case VInt32(_): path == EvalHash.key_Int || path == EvalHash.key_Float;
			case VInt64(_): path == EvalHash.key_eval_integers_Int64;
			case VFloat(f): path == EvalHash.key_Float || (path == EvalHash.key_Int && f == Std.int(f)
					&& f <= 2147483647. && f >= -2147483648.);
			case VTrue | VFalse: path == EvalHash.key_Bool;
			case VPrototype({pkind: PClass(_)}): path == EvalHash.key_Class;
			case VPrototype({pkind: PEnum(_)}): path == EvalHash.key_Enum;
			case VEnumValue(ve): path == EvalHash.key_EnumValue || path == ve.epath;
			case VString(_): path == EvalHash.key_String;
			case VArray(_): path == EvalHash.key_Array;
			case VVector(_): path == EvalHash.key_eval_Vector;
			case VInstance(vi):
				inline function hasInterface(path2:Int):Bool {
					try {
						return switch getStaticPrototypeRaise(getCtx(), path2).pkind {
							case PClass(interfaces): interfaces.indexOf(path) >= 0;
							case _: false;
						}
					} catch (_:NotFound) {
						return false;
					}
				}
				var proto = vi.iproto;
				var found = false;
				while (true) {
					if (path == proto.ppath || hasInterface(proto.ppath)) {
						found = true;
						break;
					}
					if (proto.pparent == null) break;
					proto = proto.pparent;
				}
				found;
			case _: false;
		}
	}
}
