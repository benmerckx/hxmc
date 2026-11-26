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

// port: the closures of the conditions (`env -> bool`).
typedef Cond = Env->Bool;

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

// port: an entry of the inline cache of `emitMethodCall`.
class MethodCache {
	public final proto:Vprototype;
	public final owner:Vprototype;
	public final slot:Int;

	public inline function new(proto:Vprototype, owner:Vprototype, slot:Int) {
		this.proto = proto;
		this.owner = owner;
		this.slot = slot;
	}
}

// port: deviations:
// - OCaml partial application (`emit_x a b env`) becomes a function of the
//   compile-time arguments returning an `Emitter` closure. Emitters that upstream
//   uses unapplied (`emit_null`, `emit_new_array`, `emit_return_null`,
//   `emit_break`, `emit_continue`) are static `Emitter` values.
// - A function pops its environment on normal return only (see
//   createFunctionNoret).
// - `emit_closure`/`create_closure`: the `(slot, value) array` of captured
//   references is split into a slot array (computed once at JIT time) and a value
//   array (filled per closure creation), which avoids one tuple per capture.
// - Out-of-bounds `Array.unsafe_get`/`unsafe_set` on vectors is undefined in
//   upstream; a Haxe array would return null or grow, so these raise
//   `Invalid_argument "index out of bounds"` (OCaml's checked-access error), as
//   does the checked `ev.eargs.(i)` of `emit_enum_parameter_read`.
// - `Array.make`'s `Invalid_argument` for sizes above `Sys.max_array_length`
//   cannot happen for 32-bit sizes, so that branch of `new_vector` is
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
			case VInt(i): i;
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
			case VInt(i): i;
			case VFloat(f): Std.int(f);
			case _: unexpectedValueP(v, "int", p);
		}
	}

	public static inline function checkStackDepth(maxDepth:Int, env:Env):Void {
		if (env.envStackDepth > maxDepth) EvalContext.excString("Stack overflow");
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

	// port: `emit_args` (the arguments of a call, evaluated from left to right),
	// applied per call: up to three arguments as an array literal (one allocation
	// at its size).
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

	// The values of [execs], evaluated in order.
	// port: `eval_array`
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

	public static function emitLocalNullCheck(slot:Int, p:Pos):Emitter {
		return function(env:Env):Value {
			return switch env.envLocals[slot] {
				case VNull: EvalMisc.throwString("Null Access", p);
				case v: v;
			}
		}
	}

	public static final emitNewArray:Emitter = _ -> EvalEncode.encodeArrayInstance(EvalArray.create(new Vector(0)));

	public static function newVector(i:Int, p:Pos):Value {
		if (i < 0) EvalContext.excStringP("Vector size must be >= 0", p);
		var a = new Vector<Value>(i, VNull);
		return EvalEncode.encodeVectorInstance(a);
	}

	public static function emitNewVectorInt(i:Int, p:Pos):Emitter return _ -> newVector(i, p);

	public static function emitNewVector(exec:Emitter, p:Pos):Emitter {
		return function(env:Env):Value {
			var i = decodeIntP(exec(env), p);
			return newVector(i, p);
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
				case VInt(i):
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
				case VInt(i32):
					var i = i32 + shift;
					if (i >= cases.length || i < 0) execDef(env) else cases[i](env);
				case VNull:
					execDef(env);
				case v:
					unexpectedValueP(v, "int", p);
			}
		}
	}

	public static function emitTry(exec:Emitter, catches:Array<TryCatch>):Emitter {
		return function(env:Env):Value {
			var ctx = EvalContext.getCtx();
			var eval = env.envEval;
			// the caught types are only registered for the debugger
			var debugger = ctx.debug.supportDebugger;
			if (debugger) {
				for (c in catches) eval.caughtTypes.set(c.path, true);
			}
			inline function restore() {
				if (debugger) for (c in catches) eval.caughtTypes.remove(c.path);
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

	public static function emitSuperFieldCall(maxDepth:Int, slot:Int, proto:Vprototype, i:Int, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
			var vthis = env.envLocals[slot];
			var vf = proto.pfields[i];
			var vl = applyAllOn(vthis, vf, execs, env);
			return callOn(vf, vl);
		}
	}

	// Type.call() - immediate

	public static function emitProtoFieldCall(maxDepth:Int, v:AtomicLazy<Vfunc>, execs:Array<Emitter>, p:Pos):Emitter {
		// port: forced once per call site: reading the generic AtomicLazy's value back as a
		// function is a dynamic cast on HashLink.
		var forced:Null<Vfunc> = null;
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
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

	// port: not at the pinned commit: upstream's inline cache of method calls (haxe6
	// work, HaxeFoundation/haxe 7f7195da). The prototype a call site last saw, with
	// the prototype declaring the method and its slot (a monomorphic inline cache).
	// An entry is immutable: a thread reading the cache while another one changes it
	// sees either entry.
	static function findMethod(proto:Vprototype, name:Int, p:Pos):MethodCache {
		var owner = proto;
		while (true) {
			var i = owner.pnames.findOpt(name);
			if (i != null) return new MethodCache(proto, owner, i);
			owner = owner.pparent;
			if (owner == null)
				EvalMisc.throwString('Field ${EvalHash.revHash(name)} not found on prototype ${EvalHash.revHash(proto.ppath)}', p);
		}
	}

	public static function emitMethodCall(maxDepth:Int, exec:Emitter, name:Int, execs:Array<Emitter>, p:Pos):Emitter {
		var cache:Null<MethodCache> = null;
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
			var vthis = exec(env);
			var proto = getPrototype(vthis, p);
			var c = cache;
			if (c == null || c.proto != proto) c = cache = findMethod(proto, name, p);
			var vf = c.owner.pfields[c.slot];
			var vl = applyAllOn(vthis, vf, execs, env);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			return callOn(vf, vl);
		}
	}

	// instance.call() where call is not a method - lookup + this-binding

	public static function emitFieldCall(maxDepth:Int, exec:Emitter, name:Int, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
			var vthis = exec(env);
			var vf = EvalField.field(vthis, name);
			env.envLeavePmin = p.pmin;
			env.envLeavePmax = p.pmax;
			return callOn(vf, applyAllOn(vthis, vf, execs, env));
		}
	}

	// new() - immediate + this-binding

	public static function emitConstructorCall(maxDepth:Int, proto:Vprototype, v:AtomicLazy<Vfunc>, execs:Array<Emitter>, p:Pos):Emitter {
		// port: forced once per call site: reading the generic AtomicLazy's value back as a
		// function is a dynamic cast on HashLink.
		var forced:Null<Vfunc> = null;
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
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

	public static function emitSpecialSuperCall(maxDepth:Int, fnew:Array<Value>->Value, execs:Array<Emitter>):Emitter {
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
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

	public static function emitSuperCall(maxDepth:Int, v:AtomicLazy<Vfunc>, execs:Array<Emitter>, p:Pos):Emitter {
		// port: forced once per call site: reading the generic AtomicLazy's value back as a
		// function is a dynamic cast on HashLink.
		var forced:Null<Vfunc> = null;
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
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

	public static function emitCall(maxDepth:Int, exec:Emitter, execs:Array<Emitter>, p:Pos):Emitter {
		return function(env:Env):Value {
			checkStackDepth(maxDepth, env);
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

	public static function emitLocalArrayLengthRead(slot:Int,
			p:Pos):Emitter return env -> EvalValueTools.vint32(asArray(p, env.envLocals[slot]).alength);

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

	public static function emitLocalInstanceFieldRead(slot:Int, p:Pos, i:Int):Emitter {
		return function(env:Env):Value {
			return switch env.envLocals[slot] {
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

	static inline function anonFieldRead(proto:Vprototype, i:Int, name:Int, p:Pos, v:Value):Value {
		return switch EvalValueTools.vresolve(v) {
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

	public static function emitAnonFieldRead(exec:Emitter, proto:Vprototype, i:Int, name:Int, p:Pos):Emitter {
		return env -> anonFieldRead(proto, i, name, p, exec(env));
	}

	public static function emitLocalAnonFieldRead(slot:Int, proto:Vprototype, i:Int, name:Int, p:Pos):Emitter {
		return env -> anonFieldRead(proto, i, name, p, env.envLocals[slot]);
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

	public static function emitArrayReadLl(slot1:Int, p1:Pos, slot2:Int, p2:Pos):Emitter {
		return function(env:Env):Value {
			var a = asArray(p1, env.envLocals[slot1]);
			var i = asInt(p2, env.envLocals[slot2]);
			if (i < 0) return VNull;
			else return EvalArray.get(a, i);
		}
	}

	public static function emitArrayReadLe(slot1:Int, p1:Pos, exec2:Emitter, p2:Pos):Emitter {
		return function(env:Env):Value {
			var a = asArray(p1, env.envLocals[slot1]);
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

	public static function emitLocalEnumIndex(slot:Int, p:Pos):Emitter return env -> EvalValueTools.vint32(asEnumValue(p, env.envLocals[slot]).eindex);

	public static function emitLocalEnumParameterRead(slot:Int, i:Int):Emitter {
		return function(env:Env):Value {
			return switch env.envLocals[slot] {
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

	public static function emitLocalInstanceFieldWrite(slot:Int, p:Pos, i:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			return switch env.envLocals[slot] {
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
			case VInt(i32): EvalValueTools.vint32(i32 + 1);
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

	// Arithmetic, with the same operand variants as the conditions (below).

	static inline function arithAdd(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: EvalValueTools.vint32(a + b);
			case [VFloat(a), VFloat(b)]: VFloat(a + b);
			case _: EvalMisc.opAdd(p, v1, v2);
		}
	}

	public static function emitOpAdd(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithAdd(p, v1, v2);
		}
	}

	public static function emitOpAddLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithAdd(p, v1, v2);
		}
	}

	public static function emitOpAddLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithAdd(p, env.envLocals[slot], v2);

	public static function emitOpAddLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithAdd(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpAddEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithAdd(p, exec1(env), v2);

	// [local op= exec]
	public static function emitLocalAssignAdd(p:Pos, slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = arithAdd(p, v1, v2);
			env.envLocals[slot] = v;
			return v;
		}
	}

	static inline function arithSub(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: EvalValueTools.vint32(a - b);
			case [VFloat(a), VFloat(b)]: VFloat(a - b);
			case _: EvalMisc.opSub(p, v1, v2);
		}
	}

	public static function emitOpSub(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithSub(p, v1, v2);
		}
	}

	public static function emitOpSubLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithSub(p, v1, v2);
		}
	}

	public static function emitOpSubLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithSub(p, env.envLocals[slot], v2);

	public static function emitOpSubLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithSub(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpSubEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithSub(p, exec1(env), v2);

	// [local op= exec]
	public static function emitLocalAssignSub(p:Pos, slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = arithSub(p, v1, v2);
			env.envLocals[slot] = v;
			return v;
		}
	}

	static inline function arithMult(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: EvalValueTools.vint32(a * b);
			case [VFloat(a), VFloat(b)]: VFloat(a * b);
			case _: EvalMisc.opMult(p, v1, v2);
		}
	}

	public static function emitOpMult(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithMult(p, v1, v2);
		}
	}

	public static function emitOpMultLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithMult(p, v1, v2);
		}
	}

	public static function emitOpMultLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithMult(p, env.envLocals[slot], v2);

	public static function emitOpMultLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithMult(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpMultEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithMult(p, exec1(env), v2);

	// [local op= exec]
	public static function emitLocalAssignMult(p:Pos, slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = arithMult(p, v1, v2);
			env.envLocals[slot] = v;
			return v;
		}
	}

	static inline function arithDiv(p:Pos, v1:Value, v2:Value):Value {
		return EvalMisc.opDiv(p, v1, v2);
	}

	public static function emitOpDiv(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithDiv(p, v1, v2);
		}
	}

	public static function emitOpDivLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithDiv(p, v1, v2);
		}
	}

	public static function emitOpDivLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithDiv(p, env.envLocals[slot], v2);

	public static function emitOpDivLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithDiv(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpDivEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithDiv(p, exec1(env), v2);

	static inline function arithAnd(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VInt(a & b);
			case _: EvalMisc.opAnd(p, v1, v2);
		}
	}

	public static function emitOpAnd(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithAnd(p, v1, v2);
		}
	}

	public static function emitOpAndLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithAnd(p, v1, v2);
		}
	}

	public static function emitOpAndLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithAnd(p, env.envLocals[slot], v2);

	public static function emitOpAndLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithAnd(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpAndEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithAnd(p, exec1(env), v2);

	// [local op= exec]
	public static function emitLocalAssignAnd(p:Pos, slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = arithAnd(p, v1, v2);
			env.envLocals[slot] = v;
			return v;
		}
	}

	static inline function arithOr(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VInt(a | b);
			case _: EvalMisc.opOr(p, v1, v2);
		}
	}

	public static function emitOpOr(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithOr(p, v1, v2);
		}
	}

	public static function emitOpOrLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithOr(p, v1, v2);
		}
	}

	public static function emitOpOrLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithOr(p, env.envLocals[slot], v2);

	public static function emitOpOrLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithOr(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpOrEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithOr(p, exec1(env), v2);

	// [local op= exec]
	public static function emitLocalAssignOr(p:Pos, slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = arithOr(p, v1, v2);
			env.envLocals[slot] = v;
			return v;
		}
	}

	static inline function arithXor(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: VInt(a ^ b);
			case _: EvalMisc.opXor(p, v1, v2);
		}
	}

	public static function emitOpXor(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithXor(p, v1, v2);
		}
	}

	public static function emitOpXorLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithXor(p, v1, v2);
		}
	}

	public static function emitOpXorLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithXor(p, env.envLocals[slot], v2);

	public static function emitOpXorLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithXor(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpXorEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithXor(p, exec1(env), v2);

	// [local op= exec]
	public static function emitLocalAssignXor(p:Pos, slot:Int, exec:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec(env);
			var v = arithXor(p, v1, v2);
			env.envLocals[slot] = v;
			return v;
		}
	}

	static inline function arithShl(p:Pos, v1:Value, v2:Value):Value {
		return EvalMisc.opShl(p, v1, v2);
	}

	public static function emitOpShl(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithShl(p, v1, v2);
		}
	}

	public static function emitOpShlLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithShl(p, v1, v2);
		}
	}

	public static function emitOpShlLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithShl(p, env.envLocals[slot], v2);

	public static function emitOpShlLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithShl(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpShlEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithShl(p, exec1(env), v2);

	static inline function arithShr(p:Pos, v1:Value, v2:Value):Value {
		return EvalMisc.opShr(p, v1, v2);
	}

	public static function emitOpShr(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithShr(p, v1, v2);
		}
	}

	public static function emitOpShrLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithShr(p, v1, v2);
		}
	}

	public static function emitOpShrLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithShr(p, env.envLocals[slot], v2);

	public static function emitOpShrLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithShr(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpShrEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithShr(p, exec1(env), v2);

	static inline function arithUshr(p:Pos, v1:Value, v2:Value):Value {
		return EvalMisc.opUshr(p, v1, v2);
	}

	public static function emitOpUshr(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithUshr(p, v1, v2);
		}
	}

	public static function emitOpUshrLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithUshr(p, v1, v2);
		}
	}

	public static function emitOpUshrLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithUshr(p, env.envLocals[slot], v2);

	public static function emitOpUshrLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithUshr(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpUshrEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithUshr(p, exec1(env), v2);

	static inline function arithMod(p:Pos, v1:Value, v2:Value):Value {
		return EvalMisc.opMod(p, v1, v2);
	}

	public static function emitOpMod(p:Pos, exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return arithMod(p, v1, v2);
		}
	}

	public static function emitOpModLe(p:Pos, slot:Int, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return arithMod(p, v1, v2);
		}
	}

	public static function emitOpModLc(p:Pos, slot:Int, v2:Value):Emitter return env -> arithMod(p, env.envLocals[slot], v2);

	public static function emitOpModLl(p:Pos, slot1:Int, slot2:Int):Emitter return env -> arithMod(p, env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitOpModEc(p:Pos, exec1:Emitter, v2:Value):Emitter return env -> arithMod(p, exec1(env), v2);

	public static function emitOpEq(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return switch [v1, v2] {
				case [VInt(a), VInt(b)]: EvalValueTools.vbool(a == b);
				case _: EvalValueTools.vbool(EvalValueTools.equals(v1, v2));
			}
		}
	}

	public static function emitOpNotEq(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return switch [v1, v2] {
				case [VInt(a), VInt(b)]: EvalValueTools.vbool(a != b);
				case _: EvalValueTools.vbool(!EvalValueTools.equals(v1, v2));
			}
		}
	}

	public static function emitOpGt(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return switch [v1, v2] {
				case [VInt(a), VInt(b)]: EvalValueTools.vbool(a > b);
				case [VFloat(a), VFloat(b)]: EvalValueTools.vbool(a > b);
				case _: EvalValueTools.vbool(EvalMisc.compare(v1, v2) == CSup);
			}
		}
	}

	public static function emitOpGte(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return switch [v1, v2] {
				case [VInt(a), VInt(b)]: EvalValueTools.vbool(a >= b);
				case [VFloat(a), VFloat(b)]: EvalValueTools.vbool(a >= b);
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
			return switch [v1, v2] {
				case [VInt(a), VInt(b)]: EvalValueTools.vbool(a < b);
				case [VFloat(a), VFloat(b)]: EvalValueTools.vbool(a < b);
				case _: EvalValueTools.vbool(EvalMisc.compare(v1, v2) == CInf);
			}
		}
	}

	public static function emitOpLte(exec1:Emitter, exec2:Emitter):Emitter {
		return function(env:Env):Value {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return switch [v1, v2] {
				case [VInt(a), VInt(b)]: EvalValueTools.vbool(a <= b);
				case [VFloat(a), VFloat(b)]: EvalValueTools.vbool(a <= b);
				case _: EvalValueTools.vbool(switch EvalMisc.compare(v1, v2) {
						case CInf | CEq: true;
						case _: false;
					});
			}
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
				case VInt(i): EvalValueTools.vint32(-i);
				case VInt64(i): VInt64(-i);
				case _: EvalMisc.throwString("Invalid operation", p);
			}
		}
	}

	/* Conditions

		A condition is compiled to a closure giving a bool: [cond e] is
		[is_true (exec e)], with the same evaluation, without building and matching
		a Bool value. Comparisons have variants for a local operand ([l]) and a
		constant one ([c]), read without calling a closure. */

	public static function emitCondValue(exec:Emitter):Cond return env -> EvalMisc.isTrue(exec(env));

	public static function emitCondNot(exec:Emitter):Cond {
		return function(env:Env):Bool {
			return switch exec(env) {
				case VNull | VFalse: true;
				case _: false;
			}
		}
	}

	public static function emitCondNotCond(cond:Cond):Cond return env -> !cond(env);

	public static function emitCondAnd(cond1:Cond, cond2:Cond):Cond return env -> cond1(env) && cond2(env);

	public static function emitCondOr(cond1:Cond, cond2:Cond):Cond return env -> cond1(env) || cond2(env);

	public static function emitCondEqNull(exec:Emitter):Cond return env -> exec(env).match(VNull);

	public static function emitCondNotEqNull(exec:Emitter):Cond return env -> !exec(env).match(VNull);

	public static function emitCondLocalEqNull(slot:Int):Cond return env -> env.envLocals[slot].match(VNull);

	public static function emitCondLocalNotEqNull(slot:Int):Cond return env -> !env.envLocals[slot].match(VNull);

	static inline function condLt(v1:Value, v2:Value):Bool {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: a < b;
			case [VFloat(a), VFloat(b)]: a < b;
			case _: EvalMisc.compare(v1, v2) == CInf;
		}
	}

	public static function emitCondLt(exec1:Emitter, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return condLt(v1, v2);
		}
	}

	public static function emitCondLtLe(slot:Int, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return condLt(v1, v2);
		}
	}

	public static function emitCondLtLc(slot:Int, v2:Value):Cond return env -> condLt(env.envLocals[slot], v2);

	public static function emitCondLtLl(slot1:Int, slot2:Int):Cond return env -> condLt(env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitCondLtEc(exec1:Emitter, v2:Value):Cond return env -> condLt(exec1(env), v2);

	static inline function condLte(v1:Value, v2:Value):Bool {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: a <= b;
			case [VFloat(a), VFloat(b)]: a <= b;
			case _: switch EvalMisc.compare(v1, v2) {
					case CInf | CEq: true;
					case _: false;
				};
		}
	}

	public static function emitCondLte(exec1:Emitter, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return condLte(v1, v2);
		}
	}

	public static function emitCondLteLe(slot:Int, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return condLte(v1, v2);
		}
	}

	public static function emitCondLteLc(slot:Int, v2:Value):Cond return env -> condLte(env.envLocals[slot], v2);

	public static function emitCondLteLl(slot1:Int, slot2:Int):Cond return env -> condLte(env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitCondLteEc(exec1:Emitter, v2:Value):Cond return env -> condLte(exec1(env), v2);

	static inline function condGt(v1:Value, v2:Value):Bool {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: a > b;
			case [VFloat(a), VFloat(b)]: a > b;
			case _: EvalMisc.compare(v1, v2) == CSup;
		}
	}

	public static function emitCondGt(exec1:Emitter, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return condGt(v1, v2);
		}
	}

	public static function emitCondGtLe(slot:Int, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return condGt(v1, v2);
		}
	}

	public static function emitCondGtLc(slot:Int, v2:Value):Cond return env -> condGt(env.envLocals[slot], v2);

	public static function emitCondGtLl(slot1:Int, slot2:Int):Cond return env -> condGt(env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitCondGtEc(exec1:Emitter, v2:Value):Cond return env -> condGt(exec1(env), v2);

	static inline function condGte(v1:Value, v2:Value):Bool {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: a >= b;
			case [VFloat(a), VFloat(b)]: a >= b;
			case _: switch EvalMisc.compare(v1, v2) {
					case CSup | CEq: true;
					case _: false;
				};
		}
	}

	public static function emitCondGte(exec1:Emitter, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return condGte(v1, v2);
		}
	}

	public static function emitCondGteLe(slot:Int, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return condGte(v1, v2);
		}
	}

	public static function emitCondGteLc(slot:Int, v2:Value):Cond return env -> condGte(env.envLocals[slot], v2);

	public static function emitCondGteLl(slot1:Int, slot2:Int):Cond return env -> condGte(env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitCondGteEc(exec1:Emitter, v2:Value):Cond return env -> condGte(exec1(env), v2);

	static inline function condEq(v1:Value, v2:Value):Bool {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: a == b;
			case _: EvalValueTools.equals(v1, v2);
		}
	}

	public static function emitCondEq(exec1:Emitter, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return condEq(v1, v2);
		}
	}

	public static function emitCondEqLe(slot:Int, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return condEq(v1, v2);
		}
	}

	public static function emitCondEqLc(slot:Int, v2:Value):Cond return env -> condEq(env.envLocals[slot], v2);

	public static function emitCondEqLl(slot1:Int, slot2:Int):Cond return env -> condEq(env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitCondEqEc(exec1:Emitter, v2:Value):Cond return env -> condEq(exec1(env), v2);

	static inline function condNeq(v1:Value, v2:Value):Bool {
		return switch [v1, v2] {
			case [VInt(a), VInt(b)]: a != b;
			case _: !EvalValueTools.equals(v1, v2);
		}
	}

	public static function emitCondNeq(exec1:Emitter, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = exec1(env);
			var v2 = exec2(env);
			return condNeq(v1, v2);
		}
	}

	public static function emitCondNeqLe(slot:Int, exec2:Emitter):Cond {
		return function(env:Env):Bool {
			var v1 = env.envLocals[slot];
			var v2 = exec2(env);
			return condNeq(v1, v2);
		}
	}

	public static function emitCondNeqLc(slot:Int, v2:Value):Cond return env -> condNeq(env.envLocals[slot], v2);

	public static function emitCondNeqLl(slot1:Int, slot2:Int):Cond return env -> condNeq(env.envLocals[slot1], env.envLocals[slot2]);

	public static function emitCondNeqEc(exec1:Emitter, v2:Value):Cond return env -> condNeq(exec1(env), v2);

	public static function emitIfCond(cond:Cond, execThen:Emitter, execElse:Emitter):Emitter {
		return env -> if (cond(env)) execThen(env) else execElse(env);
	}

	// port: the tail recursion on `Continue` is a loop.
	public static function runWhileCondContinue(cond:Cond, execBody:Emitter, env:Env):Void {
		while (true) {
			try {
				while (cond(env)) {
					execBody(env);
					core.ds.GcPolicy.tick(); // port: loops allocate without calls or typing
					EvalLock.tick();
				}
				return;
			} catch (_:Continue) {}
		}
	}

	public static function emitWhileCond(cond:Cond, execBody:Emitter):Emitter {
		return function(env:Env):Value {
			try runWhileCondContinue(cond, execBody, env)
			catch (_:Break) {}
			return VNull;
		}
	}

	public static function emitDoWhileCond(cond:Cond, execBody:Emitter):Emitter {
		return function(env:Env):Value {
			try {
				execBody(env);
				runWhileCondContinue(cond, execBody, env);
			} catch (_:Break) {} catch (_:Continue) {
				try runWhileCondContinue(cond, execBody, env)
				catch (_:Break) {}
			}
			return VNull;
		}
	}

	// Function

	/* The parameters of a function are the slots of its arguments: a local slot,
		or [-1 - slot] for a captured one. */
	public static inline function paramLocal(slot:Int):Int return slot;

	public static inline function paramCapture(slot:Int):Int return -1 - slot;

	static inline function setArgument(params:Vector<Int>, k:Int, env:Env, v:Value):Void {
		var slot = params[k];
		if (slot >= 0) env.envLocals[slot] = v else env.envCaptures[-1 - slot] = v;
	}

	// port: `set_arguments` over the argument array
	public static inline function processArguments(params:Vector<Int>, vl:Array<Value>, env:Env):Void {
		var nf = params.length;
		var nv = vl.length;
		var k = 0;
		while (k < nf) {
			setArgument(params, k, env, k < nv ? vl[k] : VNull);
			k++;
		}
		if (nv > nf) EvalContext.excString('Bad number of arguments: 0 vs. ${nv - nf}');
	}

	/* The functions run their body in an environment of their own, popped however
		the body ends. */
	// port: a try is a setjmp on HashLink/C, so the environment is popped on normal
	// return only; after an exception, frames are popped where it is caught
	// (emit_try, catch_exceptions) before anything reads eval.env, which is the
	// state upstream's handlers leave.
	public static function createFunctionNoret(ctx:Context, eci:EnvInfo, exec:Emitter, fl:Vector<Int>):Vfunc {
		return function(vl:Array<Value>):Value {
			var env = EvalContext.pushEnvironment(ctx, eci);
			processArguments(fl, vl, env);
			var v = exec(env);
			EvalContext.popEnvironment(ctx, env);
			return v;
		}
	}

	public static function createFunction(ctx:Context, eci:EnvInfo, exec:Emitter, fl:Vector<Int>):Vfunc {
		return function(vl:Array<Value>):Value {
			var env = EvalContext.pushEnvironment(ctx, eci);
			processArguments(fl, vl, env);
			var v = try exec(env) catch (r:Return) r.value;
			EvalContext.popEnvironment(ctx, env);
			return v;
		}
	}

	public static function createClosureNoret(ctx:Context, eci:EnvInfo, refSlots:Vector<Int>, refValues:Vector<Value>, exec:Emitter,
			fl:Vector<Int>):Vfunc {
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
			fl:Vector<Int>):Vfunc {
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
			fl:Vector<Int>):Emitter {
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
