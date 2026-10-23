package hxmc;

import core.Ast;
import core.MetaList.StrictMeta;
import core.TType;
import hxmc.macro.HostTable.HostFps;
import syntax.Parser.ParseResult;

// The bodies the macro context of -D hxmc.macros=mir need not parse
// (interp.MacroRuntime). That context loads hxmc's whole runtime (Std imports
// hxmc.rt.Runtime), whose parsing was most of what the runtime still cost
// a cold build there once the runtime's functions the compiler has were no
// longer typed (a trivial macro: 0.07 G of 1.15 G instructions). A
// compiler with Mir macros (a Mir host) carries their lines (macro.HostTable,
// made at its link: Driver.hostCuts): for each file of
// the runtime (hxmc.rt, hxmc.unsafe), its content's hash and the ranges of
// the block bodies that macro context never types: those of the static
// functions MacroRuntime takes as the compiler's native code, by their
// declaration (`eligible`: a subset of what MacroRuntime decides, which
// also has the typed signature) and by what the executable has (its
// fingerprints' flags, `nativeFlags`). The macro context blanks those ranges
// (`apply`, from TypeloadParse.sourceHook) when the file is the same:
// `{throw "hxmc.cut";}` padded with spaces, the line breaks kept, so that
// every position in the file stays the same. A function whose body is cut
// and that MacroRuntime would type fails the build (MacroRuntime.body).
class MacroCuts {
	public static inline var MARKER = "hxmc.cut";
	static inline var STUB = 'throw "hxmc.cut";';

	// the symbol of a static function's native code (Facts.symbol: its
	// export's, or F_ and its name); cls: its class's path, `_` between the parts
	public static function symbol(cls:String, field:String, meta:Metadata):String {
		var exported = meta.length > 0 ? hxmc.ir.Lower.metaString(":hxmc.export", meta) : null;
		return exported != null ? exported : "F_" + @:privateAccess hxmc.ir.Facts.ident(cls + "_" + field);
	}

	// the flags (HostFps) of the compiler's native code of that symbol when it
	// may stand for the function: the compiler has it, no other function may
	// have that symbol (Facts numbers the others of one name: sym_1, ...) and
	// the Mir inliner does not copy it into callers (code loaded at run time
	// would copy a body there is none of); else -1
	public static function nativeFlags(fps:HostFps, sym:String):Int {
		var flags = fps.flags(sym);
		if (flags < 0 || flags & HostFps.INLINE != 0 || fps.flags(sym + "_1") >= 0) return -1;
		return flags;
	}

	// whether a body returns no value (its own `return`s: not those of the
	// functions in it), which typeFunction makes Void when no type is written
	public static function returnsNothing(e:Expr):Bool {
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

	// ---- writing (the compiler's build, a Mir host)

	// the lines (the compiler's link: macro.HostTable carries them), given the compiler's fingerprints
	public static function text(com:context.Common.CommonContext, fps:HostFps):String {
		var files = new Map<String, String>();
		for (t in com.types)
			switch t {
				case TClassDecl(c) if (c.clPath.pack.length >= 2 && c.clPath.pack[0] == "hxmc" && (c.clPath.pack[1] == "rt" || c.clPath.pack[1] == "unsafe")):
					var rel = c.clModule.mPath.pack.join("/") + "/" + c.clModule.mPath.name + ".hx";
					if (!files.exists(rel)) files.set(rel, c.clPos.pfile);
				case _:
			}
		var rels = [for (k in files.keys()) k];
		rels.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		var lines = [];
		for (rel in rels) {
			var source = try core.StringHelper.ofBytes(sys.io.File.getBytes(files.get(rel))) catch (_:Dynamic) continue;
			var ranges = cuts(com, rel, source, fps);
			if (ranges.length > 0) lines.push(rel + " " + Fingerprint.hash(source) + " " + ranges.join(" ") + "\n");
		}
		return lines.join("");
	}

	// the ranges (a-b) of the bodies in file `rel` (hxmc/rt/Dyn.hx) to cut
	static function cuts(com:context.Common.CommonContext, rel:String, source:String, fps:HostFps):Array<String> {
		// (positions count code points: with no surrogate pair, they are the string's indices)
		for (i in 0...source.length)
			if (StringTools.fastCodeAt(source, i) & 0xF800 == 0xD800) return [];
		// (a name of its own: the lexer's table of the file's lines stays the one typing made)
		var name = rel + "#cuts";
		var parsed = syntax.ParserEntry.parse(syntax.ParserConfig.fileParserConfig(com, name), syntax.Grammar.parseFileStream,
			syntax.Lexer.createFileCtx(name), new syntax.Lexer(source, name), name);
		var pkg = switch parsed {
			case ParseSuccess(data, _): data;
			case ParseError(_, _, _): return [];
		}
		var out = [];
		for (d in pkg.declarations)
			switch d.definition {
				case EClass(cd) if (plain(cd)):
					var cls = pkg.pack.concat([cd.name.name]).join("_");
					for (f in cd.data)
						switch f.cffKind {
							case FFun(fd) if (eligible(f, fd) && nativeFlags(fps, symbol(cls, f.cffName.name, f.cffMeta)) >= 0):
								var a = fd.fExpr.pos.pmin, b = fd.fExpr.pos.pmax;
								if (closed(source, a, b) && blank(source, a, b) != null) out.push(a + "-" + b);
							case _:
						}
				case _:
			}
		return out;
	}

	// a class neither extern, an interface nor private (whose path, which
	// names its functions' code, is its module's)
	static function plain(cd:ClassDefinition):Bool {
		for (f in cd.flags)
			switch f {
				case HExtern | HInterface | HPrivate: return false;
				case _:
			}
		return true;
	}

	// a static function MacroRuntime takes as the compiler's native code, by
	// its declaration: not inline, macro, extern, dynamic, overloaded or a
	// coroutine, without type parameters, its arguments' types written and
	// none of them optional, its result's type written or no value returned
	// (Void), its body a block
	static function eligible(f:ClassField, fd:Func):Bool {
		var isStatic = false;
		for (a in f.cffAccess)
			switch a.access {
				case AStatic: isStatic = true;
				case AInline | AMacro | AExtern | ADynamic | AOverride | AAbstract | AOverload: return false;
				case _:
			}
		if (!isStatic || f.cffName.name == "__init__" || fd.fParams.length > 0 || fd.fExpr == null) return false;
		if (core.Meta.has(Custom(":hxmc.callback"), f.cffMeta) || core.Meta.has(Overload, f.cffMeta) || core.Meta.has(Coroutine, f.cffMeta))
			return false;
		for (a in fd.fArgs)
			if (a.optional || a.expr != null || a.type == null) return false;
		if (!fd.fExpr.expr.match(EBlock(_))) return false;
		return fd.fType != null || returnsNothing(fd.fExpr);
	}

	// whether the conditional compilation in source[a, b) closes in it: no
	// #else, #elseif or #end of an #if outside (blanking it would leave its
	// #if open)
	static function closed(source:String, a:Int, b:Int):Bool {
		var depth = 0;
		var i = a;
		while (i < b) {
			if (StringTools.fastCodeAt(source, i) != "#".code) {
				i++;
				continue;
			}
			var w = i + 1;
			while (w < b && StringTools.fastCodeAt(source, w) >= "a".code && StringTools.fastCodeAt(source, w) <= "z".code)
				w++;
			switch source.substring(i + 1, w) {
				case "if": depth++;
				case "end": if (--depth < 0) return false;
				case "else" | "elseif": if (depth == 0) return false;
				case _:
			}
			i = w;
		}
		return depth == 0;
	}

	static var spaces = "                                                                ";

	// the block source[a, b) blanked: the stub on its first line with room,
	// spaces elsewhere, the line breaks where they were; null when it is not
	// a block or no line has room
	static function blank(source:String, a:Int, b:Int):Null<String> {
		if (b - a < STUB.length + 2 || StringTools.fastCodeAt(source, a) != "{".code || StringTools.fastCodeAt(source, b - 1) != "}".code) return null;
		var buf = new StringBuf();
		buf.addChar("{".code);
		var placed = false;
		var i = a + 1, end = b - 1;
		while (i < end) {
			// (a line: [i, e), then its break)
			var e = i;
			while (e < end) {
				var c = StringTools.fastCodeAt(source, e);
				if (c == "\n".code || c == "\r".code) break;
				e++;
			}
			var n = e - i;
			if (!placed && n >= STUB.length) {
				buf.add(STUB);
				n -= STUB.length;
				placed = true;
			}
			while (n > 0) {
				var k = n < spaces.length ? n : spaces.length;
				buf.addSub(spaces, 0, k);
				n -= k;
			}
			if (e < end) buf.addChar(StringTools.fastCodeAt(source, e));
			i = e + 1;
		}
		buf.addChar("}".code);
		return placed ? buf.toString() : null;
	}

	// ---- reading (the macro context)

	// the cuts of the lines by file (hxmc/rt/Dyn.hx), with the hash of the content they are of
	public static function read(text:String):Map<String, {hash:String, ranges:Array<Int>}> {
		var m = new Map();
		for (line in text.split("\n")) {
			var parts = line.split(" ");
			if (parts.length < 3) continue;
			var ranges = [];
			for (k in 2...parts.length) {
				var ab = parts[k].split("-");
				ranges.push(Std.parseInt(ab[0]));
				ranges.push(Std.parseInt(ab[1]));
			}
			m.set(parts[0], {hash: parts[1], ranges: ranges});
		}
		return m;
	}

	// the source with the cuts blanked, or null when it is not the content they are of
	public static function apply(source:String, cuts:{hash:String, ranges:Array<Int>}):Null<String> {
		if (Fingerprint.hash(source) != cuts.hash) return null;
		var buf = new StringBuf();
		var at = 0;
		var k = 0;
		while (k < cuts.ranges.length) {
			var a = cuts.ranges[k], b = cuts.ranges[k + 1];
			var s = a >= at && b <= source.length ? blank(source, a, b) : null;
			if (s == null) return null;
			buf.addSub(source, at, a - at);
			buf.add(s);
			at = b;
			k += 2;
		}
		buf.addSub(source, at, source.length - at);
		return buf.toString();
	}
}
