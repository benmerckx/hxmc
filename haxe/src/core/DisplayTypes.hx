package core;

import core.Globals.Pos;
import core.Ast.Expr;
import core.TType;
import core.TFunctions.*;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.json.Genjson;
import core.json.Genjson.GenjsonContext;
import core.display.CompletionItem;

// port: from haxe/src/core/displayTypes.ml
enum SymbolKindValue {
	Class;
	Interface;
	Enum;
	TypeAlias;
	Abstract;
	Field;
	Property;
	Method;
	Constructor;
	Function;
	Variable;
	Struct;
	EnumAbstract;
	Operator;
	EnumMember;
	Constant;
	Module;
}

class SymbolKind {
	public static function toInt(kind:SymbolKindValue):Int return std.Type.enumIndex(kind) + 1;
}

@:structInit class SymbolInformationData {
	public var name:String;
	public var kind:SymbolKindValue;
	public var pos:Pos;
	public var containerName:Null<String>;
	public var deprecated:Bool;

	public inline function new(name:String, kind:SymbolKindValue, pos:Pos, containerName:Null<String>, deprecated:Bool) {
		this.name = name;
		this.kind = kind;
		this.pos = pos;
		this.containerName = containerName;
		this.deprecated = deprecated;
	}
}

class SymbolInformation {
	public static function make(name:String, kind:SymbolKindValue, pos:Pos, containerName:Null<String>,
			deprecated:Bool):SymbolInformationData return {
			name: name,
			kind: kind,
			pos: pos,
			containerName: containerName,
			deprecated: deprecated
		};
}

@:structInit class ExpectedTypeCompletion {
	public var expectedType:CompletionTypeKind;
	public var expectedTypeFollowed:CompletionTypeKind;
	public var compatibleTypes:Array<CompletionTypeKind>;

	public inline function new(expectedType:CompletionTypeKind, expectedTypeFollowed:CompletionTypeKind,
			compatibleTypes:Array<CompletionTypeKind>) {
		this.expectedType = expectedType;
		this.expectedTypeFollowed = expectedTypeFollowed;
		this.compatibleTypes = compatibleTypes;
	}
}

enum CompletionResultKindValue {
	CRField(item:CompletionItemData, pos:Pos, iterator:Null<T>, keyValueIterator:Null<{key:T, value:T}>);
	CRStructureField;
	CRToplevel(expected:Null<ExpectedTypeCompletion>);
	CRMetadata;
	CRTypeHint;
	CRExtends;
	CRImplements;
	CRStructExtension(isIntersectionType:Bool);
	CRImport;
	CRUsing;
	CRNew;
	CRPattern(expected:Null<ExpectedTypeCompletion>, isOutermostPattern:Bool);
	CROverride;
	CRTypeRelation;
	CRTypeDecl;
}

class CompletionResultKind {
	public static function toJson(ctx:GenjsonContext, kind:CompletionResultKindValue):JsonValue {
		inline function kv(n:String, v:JsonValue):JsonField return {name: n, value: v};
		function expectedTypeFields(t:Null<ExpectedTypeCompletion>):Array<JsonField> {
			if (t == null) return [];
			return [
				kv("expectedType", CompletionType.toJson(ctx, t.expectedType)),
				kv("expectedTypeFollowed", CompletionType.toJson(ctx, t.expectedTypeFollowed)),
				kv("compatibleTypes", Genjson.jarray(t.compatibleTypes.map(CompletionType.toJson.bind(ctx))))
			];
		}
		var i:Int, args:Null<JsonValue> = null;
		switch kind {
			case CRField(item, p, iterator, keyValueIterator):
				var t = CompletionItem.getType(item);
				var t:Null<{mt:JsonValue, mtFollowed:JsonValue, ct:JsonValue}> = if (t == null) null else {
					try {
						var mt = moduleTypeOfType(t.t);
						var ctx = ctx.clone();
						ctx.generateAbstractImpl = true;
						function make(mt:ModuleType):JsonValue return Genjson.generateModuleType(ctx, mt);
						var jMt = make(mt);
						var jMtFollowed = t.t == follow(t.t) ? Genjson.jnull : make(moduleTypeOfType(follow(t.t)));
						{mt: jMt, mtFollowed: jMtFollowed, ct: CompletionType.toJson(ctx, t.ct)};
					} catch (_:Dynamic) {
						null;
					}
				};
				var fields = [
					kv("item", CompletionItem.toJson(ctx, null, item)),
					kv("range", Genjson.generatePosAsRange(p)),
					kv("iterator", iterator == null ? Genjson.jnull : Genjson.jobject([kv("type", Genjson.generateType(ctx, iterator))])),
					kv("keyValueIterator", keyValueIterator == null ? Genjson.jnull : Genjson.jobject([
						kv("key", Genjson.generateType(ctx, keyValueIterator.key)),
						kv("value", Genjson.generateType(ctx, keyValueIterator.value))
					]))
				];
				if (t != null) fields = fields.concat([kv("type", t.ct), kv("moduleType", t.mt), kv("moduleTypeFollowed", t.mtFollowed)]);
				i = 0;
				args = Genjson.jobject(fields);
			case CRStructureField:
				i = 1;
			case CRToplevel(t):
				i = 2;
				args = Genjson.jobject(expectedTypeFields(t));
			case CRMetadata:
				i = 3;
			case CRTypeHint:
				i = 4;
			case CRExtends:
				i = 5;
			case CRImplements:
				i = 6;
			case CRStructExtension(isIntersectionType):
				i = 7;
				args = Genjson.jobject([kv("isIntersectionType", Genjson.jbool(isIntersectionType))]);
			case CRImport:
				i = 8;
			case CRUsing:
				i = 9;
			case CRNew:
				i = 10;
			case CRPattern(t, isOutermostPattern):
				var fields = [kv("isOutermostPattern", Genjson.jbool(isOutermostPattern))].concat(expectedTypeFields(t));
				i = 11;
				args = Genjson.jobject(fields);
			case CROverride:
				i = 12;
			case CRTypeRelation:
				i = 13;
			case CRTypeDecl:
				i = 14;
		}
		var fl = [kv("kind", Genjson.jint(i))];
		if (args != null) fl.push(kv("args", args));
		return Genjson.jobject(fl);
	}
}

enum DisplayModeValue {
	DMNone;
	DMDefault;

	/**
		Find usages/references of the requested symbol.
		@param definition - add symbol definition to the response
		@param descendants - also find usages of descendants of the symbol (e.g methods, which override the requested one)
		@param base - look for a base method if requested for a method with `override` accessor.
	**/
	DMUsage(definition:Bool, descendants:Bool, base:Bool);

	DMDefinition;
	DMTypeDefinition;
	DMImplementation;
	DMPackage;
	DMHover;
	DMModuleSymbols(filter:Null<String>);
	DMSignature;
}

enum ErrorPolicy {
	EPIgnore;
	EPShow;
}

enum DisplayFilePolicy {
	DFPOnly;
	DFPAlso;
	DFPNo;
}

typedef DisplaySettings = {
	var dmsKind:DisplayModeValue;
	var dmsFullTyping:Bool;
	var dmsForceMacroTyping:Bool;
	var dmsErrorPolicy:ErrorPolicy;
	var dmsCheckCoreApi:Bool;
	var dmsInline:Bool;
	var dmsDisplayFilePolicy:DisplayFilePolicy;
	var dmsExitDuringTyping:Bool;
	var dmsPopulateCache:Bool;
	var dmsPerFile:Bool;
}

class DisplayMode {
	public static final defaultDisplaySettings:DisplaySettings = {
		dmsKind: DMDefault,
		dmsFullTyping: false,
		dmsForceMacroTyping: false,
		dmsErrorPolicy: EPIgnore,
		dmsCheckCoreApi: false,
		dmsInline: false,
		dmsDisplayFilePolicy: DFPOnly,
		dmsExitDuringTyping: true,
		dmsPopulateCache: false,
		dmsPerFile: false
	};
	public static final defaultCompilationSettings:DisplaySettings = {
		dmsKind: DMNone,
		dmsFullTyping: true,
		dmsForceMacroTyping: true,
		dmsErrorPolicy: EPShow,
		dmsCheckCoreApi: true,
		dmsInline: true,
		dmsDisplayFilePolicy: DFPNo,
		dmsExitDuringTyping: false,
		dmsPopulateCache: true,
		dmsPerFile: false
	};

	public static function copy(s:DisplaySettings):DisplaySettings return cast core.ds.Record.copy(s);

	public static function create(dm:DisplayModeValue):DisplaySettings {
		var settings = copy(defaultDisplaySettings);
		settings.dmsKind = dm;
		switch dm {
			case DMNone:
				return defaultCompilationSettings;
			case DMDefault | DMDefinition | DMTypeDefinition | DMPackage | DMHover | DMSignature:
			case DMUsage(_, _, _) | DMImplementation:
				settings.dmsFullTyping = true;
				settings.dmsForceMacroTyping = true;
				settings.dmsDisplayFilePolicy = DFPAlso;
				settings.dmsExitDuringTyping = false;
			case DMModuleSymbols(filter):
				settings.dmsDisplayFilePolicy = filter == null ? DFPOnly : DFPNo;
				settings.dmsExitDuringTyping = false;
				settings.dmsForceMacroTyping = false;
				settings.dmsPerFile = true;
		}
		return settings;
	}

	public static function toString(dm:DisplayModeValue):String return switch dm {
		case DMNone: "none";
		case DMDefault: "field";
		case DMDefinition: "position";
		case DMTypeDefinition: "type-definition";
		case DMImplementation: "implementation";
		case DMPackage: "package";
		case DMHover: "type";
		case DMUsage(true, _, _): "rename";
		case DMUsage(false, _, _): "references";
		case DMModuleSymbols(null): "module-symbols";
		case DMModuleSymbols(s): "workspace-symbols " + s;
		case DMSignature: "signature";
	};
}

enum Symbol {
	SKClass(cls:TClass);
	SKInterface(cls:TClass);
	SKEnum(en:TEnum);
	SKTypedef(td:TDef);
	SKAbstract(abs:TAbstract);
	SKField(field:TClassField, cls:Null<TClass>);
	SKConstructor(field:TClassField);
	SKEnumField(field:TEnumField);
	SKVariable(variable:TVar);
	SKOther;
}

@:structInit class CompletionSubject {
	public var sName:Null<String>;
	public var sStartPos:Pos;
	public var sInsertPos:Pos;

	public inline function new(sName:Null<String>, sStartPos:Pos, sInsertPos:Pos) {
		this.sName = sName;
		this.sStartPos = sStartPos;
		this.sInsertPos = sInsertPos;
	}
}

@:structInit class HoverResult {
	public var hitem:CompletionItemData;
	public var hpos:Pos;
	public var hexpected:Null<core.WithType.WithTypeValue>;

	public inline function new(hitem:CompletionItemData, hpos:Pos, hexpected:Null<core.WithType.WithTypeValue>) {
		this.hitem = hitem;
		this.hpos = hpos;
		this.hexpected = hexpected;
	}
}

@:structInit class FieldsResult {
	public var fitems:Array<CompletionItemData>;
	public var fkind:CompletionResultKindValue;
	public var fsubject:CompletionSubject;

	public inline function new(fitems:Array<CompletionItemData>, fkind:CompletionResultKindValue, fsubject:CompletionSubject) {
		this.fitems = fitems;
		this.fkind = fkind;
		this.fsubject = fsubject;
	}
}

enum SignatureKind {
	SKCall;
	SKArrayAccess;
}

// diagnostics

enum MissingFieldCause {
	AbstractParent(cls:TClass, params:TParams);
	ImplementedInterface(cls:TClass, params:TParams);

	/** true = getter **/
	PropertyAccessor(field:TClassField, getter:Bool);

	FieldAccess;
	FinalFields(fields:Array<TClassField>);
}

@:structInit class MissingFieldsDiagnostics {
	public var mfPos:Pos;
	public var mfOn:ModuleType;
	public var mfFields:Array<{field:TClassField, type:T, completion:CompletionTypeKind}>;
	public var mfCause:MissingFieldCause;

	public inline function new(mfPos:Pos, mfOn:ModuleType, mfFields:Array<{field:TClassField, type:T, completion:CompletionTypeKind}>,
			mfCause:MissingFieldCause) {
		this.mfPos = mfPos;
		this.mfOn = mfOn;
		this.mfFields = mfFields;
		this.mfCause = mfCause;
	}
}

@:structInit class ReplaceableCode {
	public var reason:String;
	public var replacement:String;
	public var displayRange:Pos;
	public var replaceRange:Pos;

	public inline function new(reason:String, replacement:String, displayRange:Pos, replaceRange:Pos) {
		this.reason = reason;
		this.replacement = replacement;
		this.displayRange = displayRange;
		this.replaceRange = replaceRange;
	}
}

@:structInit class DiagnosticsContext {
	public var replaceableCode:Array<ReplaceableCode>;

	// port: `(pos,bool ref) PMap.t`, keyed by `ImportHandling.key`.
	public var importPositions:Map<String, {pos:Pos, used:{value:Bool}}>;

	// port: `(Path.UniqueKey.t,(pos * expr) list) Hashtbl.t`
	public var deadBlocks:core.ds.OcamlHashtbl<String, Array<{pos:Pos, expr:Expr}>>;

	public var messages:Array<core.Message.CompilerMessage>;

	// port: not upstream: the report mode's files (RMDiagnostics; empty: every file; null: not
	// ... diagnostics), so the result encodes without the context
	public var reportFiles:Null<Array<String>> = null;

	// port: not upstream: the deprecation warnings to report (DiagnosticsPrinter.deprecations)
	public var deprecations:Array<{message:String, pos:Pos}> = [];

	public inline function new(replaceableCode:Array<ReplaceableCode>, importPositions:Map<String, {pos:Pos, used:{value:Bool}}>,
			deadBlocks:core.ds.OcamlHashtbl<String, Array<{pos:Pos, expr:Expr}>>, messages:Array<core.Message.CompilerMessage>) {
		this.replaceableCode = replaceableCode;
		this.importPositions = importPositions;
		this.deadBlocks = deadBlocks;
		this.messages = messages;
	}
}

enum DisplayExceptionKind {
	DisplayHover(result:HoverResult);
	DisplayFields(result:FieldsResult);
}

class DisplayTypes {
	public static function makeSubject(name:Null<String>, insertPos:Pos, ?startPos:Pos):CompletionSubject return {
		sName: name,
		sStartPos: startPos == null ? insertPos : startPos,
		sInsertPos: insertPos
	};

	public static function stringOfSymbol(symbol:Symbol):String return switch symbol {
		case SKClass(c) | SKInterface(c): c.clPath.name;
		case SKEnum(en): en.ePath.name;
		case SKTypedef(td): td.tPath.name;
		case SKAbstract(a): a.aPath.name;
		case SKField(cf, _) | SKConstructor(cf): cf.cfName;
		case SKEnumField(ef): ef.efName;
		case SKVariable(v): v.vName;
		case SKOther: "";
	};
}
