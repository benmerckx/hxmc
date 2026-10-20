package typing;

import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.TType;
import core.Globals.*;
import core.TFunctions.*;
import core.TUnification.*;
import core.TUnification;
import core.TUnification.UnifyMinT;
import core.TOther.*;
import core.TOther;
import core.Error.*;
import core.Error;
import core.Meta;
import haxe.ds.StringMap;

class NoValue extends haxe.Exception {
	public function new() super("NoValue");
}

private class UnifyMinExit extends haxe.Exception {
	public function new() super("Exit");
}

class UnifyMin {
	public static function unifyMinRaise(basic:BasicTypes, el:Array<TExpr>):T {
		if (el.length == 0) throw new NoValue();
		if (el.length == 1) return el[0].etype;
		function chkNull(e:TExpr):Bool {
			if (isNull(e.etype) || isExplicitNull(e.etype)) return true;
			return switch e.eexpr {
				case TConst(TNull): true;
				case TBlock(values): values.length > 0 && chkNull(values[values.length - 1]);
				case TParenthesis(e) | TMeta(_, e): chkNull(e);
				case _: false;
			};
		}
		// First pass: Try normal unification and find out if null is involved.
		function loop(t:Null<T>, values:Array<TExpr>):{hasError:Bool, type:T} {
			if (values.length == 0) return {hasError: false,
				// The only way to get here is if all types were Dynamic. We know there's more than 0
				// because in that case we raise NoValue above.
				type: t == null ? tDynamic : t};
			var e = values[0], rest = values.slice(1);
			if (follow(e.etype) == tDynamic) return loop(t, rest);
			if (t == null) return loop(chkNull(e) ? basic.tnull(e.etype) : e.etype, rest);
			if (chkNull(e)) t = basic.tnull(t);
			try {
				unify(e.etype, t);
				return loop(t, rest);
			} catch (_:Unify_error) {
				try {
					unify(t, e.etype);
					return loop(isNull(t) ? basic.tnull(e.etype) : e.etype, rest);
				} catch (_:Unify_error) {
					return {hasError: true, type: t};
				}
			}
		}
		var first = loop(null, el);
		if (!first.hasError) return first.type;
		try {
			// specific case for const anon : we don't want to hide fields but restrict their common type
			var fcount = -1;
			inline function expr(f:TClassField):TExpr return f.cfExpr == null ? mk(TBlock([]), f.cfType, f.cfPos) : f.cfExpr;
			var fields = new StringMap<Array<TExpr>>();
			for (e in el) switch follow(e.etype) {
				case TAnon(a) if (a.aStatus == Const):
					var names = [for (name in a.aFields.keys()) name];
					names.sort(core.ds.Key.compareStrings);
					if (fcount == -1) {
						fcount = names.length;
						for (name in names) fields.set(name, [expr(a.aFields.get(name))]);
					} else {
						if (fcount != names.length) throw core.ds.FastThrow.of("Not_found");
						var previous = [for (name in fields.keys()) name];
						previous.sort(core.ds.Key.compareStrings);
						for (name in previous) {
							var f = a.aFields.get(name);
							if (f == null) throw core.ds.FastThrow.of("Not_found");
							fields.set(name, [expr(f)].concat(fields.get(name)));
						}
					}
				case _:
					throw core.ds.FastThrow.of("Not_found");
			}
			var result = new StringMap<TClassField>();
			var names = [for (name in fields.keys()) name];
			names.sort(core.ds.Key.compareStrings);
			for (name in names) {
				var values = fields.get(name);
				var t = try unifyMinRaise(basic, values) catch (_:Unify_error) {
					throw core.ds.FastThrow.of("Not_found");
				};
				result.set(name, mkField(name, t, values[0].epos, nullPos));
			}
			return mkAnon(Closed, result);
		} catch (error:Dynamic) {
			if (error != "Not_found") throw core.ds.FastThrow.of(error);
		}
		try {
			// specific case for TFun, see #9579
			var signature = switch follow(el[0].etype) {
				case TFun(s): s;
				case _: throw core.ds.FastThrow.of(new UnifyMinExit());
			};
			var args = signature.args.copy(), arity = args.length;
			var rets:Array<T> = [];
			for (e in el.slice(1)) switch follow(e.etype) {
				case TFun(s):
					if (s.args.length != arity) throw core.ds.FastThrow.of(new UnifyMinExit());
					for (i in 0...arity) {
						var tcur = args[i].type, tnew = s.args[i].type;
						if (doesUnify(tnew, tcur)) args[i] = s.args[i];
						else if (!doesUnify(tcur, tnew)) throw core.ds.FastThrow.of(new UnifyMinExit());
					}
					rets.push(s.ret);
				case _:
					throw core.ds.FastThrow.of(new UnifyMinExit());
			}
			var commonTypes = UnifyMinT.collectBaseTypes(signature.ret);
			var ret = switch UnifyMinT.unifyMinPrime(defaultUnificationContext(), commonTypes, rets) {
				case UnifyMinOk(t): t;
				case UnifyMinError(_, _): throw core.ds.FastThrow.of(new UnifyMinExit());
			};
			return TFun({args: args, ret: ret});
		} catch (_:UnifyMinExit) {
			// Second pass: Get all base types (interfaces, super classes and their interfaces) of most general type.
			// Then for each additional type filter all types that do not unify.
			var commonTypes = UnifyMinT.collectBaseTypes(first.type);
			var dynTypes:Array<T> = [];
			function hasDynamic(c:TClass):Bool return Meta.has(MetaTag.UnifyMinDynamic, c.clMeta)
				|| (c.clSuper != null && hasDynamic(c.clSuper.cls));
			for (t in commonTypes) switch t {
				case TInst(c, params) if (params.length > 0 && hasDynamic(c)):
					dynTypes.unshift(TInst(c, params.map(function(_) return tDynamic)));
				case _:
			}
			dynTypes.reverse();
			if (dynTypes.length > 0) commonTypes = commonTypes.concat(dynTypes);
			var rest = el.slice(1);
			return switch UnifyMinT.unifyMinPrime(defaultUnificationContext(), commonTypes, rest.map(function(e) return e.etype)) {
				case UnifyMinOk(t): t;
				case UnifyMinError(errors, index): raiseTypingErrorExt(makeError(Unify(errors), rest[index].epos));
			};
		}
	}
}
