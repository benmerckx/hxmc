package hxmc.interp;

import core.Ast.Expr;
import core.TType;
import core.MetaList.StrictMeta;
import core.ds.VectorTools.vector;

using core.TFunctions;

// -D hxmc.macros=mir: the std's and the runtime's functions in the macro
// context. hxmc's std loads the runtime (hxmc.rt, hxmc.unsafe: Std imports
// hxmc.rt.Runtime), and a macro reaches few of the functions of the std's
// files the macro context loads: their bodies are parsed (TypeloadParse.
// skipBodiesHook: ParserEntry.SkippedBodies) and typed (`lazyBody`) when
// they are asked for. A bundle never compiles a runtime function the
// compiler has (MirMacros.step: its native code runs it): a static
// function of the runtime that the compiler has, whose callers need only
// its declared signature (no optional argument, nothing left to infer but
// a Void result) and that the Mir inliner does not copy into them (the
// flags of its fingerprint, macro.HostTable), is not typed at all
// (TypeBinding.untypedBodyHook): its body is a throw naming it, and
// @:hxmc.hostCode marks it; Lower makes it a function without body
// (FuncInfo.hostCode) whose facts are those of the compiler's code
// (Lower.hostCode). The macro code compiled and what it runs are the same.
// HXMC_MIR_TYPE_RUNTIME=1: the runtime's functions the compiler has typed
// too; HXMC_MIR_LAZY_BODIES=0: every body parsed and typed with its module.
@:access(hxmc.ir.Facts)
@:access(hxmc.macro.Loader)
@:access(hxmc.interp.MirRun)
class MacroRuntime {
	public static inline var META = ":hxmc.hostCode";

	public static function install() {
		if (Sys.getEnv("HXMC_MIR_TYPE_RUNTIME") != "1") typing.TypeloadFields.TypeBinding.untypedBodyHook = body;
		if (Sys.getEnv("HXMC_MIR_LAZY_BODIES") != "0") {
			typing.TypeloadFields.TypeBinding.lazyBodyHook = lazyBody;
			typing.TypeloadFields.TypeBinding.typeLazyBodies = typeAll;
			typing.TypeloadParse.skipBodiesHook = (com, file) -> com.isMacroContext && stdFile(com, file);
		}
		hxmc.ir.Lower.hostCode = native;
	}

	// ---- the std's bodies typed when they are asked for

	// TypeBinding.lazyBodyHook: in the macro context, a method of the std's
	// files (hxmc's and Haxe's, not the program's: its errors stay where they
	// are) whose callers need only its signature (its type written in full;
	// not a macro, generic, overloaded, a coroutine, a constructor or an
	// __init__, nor of an interface or an extern class) is typed when
	// lowering it needs it (`ready`: MirMacros lowers what macro code calls,
	// its classes' methods), when a call inlines it (an inline method's type
	// is lazy) or when its module is encoded (typeAll); the others never are
	// (a cold trivial macro: 1,460 bodies typed before, 834 now; Eval 677).
	// HXMC_MIR_LAZY_BODIES=0: every body typed
	static function lazyBody(ctx:context.Typecore.Typer, c:TClass, cf:TClassField, fctx:typing.TypeloadFields.FieldInitCtx, t:T):Bool {
		if (!ctx.com.isMacroContext) return false;
		globals = ctx.g;
		if (fctx.isMacro || fctx.isExtern || fctx.isAbstract || fctx.isGeneric) return false;
		if (fctx.fieldKind != CfrStatic && fctx.fieldKind != CfrMember) return false;
		if (c.hasClassFlag(CExtern) || c.hasClassFlag(CInterface) || !c.clKind.match(KNormal | KAbstractImpl(_))) return false;
		if (!cf.cfKind.match(Method(MethNormal | MethInline)) || cf.cfOverloads.length > 0) return false;
		if (cf.cfMeta.length > 0 && (core.Meta.has(Overload, cf.cfMeta) || core.Meta.has(Generic, cf.cfMeta) || typing.TypeloadFields.getCoroConfig(ctx, cf.cfMeta) != null)) return false;
		if (!full(t, null) || !stdFile(ctx.com, cf.cfPos.pfile)) return false;
		lazyCount++;
		return true;
	}

	// (HXMC_MACRO_STATS) the bodies left untyped, those typed since
	public static var lazyCount = 0;
	public static var lazyTyped = 0;

	// the macro context's typer globals (the latest)
	static var globals:Null<context.Typecore.TyperGlobals> = null;

	// the class paths of the std of a context: Haxe's, hxmc's (MirMacros.setupPlatform)
	static var roots:Null<{com:context.Common.CommonContext, paths:Array<String>}> = null;

	static function stdFile(com:context.Common.CommonContext, file:String):Bool {
		if (roots == null || roots.com != com)
			roots = {
				com: com,
				paths: [
					for (cp in com.classPaths.asList())
						if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx"))) cp.path
				]
			};
		for (r in roots.paths)
			if (StringTools.startsWith(file, r)) return true;
		return false;
	}

	// the bodies typed so far, as their filters left them (a reused macro
	// context's classes are restored to what their filters made of them,
	// the throwing body: given back as they are lowered)
	static var typed = new haxe.ds.ObjectMap<TClassField, TExpr>();

	// (Lower.bodyReady, while MirMacros lowers) whether cf's body may be
	// lowered: typed, and its class handed over to the engine (its filters
	// run), else typed by `typeBodies` first
	public static function ready(c:TClass, cf:TClassField):Bool {
		if (typing.TypeloadFields.TypeBinding.lazyBodies.exists(cf)) return false;
		var e = typed.get(cf);
		if (e != null && cf.cfExpr != e) cf.cfExpr = e;
		return handed(c);
	}

	// (the module's types handed over: flushMacroContext's `ready` ran on them)
	static inline function handed(c:TClass):Bool
		return c.clModule.mExtra.mProcessed != 0;

	// the bodies of these fields typed (those not typed yet), then the types
	// they loaded handed over (the macro context finalized and flushed, as
	// for a macro's module: MacroContext.loadMacroPrimePrime), and the
	// expression filters run on the bodies of the classes handed over before
	// (MacroContext.lateFieldFilters)
	public static function typeBodies(fields:Array<TClassField>) {
		var lazies = typing.TypeloadFields.TypeBinding.lazyBodies;
		var done = [];
		for (cf in fields) {
			var lb = lazies.get(cf);
			if (lb == null) continue;
			lazies.remove(cf);
			core.TFunctions.lazyType(lb.r);
			done.push({cf: cf, lb: lb});
			lazyTyped++;
		}
		var mctx = globals == null || globals.macros == null ? null : globals.macros.typer;
		if (mctx != null) {
			typing.Finalization.finalize(mctx);
			typing.MacroContext.flushMacroContext(macros.eval.EvalContext.getCtx(), mctx);
		}
		for (x in done) {
			if (x.lb.late && typing.MacroContext.lateFieldFilters != null) typing.MacroContext.lateFieldFilters(x.lb.c, x.cf);
			typed.set(x.cf, x.cf.cfExpr);
		}
	}

	// TypeBinding.typeLazyBodies: every body of com not typed yet, typed (and
	// those its typing makes), before com's modules are encoded
	static function typeAll(com:context.Common.CommonContext) {
		if (!com.isMacroContext) return;
		var lazies = typing.TypeloadFields.TypeBinding.lazyBodies;
		while (true) {
			var fields = [for (cf => lb in lazies) if (lb.ctx.com == com) cf];
			if (fields.length == 0) break;
			typeBodies(fields);
		}
	}

	// a class of the runtime (macro.BundleFacts.runtime: its package)
	static function runtimeClass(c:TClass):Bool {
		var pk = c.clPath.pack;
		return pk.length >= 2 && pk[0] == "hxmc" && (pk[1] == "rt" || pk[1] == "unsafe");
	}

	// whether a type has nothing left to infer (TypeBinding.bindType's
	// is_full_type), but the monomorph `void`, which the body makes Void
	static function full(t:T, void:Null<TMono>):Bool
		return switch t {
			case TFun(s):
				if (!full(s.ret, void)) return false;
				for (a in s.args)
					if (!full(a.type, void)) return false;
				true;
			case TMono(m): m.tmType != null ? full(m.tmType, void) : m == void;
			case _: true;
		}

	// TypeBinding.untypedBodyHook
	static function body(ctx:context.Typecore.Typer, c:TClass, cf:TClassField, fctx:typing.TypeloadFields.FieldInitCtx,
			args:typing.FunctionArguments, t:T, ret:T, e:Expr, p:core.Globals.Pos):Null<TExpr> {
		if (!ctx.com.isMacroContext || !runtimeClass(c)) return null;
		return bodiless(ctx, c, cf, fctx, args, t, ret, e, p);
	}

	static function bodiless(ctx:context.Typecore.Typer, c:TClass, cf:TClassField, fctx:typing.TypeloadFields.FieldInitCtx,
			args:typing.FunctionArguments, t:T, ret:T, e:Expr, p:core.Globals.Pos):Null<TExpr> {
		if (!fctx.isStatic || fctx.isInline || fctx.isMacro || fctx.isExtern || fctx.isAbstract || fctx.fieldKind != CfrStatic) return null;
		if (c.hasClassFlag(CExtern) || c.hasClassFlag(CInterface) || c.clKind.match(KAbstractImpl(_))) return null;
		if (!cf.cfKind.match(Method(MethNormal)) || cf.cfParams.length > 0 || cf.cfOverloads.length > 0) return null;
		if (cf.cfMeta.length > 0 && (hxmc.ir.Lower.hasMeta(":hxmc.callback", cf.cfMeta) || core.Meta.has(Overload, cf.cfMeta))) return null;
		switch t {
			case TFun(s):
				for (a in s.args)
					if (a.optional) return null;
			case _:
				return null;
		}
		// (no return type written: Void when the body returns no value)
		var void = switch ret {
			case TMono(m) if (m.tmType == null): m;
			case _: null;
		}
		if (!full(t, void)) return null;
		if (nativeFlags(MirRun.hostFps(), symbol(hxmc.ir.Lower.nativeName(c), cf.cfName, cf.cfMeta)) < 0) return null;
		if (void != null) {
			// (a body the parse skipped: whether it has a `return` of a value, from its source)
			var nothing = syntax.ParserEntry.SkippedBodies.returnsNothing(e);
			if (nothing == null) nothing = returnsNothing(syntax.ParserEntry.SkippedBodies.body(e));
			if (!nothing) return null;
			context.Typecore.unify(ctx, ctx.t.tvoid, ret, p);
		}
		cf.cfMeta.push({meta: Custom(META), exprs: vector(), pos: p});
		var msg = core.Globals.sTypePath(c.clPath) + "." + cf.cfName + " is the compiler's native code (hxmc.interp.MacroRuntime): its body was not typed";
		var b = ctx.t;
		var tf:TFunc = {
			tfArgs: args.forExpr(ctx),
			tfType: ret,
			tfExpr: core.TFunctions.mk(TThrow(core.TFunctions.mk(TConst(TString(msg)), b.tstring, p)), b.tvoid, p)
		};
		return core.TFunctions.mk(TFunction(tf), t, p);
	}

	// the symbol of a static function's native code (Facts.symbol: its
	// export's, or F_ and its name); cls: its class's path, `_` between the parts
	public static function symbol(cls:String, field:String, meta:core.Ast.Metadata):String {
		var exported = meta.length > 0 ? hxmc.ir.Lower.metaString(":hxmc.export", meta) : null;
		return exported != null ? exported : "F_" + hxmc.ir.Facts.ident(cls + "_" + field);
	}

	// the flags (HostFps) of the compiler's native code of that symbol when it
	// may stand for the function: the compiler has it, no other function may
	// have that symbol (Facts numbers the others of one name: sym_1, ...) and
	// the Mir inliner does not copy it into callers (code loaded at run time
	// would copy a body there is none of); else -1
	static function nativeFlags(fps:hxmc.macro.HostTable.HostFps, sym:String):Int {
		var flags = fps.flags(sym);
		if (flags < 0 || flags & hxmc.macro.HostTable.HostFps.INLINE != 0 || fps.flags(sym + "_1") >= 0) return -1;
		return flags;
	}

	// whether a body returns no value (its own `return`s: not those of the
	// functions in it), which typeFunction makes Void when no type is written
	static function returnsNothing(e:Expr):Bool {
		function loop(e:Expr) {
			switch e.expr {
				case EReturn(v) if (v != null): throw core.ds.Exit.raise();
				case EFunction(_, _):
				case _: core.Ast.iterExpr(loop, e);
			}
		}
		return try {
			loop(e);
			true;
		} catch (_:core.ds.Exit) false;
	}

	// Lower.hostCode: what the compiler's code of fi does (Facts), from its fingerprint's flags
	static function native(fi:hxmc.ir.Ir.FuncInfo):Null<{noGc:Bool, blocks:Bool}> {
		var sym = fi.cSymbol != null ? fi.cSymbol : "F_" + hxmc.ir.Facts.ident(fi.name);
		if (!hxmc.macro.Loader.hostSyms().exists(sym)) return null;
		var flags = MirRun.hostFps().flags(sym);
		if (flags < 0) return null;
		return {noGc: flags & hxmc.macro.HostTable.HostFps.NO_GC != 0, blocks: flags & hxmc.macro.HostTable.HostFps.BLOCKS != 0};
	}
}
