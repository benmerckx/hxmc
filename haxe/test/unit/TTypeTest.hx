package unit;

import core.Globals;
import core.TType.T;
import core.TType.TExpr;
import core.TType.TExprDef;
import core.TType.TMono;
import core.TType.TMonoConstraint;
import core.TType.TMonoModifier;
import core.TType.TSignature;
import core.TType.TType;
import core.ds.VectorTools.vector;

class TTypeTest {
	public static function main():Void {
		var mono:TMono = {tmType: null, tmDownConstraints: [MEmptyStructure], tmUpConstraints: [], tmModifiers: [MOpenStructure]};
		var type:T = TMono(mono);
		mono.tmType = TDynamic(null);
		var signature:TSignature = {args: vector({name: "value", optional: false, type: type}), ret: mono.tmType};
		var expression:TExpr = {eexpr: TConst(TInt(1)), etype: TFun(signature), epos: Globals.nullPos};
		assert(switch (expression.etype) { case TFun(value): value.args[0].name == "value" && switch (value.ret) { case TDynamic(_): true; case _: false; }; case _: false; });
		assert(TType.flagTClassFieldNames.length == 17);
	}

	static function assert(value:Bool):Void if (!value) throw "Assertion failed";
}
