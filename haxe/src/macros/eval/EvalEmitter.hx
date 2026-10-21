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
import core.ds.InvalidArgument;
import core.ds.NotFound;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalExceptions.Break;
import macros.eval.EvalExceptions.Continue;
import macros.eval.EvalExceptions.Return;
import haxe.ds.Vector;

using macros.eval.EvalValue.EvalValueTools;

// port: the closures the JIT produces: an emitter is applied to its compile-time
// arguments and returns an `Emitter` (`env -> value`).
typedef Emitter = Env->Value;

// port: `env -> value -> unit` argument setters of `process_arguments`.
typedef ArgSetter = Env->Value->Void;

// port: one `catch` of `emit_try`: `(exec, path, varacc)`.
class TryCatch {
	public final exec:Emitter;
	public final path:Int;
	public final varacc:Emitter->Emitter;

	public inline function new(exec:Emitter, path:Int, varacc:Emitter->Emitter) {
		this.exec = exec;
		this.path = path;
		this.varacc = varacc;
	}
}

// port: deviations:
// - OCaml partial application (`emit_x a b env`) becomes a function of the
//   compile-time arguments returning an `Emitter` closure. Emitters that upstream
//   uses unapplied (`emit_null`, `emit_new_array`, `emit_return_null`,
//   `emit_break`, `emit_continue`) are static `Emitter` values.
// - `Std.finally (pop_environment)` pops the environment on normal return only
//   (see createFunctionNoret).
// - `emit_closure`/`create_closure`: the `(slot, value) array` of captured
//   references is split into a slot array (computed once at JIT time) and a value
//   array (filled per closure creation), which avoids one tuple per capture.
// - Out-of-bounds `Array.unsafe_get`/`unsafe_set` on vectors is undefined in
//   upstream; a Haxe array would return null or grow, so these raise
//   `Invalid_argument "index out of bounds"` (OCaml's checked-access error), as
//   does the checked `ev.eargs.(i)` of `emit_enum_parameter_read`.
// - `Array.make`'s `Invalid_argument` for sizes above `Sys.max_array_length`
//   cannot happen for 32-bit sizes, so that branch of `emit_new_vector_int` is
//   not reproduced.
class EvalEmitter {
	// Helper
	public static function unexpectedValueP(v:Value, s:String, p:Pos):Dynamic {
		var str = switch v {
			case VNull: "Null Access";
			case _: 'Unexpected value ${EvalPrinting.valueString(v)}, expected $s';
		}
		return EvalMisc.throwString(str, p);
	}

	public static function asArray(p:Pos, v:Value):Varray {
		return switch v {
			case VArray(va): va;
			case v: unexpectedValueP(v, "Array", p);
		}
	}

	public static function asBytes(p:Pos, v:Value):haxe.io.Bytes {
		return switch v {
			case VInstance({ikind: IBytes(s)}): s;
			case v: unexpectedValueP(v, "Bytes", p);
		}
	}

	public static function asEnumValue(p:Pos, v:Value):VenumValue {
		return switch v {
			case VEnumValue(ve): ve;
			case v: unexpectedValueP(v, "enum value", p);
		}
	}

	public static function asInt(p:Pos, v:Value):Int {
		return switch v {
			case VInt32(i): i;
			case VFloat(f): Std.int(f);
			case v: unexpectedValueP(v, "int", p);
		}
	}

	public static function asVector(p:Pos, v:Value):Vvector {
		return switch v {
			case VVector(vv): vv;
			case v: unexpectedValueP(v, "Vector", p);
		}
	}

	public static function cannotCall(v:Value, p:Pos):Dynamic {
		return EvalContext.throwValue(EvalString.createUnknown("Cannot call " + EvalPrinting.valueString(v)), p);
	}

	public static function decodeIntP(v:Value, p:Pos):Int {
		return switch v {
			case VInt32(i): i;
			case VFloat(f): Std.int(f);
			case _: unexpectedValueP(v, "int", p);
		}
	}

	public static inline function checkStackDepth(env:Env):Void {
		if (env.envStackDepth > EvalContext.getCtx().maxStackDepth) EvalContext.excString("Stack overflow");
	}

	// port: an argument array allocated at its size (pushing grows it several times on HashLink).
	static inline function presized(n:Int):Array<Value> {
		#if hl
		return cast hl.types.ArrayObj.alloc(new hl.NativeArray<Value>(n));
		#else
		var a = new Array<Value>();
		a.resize(n);
		return a;
		#end
	}

	// port: evaluates [execs] in order (`List.map (apply env) execs`); up to
	// three arguments as an array literal (one allocation at its size).
	static inline function applyAll(execs:Array<Emitter>, env:Env):Array<Value> {
		#if !hl
		return switch execs.length {
			case 0: [];
			case 1: [execs[0](env)];
			case 2:
				var v0 = execs[0](env);
				[v0, execs[1](env)];
			case 3:
				var v0 = execs[0](env);
				var v1 = execs[1](env);
				[v0, v1, execs[2](env)];
			case _: applyAllLoop(execs, env);
		}
		#else
		return applyAllLoop(execs, env);
		#end
	}

	static function applyAllLoop(execs:Array<Emitter>, env:Env):Array<Value> {
		var vl = presized(execs.length);
		for (i in 0...execs.length) vl[i] = execs[i](env);
		return vl;
	}

	// port: `Array.map (apply env) execs` (in order): the value array itself
	static inline function applyAllArray(execs:Vector<Emitter>, env:Env):Vector<Value> {
		var vl = new Vector<Value>(execs.length);
		for (i in 0...execs.length)
			vl[i] = execs[i](env);
		return vl;
	}

	// port: `vthis :: List.map (apply env) execs` without an intermediate array.
	static inline function applyAllThis(vthis:Value, execs:Array<Emitter>, env:Env):Array<Value> {
		#if !hl
		return switch execs.length {
			case 0: [vthis];
			case 1: [vthis, execs[0](env)];
			case 2:
				var v0 = execs[0](env);
				[vthis, v0, execs[1](env)];
			case _: applyAllThisLoop(vthis, execs, env);
		}
		#else
		return applyAllThisLoop(vthis, execs, env);
		#end
	}

	static function applyAllThisLoop(vthis:Value, execs:Array<Emitter>, env:Env):Array<Value> {
		var vl = presized(execs.length + 1);
		vl[0] = vthis;
		for (i in 0...execs.length) vl[i + 1] = execs[i](env);
		return vl;
	}

	// port: the arguments of `call_value_on vthis vf (List.map (apply env) execs)`
	// with the receiver call_value_on puts in front (`vthis :: vl`, `v1 :: vl`)
	// already there, so that the call (callOn) copies nothing.
	static inline function applyAllOn(vthis:Value, vf:Value, execs:Array<Emitter>, env:Env):Array<Value> {
		return switch vf {
			case VFunction(_, false): applyAllThis(vthis, execs, env);
			case VFieldClosure(v1, _): applyAllThis(v1, execs, env);
			case _: applyAll(execs, env);
		}
	}

	// port: `call_value_on` on the arguments of applyAllOn.
	static inline function callOn(vf:Value, vl:Array<Value>):Value {
		return switch vf {
			case VFunction(f, _) | VFieldClosure(_, f): f(vl);
			case _: EvalContext.excString("Cannot call " + EvalPrinting.valueString(vf));
		}
	}

	static function outOfBounds():Dynamic throw new InvalidArgument("index out of bounds");

	// Emitter

	public static inline function apply(env:Env, exec:Emitter):Value return exec(env);

	// Objects and values
	public static final emitNull:Emitter = _ -> VNull;

	public static function emitLocalDeclaration(i:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			env.envLocals[i] = exec(env);
			return VNull;
		}
	}

	public static function emitCaptureDeclaration(i:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			env.envCaptures[i] = exec(env);
			return VNull;
		}
	}

	public static function emitConst(v:Value):Emitter return _->v;

	public static function emitNullCheck(exec:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VNull: EvalMisc.throwString("Null Access", p);
				case v: v;
			}
		}
	}

	public static final emitNewArray:Emitter = _ -> EvalEncode.encodeArrayInstance(EvalArray.create(new Vector(0)));

	public static function emitNewVectorIntRaw(i:Int, p:Pos):Value {
		if (i < 0) EvalContext.excStringP("Vector size must be >= 0", p);
		var a = new Vector<Value>(i, VNull);
		return EvalEncode.encodeVectorInstance(a);
	}

	public static function emitNewVectorInt(i:Int, p:Pos):Emitter return _ -> emitNewVectorIntRaw(i, p);

	public static function emitNewVector(exec:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			var i = decodeIntP(exec(env), p);
			return emitNewVectorIntRaw(i, p);
		}
	}

	public static function emitSpecialInstance(f:Array<Value>->Value, execs:Array<Emitter>):Emitter {
		return function(env:Env):Value {
			var vl = applyAll(execs, env);
			return f(vl);
		}
	}

	public static function emitObjectDeclaration(proto:Vprototype, fa:Array<{i:Int, exec:Emitter}>):Emitter {
		var n = fa.length;
		var indices = new Vector<Int>(n), execs = new Vector<Emitter>(n);
		for (k in 0...n) {
			indices[k] = fa[k].i;
			execs[k] = fa[k].exec;
		}
		return function(env:Env):Value {
			var a = new Vector<Value>(n, VNull);
			for (k in 0...n) a[indices[k]] = execs[k](env);
			return VObject(new Vobject(a, OProto(proto)));
		}
	}

	public static function emitArrayDeclaration(execs:Vector<Emitter>):Emitter {
		return function(env:Env):Value {
			var vl = applyAllArray(execs, env);
			return EvalEncode.encodeArrayInstance(EvalArray.create(vl));
		}
	}

	public static function emitTypeExpr(proto:Value):Emitter return _->proto;

	public static function emitMkPos(p:Pos):Emitter return _ -> EvalEncode.encodePos(p);

	public static function emitEnumConstruction(key:Int, i:Int, execs:Vector<Emitter>, p:Null<Pos>):Emitter {
		return function(env:Env):Value {
			return EvalEncode.encodeEnumValueV(key, i, applyAllArray(execs, env), p);
		}
	}

	// Branching

	public static function emitIf(execCond:Emitter, execThen:Emitter, execElse:Emitter):Emitter {
		return function(env:Env):Value {
			return switch execCond(env) {
				case VTrue: execThen(env);
				case _: execElse(env);
			}
		}
	}

	public static function emitSwitch(exec:Emitter, execs:Vector<Emitter>, patterns:Vector<Array<Emitter>>, execDef:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec(env);
			var i = 0;
			while (i < patterns.length) {
				for (exec in patterns[i])
					if (EvalValueTools.equals(v1, exec(env))) return execs[i](env);
				i++;
			}
			return execDef(env);
		}
	}

	public static function emitIntSwitchMap(exec:Emitter, cases:GlobalsIntMap<Emitter>, execDef:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VInt32(i):
					// port: IntMap.find raising Not_found: emitters are never null
					var f = cases.findOpt(i);
					if (f == null) execDef(env) else f(env);
				case VNull:
					execDef(env);
				case v:
					unexpectedValueP(v, "int", p);
			}
		}
	}

	public static function emitStringSwitchMap(exec:Emitter, cases:haxe.ds.StringMap<Emitter>, execDef:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VString(s):
					var f = cases.get(s.sstring);
					if (f == null) execDef(env) else f(env);
				case VNull:
					execDef(env);
				case v:
					unexpectedValueP(v, "string", p);
			}
		}
	}

	public static function emitIntSwitchArray(shift:Int, exec:Emitter, cases:Vector<Emitter>, execDef:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VInt32(i32):
					var i = i32 + shift;
					if (i >= cases.length || i < 0) execDef(env) else cases[i](env);
				case VNull:
					execDef(env);
				case v:
					unexpectedValueP(v, "int", p);
			}
		}
	}

	// port: the tail recursion on `Continue` is a loop.
	public static function runWhileContinue(execCond:Emitter, execBody:Emitter, env:Env):Void {
		while (true) {
			try {
				while (EvalMisc.isTrue(execCond(env))) {
					execBody(env);
					core.ds.GcPolicy.tick(); // port: loops allocate without calls or typing
					EvalLock.tick();
				}
				return;
			} catch (_:Continue) {}
		}
	}

	public static function runWhile(execCond:Emitter, execBody:Emitter, env:Env):Void {
		while (EvalMisc.isTrue(execCond(env))) {
			execBody(env);
			core.ds.GcPolicy.tick();
			EvalLock.tick();
		}
	}

	public static function emitWhileBreak(execCond:Emitter, execBody:Emitter):Emitter {
		return function(env:Env):Value {
			try runWhileContinue(execCond, execBody, env)
			catch (_:Break) {}
			return VNull;
		}
	}

	public static function emitWhileBreakContinue(execCond:Emitter, execBody:Emitter):Emitter {
		return function(env:Env):Value {
			try runWhileContinue(execCond, execBody, env)
			catch (_:Break) {}
			return VNull;
		}
	}

	public static function emitDoWhileBreakContinue(execCond:Emitter, execBody:Emitter):Emitter {
		return function(env:Env):Value {
			try {
				execBody(env);
				runWhileContinue(execCond, execBody, env);
			} catch (_:Break) {} catch (_:Continue) {
				try runWhileContinue(execCond, execBody, env)
				catch (_:Break) {}
			}
			return VNull;
		}
	}

	public static function emitTry(exec:Emitter, catches:Array<TryCatch>):Emitter {
		return function(env:Env):Value {
			var ctx = EvalContext.getCtx();
			var eval = env.envEval;
			if (ctx.debug.supportDebugger) {
				for (c in catches) eval.caughtTypes.set(c.path, true);
			}
			inline function restore() {
				for (c in catches) eval.caughtTypes.remove(c.path);
			}
			var v = try {
				var v = EvalExceptions.handleStackOverflow(eval, () -> exec(env));
				restore();
				v;
			} catch (exc:RunTimeException) {
				var v = exc.value;
				eval.caughtException = VNull;
				restore();
				// port: frames left by the throw are popped first (see createFunction): upstream's
				// finally has popped them by the time its handler builds the stack.
				while (true) {
					var env2 = eval.env;
					if (env2 != null && env2 != env) EvalContext.popEnvironment(ctx, env2)
					else break;
				}
				EvalExceptions.buildExceptionStack(eval, env);
				var found:Null<TryCatch> = null;
				for (c in catches) {
					if (c.path == EvalHash.key_Dynamic || EvalContext.is(v, c.path)) {
						found = c;
						break;
					}
				}
				if (found == null) throw exc;
				found.varacc(_ -> v)(env);
				found.exec(env);
			}
			return v;
		}
	}

	// Control flow

	public static function emitValue(exec:Emitter):Emitter return exec;

	public static function emitSeq2(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			exec1(env);
			return exec2(env);
		}
	}

	public static function emitSeq4(exec1:Emitter, exec2:Emitter, exec3:Emitter, exec4:Emitter):Emitter {
		return function(env:Env):Value {
			exec1(env);
			exec2(env);
			exec3(env);
			return exec4(env);
		}
	}

	public static function emitSeq8(exec1:Emitter, exec2:Emitter, exec3:Emitter, exec4:Emitter, exec5:Emitter, exec6:Emitter,
			exec7:Emitter, exec8:Emitter):Emitter {
		return function(env:Env):Value {
			exec1(env);
			exec2(env);
			exec3(env);
			exec4(env);
			exec5(env);
			exec6(env);
			exec7(env);
			return exec8(env);
		}
	}

	public static final emitReturnNull:Emitter = _ -> throw core.ds.FastThrow.of(new Return(VNull));

	public static function emitReturnValue(exec:Emitter):Emitter return env -> throw core.ds.FastThrow.of(new Return(exec(env)));

	public static final emitBreak:Emitter = _ -> throw Break.raise();

	public static final emitContinue:Emitter = _ -> throw Continue.raise();

	public static function emitThrow(exec:Emitter, p:Pos):Emitter return env -> EvalContext.throwValue(exec(env), p);

	public static function emitSafeCast(exec:Emitter, t:Int, p:Pos):Emitter {
		return function(env:Env):Value {
			var v1 = exec(env);
			return switch EvalValueTools.vresolve(v1) {
				case VNull: v1;
				case _: if (!EvalContext.is(v1, t)) EvalMisc.throwString("Class cast error", p) else v1;
			}
		}
	}

	// Calls
	// super.call() - immediate

	public static function emitSuperFieldCall(slot:Int, proto:Vprototype, i:Int, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(env);
			var vthis = env.envLocals[slot];
			var vf = proto.pfields[i];
			var vl = applyAllOn(vthis, vf, execs, env);
			return callOn(vf, vl);
		}
	}

	// Type.call() - immediate

	public static function emitProtoFieldCall(v:AtomicLazy<Vfunc>, execs:Array<Emitter>, p:Pos):Emitter {
		// port: forced once per call site: reading the generic AtomicLazy's value back as a
		// function is a dynamic cast on HashLink.
		var forced:Null<Vfunc> = null;
		return function(env:Env):Value {
			checkStackDepth(env);
			var f = forced;
			if (f == null) f = forced = v.force();
			var vl = applyAll(execs, env);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			return f(vl);
		}
	}

	// instance.call() where call is overridden - dynamic dispatch

	public static function getPrototype(v:Value, p:Pos):Vprototype {
		return switch EvalValueTools.vresolve(v) {
			case VInstance({iproto: proto}) | VPrototype(proto): proto;
			case VString(_): EvalContext.getCtx().stringPrototype;
			case VArray(_): EvalContext.getCtx().arrayPrototype;
			case VVector(_): EvalContext.getCtx().vectorPrototype;
			case _: unexpectedValueP(v, "instance", p);
		}
	}

	public static function emitMethodCall(exec:Emitter, name:Int, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(env);
			var vthis = exec(env);
			var proto = getPrototype(vthis, p);
			var vf = try EvalField.protoFieldRaise(proto,
				name) catch (_:NotFound)
				EvalMisc.throwString('Field ${EvalHash.revHash(name)} not found on prototype ${EvalHash.revHash(proto.ppath)}', p);
			var vl = applyAllOn(vthis, vf, execs, env);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			return callOn(vf, vl);
		}
	}

	// instance.call() where call is not a method - lookup + this-binding

	public static function emitFieldCall(exec:Emitter, name:Int, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(env);
			var vthis = exec(env);
			var vf = EvalField.field(vthis, name);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			return callOn(vf, applyAllOn(vthis, vf, execs, env));
		}
	}

	// new() - immediate + this-binding

	public static function emitConstructorCall(proto:Vprototype, v:AtomicLazy<Vfunc>, execs:Array<Emitter>, p:Pos):Emitter {
		// port: forced once per call site: reading the generic AtomicLazy's value back as a
		// function is a dynamic cast on HashLink.
		var forced:Null<Vfunc> = null;
		return function(env:Env):Value {
			checkStackDepth(env);
			var f = forced;
			if (f == null) f = forced = v.force();
			var vthis = EvalEncode.createInstanceDirect(proto, INormal);
			var vl = applyAllThis(vthis, execs, env);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			f(vl);
			return vthis;
		}
	}

	// super() - immediate + this-binding

	public static function emitSpecialSuperCall(fnew:Array<Value>->Value, execs:Array<Emitter>):Emitter {
		return function(env:Env):Value {
			checkStackDepth(env);
			var vl = applyAll(execs, env);
			var vi2 = fnew(vl);
			var vthis = env.envLocals[0];
			// This isn't very elegant, but it's probably a rare case to extend these types.
			switch [vthis, vi2] {
				case [VInstance(vi), VInstance(vi2)]:
					vi.ikind = vi2.ikind;
				case _:
					Globals.die("", "evalEmitter.ml:emitSpecialSuperCall");
			}
			return VNull;
		}
	}

	public static function emitSuperCall(v:AtomicLazy<Vfunc>, execs:Array<Emitter>, p:Pos):Emitter {
		// port: forced once per call site: reading the generic AtomicLazy's value back as a
		// function is a dynamic cast on HashLink.
		var forced:Null<Vfunc> = null;
		return function(env:Env):Value {
			checkStackDepth(env);
			var f = forced;
			if (f == null) f = forced = v.force();
			var vthis = env.envLocals[0];
			var vl = applyAllThis(vthis, execs, env);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			f(vl);
			return vthis;
		}
	}

	// unknown call - full lookup

	public static function emitCall(exec:Emitter, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(env);
			var v1 = exec(env);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			// port: `call_value v1 (List.map (apply env) execs)`, a field closure's
			// receiver put in front while the arguments are evaluated
			return switch v1 {
				case VFieldClosure(vt, f): f(applyAllThis(vt, execs, env));
				case _: EvalMisc.callValue(v1, applyAll(execs, env));
			}
		}
	}

	// Read

	public static function emitLocalRead(i:Int):Emitter return env -> env.envLocals[i];

	public static function emitCaptureRead(i:Int):Emitter return env -> env.envCaptures[i];

	public static function emitArrayLengthRead(exec:Emitter,
			p:Pos):Emitter return env -> EvalValueTools.vint32(asArray(p, exec(env)).alength);

	public static function emitVectorLengthRead(exec:Emitter,
			p:Pos):Emitter return env -> EvalValueTools.vint32(asVector(p, exec(env)).length);

	public static function emitBytesLengthRead(exec:Emitter,
			p:Pos):Emitter return env -> EvalValueTools.vint32(asBytes(p, exec(env)).length);

	public static function emitProtoFieldRead(proto:Vprototype, i:Int):Emitter return _ -> proto.pfields[i];

	public static function emitInstanceFieldRead(exec:Emitter, p:Pos, i:Int):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VInstance(vi): vi.ifields[i];
				case VString(s): EvalValueTools.vint32(s.slength);
				case VNull: EvalMisc.throwString("field access on null", p);
				case v: unexpectedValueP(v, "instance", p);
			}
		}
	}

	public static function emitThisFieldRead(iv:Int, i:Int):Emitter {
		return function(env:Env):Value {
			return switch env.envLocals[iv] {
				case VInstance(vi): vi.ifields[i];
				case v: EvalExceptions.unexpectedValue(v, "instance");
			}
		}
	}

	public static function emitFieldClosure(exec:Emitter, name:Int):Emitter {
		return function(env:Env):Value {
			var v = exec(env);
			return EvalField.dynamicField(v, name);
		}
	}

	public static function emitAnonFieldRead(exec:Emitter, proto:Vprototype, i:Int, name:Int, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch EvalValueTools.vresolve(exec(env)) {
				case VObject(o):
					switch o.oproto {
						case OProto(proto2) if (proto2 == proto):
							o.ofields[i];
						case _:
							EvalField.objectField(o, name);
					}
				case VNull: EvalMisc.throwString("field access on null", p);
				case v: EvalField.field(v, name);
			}
		}
	}

	public static function emitFieldRead(exec:Emitter, name:Int, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VNull: EvalMisc.throwString("field access on null", p);
				case v: EvalField.field(v, name);
			}
		}
	}

	public static function emitArrayRead(exec1:Emitter, p1:Pos, exec2:Emitter, p2:Pos):Emitter {
		return function(env:Env):Value {
			var a = asArray(p1, exec1(env));
			var i = asInt(p2, exec2(env));
			if (i < 0) return VNull;
			else return EvalArray.get(a, i);
		}
	}

	public static function emitVectorRead(exec1:Emitter, p1:Pos, exec2:Emitter, p2:Pos):Emitter {
		return function(env:Env):Value {
			var v = asVector(p1, exec1(env));
			var i = asInt(p2, exec2(env));
			if (i < 0) return VNull;
			else if (i >= v.length) return outOfBounds();
			else return v[i];
		}
	}

	public static function emitEnumIndex(exec:Emitter, p:Pos):Emitter return env -> EvalValueTools.vint32(asEnumValue(p, exec(env)).eindex);

	public static function emitEnumParameterRead(exec:Emitter, i:Int):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VEnumValue(ev): if (i < 0 || i >= ev.eargs.length) outOfBounds() else ev.eargs[i];
				case v1: EvalExceptions.unexpectedValue(v1, "enum value");
			}
		}
	}

	public static function emitStringCca(exec1:Emitter, exec2:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			var s = EvalDecode.decodeVstring(exec1(env));
			var index = decodeIntP(exec2(env), p);
			if (index < 0 || index >= s.slength) return VNull;
			else return EvalValueTools.vint32(EvalString.charAt(s, index));
		}
	}

	public static function emitStringCcaUnsafe(exec1:Emitter, exec2:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			var s = EvalDecode.decodeVstring(exec1(env));
			var index = decodeIntP(exec2(env), p);
			return EvalValueTools.vint32(EvalString.charAt(s, index));
		}
	}

	// Write

	public static function emitBytesLengthWrite(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			EvalMisc.setBytesLengthField(v1, v2);
			return v2;
		}
	}

	public static function emitLocalWrite(slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v = exec(env);
			env.envLocals[slot] = v;
			return v;
		}
	}

	public static function emitCaptureWrite(slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v = exec(env);
			env.envCaptures[slot] = v;
			return v;
		}
	}

	public static function emitProtoFieldWrite(proto:Vprototype, i:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v = exec2(env);
			proto.pfields[i] = v;
			return v;
		}
	}

	public static function emitInstanceFieldWrite(exec1:Emitter, p:Pos, i:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			return switch exec1(env) {
				case VInstance(vi):
					var v = exec2(env);
					vi.ifields[i] = v;
					v;
				case v: unexpectedValueP(v, "instance", p);
			}
		}
	}

	public static function emitAnonFieldWrite(exec1:Emitter, p:Pos, proto:Vprototype, i:Int, name:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			switch EvalValueTools.vresolve(v1) {
				case VObject(o):
					switch o.oproto {
						case OProto(proto2) if (proto2 == proto):
							o.ofields[i] = v2;
						case _:
							EvalMisc.setObjectField(o, name, v2);
					}
				case VNull:
					EvalMisc.throwString("field access on null", p);
				case _:
					EvalMisc.setField(v1, name, v2);
			}
			return v2;
		}
	}

	public static function emitFieldWrite(exec1:Emitter, p1:Pos, name:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			try EvalMisc.setField(v1, name, v2)
			catch (e:RunTimeException) throw new RunTimeException(e.value, e.envs, p1);
			return v2;
		}
	}

	public static function emitArrayWrite(exec1:Emitter, p1:Pos, exec2:Emitter, p2:Pos, exec3:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			var a = asArray(p1, exec1(env));
			var i = asInt(p2, exec2(env));
			var v3 = exec3(env);
			if (i < 0) EvalMisc.throwString('Negative array index: $i', p);
			EvalArray.set(a, i, v3);
			return v3;
		}
	}

	public static function emitVectorWrite(exec1:Emitter, p1:Pos, exec2:Emitter, p2:Pos, exec3:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			var vv = asVector(p1, exec1(env));
			var i = asInt(p2, exec2(env));
			var v3 = exec3(env);
			if (i < 0) EvalMisc.throwString('Negative vector index: $i', p);
			if (i >= vv.length) outOfBounds();
			vv[i] = v3;
			return v3;
		}
	}

	// Read + write

	public static function doIncr(v:Value, p:Pos):Value {
		return switch v {
			case VInt32(i32): EvalValueTools.vint32(i32 + 1);
			case VInt64(i64): VInt64(i64 + 1);
			case VFloat(f): VFloat(f + 1.);
			case v: unexpectedValueP(v, "number", p);
		}
	}

	public static function emitLocalIncrPrefix(slot:Int, p:Pos):Emitter {
		return function(env:Env):Value {
			var v0 = env.envLocals[slot];
			var v = doIncr(v0, p);
			env.envLocals[slot] = v;
			return v;
		}
	}

	public static function emitLocalIncrPostfix(slot:Int, p:Pos):Emitter {
		return function(env:Env):Value {
			var v0 = env.envLocals[slot];
			var v = doIncr(v0, p);
			env.envLocals[slot] = v;
			return v0;
		}
	}

	public static function emitLocalReadWrite(slot:Int, exec:Emitter, fop:Value->Value->Value, prefix:Bool):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = fop(v1, v2);
			env.envLocals[slot] = v;
			return if (prefix) v else v1;
		}
	}

	public static function emitCaptureReadWrite(slot:Int, exec:Emitter, fop:Value->Value->Value, prefix:Bool):Emitter {
		return function(env:Env):Value {
			var v1 = env.envCaptures[slot];
			var v2 = exec(env);
			var v = fop(v1, v2);
			env.envCaptures[slot] = v;
			return if (prefix) v else v1;
		}
	}

	static inline function protoFieldReadWrite(proto:Vprototype, i:Int, exec2:Emitter, fop:Value->Value->Value, prefix:Bool,
			env:Env):Value {
		var vf = proto.pfields[i];
		var v2 = exec2(env);
		var v = fop(vf, v2);
		proto.pfields[i] = v;
		return if (prefix) v else vf;
	}

	public static function emitProtoFieldReadWrite(proto:Vprototype, i:Int, exec2:Emitter, fop:Value->Value->Value, prefix:Bool):Emitter {
		return env -> protoFieldReadWrite(proto, i, exec2, fop, prefix, env);
	}

	public static function instanceFieldReadWrite(vi:Vinstance, i:Int, exec2:Emitter, fop:Value->Value->Value, prefix:Bool, env:Env):Value {
		var vf = vi.ifields[i];
		var v2 = exec2(env);
		var v = fop(vf, v2);
		vi.ifields[i] = v;
		return if (prefix) v else vf;
	}

	public static function emitInstanceFieldReadWrite(exec1:Emitter, p1:Pos, i:Int, exec2:Emitter, fop:Value->Value->Value,
			prefix:Bool):Emitter {
		return function(env:Env):Value {
			return switch exec1(env) {
				case VInstance(vi): instanceFieldReadWrite(vi, i, exec2, fop, prefix, env);
				case v: unexpectedValueP(v, "instance", p1);
			}
		}
	}

	public static function emitFieldReadWrite(exec1:Emitter, p1:Pos, name:Int, exec2:Emitter, fop:Value->Value->Value,
			prefix:Bool):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			return switch EvalValueTools.vresolve(v1) {
				case VObject(o):
					var vf = EvalField.objectField(o, name);
					var v2 = exec2(env);
					var v = fop(vf, v2);
					EvalMisc.setObjectField(o, name, v);
					if (prefix) v else vf;
				case VInstance(vi):
					var i = EvalContext.getInstanceFieldIndex(vi.iproto, name, Globals.nullPos);
					instanceFieldReadWrite(vi, i, exec2, fop, prefix, env);
				case VPrototype(proto):
					var i = EvalContext.getProtoFieldIndex(proto, name);
					protoFieldReadWrite(proto, i, exec2, fop, prefix, env);
				case _:
					var vf = EvalField.field(v1, name);
					var v2 = exec2(env);
					var v = fop(vf, v2);
					try EvalMisc.setField(v1, name, v)
					catch (e:RunTimeException) throw new RunTimeException(e.value, e.envs, p1);
					if (prefix) v else vf;
			}
		}
	}

	public static function emitArrayReadWrite(exec1:Emitter, p1:Pos, exec2:Emitter, p2:Pos, exec3:Emitter, fop:Value->Value->Value,
			prefix:Bool):Emitter {
		return function(env:Env):Value {
			var va = asArray(p1, exec1(env));
			var i = asInt(p2, exec2(env));
			if (i < 0) EvalMisc.throwString('Negative array index: $i', p2);
			var v = EvalArray.get(va, i);
			var v2 = exec3(env);
			var v3 = fop(v, v2);
			EvalArray.set(va, i, v3);
			return if (prefix) v3 else v;
		}
	}

	public static function emitVectorReadWrite(exec1:Emitter, p1:Pos, exec2:Emitter, p2:Pos, exec3:Emitter, fop:Value->Value->Value,
			prefix:Bool):Emitter {
		return function(env:Env):Value {
			var va = asVector(p1, exec1(env));
			var i = asInt(p2, exec2(env));
			if (i < 0) EvalMisc.throwString('Negative vector index: $i', p2);
			if (i >= va.length) outOfBounds();
			var v = va[i];
			var v2 = exec3(env);
			var v3 = fop(v, v2);
			va[i] = v3;
			return if (prefix) v3 else v;
		}
	}

	// Ops

	public static function emitEqNull(exec:Emitter):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VNull: VTrue;
				case _: VFalse;
			}
		}
	}

	public static function emitNotEqNull(exec:Emitter):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VNull: VFalse;
				case _: VTrue;
			}
		}
	}

	public static function emitOpAdd(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opAdd(p, v1, v2);
		}
	}

	public static function emitOpMult(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opMult(p, v1, v2);
		}
	}

	public static function emitOpDiv(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opDiv(p, v1, v2);
		}
	}

	public static function emitOpSub(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opSub(p, v1, v2);
		}
	}

	public static function emitOpEq(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalValueTools.vbool(EvalValueTools.equals(v1, v2));
		}
	}

	public static function emitOpNotEq(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalValueTools.vbool(!EvalValueTools.equals(v1, v2));
		}
	}

	public static function emitOpGt(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			// port: compare on two Int32s, inline
			return switch [v1, v2] {
				case [VInt32(i1), VInt32(i2)]: EvalValueTools.vbool(i1 > i2);
				case _: EvalValueTools.vbool(EvalMisc.compare(v1, v2) == CSup);
			}
		}
	}

	public static function emitOpGte(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			// port: compare on two Int32s, inline
			return switch [v1, v2] {
				case [VInt32(i1), VInt32(i2)]: EvalValueTools.vbool(i1 >= i2);
				case _: EvalValueTools.vbool(switch EvalMisc.compare(v1, v2) {
						case CSup | CEq: true;
						case _: false;
					});
			}
		}
	}

	public static function emitOpLt(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			// port: compare on two Int32s, inline
			return switch [v1, v2] {
				case [VInt32(i1), VInt32(i2)]: EvalValueTools.vbool(i1 < i2);
				case _: EvalValueTools.vbool(EvalMisc.compare(v1, v2) == CInf);
			}
		}
	}

	public static function emitOpLte(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			// port: compare on two Int32s, inline
			return switch [v1, v2] {
				case [VInt32(i1), VInt32(i2)]: EvalValueTools.vbool(i1 <= i2);
				case _: EvalValueTools.vbool(switch EvalMisc.compare(v1, v2) {
						case CInf | CEq: true;
						case _: false;
					});
			}
		}
	}

	public static function emitOpAnd(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opAnd(p, v1, v2);
		}
	}

	public static function emitOpOr(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opOr(p, v1, v2);
		}
	}

	public static function emitOpXor(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opXor(p, v1, v2);
		}
	}

	public static function emitOpShl(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opShl(p, v1, v2);
		}
	}

	public static function emitOpShr(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opShr(p, v1, v2);
		}
	}

	public static function emitOpUshr(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opUshr(p, v1, v2);
		}
	}

	public static function emitOpMod(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return EvalMisc.opMod(p, v1, v2);
		}
	}

	public static function emitNot(exec:Emitter):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VNull | VFalse: VTrue;
				case _: VFalse;
			}
		}
	}

	public static function emitBoolAnd(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			if (EvalMisc.isTrue(exec1(env))) return exec2(env);
			else return VFalse;
		}
	}

	public static function emitBoolOr(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			if (EvalMisc.isTrue(exec1(env))) return VTrue;
			else return exec2(env);
		}
	}

	public static function emitNeg(exec:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch exec(env) {
				case VFloat(f): VFloat(-f);
				case VInt32(i): EvalValueTools.vint32(-i);
				case VInt64(i): VInt64(-i);
				case _: EvalMisc.throwString("Invalid operation", p);
			}
		}
	}

	// Function

	public static function executeSetLocal(i:Int):ArgSetter return (env, v) -> env.envLocals[i] = v;

	public static function executeSetCapture(i:Int):ArgSetter return (env, v) -> env.envCaptures[i] = v;

	public static inline function processArguments(fl:Array<ArgSetter>, vl:Array<Value>, env:Env):Void {
		var nf = fl.length;
		var nv = vl.length;
		var k = 0;
		while (k < nf) {
			fl[k](env, k < nv ? vl[k] : VNull);
			k++;
		}
		if (nv > nf) EvalContext.excString('Bad number of arguments: 0 vs. ${nv - nf}');
	}

	// port: upstream wraps each call in `Std.finally (pop_environment)`. A try is a setjmp
	// on HashLink/C, so the environment is popped on normal return only; after an
	// exception, frames are popped where it is caught (emit_try, catch_exceptions)
	// before anything reads eval.env, which is the state upstream's finally leaves.
	public static function createFunctionNoret(ctx:Context, eci:EnvInfo, exec:Emitter, fl:Array<ArgSetter>):Vfunc {
		return function(vl:Array<Value>):Value {
			var env = EvalContext.pushEnvironment(ctx, eci);
			processArguments(fl, vl, env);
			var v = exec(env);
			EvalContext.popEnvironment(ctx, env);
			return v;
		}
	}

	public static function createFunction(ctx:Context, eci:EnvInfo, exec:Emitter, fl:Array<ArgSetter>):Vfunc {
		return function(vl:Array<Value>):Value {
			var env = EvalContext.pushEnvironment(ctx, eci);
			processArguments(fl, vl, env);
			var v = try exec(env) catch (r:Return) r.value;
			EvalContext.popEnvironment(ctx, env);
			return v;
		}
	}

	public static function createClosureNoret(ctx:Context, eci:EnvInfo, refSlots:Vector<Int>, refValues:Vector<Value>, exec:Emitter,
			fl:Array<ArgSetter>):Vfunc {
		return function(vl:Array<Value>):Value {
			var env = EvalContext.pushEnvironment(ctx, eci);
			for (k in 0...refSlots.length) env.envCaptures[refSlots[k]] = refValues[k];
			processArguments(fl, vl, env);
			var v = exec(env);
			EvalContext.popEnvironment(ctx, env);
			return v;
		}
	}

	public static function createClosure(refSlots:Vector<Int>, refValues:Vector<Value>, ctx:Context, eci:EnvInfo, exec:Emitter,
			fl:Array<ArgSetter>):Vfunc {
		return function(vl:Array<Value>):Value {
			var env = EvalContext.pushEnvironment(ctx, eci);
			for (k in 0...refSlots.length) env.envCaptures[refSlots[k]] = refValues[k];
			processArguments(fl, vl, env);
			var v = try exec(env) catch (r:Return) r.value;
			EvalContext.popEnvironment(ctx, env);
			return v;
		}
	}

	// port: [mapping] is upstream's `(i, slot) array`, as two parallel arrays: the
	// closure's capture slots [mappingI] and the outer capture slots [mappingSlot].
	public static function emitClosure(ctx:Context, mappingI:Vector<Int>, mappingSlot:Vector<Int>, eci:EnvInfo, hasret:Bool, exec:Emitter,
			fl:Array<ArgSetter>):Emitter {
		return function(env:Env):Value {
			var refValues = new Vector<Value>(mappingSlot.length);
			for (k in 0...mappingSlot.length) refValues[k] = env.envCaptures[mappingSlot[k]];
			var f = if (hasret && eci.numCaptures == 0) createFunction(ctx, eci, exec,
				fl) else if (!hasret && eci.numCaptures == 0) createFunctionNoret(ctx, eci, exec,
				fl) else createClosure(mappingI, refValues, ctx, eci, exec, fl);
			return EvalValueTools.vstaticFunction(f);
		}
	}
}
