import haxe.macro.Context;
import haxe.macro.Expr;

class EntryMacro {
	// Simulates a global JSX init macro touching markup in the entry module.
	public static macro function xml(e:Expr):Expr {
		return switch e {
			case macro @:markup $v{(s:String)}:
				macro $v{s};
			default:
				Context.error("markup literal expected", e.pos);
		}
	}

	public static macro function init():Array<Field> {
		return Context.getBuildFields();
	}
}