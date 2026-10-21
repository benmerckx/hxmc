package filters.safe;

import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Meta;
import core.Texpr;
import core.Error;
import haxe.ds.IntMap;
import core.ds.VectorTools.vector;

@:structInit class LsContext {
	public var scom:context.SafeCom.SafeContext;
	public var lut:IntMap<TClassField>;
	public var addedFields:Array<TClassField>;

	public inline function new(scom:context.SafeCom.SafeContext, lut:IntMap<TClassField>, addedFields:Array<TClassField>) {
		this.scom = scom;
		this.lut = lut;
		this.addedFields = addedFields;
	}

	public inline function clone():LsContext return new LsContext(scom, lut, addedFields);
}

class LocalStatic {
	public static function promoteLocalStatic(lsctx:LsContext, run:TExpr->TExpr, v:TVar, eo:Null<TExpr>):Void {
		var name = lsctx.scom.curfield.cfName + "_" + v.vName;
		var c:TClass = lsctx.scom.curclass;
		if (c.clStatics.exists(name)) {
			var conflicting = c.clStatics.get(name);
			Error.raiseTypingErrorExt(Error.makeError(Custom("The expanded name of this local ("
				+ name
				+ ") conflicts with another static field"), v.vPos, [
					Error.makeError(Custom("Conflicting field was found here"), conflicting.cfNamePos)
				]));
			return;
		}
		var cf = TypeOps.mkField(name, v.vType, v.vPos, v.vPos, true, true);
		cf.cfMeta = ([{meta: core.MetaList.StrictMeta.NoCompletion, exprs: vector(), pos: Globals.nullPos}] : Array<core.Ast.MetadataEntry>)
			.concat(v.vMeta);
		TypeOps.addClassFieldFlag(cf, CfNoLookup);
		if (eo != null) {
			var declaredVars = new IntMap<Bool>();
			function declare(v:TVar):Void declaredVars.set(v.vId, true);
			function loop(inFunction:Bool, inLoop:Bool, e:TExpr):TExpr {
				var loopHere = e -> loop(inFunction, inLoop, e);
				var result:TExprDef = switch e.eexpr {
					case TLocal(v) if (TypeOps.hasVarFlag(v, VStatic)): return run(e);
					case TLocal(v) if (!declaredVars.exists(v.vId)):
						return Error.raiseTypingError("Accessing local variables in static initialization is not allowed", e.epos);
					case TVar(v, eo):
						var eo = eo == null ? null : loopHere(eo);
						declare(v);
						TVar(v, eo);
					case TFunction(tf):
						var args = tf.tfArgs.map(function(a) {
							declare(a.variable);
							return {variable: a.variable, defaultValue: a.defaultValue == null ? null : loopHere(a.defaultValue)};
						});
						TFunction({tfArgs: args, tfType: tf.tfType, tfExpr: loop(true, inLoop, tf.tfExpr)});
					case TTry(e1, catches):
						var e1 = loopHere(e1);
						TTry(e1, catches.map(function(c) {
							declare(c.variable);
							return {variable: c.variable, expr: loopHere(c.expr)};
						}));
					case TWhile(e1, e2, flag):
						var e1 = loopHere(e1);
						var e2 = loop(inFunction, true, e2);
						TWhile(e1, e2, flag);
					case TConst(TThis | TSuper):
						return Error.raiseTypingError("Accessing `this` in static initialization is not allowed", e.epos);
					case TReturn(_) if (!inFunction):
						return Error.raiseTypingError("This kind of control flow in static initialization is not allowed", e.epos);
					case TBreak | TContinue if (!inLoop):
						return Error.raiseTypingError("This kind of control flow in static initialization is not allowed", e.epos);
					case _: return core.Texpr.mapExpr(loopHere, e);
				};
				return {eexpr: result, etype: e.etype, epos: e.epos};
			}
			cf.cfExpr = loop(false, false, eo);
		}
		lsctx.addedFields.unshift(cf);
		// Add to lookup early so that the duplication check works.
		c.clStatics.set(cf.cfName, cf);
		lsctx.lut.set(v.vId, cf);
	}

	public static function findLocalStatic(lut:IntMap<TClassField>, v:TVar):TClassField {
		if (!lut.exists(v.vId)) throw "Not_found";
		return lut.get(v.vId);
	}

	public static function run(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		var lsctx:LsContext = {scom: scom, lut: new IntMap(), addedFields: []};
		var c:TClass = scom.curclass;
		function run(e:TExpr):TExpr {
			return switch e.eexpr {
				case TBlock(el):
					var result = [];
					for (e in el) switch e.eexpr {
						case TVar(v, eo) if (TypeOps.hasVarFlag(v, VStatic)): promoteLocalStatic(lsctx, run, v, eo);
						case _: result.push(run(e));
					}
					{eexpr: TBlock(haxe.ds.Vector.fromArrayCopy(result)), etype: e.etype, epos: e.epos};
				case TLocal(v) if (TypeOps.hasVarFlag(v, VStatic)):
					if (!lsctx.lut.exists(v.vId)) Error.raiseTypingError("Could not find local static " + v.vName + " (id " + v.vId + ")",
						e.epos);
					Texpr.Builder.makeStaticField(c, findLocalStatic(lsctx.lut, v), e.epos);
				case _: core.Texpr.mapExpr(run, e);
			};
		}
		var e = run(e);
		// Add to ordered list in reverse order
		for (cf in lsctx.addedFields) c.clOrderedStatics.unshift(cf);
		return e;
	}
}
