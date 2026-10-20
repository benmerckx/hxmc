/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package typing;

/* Parsing of module files into modules. */

import core.Ast;
import core.Ast as AstTools;
import core.ClassPaths.ResolvedFile;
import core.Globals;
import core.Globals.*;
import core.Meta as MetadataTools;
import core.MetaList.StrictMeta as MetaTag;
import core.Path.UniqueKey;
import core.Define;
import core.DisplayTypes.DisplayModeValue;
import core.Error.*;
import core.ds.NotFound;
import core.ds.Record;
import context.Common;
import context.Common.*;
import context.Typecore.ForbidPackage;
import core.Message.CompilerMessageKind;
import core.Message.MessageKind;
import syntax.Parser;
import syntax.ParserConfig;
import syntax.ParserEntry;
import syntax.Grammar;
import syntax.Lexer;

@:structInit class SourceParseResult {
	public var data:Package;
	public var warnings:Array<ParseWarning>;

	public inline function new(data:Package, warnings:Array<ParseWarning>) {
		this.data = data;
		this.warnings = warnings;
	}

	public inline function clone():SourceParseResult return new SourceParseResult(data, warnings);
}

@:structInit class SourceModuleResult {
	public var file:ResolvedFile;
	public var declarations:Array<TypeDecl>;
	public var warnings:Array<ParseWarning>;

	public inline function new(file:ResolvedFile, declarations:Array<TypeDecl>, warnings:Array<ParseWarning>) {
		this.file = file;
		this.declarations = declarations;
		this.warnings = warnings;
	}

	public inline function clone():SourceModuleResult return new SourceModuleResult(file, declarations, warnings);
}

@:structInit class SourceModuleParts {
	public var file:ResolvedFile;
	public var remap:Array<String>;
	public var pack:Array<String>;
	public var declarations:Array<TypeDecl>;
	public var warnings:Array<ParseWarning>;

	public inline function new(file:ResolvedFile, remap:Array<String>, pack:Array<String>, declarations:Array<TypeDecl>,
			warnings:Array<ParseWarning>) {
		this.file = file;
		this.remap = remap;
		this.pack = pack;
		this.declarations = declarations;
		this.warnings = warnings;
	}
}

class DisplayInMacroBlock extends haxe.Exception {
	public function new() super("DisplayInMacroBlock");
}

class TypeloadParse {
	public static function parseFileFromString(com:CommonContext, file:String, p:Pos, source:String):ParseResult<Package> {
		return core.Timer.time(com.timerCtx, ["parsing"], function(source:String) {
			com.requestScope.stats.sFilesParsed++;
			var result = try ParserEntry.parse(ParserConfig.fileParserConfig(com, file), Grammar.parseFileStream, Lexer.createFileCtx(file),
				new Lexer(source, file), file) catch (_:syntax.Lexer.MalFormed)
				raiseTypingError("Malformed file. Source files must be encoded with UTF-8.", Globals.filePos(file));
			switch [com.display.dmsKind, result] {
				case [DMModuleSymbols(""), _]:
				case [DMModuleSymbols(filter), ParseSuccess(data, _)]
					if (filter == null && core.display.DisplayPosition.displayPosition.isInFile(com.partScope.fileKeys.get(file))):
					var ds = context.display.DocumentSymbols.collectModuleSymbols(null, filter == null, data);
					context.display.DisplayException.sendModuleSymbolsRaise(com,
						context.display.DocumentSymbols.DocumentSymbolsPrinter.jsonOfModuleSymbols(com, [
							{
								file: file,
								symbols: ds
							}
						], filter));
				case [_, ParseSuccess(_, pdi)] if (pdi.pdWasDisplayFile):
					if (pdi.pdHadResume) com.partScope.parserState.hadParserResume = true;
					com.partScope.parserState.delayedSyntaxCompletion.value = pdi.pdDelayedSyntaxCompletion;
				case _:
			}
			Common.log(com, "Parsed " + file);
			return result;
		}, source);
	}

	public static function parseFile(com:CommonContext, rfile:ResolvedFile, p:Pos):ParseResult<Package> {
		var key = com.partScope.fileKeys.get(rfile.file),
			contents:Null<String> = null;
		if (com.fileContents.length == 0
			&& Common.defined(com, Define.DisplayStdin)
			&& core.display.DisplayPosition.displayPosition.isInFile(key)) {
			var s = core.StringHelper.ofBytes(Sys.stdin().readAll());
			Sys.stdin().close();
			com.fileContents = [{fileKey: key, content: s}];
			contents = s;
		} else for (entry in com.fileContents) if (entry.fileKey == key) {
			contents = entry.content;
			break;
		}
		if (contents == null) {
			var bytes:haxe.io.Bytes;
			try bytes = sys.io.File.getBytes(rfile.file)
			catch (_:Dynamic) return raiseTypingError("Could not open " + rfile.file, p);
			// port: bytes that are not UTF-8 decode to lone surrogates, which the
			// lexer rejects as upstream's does (syntax.Lexer.MalFormed)
			contents = core.StringHelper.ofBytes(bytes);
		}
		return parseFileFromString(com, rfile.file, p, contents);
	}

	public static var parseHook:CommonContext->ResolvedFile->Pos->ParseResult<Package> = parseFile;

	public static function handleParserResult(com:CommonContext, p:Pos, result:ParseResult<Package>):SourceParseResult {
		inline function handleError(error:ParseErrorInfo):Void {
			var msg = Parser.errorMsg(error.message);
			switch com.display.dmsErrorPolicy {
				case EPShow:
					if (Common.isDiagnostics(com)) Common.addDiagnosticsMessage(com, msg, error.pos, MKError, 0, DKParserError);
					else raiseTypingError(msg, error.pos);
				case EPIgnore:
					com.partScope.hasError = true;
			}
		}
		return switch result {
			case ParseSuccess(data, pdi):
				if (pdi.pdWasDisplayFile) {
					if (pdi.pdErrors.length > 0) handleError(pdi.pdErrors[0]);
					PdiHandler.handlePdi(com, pdi);
				}
				{data: data, warnings: pdi.pdWarnings};
			case ParseError(data, error, _):
				handleError(error);
				{data: data, warnings: []};
		};
	}

	public static function parseModuleFile(com:CommonContext, rfile:ResolvedFile,
			p:Pos):SourceParseResult return handleParserResult(com, p, parseHook(com, rfile, p));

	public static function resolveModuleFile(com:CommonContext, path:GlobalTypePath, remap:{value:Array<String>}, p:Pos):ResolvedFile {
		try return com.moduleToFile.find(path)
		catch (_:NotFound) {}
		var classPaths:core.ClassPaths = com.classPaths;
		var forbidden = false, pack = path.pack.copy();
		if (pack.length > 0) switch com.packageRules.get(pack[0]) {
			case Forbidden:
				forbidden = true;
			case Remap(name):
				pack[0] = name;
				remap.value = pack.copy();
			case null:
		}
		// port: findFileNoRaise returns null where upstream raises Not_found.
		var lookup = classPaths.findFileNoRaise(pack.concat([path.name]).join("/") + ".hx");
		if (lookup == null) throw NotFound.raise();
		var rfile = lookup.resolvedFile;
		if (Sys.systemName() == "Windows") switch path.name.toLowerCase() {
			case "con", "aux", "prn", "nul", "com1", "com2", "com3", "lpt1", "lpt2", "lpt3":
				// these names are reserved by the OS - old DOS legacy, such files cannot be easily created but are reported as visible
				var size = try sys.FileSystem.stat(rfile.file).size catch (_:Dynamic) 0;
				if (size <= 0) throw NotFound.raise();
			case _:
		}
		// if we try to load a std.xxxx class and resolve a real std file, the package name is not valid, ignore
		if (path.pack.length > 0 && path.pack[0] == "std") {
			var key = com.partScope.fileKeys.get(rfile.file);
			for (cp in classPaths.getStdPaths()) if (UniqueKey.startsWith(key, com.partScope.fileKeys.get(cp.path))) throw NotFound.raise();
		}
		if (forbidden) {
			var meta:Metadata = [];
			switch parseHook(com, rfile, p) {
				case ParseSuccess(data, _):
					for (decl in data.declarations) {
						var found:Null<Metadata> = switch decl.definition {
							case EClass(d): d.meta;
							case EEnum(d): d.meta;
							case EAbstract(d): d.meta;
							case ETypedef(d): d.meta;
							case EStatic(d): d.meta;
							case EImport(_) | EUsing(_): null;
						};
						if (found != null) {
							meta = found;
							break;
						}
					}
				case ParseError(_, _, _):
			}
			if (!MetadataTools.has(MetaTag.NoPackageRestrict,
				meta)) throw new ForbidPackage({name: path.pack[0], path: path, pos: p}, [], Common.platformNameMacro(com));
		}
		com.moduleToFile.add(path, rfile);
		return rfile;
	}

	public static function parseModule_(com:CommonContext, path:GlobalTypePath, p:Pos):SourceModuleParts {
		var remap = {value: path.pack.copy()},
			rfile = resolveModuleFile(com, path, remap, p),
			parsed = parseModuleFile(com, rfile, p);
		return {
			file: rfile,
			remap: remap.value,
			pack: parsed.data.pack,
			declarations: parsed.data.declarations,
			warnings: parsed.warnings
		};
	}

	public static function parseModule(com:CommonContext, path:GlobalTypePath, p:Pos):SourceModuleResult {
		var remap = {value: path.pack.copy()},
			rfile = resolveModuleFile(com, path, remap, p),
			parsed = parseModuleFile(com, rfile, p),
			pack = parsed.data.pack;
		function same(a:Array<String>, b:Array<String>):Bool {
			if (a.length != b.length) return false;
			for (i in 0...a.length) if (a[i] != b[i]) return false;
			return true;
		}
		if (!same(pack, remap.value)) {
			inline function sPack(pack:Array<String>):String return pack.length == 0 ? "`package;`" : "`package " + pack.join(".") + ";`";
			if (p == Globals.nullPos) Common.displayError(com,
				"Invalid commandline class : " + Globals.sTypePath(path) + " should be " + Globals.sTypePath({
					pack: pack,
					name: path.name
				}), p);
			else Common.displayError(com, sPack(pack) + " in " + rfile.file + " should be " + sPack(path.pack),
				Record.withFields(p, {pmax: p.pmin}));
		}
		var declarations = parsed.data.declarations;
		if (!same(remap.value, path.pack)) {
			// build typedefs to redirect to real package
			var redirected:Array<TypeDecl> = [
				{
					definition: EImport({
						path: remap.value.concat([path.name]).map(s -> ({name: s, pos: Globals.nullPos} : core.Ast.PlacedName)),
						mode: INormal
					}),
					pos: Globals.nullPos
				}
			];
			inline function build(name:PlacedName, params:Array<TypeParam>, priv:Bool, p:Pos):Void {
				var tp = priv ? AstTools.mkTypePath([],
					"Dynamic") : AstTools.mkTypePath(remap.value, path.name,
						params.map(tp -> TPType(AstTools.makePtpTh(AstTools.mkTypePath([], tp.tpName.name), Globals.nullPos))), name.name);
				redirected.push({
					definition: ETypedef({
						name: name,
						doc: null,
						meta: [],
						params: params,
						flags: priv ? [TDPrivate] : [],
						data: AstTools.makePtpTh(tp, name.pos)
					}),
					pos: p
				});
			}
			for (decl in declarations) switch decl.definition {
				case EClass(d):
					build(d.name, d.params, d.flags.contains(HPrivate), decl.pos);
				case EEnum(d):
					build(d.name, d.params, d.flags.contains(EPrivate), decl.pos);
				case ETypedef(d):
					build(d.name, d.params, d.flags.contains(TDPrivate), decl.pos);
				case EAbstract(d):
					build(d.name, d.params, d.flags.contains(AbPrivate), decl.pos);
				case EStatic(d):
					build(d.name, d.params, core.ds.ArrayTools.exists(d.flags, f -> f.access == AStatic && f.pos == Globals.nullPos),
						decl.pos);
				case EImport(_) | EUsing(_):
			}
			declarations = redirected;
		}
		return {file: rfile, declarations: declarations, warnings: parsed.warnings};
	}
}

// port: module ConditionDisplay of typeloadParse.ml
class ConditionDisplay {
	static final tSemver:core.TType.T = TInst(core.TFunctions.mkClass(core.TFunctions.nullModule, {pack: [], name: "SemVer"},
		Globals.nullPos, Globals.nullPos), []);

	static function convertSmallType(com:CommonContext, v:syntax.ParserEntry.SmallType):{s:String, t:core.TType.T}
		return switch v {
			case TNull: {s: "null", t: core.TFunctions.mkMono()};
			case TBool(b): {s: b ? "true" : "false", t: com.basic.tbool};
			case TFloat(f): {s: core.Numeric.validFloatLexeme(core.ds.OcamlPrintf.formatG(12, f)), t: com.basic.tfloat};
			case TString(s): {s: "\"" + core.StringHelper.sEscape(s) + "\"", t: com.basic.tstring};
			case TVersion(r): {s: syntax.SemVer.SemVerTools.toString(r), t: tSemver};
		};

	public static function checkCondition(com:CommonContext, e:Expr):Void {
		var dp = core.display.DisplayPosition.displayPosition.get();
		function checkPosition(p:Pos):Bool return com.display.dmsKind == DMHover ? core.display.DisplayPosition.enclosesPositionGt(dp,
			p) : core.display.DisplayPosition.enclosesPosition(dp, p);
		function tpair(t:core.TType.T):core.display.CompletionItem.TPair return {
			t: t,
			ct: core.display.CompletionItem.CompletionType.fromType(function(_) return Imported, t)
		};
		function checkExpr(e:Expr):Void switch e.expr {
			case ECall({expr: EConst(Ident("version")), pos: p}, _):
				var t = core.TType.T.TFun({args: [{name: "s", optional: false, type: com.basic.tstring}], ret: tSemver});
				if (checkPosition(p)) context.display.DisplayException.sendHoverRaise(com, core.display.CompletionItem.makeCiClassField({
					field: {
						cfName: "version",
						cfType: t,
						cfPos: Globals.nullPos,
						cfNamePos: Globals.nullPos,
						cfDoc: AstTools.docFromString("Allows comparing defines (such as the version of a Haxelib or Haxe) with SemVer semantics.
Both the define and the string passed to `version()` must be valid semantic versions.

Example:
```haxe
#if (haxe >= version(\"4.0.0-rc.3\"))\n
```

Note: this syntax does not parse with Haxe versions earlier than 4.0.0-rc.3,
so it should be avoided if backwards-compatibility with earlier versions is needed.

@see https://semver.org/"),
						cfMeta: [],
						cfKind: Method(MethNormal),
						cfParams: [],
						cfExpr: null,
						cfExprUnoptimized: null,
						cfOverloads: [],
						cfFlags: core.TFunctions.setFlag(0, core.TFunctions.intOfClassFieldFlag(CfPublic))
					},
					scope: CFSStatic,
					origin: BuiltIn,
					isQualified: true
				}, tpair(t)), null, p);
			case EConst(Ident(n)):
				var v = ParserEntry.eval(com.defines, e);
				context.display.DisplayException.sendHoverRaise(com, core.display.CompletionItem.makeCiDefine(n, switch v {
					case TNull: null;
					case TString(s): core.StringHelper.sEscape(s);
					case _: throw new core.Globals.InternalCompilerError("typeloadParse.ml: unexpected define value", "");
				}, tpair(com.basic.tstring)), null, e.pos);
			case _:
		}
		function loop(e:Expr):Void {
			if (checkPosition(e.pos)) checkExpr(e);
			AstTools.iterExpr(loop, e);
			if (checkPosition(e.pos)) {
				var v = ParserEntry.eval(com.defines, e);
				var r = convertSmallType(com, v);
				context.display.DisplayException.sendHoverRaise(com, core.display.CompletionItem.makeCiLiteral(r.s, tpair(r.t)), null,
					e.pos);
			}
		}
		loop(e);
	}
}

// port: module PdiHandler of typeloadParse.ml
class PdiHandler {
	static function isTrue(defines:core.Define.DefineContext, e:Expr):Bool return ParserEntry.isTrue(ParserEntry.eval(defines, e));

	public static function handlePdi(com:CommonContext, pdi:ParserDisplayInformation):Void {
		var macroDefines = Common.adaptDefinesToMacroContext(com.defines);
		var dp = core.display.DisplayPosition.displayPosition.get();
		function check(p:Pos):Bool return com.display.dmsKind == DMHover ? core.display.DisplayPosition.enclosesPositionGt(dp,
			p) : core.display.DisplayPosition.enclosesPosition(dp, p);
		for (b in pdi.pdDeadBlocks) {
			var hasMacroDefine = isTrue(macroDefines, b.expr);
			if (hasMacroDefine) com.partScope.parserState.displayModuleHasMacroDefines = true;
			if (check(b.pos)) {
				if (hasMacroDefine) throw new DisplayInMacroBlock();
				switch com.display.dmsKind {
					case DMHover:
						context.display.DisplayException.sendNoResultRaise(com);
					case _:
				}
			}
		}
		switch com.display.dmsKind {
			case DMHover:
				for (e in pdi.pdConditions) ConditionDisplay.checkCondition(com, e);
			case _:
		}
	}
}
