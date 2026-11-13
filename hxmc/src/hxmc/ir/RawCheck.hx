package hxmc.ir;

import core.TType;
import core.MetaList.StrictMeta;
import core.Message.WarningCode;

using core.TFunctions;

// Raw memory only in @:hxmc.unsafe code (docs/interop.md, "Unsafe code"),
// checked on the typed program, so whatever Haxe inlined counts as the code
// it was inlined into, at the call's position.
//
// Raw is:
//   - a value of hxmc.unsafe's types but its C scalars (Ptr, BytesPtr,
//     CString, Slice, Arena, IoBuffer, ...) or of an abstract over one
//     (KernelCheck.isRaw): a value, so whatever makes, passes or reads one;
//   - a call of Mem but its functions of values (KernelCheck.PURE_MEM and
//     the tag conversions of scalars), of Atomic, Blocking and Callback, of
//     the raw types' own functions, and Linux.syscall, whose arguments may
//     be addresses; such a function as a value too (Mem.setRefBarrier in
//     a local, then called). A C function of hxmc.unsafe (LibC, Posix, ...) or of
//     the program is raw through its types only: one of scalars is not.
//
// Trusted (unchecked) code is a function or class declared @:hxmc.unsafe,
// which also promises no GC point (Facts.findNoGc), or @:hxmc.unsafe(gc),
// which does not (GC code: Facts' raw-address check holds a heap address to
// the next GC point); and hxmc.unsafe's own modules, the raw API. An inline
// function's @:hxmc.unsafe goes with the copies Haxe inlines (the typer
// keeps it there: TargetFlags), so a trusted helper is trusted where it
// lands; an extern class's inline functions are checked as any. A trusted
// coroutine's state machine, the class its body moved to, is trusted with
// it (machines). Kernels are
// checked by KernelCheck (stricter); declarations of C functions and fields
// not at all, only their uses.
//
// In hxmc's std (a class path holding hxmc/unsafe/Mem.hx) a violation is an
// error; in the program's own code a warning, an error with -D hxmc.strict.
class RawCheck {
	public static inline var RULE = "raw memory needs @:hxmc.unsafe";

	// Mem's functions of values beyond the safe kernels' (KernelCheck.PURE_MEM)
	static final VALUES = ["mirHost", "compact", "abi", "tagInt", "tagFloat", "tagBool", "untagInt", "untagFloat", "untagBool"];

	// hxmc.unsafe's classes of C functions, raw through their types only
	static final C_CLASSES = ["LibC", "Posix", "Win32", "Winsock", "Linux"];

	var c:TClass;
	var cf:TClassField;
	var first:Null<String> = null;
	var firstPos:Null<core.Globals.Pos> = null;
	var count = 0;

	function new(c, cf) {
		this.c = c;
		this.cf = cf;
	}

	// the seconds spent checking (HXMC_STATS)
	public static var seconds = 0.0;

	// the violations of the typed program (TargetFlags: after typing, before
	// the filters, whose analyzer drops a statement's metadata): errors in
	// hxmc's std, warnings elsewhere, kept with the module (-D hxmc.strict: errors)
	public static function run(com:context.Common.CommonContext, types:Array<ModuleType>) {
		var t0 = haxe.Timer.stamp();
		check(com, types);
		seconds += haxe.Timer.stamp() - t0;
	}

	static function check(com:context.Common.CommonContext, types:Array<ModuleType>) {
		var roots = stdRoots([for (cp in com.classPaths.asList()) cp.path]);
		var strict = core.Define.rawDefined(com.defines, "hxmc.strict");
		// (HXMC_RAW_LIST=<file>: the violations listed there instead, to annotate them)
		var listFile = Sys.getEnv("HXMC_RAW_LIST");
		var list = [];
		var made = machines(types);
		for (t in types)
			switch t {
				// (a module typed in this build: one restored from a cache, the server's or
				// an archive, passed after the filters; its warnings come back with it)
				case TClassDecl(c) if (c.clModule.mExtra.mProcessed == 0 && !rawApi(c)):
					var std = inStd(c, roots);
					function field(cf:TClassField) {
						if (cf.cfExpr == null || trusted(c, cf) || made.exists(c)) return;
						var r = new RawCheck(c, cf);
						r.expr(cf.cfExpr);
						if (r.count == 0) return;
						if (listFile != null) {
							var kind = cf.cfKind.match(Method(MethInline)) ? "inline" : cf.cfKind.match(Var(_)) ? "var" : "method";
							list.push([cf.cfPos.pfile, "" + CInterop.lineOf(cf.cfPos.pfile, cf.cfPos.pmin), cf.cfName, kind, r.what()].join("\t"));
						} else if (std || strict) com.error(r.what(), r.firstPos) else context.Common.moduleWarning(com, c.clModule, WUser, com.warningOptions, r.what(), r.firstPos);
					}
					if (c.clConstructor != null) field(c.clConstructor);
					for (cf in c.clOrderedStatics)
						field(cf);
					for (cf in c.clOrderedFields)
						field(cf);
				case _:
			}
		if (list.length == 0) return;
		var o = sys.io.File.append(listFile);
		o.writeString(list.join("\n") + "\n");
		o.close();
	}

	// hxmc.unsafe's own modules (and their abstracts' implementations): the raw API
	static function rawApi(c:TClass):Bool
		return c.clPath.pack.length >= 2 && c.clPath.pack[0] == "hxmc" && c.clPath.pack[1] == "unsafe";

	static inline function unsafePack(p:Array<String>):Bool
		return p.length == 2 && p[1] == "unsafe" && p[0] == "hxmc";

	function what():String
		return core.Globals.sTypePath(c.clPath) + "." + cf.cfName + ": " + first + (count > 1 ? " and " + (count - 1) + " more" : "") + " (" + RULE + ")";

	// the class paths of hxmc's std
	public static function stdRoots(paths:Array<String>):Array<String>
		return [
			for (p in paths)
				if (p != "" && sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(p) + "hxmc/unsafe/Mem.hx"))
					normal(haxe.io.Path.addTrailingSlash(p))
		];

	static function normal(p:String):String
		return StringTools.replace(sys.FileSystem.absolutePath(p), "\\", "/");

	static var stdFiles = new Map<String, Bool>();

	static function inStd(c:TClass, roots:Array<String>):Bool {
		if (roots.length == 0) return false;
		var known = stdFiles.get(c.clPos.pfile);
		if (known != null) return known;
		var f = normal(c.clPos.pfile), r = false;
		for (root in roots)
			if (StringTools.startsWith(f, haxe.io.Path.addTrailingSlash(root))) r = true;
		stdFiles.set(c.clPos.pfile, r);
		return r;
	}

	static function has(ml:core.Ast.Metadata, n:String):Bool
		return ml.length > 0 && Lower.hasMeta(n, ml);

	// declared trusted (@:hxmc.unsafe) or a kernel (KernelCheck's)
	static function trusted(c:TClass, cf:TClassField):Bool {
		var ml = [c.clMeta, cf.cfMeta];
		switch c.clKind {
			case KAbstractImpl(a): ml.push(a.aMeta);
			case _:
		}
		for (m in ml)
			if (m.length > 0 && (Lower.isUnsafe(m) || has(m, ":hxmc.kernel"))) return true;
		return has(cf.cfMeta, ":hxmc.blocking");
	}

	// the state machines of trusted coroutines: the coroutine transform moves a
	// coroutine's body into a class of its own (a haxe.coro.BaseContinuation),
	// made by the function, or the closure, it was, which keeps none of the
	// function's metadata; it is trusted as the function that makes it is, so
	// @:hxmc.unsafe on a coroutine covers its whole body (and a coroutine
	// closure's made in it, transitively). Not one that unmarked code also
	// makes: an unmarked inline function's coroutine closure, inlined into a
	// marked one too, stays checked (one class for every copy)
	static function machines(types:Array<ModuleType>):Map<TClass, Bool> {
		var classes = [
			for (t in types)
				switch t {
					case TClassDecl(c) if (c.clModule.mExtra.mProcessed == 0 && !machine(c)): c;
					case _: continue;
				}
		];
		// (the machines that code reaches, through the machines it makes)
		function reach(seeds:Array<{c:TClass, e:TExpr}>, skip:Map<TClass, Bool>, sameModule:Bool):Map<TClass, Bool> {
			var made = new Map<TClass, Bool>(), work:Array<{c:TClass, e:TExpr}> = seeds.copy();
			while (work.length > 0) {
				var w = work.pop();
				function walk(e:TExpr) {
					switch e.eexpr {
						case TNew(k, _, _) if (!made.exists(k) && !skip.exists(k) && (!sameModule || k.clModule == w.c.clModule) && machine(k)):
							made.set(k, true);
							for (cf in fieldsOf(k))
								if (cf.cfExpr != null) work.push({c: k, e: cf.cfExpr});
						case _:
					}
					core.Texpr.iter(walk, e);
				}
				walk(w.e);
			}
			return made;
		}
		var marked = [], unmarked = [];
		for (c in classes)
			for (cf in fieldsOf(c))
				if (cf.cfExpr != null) (declared(c, cf) ? marked : unmarked).push({c: c, e: cf.cfExpr});
		return reach(marked, reach(unmarked, new Map(), false), true);
	}

	// (a class's functions and variables)
	static function fieldsOf(c:TClass):Array<TClassField>
		return (c.clConstructor == null ? [] : [c.clConstructor]).concat(c.clOrderedStatics).concat(c.clOrderedFields);

	// (declared @:hxmc.unsafe: not a kernel's trust, KernelCheck's)
	static function declared(c:TClass, cf:TClassField):Bool {
		if (Lower.isUnsafe(c.clMeta) || Lower.isUnsafe(cf.cfMeta)) return true;
		return switch c.clKind {
			case KAbstractImpl(a): Lower.isUnsafe(a.aMeta);
			case _: false;
		}
	}

	// (a coroutine's state machine: the class the transform made, HxCoro_..., a
	// haxe.coro.BaseContinuation in its function's module; not a continuation
	// the program declares)
	static function machine(c:TClass):Bool {
		if (!StringTools.startsWith(c.clPath.name, "HxCoro_")) return false;
		var s = c.clSuper;
		while (s != null) {
			var p = s.cls.clPath;
			if (p.name == "BaseContinuation" && p.pack.length == 2 && p.pack[0] == "haxe" && p.pack[1] == "coro") return true;
			s = s.cls.clSuper;
		}
		return false;
	}

	function fail(p:core.Globals.Pos, what:String) {
		if (count++ == 0) {
			first = what;
			firstPos = p;
		}
	}

	static function typeName(t:T):String
		return core.TPrinting.Printer.sType(t);

	// a call of f that is raw by the function alone (its types are checked as
	// values); also f as a value, which its calls then are (a closure of Mem
	// has no raw type)
	static function rawCall(f:TExpr, call = "a call of "):Null<String> {
		switch f.eexpr {
			case TField(_, FStatic(c, cf)):
				var owner = switch c.clKind {
					case KAbstractImpl(a): a.aPath;
					case _: c.clPath;
				};
				if (!unsafePack(owner.pack)) return null;
				var n = owner.name;
				var full = "hxmc.unsafe." + n + "." + cf.cfName;
				if (n == "Mem") return KernelCheck.PURE_MEM.indexOf(cf.cfName) >= 0 || VALUES.indexOf(cf.cfName) >= 0 ? null : call + full;
				if (n == "Linux" && cf.cfName == "syscall") return call + full;
				if (C_CLASSES.indexOf(n) >= 0 || n == "Struct" || KernelCheck.isScalar(n)) return null;
				return call + full;
			case _:
				return null;
		}
	}

	static function isTrust(m:core.Ast.MetadataEntry):Bool
		return switch m.meta {
			case Custom(":hxmc.unsafe"): true;
			case _: false;
		}

	function expr(e:TExpr) {
		switch e.eexpr {
			case TMeta(m, _) if (isTrust(m)):
				return;
			case TCall(f, _):
				var why = rawCall(f);
				if (why != null) return fail(e.epos, why);
			case TVar(v, _) if (KernelCheck.isRaw(v.vType)):
				return fail(e.epos, "the local " + v.vName + " of the raw type " + typeName(v.vType));
			case TField(_, FStatic(_, {cfKind: Method(_)})):
				var why = rawCall(e, "the function ");
				if (why != null) return fail(e.epos, why + " as a value");
			case TTypeExpr(m):
				// (a class of the raw API as a value: Dynamic reaches its
				// functions, `var p:Dynamic = BytesPtr; p.copyIn(...)`)
				var path = unsafeType(m);
				if (path != null) fail(e.epos, "the type " + path + " as a value");
				return;
			case _:
		}
		if (KernelCheck.isRaw(e.etype)) return fail(e.epos, "a value of the raw type " + typeName(e.etype));
		switch e.eexpr {
			case TField({eexpr: TTypeExpr(_)}, _):
				return; // (a static's owner, no value)
			case _:
		}
		core.Texpr.iter(expr, e);
	}

	static function unsafeType(m:ModuleType):Null<String> {
		var path = switch m {
			case TClassDecl({clKind: KAbstractImpl(a)}): a.aPath;
			case _: m.tPath();
		};
		return unsafePack(path.pack) ? core.Globals.sTypePath(path) : null;
	}
}
