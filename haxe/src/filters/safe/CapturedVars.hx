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

package filters.safe;

import context.PlatformConfig;
import core.TType;
import core.TFunctions as TypeOps;
import core.Texpr;
import filters.LocalUsage;
import haxe.ds.IntMap;

using core.ds.VectorTools;

// port: persistent-map snapshots use copies. Sorted integer keys retain OCaml PMap fold order.
class CapturedVars {
	static function ids<T>(m:IntMap<T>):Array<Int> {
		var a = [for (i in m.keys()) i];
		a.sort((a, b) -> a - b);
		return a;
	}

	// BLOCK VARIABLES CAPTURE
	/*
		For some platforms, it will simply mark the variables which are used in closures
		using the v_capture flag so it can be processed in a more optimized

		For Flash/JS platforms, it will ensure that variables used in loop sub-functions
		have an unique scope. It transforms the following expression :

		for( x in array )
			funs.push(function() return x++);

		Into the following :

		for( _x in array ) {
			var x = [_x];
			funs.push(function(x) { function() return x[0]++; }(x));
		}
	*/
	public static function capturedVars(scom:context.SafeCom.SafeContext, impl:context.Common.LocalWrapperApi, forCoro:Bool,
			e:TExpr):TExpr {
		inline function mkVar(v:TVar, used:IntMap<T>):TVar {
			if (!used.exists(v.vId)) throw "Not_found";
			var v2 = TypeOps.allocVar(v.vKind, v.vName, used.get(v.vId), v.vPos);
			v2.vMeta = v.vMeta;
			return v2;
		}
		function wrap(used:IntMap<T>, e:TExpr):TExpr {
			var def:TExprDef = switch e.eexpr {
				case TVar(v, ve):
					var ve = ve == null ? null : wrap(used, ve);
					TVar(v, used.exists(v.vId) ? impl.mkRef(v, ve, e.epos) : ve);
				case TLocal(v) if (used.exists(v.vId)): return impl.mkRefAccess(e, v);
				case TTry(expr, catches):
					var catches = catches.map(function(c) {
						var body = wrap(used, c.expr);
						if (!used.exists(c.variable.vId)) return {variable: c.variable, expr: body};
						var vtmp = mkVar(c.variable, used);
						return {variable: vtmp, expr: TypeOps.concat(impl.mkInit(c.variable, vtmp, body.epos), body)};
					});
					TTry(wrap(used, expr), catches);
				case TFunction(f):
					/*
						list variables that are marked as used, but also used in that
						function and which are not declared inside it !
					*/
					var fused = new IntMap<TVar>();
					var tmpUsed = used.copy();
					function browse(u:Usage):Void switch u {
						case Block(f) | Loop(f) | Function(f):
							f(browse);
						case Use(v) | Assign(v):
							if (tmpUsed.exists(v.vId)) fused.set(v.vId, v);
						case Declare(v):
							tmpUsed.remove(v.vId);
					}
					LocalUsage.localUsage(browse, e);
					var vars:Array<TVar> = [];
					for (id in ids(fused)) vars.unshift(fused.get(id));
					// in case the variable has been marked as used in a parallel scope...
					var fexpr = wrap(used, f.tfExpr);
					var fargs = f.tfArgs.map(function(a) {
						if (!used.exists(a.variable.vId)) return a;
						var vtmp = mkVar(a.variable, used);
						fexpr = TypeOps.concat(impl.mkInit(a.variable, vtmp, e.epos), fexpr);
						return {variable: vtmp, defaultValue: a.defaultValue};
					});
					var e = TypeOps.mk(TFunction(({tfArgs: fargs, tfType: f.tfType, tfExpr: fexpr} : core.TType.TFunc)), e.etype, e.epos);
					/*
						Create a new function scope to make sure that the captured loop variable
						will not be overwritten in next loop iteration
					*/
					if (scom.platformConfig.pfCapturePolicy != CPLoopVars) return e;
					// We don't want to duplicate any variable declarations, so let's make copies (issue #3902).
					var newVars = vars.map(v -> {id: v.vId, variable: TypeOps.allocVar(v.vKind, v.vName, v.vType, v.vPos)});
					function loop(e:TExpr):TExpr return switch e.eexpr {
						case TLocal(v):
							var vnew:Null<TVar> = null;
							for (entry in newVars) if (entry.id == v.vId) {
								vnew = entry.variable;
								break;
							}
							if (vnew == null) e; else {
								TypeOps.addVarFlag(vnew, VCaptured);
								TypeOps.mk(TLocal(vnew), e.etype, e.epos);
							}
						case _: core.Texpr.mapExpr(loop, e);
					};
					e = loop(e);
					var fn:TFunc = {
						tfArgs: newVars.mapToVector(a -> ({variable: a.variable, defaultValue: null} : {variable:TVar, defaultValue:Null<TExpr>})),
						tfType: e.etype,
						tfExpr: TypeOps.mkBlock(TypeOps.mk(TReturn(e), e.etype, e.epos))
					};
					var ft = TFun({
						args: newVars.mapToVector(a -> {name: a.variable.vName, optional: false, type: a.variable.vType}),
						ret: e.etype
					});
					return TypeOps.mk(TCall(Texpr.Builder.mkParent(TypeOps.mk(TFunction(fn), ft, e.epos)),
						vars.mapToVector(v -> TypeOps.mk(TLocal(v), v.vType, e.epos))),
						e.etype, e.epos);
				case _: return core.Texpr.mapExprWith(wrap, used, e);
			};
			return TypeOps.mk(def, e.etype, e.epos);
		}
		inline function doWrap(used:IntMap<TVar>, e:TExpr):TExpr {
			var keys = ids(used);
			if (keys.length == 0) return e;
			var types = new IntMap<T>();
			for (id in keys) {
				var v = used.get(id);
				var vt = v.vType;
				v.vType = impl.capturedType(vt);
				TypeOps.addVarFlag(v, VCaptured);
				if (forCoro) TypeOps.addVarFlag(v, VCoroCaptured);
				types.set(id, vt);
			}
			return wrap(types, e);
		}
		function outLoop(e:TExpr):TExpr {
			switch e.eexpr {
				case TWhile(_, _, _):
					/*
						collect variables that are declared in loop but used in subfunctions
					*/
					var vars = new core.ds.ScopedIntMap();
					var used = new IntMap<TVar>();
					var depth = 0;
					function collectVars(inLoop:Bool, u:Usage):Void switch u {
						case Block(f):
							var old = vars.mark();
							f(u -> collectVars(inLoop, u));
							vars.rollback(old);
						case Loop(f):
							var old = vars.mark();
							f(u -> collectVars(true, u));
							vars.rollback(old);
						case Function(f):
							++depth;
							f(u -> collectVars(false, u));
							--depth;
						case Declare(v):
							if (inLoop) vars.set(v.vId, depth);
						case Use(v) | Assign(v):
							if (vars.exists(v.vId) && vars.get(v.vId) != depth) used.set(v.vId, v);
					}
					LocalUsage.localUsage(u -> collectVars(false, u), e);
					return doWrap(used, e);
				case _:
					return core.Texpr.mapExpr(outLoop, e);
			}
		}
		inline function allVars(e:TExpr):IntMap<TVar> {
			// port: scoped maps: restoring a saved PMap is a rollback rather than a copy per scope.
			var vars = new core.ds.ScopedIntMap();
			var used = new IntMap<TVar>();
			var inLoop = false;
			var loopVars = new core.ds.ScopedIntMap(); // port: 1 when assigned
			var assigned = new IntMap<TVar>();
			var depth = 0;
			inline function markAssigned(v:TVar):Void {
				assigned.set(v.vId, v);
				// Remove from vars lookup because we're done with it
				vars.remove(v.vId);
			}
			inline function checkLoopVar(v:TVar, isAssign:Bool):Void {
				if (!inLoop) return;
				if (loopVars.exists(v.vId)) {
					// If we have both read and write in the same loop we need to wrap.
					if (isAssign != (loopVars.get(v.vId) == 1)) markAssigned(v);
				} else loopVars.set(v.vId, isAssign ? 1 : 0);
			}
			function collectVars(u:Usage):Void switch u {
				case Block(f):
					var old = vars.mark();
					f(collectVars);
					vars.rollback(old);
				case Loop(f):
					var old = vars.mark();
					var oldLoopVars = loopVars.mark();
					var oldLoop = inLoop;
					inLoop = true;
					f(collectVars);
					inLoop = oldLoop;
					loopVars.rollback(oldLoopVars);
					vars.rollback(old);
				case Function(f):
					++depth;
					f(collectVars);
					--depth;
				case Declare(v) if (!forCoro && TypeOps.hasVarFlag(v, VCoroCaptured)):
				case Declare(v):
					vars.set(v.vId, depth);
				case Use(v):
					if (vars.exists(v.vId) && vars.get(v.vId) != depth) {
						checkLoopVar(v, false);
						used.set(v.vId, v);
					}
				case Assign(v):
					if (vars.exists(v.vId)) {
						// different depth - needs wrap
						if (vars.get(v.vId) != depth) {
							used.set(v.vId, v);
							markAssigned(v);
						}
						// same depth but assigned after being used on a different depth - needs wrap
						else if (used.exists(v.vId)) markAssigned(v);
						else checkLoopVar(v, true);
					}
			}
			LocalUsage.localUsage(collectVars, e);
			// mark all capture variables - also used in rename_local_vars at later stage
			for (id in ids(used)) {
				var v = used.get(id);
				TypeOps.addVarFlag(v, VCaptured);
				if (forCoro) TypeOps.addVarFlag(v, VCoroCaptured);
			}
			return assigned;
		}
		var captured = allVars(e);
		return switch scom.platformConfig.pfCapturePolicy {
			case CPNone: e;
			case CPWrapRef: doWrap(captured, e);
			case CPLoopVars: outLoop(e);
		};
	}
}
