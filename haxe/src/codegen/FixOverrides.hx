package codegen;

import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.TUnification;
import core.TOther.*;
import context.Common;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// -------------------------------------------------------------------------- //
// FIX OVERRIDES

/*
	on some platforms which doesn't support type parameters, we must have the
	exact same type for overridden/implemented function as the original one
*/
class FixOverrides {
	public static function findField(com:CommonContext, c:TClass, f:TClassField):TClassField {
		try {
			var s = c.clSuper;
			// cpp.FastIterator: This is a strongly typed 'extern' and the usual rules don't apply
			if (s == null || (s.cls.clPath.pack.join(".") == "cpp" && s.cls.clPath.name == "FastIterator")) throw "Not_found";
			return findField(com, s.cls, f);
		} catch (e:Dynamic) {
			if (e != "Not_found") throw e;
		}
		try {
			if (com.platform == Cpp || com.platform == Hl) throw "Not_found"; // uses delegation for interfaces
			// port: HashLink 2.0 JIT: an early exit through two nested try blocks restores
			// only the innermost trap, leaving a dangling handler.
			for (parent in c.clImplements) {
				var r = try findField(com, parent.cls, f) catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					null;
				}
				if (r != null) return r;
			}
			throw "Not_found";
		} catch (e:Dynamic) {
			if (e != "Not_found") throw e;
		}
		var field = c.clFields.get(f.cfName);
		if (field == null) throw "Not_found";
		switch field.cfKind {
			case Var({vRead: AccRequire(_, _)}):
				throw "Not_found";
			case _:
		}
		return field;
	}

	public static function fixOverride(com:CommonContext, c:TClass, f:TClassField, fd:Null<TFunc>):Void {
		var f2 = try findField(com, c, f) catch (e:Dynamic) {
			if (e != "Not_found") throw e;
			null;
		};
		if (f2 != null && fd != null) {
			var signature = switch followWithCoro(f2.cfType) {
				case Coro(s): Common.expandCoroType(com.basic, s.args, s.ret);
				case NotCoro(TFun(s)): s;
				case _: throw "Invalid override type";
			};
			var changed:Array<{original:TVar, replacement:TVar}> = [];
			if (fd.tfArgs.length != signature.args.length) throw "Invalid_argument: List.map2";
			var nargs = new Vector(fd.tfArgs.length);
			for (i in 0...fd.tfArgs.length) {
				var cur = fd.tfArgs[i],
					v = cur.variable,
					t2 = signature.args[i].type;
				var next = cur;
				try {
					typeEq(EqStrict, monomorphs(c.clParams, monomorphs(f.cfParams, v.vType)), t2);
					// Flash generates type parameters with a single constraint as that constraint type, so we
					// have to detect this case and change the variable (issue #2712).
					switch follow(v.vType) {
						case TInst(cp = {clKind: KTypeParameter(ttp)}, _) if (com.platform == Flash):
							if (getConstraints(ttp).length == 1
								&& core.ds.ArrayTools.exists(c.clParams,
									function(tp) return tp.ttpName == cp.clPath.name)) throw new Unify_error([]);
						case _:
					}
				} catch (_:Unify_error) {
					var v2 = allocVar(VGenerated, "_tmp_" + v.vName, t2, v.vPos);
					changed.unshift({original: v, replacement: v2});
					next = {variable: v2, defaultValue: cur.defaultValue};
				}
				nargs[i] = next;
			}
			changed.reverse();
			var expr = fd.tfExpr;
			if (changed.length > 0) {
				var el = switch expr.eexpr {
					case TBlock(el): el;
					case _: vector(expr);
				};
				var p = el.length == 0 ? expr.epos : el[0].epos;
				var decls = changed.mapToVector(function(pair) return mk(TVar(pair.original,
					mk(TCast(mk(TLocal(pair.replacement), pair.replacement.vType, p), null), pair.original.vType, p)),
					com.basic.tvoid, p));
				expr = {eexpr: TBlock(decls.concat(el)), etype: expr.etype, epos: expr.epos};
			}
			var fd2 = ({tfArgs: nargs, tfType: signature.ret, tfExpr: expr} : core.TType.TFunc);
			var args = nargs.map(function(arg) return {
				name: arg.variable.vName,
				optional: arg.defaultValue != null,
				type: arg.variable.vType
			});
			var fde = f.cfExpr;
			if (fde == null) throw "Missing override expression";
			var e:TExpr = {eexpr: TFunction(fd2), etype: fde.etype, epos: fde.epos};
			var tret = signature.ret;
			var e = if (com.config.pfAddFinalReturn && core.TOther.ExtType.isVoid(follow(fd.tfType))
				&& !core.TOther.ExtType.isVoid(follow(tret))) {
				function loop(e:TExpr):TExpr return switch e.eexpr {
					case TReturn(null): {eexpr: TReturn(mk(TConst(TNull), tret, e.epos)), etype: e.etype, epos: e.epos};
					case TFunction(_): e;
					case _: core.Texpr.mapExpr(loop, e);
				};
				filters.safe.AddFinalReturn.addFinalReturn({
					eexpr: TFunction({tfArgs: fd2.tfArgs, tfType: fd2.tfType, tfExpr: loop(fd2.tfExpr)}),
					etype: e.etype,
					epos: e.epos
				});
			} else e;
			f.cfExpr = e;
			f.cfType = TFun({args: args, ret: signature.ret});
		} else if (f2 != null && fd == null && hasClassFlag(c, CInterface)) {
			var s = switch followWithCoro(f2.cfType) {
				case Coro(s): Common.expandCoroType(com.basic, s.args, s.ret);
				case NotCoro(TFun(s)): s;
				case _: throw "Invalid override type";
			};
			f.cfType = TFun(s);
		}
	}

	public static function fixOverrides(com:CommonContext, t:ModuleType):Void switch t {
		case TClassDecl(c):
			// overrides can be removed from interfaces
			if (hasClassFlag(c, CInterface)) c.clOrderedFields = c.clOrderedFields.filter(function(f) {
				try {
					if (findField(com, c, f) == f) throw "Not_found";
					c.clFields.remove(f.cfName);
					return false;
				} catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					return true;
				}
			});
			for (f in c.clOrderedFields) switch [f.cfExpr, f.cfKind] {
				case [{eexpr: TFunction(fd)}, Method(MethNormal | MethInline)]: fixOverride(com, c, f, fd);
				case [null, Method(MethNormal | MethInline)] if (hasClassFlag(c, CInterface)): fixOverride(com, c, f, null);
				case _:
			}
		case _:
	};

	/*
		PHP does not allow abstract classes extending other abstract classes to override any fields, so these duplicates
		must be removed from the child interface
	*/
	public static function fixAbstractInheritance(com:CommonContext, t:ModuleType):Void switch t {
		case TClassDecl(c) if (hasClassFlag(c, CInterface)):
			c.clOrderedFields = c.clOrderedFields.filter(function(f) {
				var b = try findField(com, c, f) == f catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					false;
				};
				if (!b) c.clFields.remove(f.cfName);
				return b;
			});
		case _:
	};
}
