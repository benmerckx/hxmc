package hxmc.genesm;

import core.Globals;
import generators.Gctx;

// Production ESM (-D esm without esm.hot): static import/export between user modules.
class GenesmProd {
	public static function generate(com:Gctx):Void {
		Genesm.prodMode = true;
		var packed = Genesm.moduleGroups(com);
		var std = GenesmLinks.buildStdSet(com, packed.groups);
		generators.EsmHook.isProdEsm = () -> true;
		generators.EsmHook.isProdEsmStd = id -> std.exists(id);
		try {
			Genesm.generate(com);
		} catch (e:Dynamic) {
			Genesm.prodMode = false;
			generators.EsmHook.isProdEsm = null;
			generators.EsmHook.isProdEsmStd = null;
			throw e;
		}
		Genesm.prodMode = false;
		generators.EsmHook.isProdEsm = null;
		generators.EsmHook.isProdEsmStd = null;
	}

	public static function isModuleCyclic(homeId:String, testId:String, deps:Map<String, Array<String>>):Bool {
		if (testId == homeId) return true;
		var seen = new Map<String, Bool>();
		function testCycles(test:String):Bool {
			seen.set(test, true);
			for (d in deps.get(test) ?? [])
				if (seen.exists(d)) {
					if (d == homeId) return true;
				} else if (testCycles(d))
					return true;
			return false;
		}
		return testCycles(testId);
	}
}