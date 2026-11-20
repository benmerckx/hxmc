package core;

import core.Ast;
import core.Globals.Pos;
import core.Message.WarningCode;
import core.WarningList.WarningParseFailure;
import core.Message.WarningMode;
import core.Message.WarningOption;
import core.SourceScope.SourceScopeKind;
import core.SourceScope.SourceScopeInvalid;
import core.SourceScope.SourceScopeUnknownKind;

// port: an element of common.ml's scoped_warning_options, `(warning_option * SourceScope.t)`
typedef ScopedWarningOption = {opt:WarningOption, scope:SourceScopeKind};

// port: from haxe/src/core/warning.ml.
class Warning {
	// port: on the bytes of `s`, as upstream's positions are byte offsets
	public static function parseScopedOptions(s:String, ps:Pos):Array<{opt:WarningOption, scope:Null<SourceScopeKind>}> {
		var b = haxe.io.Bytes.ofString(s);
		var len = b.length;
		function fail(msg:String, pmin:Int, pmax:Int):Dynamic return Error.raiseTypingError(msg, {pfile: ps.pfile, pmin: ps.pmin + pmin, pmax: ps.pmin + pmax});
		function isSpace(c:Int) return c == " ".code || c == "\t".code || c == "\n".code || c == "\r".code;
		function scan(f:Int->Bool, i:Int):Int {
			while (i < len && f(b.get(i))) i++;
			return i;
		}
		function sub(i:Int, n:Int) return b.getString(i, n);
		function parseValue(i:Int):{v:String, k:Int} {
			if (i < len && b.get(i) == '"'.code) {
				var j = i + 1;
				while (j < len && b.get(j) != '"'.code) j++;
				if (j < len) return {v: sub(i + 1, j - i - 1), k: j + 1};
				return fail("Unterminated string", i, len);
			} else {
				var j = scan(c -> !isSpace(c), i);
				return {v: sub(i, j - i), k: j};
			}
		}
		function parseScope(i:Int):{scope:SourceScopeKind, k:Int} {
			var j = scan(SourceScope.isIdent, i);
			var value:Null<String> = null;
			var k = j;
			if (j < len && b.get(j) == ":".code) {
				var r = parseValue(j + 1);
				value = r.v;
				k = r.k;
			}
			return try {
				{scope: SourceScope.make(sub(i, j - i), value), k: k};
			} catch (e:SourceScopeInvalid) {
				fail(e.msg, i, k);
			} catch (_:SourceScopeUnknownKind) {
				fail(SourceScope.expected, i, j > i + 1 ? j : i + 1);
			}
		}
		var acc = [];
		var i = 0;
		while (true) {
			i = scan(isSpace, i);
			if (i >= len) return acc;
			var c = b.get(i);
			if (c == "+".code || c == "-".code) {
				var j = scan(SourceScope.isIdent, i + 1);
				var name = sub(i + 1, j - i - 1);
				if (name == "") fail("Expected identifier", i + 1, i + 2);
				var warning:WarningCode = try WarningList.fromString(name) catch (_:WarningParseFailure) fail('Unknown warning: $name', i + 1, j);
				var scope:Null<SourceScopeKind> = null;
				var k = j;
				if (j < len && b.get(j) == "@".code) {
					var r = parseScope(j + 1);
					scope = r.scope;
					k = r.k;
				}
				var mode = c == "+".code ? WMEnable : WMDisable;
				acc.push({opt: {woWarning: warning, woMode: mode}, scope: scope});
				i = k;
			} else {
				fail("Expected + or -", i, i + 1);
			}
		}
	}

	public static function parseOptions(s:String, ps:Pos):Array<WarningOption> {
		return parseScopedOptions(s, ps).map(function(o) {
			if (o.scope != null) Error.raiseTypingError("Warning scopes (@) are only supported by -w", ps);
			return o.opt;
		});
	}

	public static function fromMeta(ml:Metadata):Array<Array<WarningOption>> {
		var acc = [];
		for (entry in ml) if (entry.meta == Meta.HaxeWarning) for (arg in entry.exprs) {
			switch arg.expr {
				case EConst(String(s, _)):
					var p = arg.pos;
					acc.push(parseOptions(s, {pfile: p.pfile, pmin: p.pmin + 1, pmax: p.pmax - 1})); // pmin is on the quote
				case _:
					Error.raiseTypingError("String expected", arg.pos);
			}
		}
		return acc;
	}

	public static function getMode(w:WarningCode, lists:Array<Array<WarningOption>>):WarningMode {
		function matches(w:WarningCode, id:WarningCode):Bool {
			if (id == w) return true;
			var parent = WarningList.warningObj(w).wParent;
			return parent != null && matches(parent, id);
		}
		for (list in lists) for (opt in list) if (matches(w, opt.woWarning)) return opt.woMode;
		return WMEnable;
	}

	public static function matchesScoped(w:WarningCode, scoped:Array<ScopedWarningOption>, inScope:SourceScopeKind->Bool):Null<WarningMode> {
		function matches(w:WarningCode, id:WarningCode):Bool {
			if (id == w) return true;
			var parent = WarningList.warningObj(w).wParent;
			return parent != null && matches(parent, id);
		}
		for (o in scoped) if (matches(w, o.opt.woWarning) && inScope(o.scope)) return o.opt.woMode;
		return null;
	}
}
