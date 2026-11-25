package generators;

import context.Common.CommonContext;
import core.Ast;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.TType;
import core.TType.TClass;
import core.TType.TClassField;
import generators.Genjs.JsCtx;

// port: optional esm.hot emit hooks; hxmc sets these in EsmHotInstall.
class EsmHotEmit {
	// port: hxmc esm.hot — swappable static method bodies (GenesmHot)
	public static var tryEmitClassStatic:Null<(JsCtx, TClass, GlobalTypePath, TClassField) -> Bool> = null;
	// port: hxmc esm.hot — keyed closures as registry emit, not bare functions
	public static var tryEmitClosure:Null<(JsCtx, MetadataEntry, TFunc, Pos) -> Bool> = null;
	// port: hxmc esm.hot — mark cells and closures before RenameVars
	public static var beforeRename:Null<CommonContext -> Void> = null;
	// port: hxmc esm.hot — lower cells after RenameVars (metadata on TMeta)
	public static var afterRename:Null<CommonContext -> Void> = null;
	// port: hxmc esm.hot — lower cells before static emit (incl. keyed helpers)
	public static var prepareFieldCells:Null<(JsCtx, TClass, TClassField) -> Void> = null;
}