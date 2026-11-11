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
//     be addresses. A C function of hxmc.unsafe (LibC, Posix, ...) or of
//     the program is raw through its types only: one of scalars is not.
//
// Trusted (unchecked) code is a function or class declared @:hxmc.unsafe,
// which also promises no GC point (Facts.findNoGc), or @:hxmc.unsafe(gc),
// which does not (GC code: Facts' raw-address check holds a heap address to
// the next GC point); and hxmc.unsafe's own modules, the raw API. An inline
// function's @:hxmc.unsafe goes with the copies Haxe inlines (the typer
// keeps it there: TargetFlags), so a trusted helper is trusted where it
// lands. Kernels are checked by KernelCheck (stricter); declarations of C
// functions and fields not at all, only their uses.
//
// In hxmc's std (a class path holding hxmc/unsafe/Mem.hx) a violation is an
// error; in the program's own code a warning, an error with -D hxmc.strict.
class RawCheck {
	public static inline var RULE = "raw memory needs @:hxmc.unsafe";

	// Mem's functions of values beyond the safe kernels' (KernelCheck.PURE_MEM)
	static final VALUES = ["mirHost", "compact", "abi", "tagInt", "tagFloat", "tagBool", "untagInt", "untagFloat", "untagBool"];

	// hxmc.unsafe's classes of C functions, raw through their types only
	static final C_CLASSES = ["LibC", "Posix", "Win32", "Winsock", "Linux"];

	var name:String;
	var first:Null<String> = null;
	var firstPos:Null<core.Globals.Pos> = null;
	var count = 0;

	function new(name)
		this.name = name;

	// the violations of the typed program (TargetFlags: after typing, before
	// the filters, whose analyzer drops a statement's metadata): errors in
	// hxmc's std, warnings elsewhere, kept with the module (-D hxmc.strict: errors)
	public static function run(com:context.Common.CommonContext, types:Array<ModuleType>) {
		var roots = stdRoots([for (cp in com.classPaths.asList()) cp.path]);
		var strict = core.Define.rawDefined(com.defines, "hxmc.strict");
		// (HXMC_RAW_LIST=<file>: the violations listed there instead, to annotate them)
		var listFile = Sys.getEnv("HXMC_RAW_LIST");
		var list = [];
		for (t in types)
			switch t {
				// (a module typed in this build: one restored from a cache, the server's or
				// an archive, passed after the filters; its warnings come back with it)
				case TClassDecl(c) if (c.clModule.mExtra.mProcessed == 0 && !c.hasClassFlag(CExtern) && !rawApi(c)):
					var std = inStd(c, roots);
					function field(cf:TClassField) {
						if (cf.cfExpr == null || trusted(c, cf)) return;
						var r = new RawCheck(core.Globals.sTypePath(c.clPath) + "." + cf.cfName);
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

	function what():String
		return name + ": " + first + (count > 1 ? " and " + (count - 1) + " more" : "") + " (" + RULE + ")";

	// the class paths of hxmc's std
	public static function stdRoots(paths:Array<String>):Array<String>
		return [
			for (p in paths)
				if (p != "" && sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(p) + "hxmc/unsafe/Mem.hx"))
					normal(haxe.io.Path.addTrailingSlash(p))
		];

	static function normal(p:String):String
		return StringTools.replace(sys.FileSystem.absolutePath(p), "\\", "/");

	static function inStd(c:TClass, roots:Array<String>):Bool {
		if (roots.length == 0) return false;
		var f = normal(c.clPos.pfile);
		for (r in roots)
			if (StringTools.startsWith(f, haxe.io.Path.addTrailingSlash(r))) return true;
		return false;
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

	function fail(p:core.Globals.Pos, what:String) {
		if (count++ == 0) {
			first = what;
			firstPos = p;
		}
	}

	static function typeName(t:T):String
		return core.TPrinting.Printer.sType(t);

	// a call of f that is raw by the function alone (its types are checked as values)
	static function rawCall(f:TExpr):Null<String> {
		switch f.eexpr {
			case TField(_, FStatic(c, cf)):
				var pack = c.clPath.pack.join(".");
				var owner = switch c.clKind {
					case KAbstractImpl(a): a.aPath;
					case _: c.clPath;
				};
				if (owner.pack.join(".") != "hxmc.unsafe" && pack != "hxmc.unsafe") return null;
				var n = owner.name;
				var full = "hxmc.unsafe." + n + "." + cf.cfName;
				if (n == "Mem") return KernelCheck.PURE_MEM.indexOf(cf.cfName) >= 0 || VALUES.indexOf(cf.cfName) >= 0 ? null : "a call of " + full;
				if (n == "Linux" && cf.cfName == "syscall") return "a call of " + full;
				if (C_CLASSES.indexOf(n) >= 0 || n == "Struct" || KernelCheck.isScalar(n)) return null;
				return "a call of " + full;
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
			case TTypeExpr(_):
				return;
			case _:
		}
		if (KernelCheck.isRaw(e.etype)) return fail(e.epos, "a value of the raw type " + typeName(e.etype));
		core.Texpr.iter(expr, e);
	}
}
