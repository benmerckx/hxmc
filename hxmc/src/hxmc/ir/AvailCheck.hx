package hxmc.ir;

import core.TType;
import core.Ast.Binop;
import core.Ast.Unop;
import core.Globals.Pos;
import core.Message.WarningCode;

using core.TFunctions;

// The uses of declarations newer than the deployment target (Available;
// docs/interop.md, "Availability"), checked on the typed program of an
// Apple target as RawCheck is: whatever Haxe inlined counts as the code it
// was inlined into, and an inlined constant or function keeps its
// @:hxmc.available (TargetFlags). A use is a field read, written or called
// (a property's accessors are the property), a class or enum as a value,
// `new`, an enum constant; it needs the version of its declaration and of
// its class (or abstract). A use is allowed:
//   - where the deployment target has the version;
//   - in a function or class that @:hxmc.available gives it (its callers
//     are checked instead);
//   - guarded: in the then-branch of `if (Platform.available(...))` (and
//     the right of `&&`), the else-branch of `if (!Platform.available(...))`
//     (the right of `||`), and after `if (!Platform.available(...)) return;`
//     (or throw, break, continue) in its block.
// Else it is a warning (-D hxmc.strict: an error). A class extending a newer
// class is checked as a use of it.
class AvailCheck {
	// the seconds spent checking (HXMC_STATS)
	public static var seconds = 0.0;

	final com:context.Common.CommonContext;
	final platform:String;
	final min:Int;
	final strict:Bool;
	var module:ModuleDef;
	var seen = new Map<String, Bool>();

	function new(com, platform, min) {
		this.com = com;
		this.platform = platform;
		this.min = min;
		strict = core.Define.rawDefined(com.defines, "hxmc.strict");
	}

	// (TargetFlags: after typing, before the filters, as RawCheck)
	public static function run(com:context.Common.CommonContext, types:Array<ModuleType>) {
		var t0 = haxe.Timer.stamp();
		var t = target(com.defines);
		if (t != null) new AvailCheck(com, t.platform, t.min).check(types);
		seconds += haxe.Timer.stamp() - t0;
	}

	// the target's platform and deployment target, from the defines (null:
	// not one of Apple's; a bad version is Options.read's error)
	static function target(d:core.Define.DefineContext):Null<{platform:String, min:Int}> {
		inline function def(k:String):Null<String>
			return core.Define.rawDefined(d, k) ? core.Define.rawDefinedValue(d, k) : null;
		var t = def("hxmc.target");
		var abi = try Abi.get(t != null && t != "1" ? t : Options.host()) catch (_:Dynamic) null;
		var p = abi != null ? Available.platformOf(abi.platform) : null;
		if (p == null) return null;
		var floor = p == "macos" ? LinkMachO.macosMin(abi.arm) : LinkMachO.IOS_MIN;
		var v = try Options.minVersion(p == "macos" ? "macos" : "ios", def(p == "macos" ? "hxmc.macos_min_version" : "hxmc.ios_min_version"), floor) catch (_:Dynamic) null;
		return {platform: p, min: v ?? floor};
	}

	function check(types:Array<ModuleType>) {
		for (t in types)
			switch t {
				case TClassDecl(c) if (c.clModule.mExtra.mProcessed == 0):
					module = c.clModule;
					declared(c.clMeta);
					var own = Available.required(c.clMeta, platform);
					var floor = own > min ? own : min;
					var s = c.clSuper;
					if (s != null && !c.hasClassFlag(CExtern)) {
						var need = Available.required(s.cls.clMeta, platform);
						if (need > floor) report(c.clPos, c.clPath.name + " extends " + s.cls.clPath.name, need, floor);
					}
					function field(cf:TClassField) {
						declared(cf.cfMeta);
						if (cf.cfExpr == null) return;
						var v = Available.field(c, cf, platform);
						expr(cf.cfExpr, v > floor ? v : floor);
					}
					if (c.clConstructor != null) field(c.clConstructor);
					for (cf in c.clOrderedStatics)
						field(cf);
					for (cf in c.clOrderedFields)
						field(cf);
				case _:
			}
	}

	// an @:hxmc.available's entries: string literals of a platform and a version
	function declared(ml:core.Ast.Metadata) {
		if (ml.length == 0) return;
		for (m in ml)
			if (Available.isMeta(m)) {
				if (m.exprs.length == 0) com.error("@:hxmc.available: list a platform and a version (\"macos 14.0\")", m.pos);
				Available.of(m.exprs, platform, e -> com.error("@:hxmc.available: a platform and a version (\"macos 14.0\") as a string literal", e.pos));
			}
	}

	function report(p:Pos, what:String, need:Int, floor:Int) {
		var v = Available.version(need);
		var msg = what + ": " + Available.shown(platform) + " " + v + " and later, "
			+ (floor > min ? "this code is for " + Available.version(floor) + " and later" : "the deployment target is " + Available.version(min))
			+ ' (guard it with Platform.available("$platform $v"))';
		var key = p.pfile + ":" + p.pmin + ":" + msg;
		if (seen.exists(key)) return;
		seen.set(key, true);
		if (strict) com.error(msg, p) else context.Common.moduleWarning(com, module, WUser, com.warningOptions, msg, p);
	}

	function use(p:Pos, c:TClass, cf:TClassField, floor:Int) {
		var need = Available.field(c, cf, platform);
		if (need <= floor) return;
		var owner = switch c.clKind {
			case KAbstractImpl(a): a.aPath.name;
			case _: c.clPath.name;
		};
		var n = cf.cfName;
		if ((StringTools.startsWith(n, "get_") || StringTools.startsWith(n, "set_")) && (c.clFields.exists(n.substr(4)) || c.clStatics.exists(n.substr(4))))
			n = n.substr(4);
		report(p, owner + "." + n, need, floor);
	}

	function useClass(p:Pos, c:TClass, floor:Int) {
		var need = Available.required(c.clMeta, platform);
		if (need > floor) report(p, c.clPath.name, need, floor);
	}

	static function isTest(f:TExpr):Bool
		return switch f.eexpr {
			case TField(_, FStatic(c, cf)): cf.cfName == "available" && c.clPath.name == "Platform" && c.clPath.pack.length == 1 && c.clPath.pack[0] == "hxmc";
			case _: false;
		}

	// the version a condition guarantees when true (0: none)
	function guard(e:TExpr):Int
		return switch e.eexpr {
			case TParenthesis(x) | TMeta(_, x) | TCast(x, null): guard(x);
			case TCall(f, args) if (isTest(f)):
				max(0, Available.test(args, platform));
			case TBinop(OpBoolAnd, a, b):
				var x = guard(a), y = guard(b);
				x > y ? x : y;
			case _: 0;
		}

	// ... when false
	function unguard(e:TExpr):Int
		return switch e.eexpr {
			case TParenthesis(x) | TMeta(_, x): unguard(x);
			case TUnop(Not, _, x): guard(x);
			case TBinop(OpBoolOr, a, b):
				var x = unguard(a), y = unguard(b);
				x > y ? x : y;
			case _: 0;
		}

	static function exits(e:TExpr):Bool
		return switch e.eexpr {
			case TReturn(_) | TThrow(_) | TBreak | TContinue: true;
			case TBlock(el): el.length > 0 && exits(el[el.length - 1]);
			case TParenthesis(x) | TMeta(_, x): exits(x);
			case _: false;
		}

	static inline function max(a:Int, b:Int):Int
		return a > b ? a : b;

	function expr(e:TExpr, floor:Int) {
		switch e.eexpr {
			case TField(x, FStatic(c, cf) | FInstance(c, _, cf)):
				use(e.epos, c, cf, floor);
				// (C.f: C's version is f's)
				if (!x.eexpr.match(TTypeExpr(_))) expr(x, floor);
				return;
			case TField(x, FClosure(o, cf)) if (o != null):
				use(e.epos, o.cls, cf, floor);
				if (!x.eexpr.match(TTypeExpr(_))) expr(x, floor);
				return;
			case TField(x, FEnum(en, ef)):
				var need = max(Available.required(ef.efMeta, platform), Available.required(en.eMeta, platform));
				if (need > floor) report(e.epos, en.ePath.name + "." + ef.efName, need, floor);
				return;
			case TTypeExpr(TClassDecl(c)):
				return useClass(e.epos, c, floor);
			case TNew(c, _, args):
				var need = c.clConstructor != null ? Available.field(c, c.clConstructor, platform) : Available.required(c.clMeta, platform);
				if (need > floor) report(e.epos, "new " + c.clPath.name, need, floor);
				for (a in args)
					expr(a, floor);
				return;
			case TMeta(m, x) if (Available.isMeta(m)):
				// (an inlined constant or function: its own version)
				var need = Available.of(m.exprs, platform);
				if (need > floor) report(e.epos, shown(e), need, floor);
				return expr(x, max(floor, need));
			case TIf(cond, a, b):
				expr(cond, floor);
				expr(a, max(floor, guard(cond)));
				if (b != null) expr(b, max(floor, unguard(cond)));
				return;
			case TBinop(OpBoolAnd, a, b):
				expr(a, floor);
				return expr(b, max(floor, guard(a)));
			case TBinop(OpBoolOr, a, b):
				expr(a, floor);
				return expr(b, max(floor, unguard(a)));
			case TBlock(el):
				var f = floor;
				for (x in el) {
					expr(x, f);
					switch x.eexpr {
						case TIf(cond, a, null) if (exits(a)): f = max(f, unguard(cond));
						case TIf(cond, a, b) if (b != null && exits(b)): f = max(f, guard(cond));
						case _:
					}
				}
				return;
			case _:
		}
		core.Texpr.iter(x -> expr(x, floor), e);
	}

	static var sources = new Map<String, String>();

	// what an inlined use was written as: its source up to a call's
	// arguments (NSWindowStyleMask.Titled, view.frameRate)
	static function shown(e:TExpr):String {
		var p = e.epos;
		var src = sources.get(p.pfile);
		if (src == null) {
			src = try sys.io.File.getContent(p.pfile) catch (_:Dynamic) "";
			sources.set(p.pfile, src);
		}
		var s = p.pmax <= src.length ? src.substring(p.pmin, p.pmax) : "";
		var call = s.indexOf("(");
		if (call > 0) s = s.substr(0, call);
		s = StringTools.trim(s);
		return s != "" ? s : core.TPrinting.Printer.sType(e.etype);
	}
}
