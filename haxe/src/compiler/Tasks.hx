package compiler;

import core.TType;
import compiler.CompilationCache;

class ClassMaintenanceTask extends ServerTask {
	final cs:Cache;
	final c:TClass;

	public function new(cs:Cache, c:TClass) {
		super(["module maintenance"], 70);
		this.cs = cs;
		this.c = c;
	}

	function execute():Void {
		function field(cf:TClassField) {
			/* Unset cf_expr. This holds the optimized version for generators, which we don't need to persist. If
				we compile again, the semi-optimized expression will be restored by calling cl_restore(). */
			cf.cfExpr = null;
			for (cf in cf.cfOverloads) field(cf);
		}
		/* What we're doing here at the moment is free, so we can just do it in one task. If this ever gets more expensive,
			we should spawn a task per-field. */
		for (cf in c.clFields) field(cf);
		for (cf in c.clStatics) field(cf);
		if (c.clConstructor != null) field(c.clConstructor);
	}
}

class ModuleMaintenanceTask extends ServerTask {
	final cs:Cache;
	final m:ModuleDef;

	public function new(cs:Cache, m:ModuleDef) {
		super(["module maintenance"], 80);
		this.cs = cs;
		this.m = m;
	}

	function execute():Void {
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c):
				cs.addTask(new ClassMaintenanceTask(cs, c));
			case _:
		}
	}
}

class ServerExplorationTask extends ServerTask {
	final cs:Cache;

	public function new(cs:Cache) {
		super(["server explore"], 90);
		this.cs = cs;
	}

	function execute():Void {
		cs.iterModules(m -> cs.addTask(new ModuleMaintenanceTask(cs, m)));
	}
}
