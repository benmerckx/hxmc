import core.Ast;
import core.TType;
import core.WithType.WithTypeValue;
import haxe.ds.Vector;
import hxmc.ir.Ir;

// A frontend as docs/hxmc.md ("Frontends") describes it: a compiler built from
// hxmc's sources (haxe/src, hxmc/src; @hxmc/source's), with this main, that
// adds a function to each program it builds for hxmc after the lowering
// (hxmc.Main.beforeCodegen): `frontend_answer`, returning 42, which the
// program's main then passes to its `show` first (FrontendCheck, the npm job).
// It also types markup literals where the typer meets them
// (typing.Typer.markupHook): one expected to be an Int as its length, one
// with a hole `{e}` as the string around e (e typed here, in the literal's
// context, its type named after it), any other as "markup " and itself.
//   haxe -cp haxe/src -cp hxmc/src -cp hxmc/test/frontend -main Frontend -D disable-parallelism --custom-target hxmc=<compiler>
//   <compiler> -cp hxmc/test/frontend/app -main Main --custom-target hxmc=<out>   (prints "answer 42", "answer 1")
//   <compiler> -cp hxmc/test/frontend/markup -main Main --custom-target hxmc=<out>   (prints the literals as typed)
class Frontend {
	static function main() {
		typing.Typer.markupHook = markup;
		hxmc.Main.beforeCodegen = (com, prog:Program) -> {
			var show = Lambda.find(prog.funcs, f -> f.name == "Main_show");
			if (show == null) return; // (a program without one: hxmc/test/frontend/markup)
			var answer = new FuncInfo("frontend_answer", "frontend");
			answer.ret = TI32;
			answer.body = Vector.fromArrayCopy([SReturn(EInt(42))]);
			prog.funcs.push(answer);
			// (main's new local: an id after its others)
			var main = prog.main, id = 0;
			for (l in main.args.concat(main.locals))
				if (l.id >= id) id = l.id + 1;
			var v = new Local(id, "answer", TI32);
			main.locals.push(v);
			main.body = Vector.fromArrayCopy([SSet(v, ECall(answer, new Vector(0))), SExpr(ECall(show, Vector.fromArrayCopy([ELocal(v)])))].concat(main.body.toArray()));
		}
		Sys.exit(hxmc.HaxeMain.run(Sys.args()));
	}

	static function markup(ctx:context.Typecore.Typer, e1:Expr, withType:WithTypeValue, p:core.Globals.Pos):Null<Expr> {
		return switch e1.expr {
			case EConst(String(s, _)): literal(ctx, s, withType, p);
			// (a display request in the literal: its string comes marked, the
			// ... expression typed in its place is marked instead)
			case EDisplay({expr: EConst(String(s, _))}, dk): {expr: EDisplay(literal(ctx, s, withType, p), dk), pos: p};
			case _: null;
		}
	}

	static function literal(ctx:context.Typecore.Typer, s:String, withType:WithTypeValue, p:core.Globals.Pos):Expr {
		inline function str(v:String):Expr return {expr: EConst(String(v, SDoubleQuotes)), pos: p};
		inline function add(a:Expr, b:Expr):Expr return {expr: EBinop(OpAdd, a, b), pos: p};
		switch withType {
			case WithType(t, _) if (core.TFunctions.follow(t).match(TAbstract({aPath: {pack: [], name: "Int"}}, _))):
				return {expr: EConst(Int(Std.string(s.length), null)), pos: p};
			case _:
		}
		var open = s.indexOf("{"), close = s.indexOf("}");
		if (open < 0 || close < open) return add(str("markup "), str(s));
		var hole:Expr = {expr: EConst(Ident(s.substring(open + 1, close))), pos: p};
		var t = typing.Typer.typeExpr(ctx, hole, core.WithType.value).etype;
		var name = core.TPrinting.sType(core.TPrinting.printContext(), t);
		return add(add(add(str(s.substr(0, open)), hole), str(s.substr(close + 1))), str(" (" + name + ")"));
	}
}
