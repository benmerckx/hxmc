import haxe.ds.Vector;
import hxmc.ir.Ir;

// A frontend as docs/hxmc.md ("Frontends") describes it: a compiler built from
// hxmc's sources (haxe/src, hxmc/src; @hxmc/source's), with this main, that
// adds a function to each program it builds for hxmc after the lowering
// (hxmc.Main.beforeCodegen): `frontend_answer`, returning 42, which the
// program's main then passes to its `show` first (FrontendCheck, the npm job).
//   haxe -cp haxe/src -cp hxmc/src -cp hxmc/test/frontend -main Frontend -D disable-parallelism --custom-target hxmc=<compiler>
//   <compiler> -cp hxmc/test/frontend/app -main Main --custom-target hxmc=<out>   (prints "answer 42", "answer 1")
class Frontend {
	static function main() {
		hxmc.Main.beforeCodegen = (com, prog:Program) -> {
			var show = Lambda.find(prog.funcs, f -> f.name == "Main_show");
			if (show == null) throw "Frontend: the program has no Main.show";
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
}
