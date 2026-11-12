package hxmc.ir;

import core.TType;
import core.Ast.Binop;
import core.Ast.Expr;

// The versions of Apple's systems a declaration needs (docs/interop.md,
// "Availability"): `@:hxmc.available(macos >= 14.0, ios >= 17.0,
// maccatalyst >= 17.0)` on a class, a protocol, a field or an enum
// abstract's constant, conditions as `#if` and `@:require` write them; a
// platform it does not list, every version of it. hxmc.Platform.supports
// tests a declaration's (AvailGuard: Platform.atLeast's three versions,
// PLATFORMS' first); `#if (macos >= 14.0)` the deployment target. Versions
// are numbers as LC_BUILD_VERSION writes them: major << 16 | minor << 8 |
// patch (0: any version), read from the literal's text (10.15 is newer than
// 10.9) or version("10.15.4"). Mac Catalyst's are iOS's. AvailCheck checks
// the uses; Lower binds the imports of the newer ones weakly (CInterop.WEAK)
// and lowers the tests (FnLower).
class Available {
	public static inline var META = ":hxmc.available";

	// the platforms an entry may name; hxmc's targets are the first three, in
	// the order of Platform.atLeast's arguments (another system's, android or
	// windows, would be one more name here and argument there)
	public static final PLATFORMS = ["macos", "ios", "maccatalyst", "tvos", "watchos", "visionos", "driverkit"];

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

	// "14.0", "10.15", "17", "10.15.4" (-1: no version)
	public static function parse(s:String):Int {
		var r = ~/^([0-9]+)(\.[0-9]+)?(\.[0-9]+)?$/;
		if (!r.match(s)) return -1;
		inline function part(i:Int):Int
			return r.matched(i) == null ? 0 : Std.parseInt(r.matched(i).substr(1));
		var major = Std.parseInt(r.matched(1)), minor = part(2), patch = part(3);
		if (major > 0xff || minor > 0xff || patch > 0xff) return -1;
		return (major << 16) | (minor << 8) | patch;
	}

	// a version as an entry writes it: a number's literal (its text, not
	// its value) or version("10.15.4"), as #if's (-1: none)
	static function number(e:Expr):Int
		return switch e.expr {
			case EConst(Int(s, null)) | EConst(Float(s, null)): parse(s);
			case ECall({expr: EConst(Ident("version"))}, args) if (args.length == 1):
				switch args[0].expr {
					case EConst(String(s, _)): parse(s);
					case _: -1;
				}
			case EParenthesis(x): number(x);
			case _: -1;
		}

	// a list's entries, `platform >= version` (`||` of them too, as
	// @:require writes them); bad: one that is not
	public static function entries(exprs:haxe.ds.Vector<Expr>, ?bad:Expr->Void):Array<{platform:String, version:Int}> {
		var out = [];
		function add(e:Expr)
			switch e.expr {
				case EParenthesis(x):
					add(x);
				case EBinop(OpBoolOr, a, b):
					add(a);
					add(b);
				case EBinop(OpGte, {expr: EConst(Ident(p))}, v) if (PLATFORMS.indexOf(p) >= 0 && number(v) >= 0):
					out.push({platform: p, version: number(v)});
				case _:
					if (bad != null) bad(e);
			}
		for (e in exprs)
			add(e);
		return out;
	}

	// the version of platform an @:hxmc.available's list asks for (0: any)
	public static function of(exprs:haxe.ds.Vector<Expr>, platform:String):Int {
		var v = 0;
		for (e in entries(exprs))
			if (e.platform == platform && e.version > v) v = e.version;
		return v;
	}

	public static function isMeta(m:core.Ast.MetadataEntry):Bool
		return switch m.meta {
			case core.MetaList.StrictMeta.Custom(n): n == META;
			case _: false;
		}

	// Platform.atLeast's arguments (AvailGuard) the version of platform they
	// ask for (0: any), or -1 if they are not its constants
	public static function test(args:haxe.ds.Vector<TExpr>, platform:String):Int {
		var i = PLATFORMS.indexOf(platform);
		if (i < 0 || i >= args.length) return 0;
		return switch args[i].eexpr {
			case TConst(TInt(v)): v;
			case _: -1;
		}
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
