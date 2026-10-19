package macros;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.ds.Vector;

// MkStd must keep the reference Vector backed by eval.Vector for macros,
// even while the compiler itself and the target use hxmc.NativeArray.
class VectorBacking {
	public static macro function build():Array<Field> {
		var v = Vector.fromArrayCopy([2, 4, 6]);
		var raw:eval.Vector<Int> = v.toData();
		raw[1] = 7;
		var copy = v.copy();
		Vector.blit(v, 0, v, 1, 2);
		var mapped = copy.map(x -> x * 0.5);
		var bools = new Vector<Bool>(3, true);
		if (v.join(",") != "2,2,7" || copy.join(",") != "2,7,6" || mapped.join(",") != "1,3.5,3" || !bools[2])
			Context.error("Vector's Eval implementation changed", Context.currentPos());
		return Context.getBuildFields();
	}
}
#end
