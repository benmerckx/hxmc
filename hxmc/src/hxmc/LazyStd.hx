package hxmc;

import core.TType;
import haxe.ds.ObjectMap;
import typing.TypeloadFields.TypeBinding;

using core.TFunctions;

// The std's bodies in the program's build, typed when DCE reaches them
// (docs/hxmc.md, "The std typed when it is reached"). Every program loads
// all of hxmc's runtime (Std imports hxmc.rt.Runtime) and much of Haxe's
// std, and a full typing types every method of every class loaded, while a
// program reaches a few hundred of them. A file of the std (hxmc's, Haxe's:
// never the program's, whose errors stay where they are) is parsed without
// its methods' bodies (ParserEntry.SkippedBodies), and a method whose
// callers need only its signature (MacroRuntime.lazyField; not inline:
// inlining wants its body as soon as it is typed) is not typed with its
// module (TypeBinding.lazyBodyHook). A macro function of the std is typed
// in the macro context when it is called, not when its class is loaded
// (TypeBinding.skipMacroHook).
//
// The filters pass over those bodies (SafeCom, Analyzer); DCE types the ones
// it reaches (Dce.lazyHook: `mark`), runs the filters the others had on each
// (`filter`) and goes on marking from it. The modules their typing loads are
// finalized as typing would (after-typing callbacks with the new types), go
// through the filters before DCE (`late`) and are DCE's entry points too;
// the program's types are then sorted again (Finalization.sortTypes, over
// the static initializers' expressions as the first sort saw them:
// `walked`), so static initializers run in the order of a full typing. The
// sort of static initializers types the bodies it walks (Finalization), and
// the modules that loads are finalized and sorted with the rest
// (Finalization.sortedHook). A body DCE does not reach is removed with its
// field and never typed. A class whose variables wait for its methods to
// infer their types has its bodies typed with the program (`inferring`); the
// fields a structure read names stand for the unifications of the bodies not
// typed (Dce.anonRead).
//
// Opt-in (-D hxmc.lazy-std, HXMC_LAZY_STD=1): its output differs from a full
// typing's where the std's unreached bodies changed what DCE keeps (an extern
// class only they load, the fields their unifications made :?used). Off for
// display, the compilation server (which keeps every module typed for
// the next build), a build writing HXB, -dce no (every field kept, so every
// body typed: no gain), with hxmc's module cache (its encoded modules have
// every body); HXMC_LAZY_MACROS=0 types the std's macro functions with
// their classes.
class LazyStd {
	// (-D hxmc.stats) the bodies left untyped as their modules were typed, those DCE typed
	public static var lazy = 0;
	public static var typed = 0;
	public static var macros = 0;

	static var com:Null<context.Common.CommonContext> = null;
	static var on = false;
	static final macrosOff = Sys.getEnv("HXMC_LAZY_MACROS") == "0";
	// the fields typed since `mark` or the sort last looked (TypeBinding.lazyTypedHook)
	static var forced:Array<{c:TClass, cf:TClassField}> = [];
	// the modules whose types went through the filters (or will, with the program's)
	static var seen = new ObjectMap<ModuleDef, Bool>();
	// the static initializers and static fields as the first sort walked them
	static var walked = new ObjectMap<TClassField, TExpr>();
	static var walkedInits = new ObjectMap<TClass, TExpr>();
	// the program's types sorted again, for DCE's sweep
	static var sorted:Null<Array<ModuleType>> = null;
	// the extern, macro and generic fields the filters removed before DCE (Filters.removedHook), which
	// a body typed later may refer to: in their classes again while DCE types
	static var removed:Array<{c:TClass, cf:TClassField, isStatic:Bool}> = [];
	static final lock = new sys.thread.Mutex();

	public static function install() {
		var lazyBody = TypeBinding.lazyBodyHook;
		TypeBinding.lazyBodyHook = function(ctx, c, cf, fctx, t) {
			if (ctx.com.isMacroContext) return lazyBody != null && lazyBody(ctx, c, cf, fctx, t);
			if (!enabled(ctx.com) || fctx.isInline || !hxmc.interp.MacroRuntime.lazyField(ctx, c, cf, fctx, t)) return false;
			lazy++;
			return true;
		}
		var skipBodies = typing.TypeloadParse.skipBodiesHook;
		typing.TypeloadParse.skipBodiesHook = (com, file) -> com.isMacroContext ? skipBodies != null && skipBodies(com,
			file) : enabled(com) && hxmc.interp.MacroRuntime.stdFile(com, file);
		TypeBinding.skipMacroHook = (ctx, c, cf) -> {
			if (macrosOff || !enabled(ctx.com) || !hxmc.interp.MacroRuntime.stdFile(ctx.com, cf.cfPos.pfile)) return false;
			macros++;
			true;
		}
		var lazyTyped = TypeBinding.lazyTypedHook;
		TypeBinding.lazyTypedHook = function(c, cf) {
			if (lazyTyped != null) lazyTyped(c, cf);
			var lb = TypeBinding.lazyBodies.get(cf);
			if (lb == null || lb.ctx.com.isMacroContext) return;
			TypeBinding.lazyBodies.remove(cf);
			forced.push({c: c, cf: cf});
			typed++;
		}
		// (the module cache sets the sort's hook as each compilation starts)
		var beforeTyping = compiler.Compiler.beforeTypingHook;
		compiler.Compiler.beforeTypingHook = function(c, actx) {
			if (beforeTyping != null) beforeTyping(c, actx);
			// (a compilation decides anew)
			com = null;
			on = false;
			var sortExpr = typing.Finalization.sortExprHook;
			typing.Finalization.sortExprHook = function(c, cf, e) {
				if (sortExpr != null) e = sortExpr(c, cf, e);
				if (!on) return e;
				var w = cf == null ? walkedInits.get(c) : walked.get(cf);
				if (w != null) return w;
				if (cf == null) walkedInits.set(c, e) else walked.set(cf, e);
				return e;
			}
		}
		typing.Finalization.sortedHook = sortedAgain;
		optimization.Dce.lazyHook = {mark: mark, types: types, active: () -> on};
		filters.Filters.removedHook = (c, cf, isStatic) -> if (on) {
			lock.acquire();
			removed.push({c: c, cf: cf, isStatic: isStatic});
			lock.release();
		}
	}

	// whether com's std is typed when it is reached (its platform is known once its typing starts)
	static function enabled(c:context.Common.CommonContext):Bool {
		if (c == com) return on;
		var dce = core.Define.rawDefined(c.defines, "dce") ? core.Define.rawDefinedValue(c.defines, "dce") : "std";
		// (not the context checking @:coreApi classes against Haxe's: Typeload.loadCoreClass)
		if (c.isMacroContext || !c.platform.match(CustomTarget("hxmc")) || core.Define.defined(c.defines, core.Define.CoreApi)) return false;
		com = c;
		on = c.display.dmsKind == DMNone && !Driver.resident && !c.sctx.isServer && c.hxbWriterConfig == null && dce != "no" && !ModuleCache.active()
			&& Options.on("hxmc.lazy-std", false, c.defines);
		if (!on) return false;
		forced = [];
		seen = new ObjectMap();
		walked = new ObjectMap();
		walkedInits = new ObjectMap();
		sorted = null;
		removed = [];
		lazy = typed = macros = 0;
		return true;
	}

	static function key(t:ModuleType):Dynamic
		return switch t {
			case TClassDecl(c): c;
			case TEnumDecl(e): e;
			case TTypeDecl(d): d;
			case TAbstractDecl(a): a;
		}

	static function moduleCount(c:context.Common.CommonContext):Int
		return c.moduleLut.fold((_, _, n) -> n + 1, 0);

	// Finalization.sortedHook: the modules the sort's typing loaded, finalized, and sorted again until none
	static function sortedAgain(ctx:context.Typecore.Typer, s:{types:Array<ModuleType>, modules:Array<ModuleDef>}) {
		if (ctx.com != com || !on) return s;
		var again = inferring();
		while (again || moduleCount(ctx.com) != s.modules.length) {
			finalizeNew(ctx, s.types);
			s = typing.Finalization.sortTypes(ctx.com, ctx.com.moduleLut);
			again = false;
		}
		// (typed with their modules, filtered with the program)
		forced = [];
		for (m in s.modules)
			seen.set(m, true);
		return s;
	}

	// the bodies of the classes whose variables' types are still to be
	// inferred (`static var codes = null`, which a method's body makes an
	// Array: haxe.Unserializer), typed as a full typing would before the
	// filters close what is left open: whether there were any
	static function inferring():Bool {
		var byClass = new ObjectMap<TClass, Array<TLazy>>();
		for (cf => lb in TypeBinding.lazyBodies)
			if (lb.ctx.com == com) {
				var a = byClass.get(lb.c);
				if (a == null) byClass.set(lb.c, a = []);
				a.push(lb.r);
			}
		var any = false;
		for (c => rs in byClass)
			if (Lambda.exists(c.clOrderedStatics.concat(c.clOrderedFields), cf -> cf.cfKind.match(Var(_)) && open(cf.cfType, 0))) {
				for (r in rs)
					core.TFunctions.lazyType(r);
				any = true;
			}
		return any;
	}

	// whether a type has a monomorph not bound yet
	static function open(t:T, depth:Int):Bool {
		if (depth > 8) return false;
		function all(ts:haxe.ds.Vector<T>):Bool {
			for (t in ts)
				if (open(t, depth + 1)) return true;
			return false;
		}
		return switch t {
			case TMono(m): m.tmType == null || open(m.tmType, depth + 1);
			case TInst(_, ps) | TEnum(_, ps) | TType(_, ps) | TAbstract(_, ps): all(ps);
			case TFun(s): open(s.ret, depth + 1) || Lambda.exists([for (a in s.args) a.type], t -> open(t, depth + 1));
			case TAnon(a): Lambda.exists(a.aFields, f -> open(f.cfType, depth + 1));
			case TDynamic(t): t != null && open(t, depth + 1);
			case TLazy(_): false;
		}
	}

	// the passes of the modules loaded since `known`'s, as Finalization.finalize
	// runs them, but the after-typing callbacks given the new types only
	static function finalizeNew(ctx:context.Typecore.Typer, known:Array<ModuleType>) {
		var handled = new ObjectMap<Dynamic, Bool>();
		for (t in known)
			handled.set(key(t), true);
		while (true) {
			context.Typecore.flushPass(ctx.g, PFinal, {name: "final", args: []});
			var all:Array<ModuleType> = ctx.com.moduleLut.fold((_, m:ModuleDef, acc:Array<ModuleType>) -> m.mTypes.concat(acc), []);
			var fresh = all.filter(t -> !handled.exists(key(t)));
			if (fresh.length == 0) return;
			for (t in fresh)
				handled.set(key(t), true);
			for (f in ctx.com.callbacks.getAfterTyping())
				f(fresh);
		}
	}

	// Dce.lazyHook.mark: the bodies of the fields reached not typed yet typed and
	// filtered; the types their typing loaded, filtered as the program's were
	static function mark(items:Array<{cls:TClass, field:TClassField, kind:ClassFieldRefKind}>):Null<{fresh:Array<ModuleType>, all:Array<ModuleType>}> {
		if (!on) return null;
		var lbs = [];
		for (i in items) {
			var lb = TypeBinding.lazyBodies.get(i.field);
			if (lb != null && !lb.ctx.com.isMacroContext) lbs.push(lb);
		}
		if (lbs.length == 0) return null;
		var ctx = lbs[0].ctx;
		var stage = ctx.com.stage;
		// (the removed fields, while the bodies are typed and filtered)
		for (r in removed)
			(r.isStatic ? r.c.clStatics : r.c.clFields).set(r.cf.cfName, r.cf);
		var fresh = try typeAll(ctx, lbs) catch (e:Dynamic) {
			unrestore();
			throw e;
		}
		var news = new ObjectMap<ModuleDef, Bool>();
		for (t in fresh)
			news.set(t.tModule(), true);
		var old = forced.filter(f -> !news.exists(f.c.clModule));
		forced = [];
		try {
			if (old.length > 0) filter(old);
			if (fresh.length > 0) late(ctx.com, fresh);
		} catch (e:Dynamic) {
			unrestore();
			throw e;
		}
		unrestore();
		ctx.com.stage = stage;
		return {fresh: fresh, all: sorted != null ? sorted : ctx.com.types};
	}

	static function unrestore()
		for (r in removed) {
			var m = r.isStatic ? r.c.clStatics : r.c.clFields;
			if (m.get(r.cf.cfName) == r.cf) m.remove(r.cf.cfName);
		}

	// the bodies typed, and the modules their typing loaded finalized (the
	// program's types sorted again with them): their types
	static function typeAll(ctx:context.Typecore.Typer, lbs:Array<{ctx:context.Typecore.Typer, c:TClass, r:TLazy, late:Bool}>):Array<ModuleType> {
		for (lb in lbs)
			core.TFunctions.lazyType(lb.r);
		var fresh:Array<ModuleType> = [];
		if (moduleCount(ctx.com) != [for (_ in seen.keys()) 1].length) {
			var s = {types: sorted != null ? sorted : ctx.com.types, modules: [for (m in seen.keys()) m]};
			do {
				finalizeNew(ctx, s.types);
				s = typing.Finalization.sortTypes(ctx.com, ctx.com.moduleLut);
			} while (moduleCount(ctx.com) != s.modules.length);
			for (m in s.modules)
				if (!seen.exists(m)) {
					seen.set(m, true);
					for (t in m.mTypes)
						fresh.push(t);
				}
			sorted = s.types;
		}
		return fresh;
	}

	// the filters before DCE (Filters.run) on bodies typed after them
	static function filter(fields:Array<{c:TClass, cf:TClassField}>) {
		var l = filters.Filters.late;
		var com = LazyStd.com;
		var classes = [];
		for (f in fields) {
			var c = f.c, cf = f.cf;
			cf.removeClassFieldFlag(CfPostProcessed);
			if (cf.cfExpr != null && cf.cfExprUnoptimized == null && filters.Filters.mightNeedCfUnoptimized(c, cf)) cf.cfExprUnoptimized = cf.cfExpr;
			context.display.DeprecationCheck.runOnField({
				com: com,
				classMeta: c.clMeta,
				fieldMeta: core.ds.VectorTools.vector(),
				curmod: c.clModule
			}, cf);
			if (classes.indexOf(c) < 0) classes.push(c);
		}
		// (the classes' other fields are filtered already, CfPostProcessed, but
		// not their __init__, which the filters run on each time)
		var inits = [for (c in classes) c.clInit];
		for (c in classes)
			c.clInit = null;
		function back()
			for (i in 0...classes.length)
				classes[i].clInit = inits[i];
		var types = [for (c in classes) TClassDecl(c)];
		try {
			context.SafeCom.runWithScom(com, l.scom, () -> filters.Filters.runSafeFilters(l.ectx, com, l.scom, com.types, types, l.rename));
		} catch (e:Dynamic) {
			back();
			throw e;
		}
		back();
		for (t in types)
			filters.Filters.updateCacheDependencies(true, l.scom, t);
		for (f in fields)
			f.cf.addClassFieldFlag(CfPostProcessed);
	}

	// Filters.run's passes before DCE, on types loaded by bodies DCE typed
	static function late(com:context.Common.CommonContext, types:Array<ModuleType>) {
		var l = filters.Filters.late;
		for (t in types)
			switch t {
				case TClassDecl(c):
					for (i in c.clImplements)
						i.cls.addDescendant(c);
					if (c.clSuper != null) c.clSuper.cls.addDescendant(c);
					function field(cf:TClassField)
						if (cf.cfExpr != null && cf.cfExprUnoptimized == null && filters.Filters.mightNeedCfUnoptimized(c, cf)) cf.cfExprUnoptimized = cf.cfExpr;
					for (cf in c.clOrderedFields)
						field(cf);
					for (cf in c.clOrderedStatics)
						field(cf);
					if (c.clConstructor != null) field(c.clConstructor);
				case _:
			}
		context.display.DeprecationCheck.run(com, types);
		typing.NullSafety.run(com, types);
		context.SafeCom.runWithScom(com, l.scom, () -> filters.Filters.runSafeFilters(l.ectx, com, l.scom, com.types, types, l.rename));
		for (t in types)
			filters.Filters.updateCacheDependencies(true, l.scom, t);
		for (t in types)
			filters.Filters.saveClassState(com.partScope.compilationStep, t);
		context.SafeCom.runWithScom(com, l.scom, () -> filters.Filters.destructionBeforeDce(null, l.scom, types));
	}

	// Dce.lazyHook.types: the program's types for the sweep (sorted again when
	// DCE's typing loaded modules); a body still untyped there is a field
	// nothing reaches, which the sweep removes, unless its class is kept whole
	static function types(types:Array<ModuleType>):Array<ModuleType> {
		if (!on) return types;
		var r = sorted != null ? sorted : types;
		sorted = null;
		return r;
	}
}
