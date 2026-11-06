package typing;

import core.Define;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import core.TFunctions.*;
import compiler.hxb.HxbData.ModuleCache;
import context.Common;
import context.Common.CommonContext;
import context.TyperPass;

enum FindModuleResult {
	GoodModule(m:ModuleDef);
	BadModule(reason:ModuleSkipReason);
	BadBinaryModule(mc:ModuleCache, reason:ModuleSkipReason);
	BinaryModule(mc:ModuleCache);
	NoModule;
}

class TypeloadCacheHook {
	public static var typeModuleHook:(com:CommonContext, delay:(TyperPass, Void->Void) -> Void, path:GlobalTypePath,
		p:Pos) -> FindModuleResult = function(_, _, _, _) return NoModule;

	// port: not upstream: typeModuleHook, with the build's cache hooks around it (core.CacheHooks)
	public static function typeModule(com:CommonContext, delay:(TyperPass, Void->Void) -> Void, path:GlobalTypePath, p:Pos):FindModuleResult {
		return core.CacheHooks.current.typeModule(com, delay, path, p, typeModuleHook);
	}

	public static function createFakeModule(com:CommonContext, file:String):ModuleDef {
		var sign = Define.getSignature(com.defines);
		var cc = com.cs.getContext(sign);
		var key:String = com.partScope.fileKeys.get(file);
		var file = core.Path.getFullPath(file);
		var mdep = try cc.findFakeModule(key) catch (_:core.ds.NotFound) null;
		if (mdep == null) {
			mdep = {
				mId: allocMid(),
				mPath: {pack: ["$DEP"], name: file},
				mTypes: [],
				mStatics: null,
				mExtra: moduleExtra(file, sign, Common.fileTime(file), MFake, com.partScope.compilationStep, [])
			};
			cc.addFakeModule(key, mdep);
		}
		com.moduleLut.add(mdep.mPath, mdep);
		return mdep;
	}
}
