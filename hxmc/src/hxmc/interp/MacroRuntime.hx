package hxmc.interp;

#if hxmc.jit
import core.Ast.Expr;
import core.TType;
import core.MetaList.StrictMeta;
import core.ds.VectorTools.vector;

using core.TFunctions;

// -D hxmc.mir-macros: the runtime's functions in the macro context. hxmc's
// std loads the runtime (hxmc.rt, hxmc.unsafe: Std imports hxmc.rt.Runtime)
// and the macro context types every function it loads, but a bundle never
// compiles a runtime function the compiler has (MirMacros.step: its native
// code runs it), so typing their bodies was most of what a cold build paid
// for the macro context (a trivial macro: 1.50 G instructions, Eval 0.60 G).
// A static function of the runtime that the compiler has, whose callers
// need only its declared signature (no optional argument, nothing left to
// infer but a Void result) and that the Mir inliner does not copy into
// them (<exe>.fps's flags), is not typed (TypeBinding.untypedBodyHook): its
// body is a throw naming it, and @:hxmc.hostCode marks it; Lower makes it a
// function without body (FuncInfo.hostCode) whose facts are those of the
// compiler's code (Lower.hostCode). Most of their bodies are not parsed
// either (hxmc.MacroCuts: <exe>.cuts, TypeloadParse.sourceHook). The macro
// code compiled and what it runs are the same. HXMC_MIR_TYPE_RUNTIME=1:
// every function typed and parsed, as before.
@:access(hxmc.ir.Facts)
@:access(hxmc.macro.Loader)
@:access(hxmc.interp.MirRun)
class MacroRuntime {
	public static inline var META = ":hxmc.hostCode";

	// <exe>.cuts, read at the first file of the runtime the macro context parses
	static var cuts:Null<Map<String, {hash:String, ranges:Array<Int>}>> = null;

	public static function install() {
		if (Sys.getEnv("HXMC_MIR_TYPE_RUNTIME") != "1") {
			typing.TypeloadFields.TypeBinding.untypedBodyHook = body;
			typing.TypeloadParse.sourceHook = source;
		}
		hxmc.ir.Lower.hostCode = native;
	}

	// a class of the runtime (macro.Guest.runtime: its package)
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
		var r = bodiless(ctx, c, cf, fctx, args, t, ret, e, p);
		// (a body MacroCuts blanked: never typed)
		if (r == null && cut(e))
			core.Error.raiseTypingError(core.Globals.sTypePath(c.clPath) + "." + cf.cfName
				+ ": its body was left out of the macro context (hxmc.MacroCuts, the compiler's .cuts), but it is not the compiler's native code there (hxmc.interp.MacroRuntime): the compiler and its std disagree", p);
		return r;
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
		if (hxmc.MacroCuts.nativeFlags(MirRun.hostFps(), hxmc.MacroCuts.symbol(hxmc.ir.Lower.nativeName(c), cf.cfName, cf.cfMeta)) < 0) return null;
		if (void != null) {
			if (!hxmc.MacroCuts.returnsNothing(e)) return null;
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

	// whether a body is one MacroCuts blanked
	static function cut(e:Expr):Bool
		return switch e.expr {
			case EBlock([{expr: EThrow({expr: EConst(core.Ast.Constant.String(s, _))})}]): s == hxmc.MacroCuts.MARKER;
			case _: false;
		}

	// TypeloadParse.sourceHook: a file of the runtime as the macro context
	// parses it, with the bodies of <exe>.cuts blanked when it is the file
	// they are of
	static function source(com:context.Common.CommonContext, file:String, text:String):String {
		if (!com.isMacroContext) return text;
		var f = StringTools.replace(file, "\\", "/");
		var at = f.lastIndexOf("/hxmc/rt/");
		if (at < 0) at = f.lastIndexOf("/hxmc/unsafe/");
		if (at < 0) return text;
		if (cuts == null) {
			var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
			cuts = hxmc.MacroCuts.read(exe + ".cuts");
		}
		var c = cuts.get(f.substr(at + 1));
		if (c == null) return text;
		var s = hxmc.MacroCuts.apply(text, c);
		return s == null ? text : s;
	}

	// Lower.hostCode: what the compiler's code of fi does (Facts), from <exe>.fps
	static function native(fi:hxmc.ir.Ir.FuncInfo):Null<{noGc:Bool, blocks:Bool}> {
		var sym = fi.cSymbol != null ? fi.cSymbol : "F_" + hxmc.ir.Facts.ident(fi.name);
		if (!hxmc.macro.Loader.hostSyms().exists(sym)) return null;
		var flags = MirRun.hostFps().flags(sym);
		if (flags < 0) return null;
		return {noGc: flags & hxmc.macro.SymFile.HostFps.NO_GC != 0, blocks: flags & hxmc.macro.SymFile.HostFps.BLOCKS != 0};
	}
}
#end
