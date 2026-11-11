package hxmc.ir;

import core.TType;
import core.Ast.Binop;

// The versions of Apple's systems a declaration needs (docs/interop.md,
// "Availability"): `@:hxmc.available("macos 14.0", "ios 17.0",
// "maccatalyst 17.0")` on a class, a protocol, a field or an enum
// abstract's constant; a platform it does not list, every version of it.
// hxmc.Platform.available takes the same list and tests it at run time.
// Versions are numbers as LC_BUILD_VERSION writes them: major << 16 |
// minor << 8 | patch (0: any version). Mac Catalyst's are iOS's.
// AvailCheck checks the uses; Lower binds the imports of the newer ones
// weakly (CInterop.WEAK) and lowers the tests (FnLower).
class Available {
	public static inline var META = ":hxmc.available";

	// the platforms the list may name; hxmc's targets are the first three
	static final PLATFORMS = ["macos", "ios", "maccatalyst", "tvos", "watchos", "visionos", "driverkit"];

	// the name of an Abi.platform's in the list (null: none of Apple's)
	public static function platformOf(platform:String):Null<String>
		return switch platform {
			case "macos": "macos";
			case "ios" | "ios-simulator": "ios";
			case "maccatalyst": "maccatalyst";
			case _: null;
		}

	// the target's, during the lowering (Lower.targetPlatform)
	public static function lowered():Null<String>
		return Lower.targetOs != 1 ? null : Lower.targetPlatform == 0 ? "macos" : Lower.targetPlatform == 3 ? "maccatalyst" : "ios";

	public static function shown(platform:String):String
		return switch platform {
			case "macos": "macOS";
			case "ios": "iOS";
			case "maccatalyst": "Mac Catalyst";
			case p: p;
		}

	public static function version(v:Int):String
		return (v >> 16) + "." + ((v >> 8) & 0xff) + (v & 0xff != 0 ? "." + (v & 0xff) : "");

	// "macos 14.0": the version if it is platform's, 0 if another's, -1 if
	// it is no platform and version
	public static function entry(s:String, platform:String):Int {
		var r = ~/^([a-z]+) ([0-9]+)(\.[0-9]+)?(\.[0-9]+)?$/;
		if (!r.match(s) || PLATFORMS.indexOf(r.matched(1)) < 0) return -1;
		inline function part(i:Int):Int
			return r.matched(i) == null ? 0 : Std.parseInt(r.matched(i).substr(1));
		var major = Std.parseInt(r.matched(2)), minor = part(3), patch = part(4);
		if (major > 0xff || minor > 0xff || patch > 0xff) return -1;
		return r.matched(1) == platform ? (major << 16) | (minor << 8) | patch : 0;
	}

	// the version of platform an @:hxmc.available's (or
	// Platform.available's) list asks for (0: any); bad: an entry that is
	// no string literal of a platform and version
	public static function of(exprs:haxe.ds.Vector<core.Ast.Expr>, platform:String, ?bad:core.Ast.Expr->Void):Int {
		var v = 0;
		for (e in exprs) {
			var n = switch e.expr {
				case EConst(core.Ast.Constant.String(s, _)): entry(s, platform);
				case _: -1;
			}
			if (n < 0 && bad != null) bad(e);
			if (n > v) v = n;
		}
		return v;
	}

	public static function isMeta(m:core.Ast.MetadataEntry):Bool
		return switch m.meta {
			case core.MetaList.StrictMeta.Custom(n): n == META;
			case _: false;
		}

	// hxmc.Platform.available's arguments (its rest: an array of them, or, as
	// typed, a block of a variable of the array or filling one, then the
	// variable cast) the version of platform they ask for (0:
	// any), or -1 if one is no string literal of a platform and version. On
	// Mac Catalyst, a list without its entry asks for iOS's, as Swift's
	// #available does (dyld answers a Catalyst process's iOS version)
	public static function test(args:haxe.ds.Vector<TExpr>, platform:String):Int {
		var v = 0, ios = 0, own = false;
		function arg(e:TExpr)
			switch e.eexpr {
				case TArrayDecl(xs):
					for (x in xs)
						arg(x);
				case TBlock(xs):
					for (x in xs)
						switch x.eexpr {
							case TBinop(OpAssign, _, i): arg(i);
							case TVar(_, i) if (i != null && i.eexpr.getIndex() == TArrayDecl(null).getIndex()): arg(i);
							case _:
						}
				case TParenthesis(x) | TCast(x, null) | TMeta(_, x):
					arg(x);
				case TConst(TString(s)):
					var n = entry(s, platform);
					if (n < 0 || v < 0) v = -1 else if (n > v) v = n;
					if (platform == "maccatalyst") {
						var i = entry(s, "ios");
						if (i > ios) ios = i;
						if (StringTools.startsWith(s, "maccatalyst ")) own = true;
					}
				case _:
					v = -1;
			}
		for (a in args)
			arg(a);
		return v >= 0 && platform == "maccatalyst" && !own ? ios : v;
	}

	// the version of platform metadata ml asks for (0: any)
	public static function required(ml:core.Ast.Metadata, platform:String):Int {
		if (ml.length == 0) return 0;
		var v = 0;
		for (m in ml)
			if (isMeta(m)) {
				var n = of(m.exprs, platform);
				if (n > v) v = n;
			}
		return v;
	}

	// the version of the target's platform a field of c needs (its own, its
	// class's; a property's accessor, its property's)
	public static function field(c:TClass, cf:TClassField, platform:String):Int {
		var v = required(cf.cfMeta, platform), k = required(c.clMeta, platform);
		if (k > v) v = k;
		switch c.clKind {
			case KAbstractImpl(a):
				var n = required(a.aMeta, platform);
				if (n > v) v = n;
			case _:
		}
		var n = cf.cfName;
		if ((StringTools.startsWith(n, "get_") || StringTools.startsWith(n, "set_")) && n.length > 4) {
			var p = c.clFields.get(n.substr(4));
			if (p == null) p = c.clStatics.get(n.substr(4));
			if (p != null) {
				var pv = required(p.cfMeta, platform);
				if (pv > v) v = pv;
			}
		}
		return v;
	}

	// a C function, C variable or class newer than the deployment target,
	// whose import is bound weakly: 0 on a system without it (Lower)
	public static function weak(c:TClass, ?cf:TClassField):Bool {
		var p = lowered();
		if (p == null) return false;
		return (cf != null ? field(c, cf, p) : required(c.clMeta, p)) > Lower.targetMin;
	}
}
