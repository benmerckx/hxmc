package hxmc.unsafe;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

// hxmc.unsafe.Struct's layout constants on the targets other than hxmc: the
// C layout hxmc gives a @:hxmc.struct class (hxmc.Span.SpanData.struct), so
// that a kernel's sizes compute the same there.
class Struct {
	public static macro function sizeOf(c:Expr):Expr
		return macro $v{layout(c).size};

	public static macro function alignOf(c:Expr):Expr
		return macro $v{layout(c).align};

	#if macro
	static function layout(c:Expr):{size:Int, align:Int} {
		var t = Context.getType(haxe.macro.ExprTools.toString(c));
		return switch t {
			case TInst(cr, _) if (cr.get().meta.has(":hxmc.struct")): hxmc.Span.SpanData.struct(cr, c.pos);
			case _: Context.error("Struct: " + haxe.macro.ExprTools.toString(c) + " is no @:hxmc.struct class", c.pos);
		}
	}
	#end
}
