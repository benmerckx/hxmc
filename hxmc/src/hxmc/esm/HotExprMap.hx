package hxmc.esm;

import core.TType;
import core.TFunctions.*;
import core.Texpr;

// Post-order expr map: callback runs on every node (TVar, TCall, TFunction, …).
// Texpr.mapExpr only recurses into children and never invokes f on those shapes.
class HotExprMap {
	public static function mapTransform(f:TExpr->TExpr, e:TExpr):TExpr {
		var e2 = Texpr.mapExpr(x -> mapTransform(f, x), e);
		return f(e2);
	}
}