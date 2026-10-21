package filters.safe;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import optimization.AnalyzerConfig;
import optimization.Analyzer;
import filters.RenameVars;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class AddFieldInits {
	public static function addFieldInits(clPath:core.Globals.GlobalTypePath, locals:RenameVars.RenameInit,
			scom:context.SafeCom.SafeContext, t:ModuleType):Void {
		inline function apply(c:TClass):Void {
			var ethis = TypeOps.mk(TConst(TThis), TInst(c, TypeOps.extractParamTypes(c.clParams)), c.clPos);
			// TODO: we have to find a variable name which is not used in any of the functions
			var v = TypeOps.allocVar(VGenerated, "_g", ethis.etype, ethis.epos);
			var needThis = false;
			var inits:Array<TClassField> = [];
			var fields:Array<TClassField> = [];
			for (cf in c.clOrderedFields) {
				switch [cf.cfKind, cf.cfExpr] {
					case [Var(_), expr] if (expr != null):
						inits.unshift(cf);
					case _:
				}
				fields.unshift(cf);
			}
			fields.reverse();
			c.clOrderedFields = fields;
			if (inits.length == 0) return;
			var el = inits.map(function(cf) {
				var e = cf.cfExpr;
				if (e == null) throw "addFieldInits: missing field initializer";
				var lhs = TypeOps.mk(TField({eexpr: ethis.eexpr, etype: ethis.etype, epos: cf.cfPos},
					FInstance(c, TypeOps.extractParamTypes(c.clParams), cf)),
					cf.cfType, cf.cfPos);
				cf.cfExpr = null;
				return TypeOps.mk(TBinop(OpAssign, lhs, e), cf.cfType, e.epos);
			});
			if (needThis) el.unshift(TypeOps.mk(TVar(v, ethis), ethis.etype, ethis.epos));
			var cf:TClassField;
			if (c.clConstructor == null) {
				var ct = TFun({args: vector(), ret: scom.basic.tvoid});
				var ce = TypeOps.mk(TFunction({
					tfArgs: vector(),
					tfType: scom.basic.tvoid,
					tfExpr: TypeOps.mk(TBlock(haxe.ds.Vector.fromArrayCopy(el)), scom.basic.tvoid, c.clPos)
				}), ct, c.clPos);
				cf = TypeOps.mkField("new", ct, c.clPos, Globals.nullPos);
				cf.cfKind = Method(MethNormal);
				cf.cfExpr = ce;
			} else {
				cf = core.ds.Record.copy(c.clConstructor);
				switch cf.cfExpr {
					case {eexpr: TFunction(f)}:
						var bl = switch f.tfExpr.eexpr {
							case TBlock(b): b;
							case _: vector(f.tfExpr);
						};
						cf.cfExpr = TypeOps.mk(TFunction({
							tfArgs: f.tfArgs,
							tfType: f.tfType,
							tfExpr: TypeOps.mk(TBlock(bl.prependArray(el)), scom.basic.tvoid, c.clPos)
						}), cf.cfType, cf.cfPos);
					case _:
						throw "addFieldInits: constructor is not a function";
				}
			}
			var config = AnalyzerConfig.getFieldConfig(scom, c, cf);
			TypeOps.removeClassFieldFlag(cf, CfPostProcessed);
			Analyzer.Run.runOnField(scom, config, c, cf);
			TypeOps.addClassFieldFlag(cf, CfPostProcessed);
			if (cf.cfExpr != null) {
				// This seems a bit expensive, but hopefully constructor expressions aren't that massive.
				var e = RenameVars.run(clPath, locals, cf.cfExpr);
				e = Sanitize.sanitize(scom, e);
				if (scom.platformConfig.pfAddFinalReturn) e = AddFinalReturn.addFinalReturn(e);
				cf.cfExpr = e;
			}
			c.clConstructor = cf;
		}
		switch t {
			case TClassDecl(c):
				apply(c);
			case _:
		}
	}
}
