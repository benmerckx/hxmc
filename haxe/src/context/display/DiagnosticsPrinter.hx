package context.display;

import core.Globals;
import core.Globals.Pos;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.Message.CompilerMessage;
import core.Message.MessageKind;
import core.Message.MessageSeverity;
import core.TFunctions.*;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import core.json.Genjson;
import core.json.Genjson.*;
import context.Common;
import core.Message;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;

@:structInit class Diagnostic {
	public var diagKind:MessageKind;
	public var diagPos:Pos;
	public var diagSeverity:MessageSeverity;
	public var diagCode:Null<String>;
	public var diagArgs:JsonValue;
	public var diagRelatedInformation:Array<{pos:Pos, depth:Int, msg:String}>;

	public inline function new(diagKind:MessageKind, diagPos:Pos, diagSeverity:MessageSeverity, diagCode:Null<String>, diagArgs:JsonValue,
			diagRelatedInformation:Array<{
			pos:Pos,
			depth:Int,
			msg:String
		}>) {
		this.diagKind = diagKind;
		this.diagPos = diagPos;
		this.diagSeverity = diagSeverity;
		this.diagCode = diagCode;
		this.diagArgs = diagArgs;
		this.diagRelatedInformation = diagRelatedInformation;
		}
}

enum UnresolvedIdentifierSuggestion {
	UISImport;
	UISTypo;
}

class DiagnosticsPrinter {
	public static function makeDiagnostic(kd:MessageKind, p:Pos, sev:MessageSeverity, code:Null<String>, args:JsonValue):Diagnostic return {
		diagKind: kd,
		diagPos: p,
		diagSeverity: sev,
		diagCode: code,
		diagArgs: args,
		diagRelatedInformation: []
	};

	public static function isDiagnosticsFile(com:CommonContext, fileKey:String):Bool {
		return switch com.partScope.reportMode {
			case RMDiagnostics(fileKeys): fileKeys.length == 0 || fileKeys.contains(fileKey);
			case _: false;
		};
	}

	// port: isDiagnosticsFile on the report mode's files (DiagnosticsContext.reportFiles)
	// port: not upstream: jsonOfDiagnostics' deprecation warnings (the enabled ones of the
	// ... warned positions), as the context has them when the result is found
	public static function deprecations(com:CommonContext):Array<{message:String, pos:Pos}> {
		var l = [];
		switch core.Warning.getMode(WDeprecated, com.warningOptions) {
			case WMEnable:
				(com.partScope.warnedPositions : OcamlHashtbl<{file:String, offset:Int},
					{message:String, pos:Pos, options:Array<Array<core.Message.WarningOption>>}>).iter(function(_, w) {
						switch core.Warning.getMode(WDeprecated, com.warningOptions.concat(w.options)) {
							case WMEnable: l.push({message: w.message, pos: w.pos});
							case WMDisable:
						}
					});
			case WMDisable:
		}
		return l;
	}

	public static function isReportedFile(reportFiles:Null<Array<String>>, fileKey:String):Bool
		return reportFiles != null && (reportFiles.length == 0 || reportFiles.contains(fileKey));

	static inline function posEq(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	/**
		Convert a single missing_fields_diagnostics to its JSON form and
		store it as a [Message.t] with [DKMissingFields].

		The JSON carries: moduleType, moduleFile, and a single entry
		(with "fields" and "cause"). The printer groups entries by
		position, handles cross-entry field deduplication, and wraps
		them in the final "entries" array.
	**/
	public static function makeMissingFieldsMessage(mf:MissingFieldsDiagnostics):CompilerMessage {
		var jctx = Genjson.createMinimalConfig();
		function scope(cf:TClassField):ClassFieldScope return hasClassFieldFlag(cf, CfStatic) ? CFSStatic : CFSMember;
		var kind:String, args:JsonValue;
		switch mf.mfCause {
			case AbstractParent(csup, tl):
				kind = "AbstractParent";
				args = jobject([
					kv("parent", generateTypePathWithParams(jctx, csup.clModule.mPath, csup.clPath, tl, csup.clMeta))
				]);
			case ImplementedInterface(ci, tl):
				kind = "ImplementedInterface";
				args = jobject([
					kv("parent", generateTypePathWithParams(jctx, ci.clModule.mPath, ci.clPath, tl, ci.clMeta))
				]);
			case PropertyAccessor(cf, isGetter):
				kind = "PropertyAccessor";
				args = jobject([
					kv("property", generateClassField(jctx, scope(cf), cf)),
					kv("isGetter", jbool(isGetter))
				]);
			case FieldAccess:
				kind = "FieldAccess";
				args = jobject([]);
			case FinalFields(cfl):
				kind = "FinalFields";
				args = jobject([kv("fields", jarray(cfl.map(cf -> generateClassField(jctx, scope(cf), cf))))]);
		}
		var currentFields:Array<{t:T, cf:TClassField}> = [];
		function mapField(f:{field:TClassField, type:T, completion:CompletionTypeKind}):Null<JsonValue> {
			var cf = f.field.clone();
			cf.cfOverloads = [];
			var t = f.type;
			if (core.ds.ArrayTools.exists(currentFields,
				e -> cf.cfName == e.cf.cfName && codegen.Overloads.sameOverloadArgs(t, e.t, cf, e.cf))) return null;
			currentFields.unshift({t: t, cf: cf});
			return jobject([
				kv("name", jstring(cf.cfName)),
				kv("field", generateClassField(jctx, scope(cf), cf)),
				kv("type", CompletionType.generateType(jctx, f.completion))
			]);
		}
		var fields = [];
		for (f in mf.mfFields) {
			var j = mapField(f);
			if (j != null) fields.push(j);
		}
		var entry = jobject([
			kv("fields", jarray(fields)),
			kv("cause", jobject([kv("kind", jstring(kind)), kv("args", args)]))
		]);
		var jctx2 = jctx.clone();
		jctx2.generateMemberBodies = false;
		var j = jobject([
			kv("moduleType", generateModuleType(jctx2, mf.mfOn)),
			kv("moduleFile", jstring(core.Path.UniqueKey.lazyPath(tInfos(mf.mfOn).mtModule.mExtra.mFile))),
			kv("entry", entry)
		]);
		return core.Message.Message.makeDiagnostic(false, DKMissingFields, j, mf.mfPos, 0, MKError);
	}

	/** Create a [Message.t] for an UnresolvedIdentifier diagnostic. **/
	public static function makeUnresolvedIdentifierMessage(i:String, p:Pos,
			suggestions:Array<{s:String, item:CompletionItemData, r:Int}>):CompilerMessage {
		var out = [];
		for (sugg in suggestions) {
			var j:Null<JsonValue> = switch sugg.item.ciKind {
				case ITType(t, _) if (sugg.r == 0):
					var path:GlobalTypePath = t.moduleName == t.name ? {pack: t.pack, name: t.name} : {
						pack: t.pack.concat([t.moduleName]),
						name: t.name
					};
					JObject([
						kv("kind", JInt(std.Type.enumIndex(UISImport))),
						kv("name", JString(Globals.sTypePath(path)))
					]);
				case _ if (sugg.r == 0):
					// TODO !!!
					null;
				case _:
					JObject([kv("kind", JInt(std.Type.enumIndex(UISTypo))), kv("name", JString(sugg.s))]);
			};
			if (j != null) out.push(j);
		}
		return core.Message.Message.makeDiagnostic(false, DKUnresolvedIdentifier, JArray(out), p, 0, MKError);
	}

	public static function jsonOfDiagnostics(dctx:DiagnosticsContext):JsonValue {
		var diagnostics = new OcamlHashtbl<String, Array<Diagnostic>>(OcamlHash.hashString, (a, b) -> a == b, 0);
		var current:Null<Diagnostic> = null;
		function add_(append:Bool, diag:Diagnostic):Void {
			var p = diag.diagPos;
			var file = posEq(p, Globals.nullPos) ? p.pfile : core.Path.getRealPath(p.pfile);
			var fdiag = diagnostics.findOpt(file);
			if (fdiag == null) {
				var d = [];
				diagnostics.add(file, d);
				fdiag = d;
			}
			if (append
				|| !core.ds.ArrayTools.exists(fdiag, diag -> posEq(diag.diagPos, p))) diagnostics.replace(file, [diag].concat(fdiag));
		}
		var fileKeys = new context.Common.FileKeys();
		function add(dk:MessageKind, p:Pos, sev:MessageSeverity, code:Null<String>, args:JsonValue):Void {
			var append = switch dk {
				case DKUnusedImport | DKReplacableCode | DKDeprecationWarning | DKInactiveBlock: false;
				case DKUnresolvedIdentifier | DKCompilerMessage | DKParserError | DKMissingFields: true;
			};
			if (posEq(p, Globals.nullPos) || isReportedFile(dctx.reportFiles, fileKeys.get(p.pfile))) {
				var diag = makeDiagnostic(dk, p, sev, code, args);
				current = diag;
				add_(append, diag);
			} else current = null;
		}
		// Collect DKMissingFields messages for grouping by position
		var missingFieldsByPos = new OcamlHashtbl<Pos, Array<CompilerMessage>>(OcamlHash.hashPos, posEq, 0);
		var messages = dctx.messages.copy();
		messages.reverse();
		for (d in messages) switch [d.cmDepth, d.cmDiagnosticsKind] {
			case [0, DKMissingFields]:
				var entries = missingFieldsByPos.findOpt(d.cmPos);
				if (entries == null) entries = [];
				missingFieldsByPos.replace(d.cmPos, [d].concat(entries));
			case _:
		}
		for (d in messages) {
			if (d.cmDiagnosticsKind == DKMissingFields) {
				// Handled separately via missing_fields_by_pos
			} else if (d.cmDepth > 0 && current != null) {
				var diag = current;
				var depth = d.cmDepth;
				// port: ExtString.String.nsplit "" returns []
				var lines = d.cmMessage == "" ? [] : d.cmMessage.split("\n");
				if (lines.length == 0) continue;
				var s = lines[0];
				var sub = lines.slice(1);
				var rsub = sub.copy();
				rsub.reverse();
				var related = [];
				for (s in rsub) related.unshift({pos: d.cmPos, depth: depth, msg: core.Error.complMsg(s)});
				diag.diagRelatedInformation = diag.diagRelatedInformation.concat([{pos: d.cmPos, depth: depth, msg: s}].concat(related));
			} else if (d.cmDepth == 0) {
				add(d.cmDiagnosticsKind, d.cmPos, core.Message.Message.severity(d), core.Message.Message.code(d), d.cmJson);
			} else {
				// Do not add errors with depth greater than one as top level diagnostic.
				// This could happen when running diagnostics for a file that is wentioned in
				// sub errors of a file not included for diagnostics.
			}
		}
		// Group MissingFields entries by position and emit combined diagnostics.
		// Cross-entry field deduplication adds "unique" flags.
		missingFieldsByPos.iter(function(p, entries) {
			var moduleType:JsonValue = JNull;
			var moduleFile:JsonValue = JNull;
			var allFieldNames = new haxe.ds.StringMap<Bool>();
			function assoc(fields:Array<JsonField>, name:String):Null<JsonValue> {
				for (f in fields) if (f.name == name) return f.value;
				return null;
			}
			function processEntry(d:CompilerMessage):Null<JsonValue> {
				return switch d.cmJson {
					case JObject(fields):
						var j = assoc(fields, "moduleType");
						if (j != null) moduleType = j;
						var j = assoc(fields, "moduleFile");
						if (j != null) moduleFile = j;
						switch assoc(fields, "entry") {
							case JObject(entryFields):
								var entryFieldJsons = switch assoc(entryFields, "fields") {
									case JArray(fl):
										fl.map(function(fj) {
											var name = switch fj {
												case JObject(l): switch assoc(l, "name") {
														case JString(n): n;
														case _: "";
													};
												case _: "";
											};
											var unique = !allFieldNames.exists(name);
											allFieldNames.set(name, true);
											return switch fj {
												case JObject(l): JObject(l.concat([kv("unique", jbool(unique))]));
												case _: fj;
											};
										});
									case _: [];
								};
								var cause = assoc(entryFields, "cause");
								if (cause == null) cause = JNull;
								jobject([kv("fields", jarray(entryFieldJsons)), kv("cause", cause)]);
							case _: null;
						}
					case _: null;
				};
			}
			// cl_interfaces is reversed, reverse again to restore order
			var rentries = entries.copy();
			rentries.reverse();
			var groupedEntries = [];
			for (d in rentries) {
				var e = processEntry(d);
				if (e != null) groupedEntries.push(e);
			}
			var j = jobject([
				kv("moduleType", moduleType),
				kv("moduleFile", moduleFile),
				kv("entries", jarray(groupedEntries))
			]);
			add(DKMissingFields, p, Error, null, j);
		});
		// non-append from here
		for (w in dctx.deprecations) add(DKDeprecationWarning, w.pos, Warning, core.WarningList.warningObj(WDeprecated).wName, JString(w.message));
		for (ip in ImportHandling.sortedImportPositions(dctx.importPositions)) {
			if (!ip.used.value) add(DKUnusedImport, ip.pos, Warning, null, JArray([]));
		}
		for (rc in dctx.replaceableCode) {
			add(DKReplacableCode, rc.displayRange, Warning, null, JObject([
				kv("description", JString(rc.reason)),
				kv("newCode", JString(rc.replacement)),
				kv("range", posEq(rc.replaceRange, Globals.nullPos) ? JNull : generatePosAsRange(rc.replaceRange))
			]));
		}
		dctx.deadBlocks.iter(function(file, ranges) {
			for (r in ranges) {
				var jo = JObject([kv("expr", JObject([kv("string", JString(core.AstPrinter.sExpr(r.expr)))]))]);
				add(DKInactiveBlock, r.pos, Hint, null, jo);
			}
		});
		var jl = diagnostics.fold(function(file, diag:Array<Diagnostic>, acc:Array<JsonValue>) {
			// port: List.rev_map
			var jl = [];
			for (diag in diag) jl.unshift(JObject([
				kv("kind", JInt(core.Message.Message.diagnosticsKindToInt(diag.diagKind))),
				kv("severity", JInt(core.Message.Message.severityToInt(diag.diagSeverity))),
				kv("range", generatePosAsRange(diag.diagPos)),
				kv("args", diag.diagArgs),
				kv("code", diag.diagCode == null ? JNull : JString(diag.diagCode)),
				kv("relatedInformation", JArray(diag.diagRelatedInformation.map(r -> JObject([
					kv("location", generatePosAsLocation(r.pos)),
					kv("depth", JInt(r.depth)),
					kv("message", JString(r.msg))
				]))))
			]));
			acc.unshift(JObject([kv("file", file == "?" ? JNull : JString(file)), kv("diagnostics", JArray(jl))]));
			return acc;
		}, []);
		return JArray(jl);
	}
}
