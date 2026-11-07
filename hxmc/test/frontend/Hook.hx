import haxe.ds.Vector;
import hxmc.ir.Ir;

// A frontend whose hook (hxmc.Main.beforeCodegen) changes the body of a
// function no edit changes, for server-verify's frontend cases (make
// dev-check): Lib.f first calls a function the hook adds each build
// (`hook_mark`), and Lib.g calls Lib.alloc, which allocates, when the
// program has Main.extra. The compilation server reuses Lib's lowered
// bodies (LowerCache) and must not take what Facts found in a body before
// or after the hook in an earlier build (its callees, whether it reaches a
// GC point) for the one the hook makes now.
//   haxe -cp haxe/src -cp hxmc/src -cp hxmc/test/frontend -main Hook -D disable-parallelism --custom-target hxmc=<compiler>
class Hook {
	static function main() {
		hxmc.Main.beforeCodegen = (com, prog:Program) -> {
			inline function find(name:String)
				return Lambda.find(prog.funcs, f -> f.name == name);
			// (a new vector: the lowered one stays LowerCache's, docs/hxmc.md "Frontends")
			function prepend(f:FuncInfo, s:Stmt)
				f.body = Vector.fromArrayCopy([s].concat(f.body.toArray()));
			var f = find("Lib_f");
			if (f != null) {
				var mark = new FuncInfo("hook_mark", "hook");
				mark.ret = TI32;
				mark.body = Vector.fromArrayCopy([SReturn(EInt(7))]);
				prog.funcs.push(mark);
				prepend(f, SExpr(ECall(mark, new Vector(0))));
			}
			var g = find("Lib_g"), alloc = find("Lib_alloc");
			if (g != null && alloc != null && find("Main_extra") != null) prepend(g, SExpr(ECall(alloc, new Vector(0))));
		}
		Sys.exit(hxmc.HaxeMain.run(Sys.args()));
	}
}
