package core;

import core.Globals;
import core.TType;

// port: not upstream: where a cache hooks into a build's typing (hxmc's module cache,
// ... hxmc/src/hxmc/ModuleCache.hx): what it watches (define reads, dependencies, macro
// ... statics, ...), what it decides (dependencyDirty, ...) and the continuations it wraps
// ... (lazy, delay). The build's CompilerInstance makes its cache's hooks current
// ... (CompilerCache.hooks); none in the compiler itself. These defaults are the compiler's.
class CacheHooks {
	/** the hooks of the build running (one at a time per process) */
	public static var current:Null<CacheHooks> = null;

	public function new() {}

	/** a define read (the compiler's, or a macro's through externalDefine first) */
	public function defineRead(ctx:Define.DefineContext, key:String):Void {}

	/** a macro reads (null key: all of them) or writes a define */
	public function externalDefine(com:context.Common.CommonContext, key:Null<String>, write:Bool):Void {}

	public function typerCreated(ctx:context.Typecore.Typer):Void {}

	/** a dependency of a cached module is dirty: true, it is typed from its source here */
	public function dependencyDirty(com:context.Common.CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra, dep:ModuleDep,
			reason:ModuleSkipReason):Bool
		return false;

	/** a module the server expects cached is not: its typing from source (null: none) */
	public function loadDirtyModule(com:context.Common.CommonContext, path:GlobalTypePath, p:Pos):Null<ModuleDef>
		return null;

	/** a module an HXB reader finds as a dependency: why it is not usable (null: it is) */
	public function readerFindModule(com:context.Common.CommonContext, mPath:GlobalTypePath):Null<ModuleSkipReason>
		return null;

	/** a module's typing from its source starts or ends */
	public function typeFromSource(com:context.Common.CommonContext, path:GlobalTypePath, start:Bool):Void {}

	/** a class's building starts or ends */
	public function buildClass(c:TClass, start:Bool):Void {}

	/** an HXB reader misses a field of `c`: true, its passes were run, read again */
	public function missingField(c:TClass):Bool
		return false;

	/** a field unification may use */
	public function maybeUsed(cl:Null<TClass>, f1:TClassField, f2:Null<TClassField>):Void {}

	/** a macro reads or writes a static variable of `c` */
	public function staticVar(c:TClass, write:Bool):Void {}

	/** a macro defined `mnew` in the typing of `mdep` */
	public function defined(mnew:ModuleDef, mdep:ModuleDef):Void {}

	public function dependency(m:ModuleDef, mdep:ModuleDef, origin:ModuleDepOrigin):Void {}

	/** a macro made a call whose result changes from run to run */
	public function volatileCall(what:String):Void {}

	/** a macro reads a file (kind: "c" content, "d" listing, "e" existence, ...) */
	public function fileRead(kind:String, path:String):Void {}

	/** a macro reads an environment variable (null: the whole environment) */
	public function envRead(name:Null<String>):Void {}

	/** a module type of the macros' context already processed (its stacks patched) */
	public function processedType(mt:ModuleType):Bool
		return false;

	/** a lazy type's typing, as it continues the typing that made it */
	public function lazy(f:Void->T):Void->T
		return f;

	/** a delayed task, as it continues the typing that delayed it */
	public function delay(f:Void->Void):Void->Void
		return f;

	// (around the compiler's own: `inner`)

	/** an expression typed (Typecore.typeExpr) */
	public function typeExpr(ctx:context.Typecore.Typer, e:Ast.Expr, withType:WithType.WithTypeValue, mode:context.Typecore.AccessMode,
			inner:(context.Typecore.Typer, Ast.Expr, WithType.WithTypeValue, ?context.Typecore.AccessMode) -> TExpr):TExpr
		return inner(ctx, e, withType, mode);

	/** a module the typer looks for in the server's cache (TypeloadCacheHook.typeModule) */
	public function typeModule(com:context.Common.CommonContext, delay:(context.TyperPass, Void->Void) -> Void, path:GlobalTypePath, p:Pos,
			inner:(context.Common.CommonContext, (context.TyperPass, Void->Void) -> Void, GlobalTypePath, Pos) -> typing.TypeloadCacheHook.FindModuleResult):typing.TypeloadCacheHook.FindModuleResult
		return inner(com, delay, path, p);

	/** a file parsed (TypeloadParse.parse) */
	public function parse(com:context.Common.CommonContext, rfile:ClassPaths.ResolvedFile, p:Pos,
			inner:(context.Common.CommonContext, ClassPaths.ResolvedFile, Pos) -> syntax.Parser.ParseResult<Ast.Package>):syntax.Parser.ParseResult<Ast.Package>
		return inner(com, rfile, p);

	/** a cached module's check, before the server's: why it is not usable (null: the server's checks decide) */
	public function checkModule(com:context.Common.CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra):Null<ModuleSkipReason>
		return null;

	/** an HXB reader made for a cached module */
	public function readerCreated(com:context.Common.CommonContext, path:GlobalTypePath, reader:compiler.hxb.HxbReader):Void {}

	/** a field's expression (cf null: the class's init) as the sort of the types walks it */
	public function sortExpr(c:TClass, cf:Null<TClassField>, e:TExpr):TExpr
		return e;
}
