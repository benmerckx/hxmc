package core.display;

import core.Ast.Expr;
import core.Ast.Keyword;
import core.Ast.Metadata;
import core.Ast.Documentation;
import core.Ast.TypeParam;
import core.Ast.TypeDecl;
import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.TFunctions.*;
import core.json.Genjson;
import core.json.Genjson.GenjsonContext;
import core.json.Genjson.*;
import core.Meta;
import core.TType;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// port: from haxe/src/core/display/completionItem.ml
enum ToplevelKind {
	TKExpr(p:Pos);
	TKType;
	TKPattern(p:Pos);
	TKOverride;
	TKField(p:Pos);
}

enum CompletionModuleKind {
	Class;
	Interface;
	Enum;
	Abstract;
	EnumAbstract;
	TypeAlias;
	Struct;
	TypeParameter;
	Static;
}

class CompletionModuleKindTools {
	public static function toInt(k:CompletionModuleKind):Int return std.Type.enumIndex(k);
}

enum ImportStatus {
	Imported;
	Unimported;
	Shadowed;
}

class ImportStatusTools {
	public static function toInt(s:ImportStatus):Int return std.Type.enumIndex(s);
}

enum NotBool {
	Yes;
	YesButPrivate;
	No;
	Maybe;
}

@:structInit class CompletionModuleTypeData {
	public var pack:Array<String>;
	public var name:String;
	public var moduleName:String;
	public var pos:Pos;
	public var isPrivate:Bool;
	public var params:haxe.ds.Vector<TypeParam>;
	public var meta:Metadata;
	public var doc:Documentation;
	public var isExtern:Bool;
	public var isFinal:Bool;
	public var isAbstract:Bool;
	public var kind:CompletionModuleKind;
	public var hasConstructor:NotBool;

	public inline function new(pack:Array<String>, name:String, moduleName:String, pos:Pos, isPrivate:Bool, params:haxe.ds.Vector<TypeParam>,
			meta:Metadata, doc:Documentation, isExtern:Bool, isFinal:Bool, isAbstract:Bool, kind:CompletionModuleKind,
			hasConstructor:NotBool) {
		this.pack = pack;
		this.name = name;
		this.moduleName = moduleName;
		this.pos = pos;
		this.isPrivate = isPrivate;
		this.params = params;
		this.meta = meta;
		this.doc = doc;
		this.isExtern = isExtern;
		this.isFinal = isFinal;
		this.isAbstract = isAbstract;
		this.kind = kind;
		this.hasConstructor = hasConstructor;
	}
}

class CompletionModuleType {
	public static function ofTypeDecl(pack:Array<String>, moduleName:String, decl:TypeDecl):CompletionModuleTypeData {
		var p = decl.pos;
		return switch decl.definition {
			case EClass(d):
				var ctor = {
					var cff = null;
					for (f in d.data) if (f.cffName.name == "new") {
						cff = f;
						break;
					}
					if (cff != null) {
						if (d.flags.has(HExtern) || core.ds.ArrayTools.exists(cff.cffAccess, a -> a.access == APublic)) Yes
						else YesButPrivate;
					} else {
						if (core.ds.ArrayTools.exists(d.flags, f -> f.match(HExtends(_)))) Maybe
						else No;
					}
				};
				{
					pack: pack,
					name: d.name.name,
					moduleName: moduleName,
					pos: p,
					isPrivate: d.flags.has(HPrivate),
					params: d.params,
					meta: d.meta,
					doc: d.doc,
					isExtern: d.flags.has(HExtern),
					isFinal: d.flags.has(HFinal),
					isAbstract: d.flags.has(HAbstract),
					kind: d.flags.has(HInterface) ? Interface : Class,
					hasConstructor: ctor
				};
			case EEnum(d):
				{
					pack: pack,
					name: d.name.name,
					moduleName: moduleName,
					pos: p,
					isPrivate: d.flags.has(EPrivate),
					params: d.params,
					meta: d.meta,
					doc: d.doc,
					isExtern: d.flags.has(EExtern),
					isFinal: false,
					isAbstract: false,
					kind: Enum,
					hasConstructor: No
				};
			case ETypedef(d):
				var kind = switch d.data.type {
					case CTAnonymous(_): Struct;
					case _: TypeAlias;
				};
				{
					pack: pack,
					name: d.name.name,
					moduleName: moduleName,
					pos: p,
					isPrivate: d.flags.has(TDPrivate),
					params: d.params,
					meta: d.meta,
					doc: d.doc,
					isExtern: d.flags.has(TDExtern),
					isFinal: false,
					isAbstract: false,
					kind: kind,
					hasConstructor: kind == Struct ? No : Maybe
				};
			case EAbstract(d):
				var ctor = {
					var cff = null;
					for (f in d.data) if (f.cffName.name == "new") {
						cff = f;
						break;
					}
					if (cff != null) {
						if (core.ds.ArrayTools.exists(cff.cffAccess, a -> a.access == APublic)) Yes
						else YesButPrivate;
					} else No;
				};
				{
					pack: pack,
					name: d.name.name,
					moduleName: moduleName,
					pos: p,
					isPrivate: d.flags.has(AbPrivate),
					params: d.params,
					meta: d.meta,
					doc: d.doc,
					isExtern: d.flags.has(AbExtern),
					isFinal: false,
					isAbstract: false,
					kind: d.flags.has(AbEnum) ? EnumAbstract : Abstract,
					hasConstructor: ctor
				};
			case EStatic(d):
				{
					pack: pack,
					name: d.name.name,
					moduleName: moduleName,
					pos: p,
					isPrivate: core.ds.ArrayTools.exists(d.flags, f -> f.access == APrivate),
					params: d.params,
					meta: d.meta,
					doc: d.doc,
					isExtern: core.ds.ArrayTools.exists(d.flags, f -> f.access == AExtern),
					isFinal: true,
					isAbstract: false,
					kind: Static,
					hasConstructor: No
				};
			case EImport(_) | EUsing(_):
				throw core.ds.Exit.raise();
		};
	}

	public static function ofModuleType(mt:ModuleType):CompletionModuleTypeData {
		function actor(a:TAbstract):NotBool {
			if (a.aImpl != null && a.aConstructor != null) {
				return (hasClassFlag(a.aImpl, CExtern) || hasClassFieldFlag(a.aConstructor, CfPublic)) ? Yes : YesButPrivate;
			}
			return No;
		}
		function ctor(c:TClass):NotBool {
			try {
				if (hasClassFlag(c, CAbstract)) throw core.ds.NotFound.raise();
				var cf = getConstructor(c);
				return (hasClassFlag(c, CExtern) || hasClassFieldFlag(cf, CfPublic)) ? Yes : YesButPrivate;
			} catch (_:core.ds.NotFound) {
				return No;
			}
		}
		function ctorInfo(mt:ModuleType):{
			isExtern:Bool,
			isFinal:Bool,
			isAbstract:Bool,
			kind:CompletionModuleKind,
			ctor:NotBool
		} {
			return switch mt {
				case TClassDecl(c):
					{
						isExtern: hasClassFlag(c, CExtern),
						isFinal: hasClassFlag(c, CFinal),
						isAbstract: hasClassFlag(c, CAbstract),
						kind: hasClassFlag(c, CInterface) ? Interface : Class,
						ctor: ctor(c)
					};
				case TEnumDecl(en):
					{
						isExtern: hasEnumFlag(en, EnExtern),
						isFinal: false,
						isAbstract: false,
						kind: Enum,
						ctor: No
					};
				case TTypeDecl(td):
					var r = switch follow(td.tType) {
						case TAnon(_): {kind: Struct, ctor: No};
						case TInst(c, _): {kind: TypeAlias, ctor: ctor(c)};
						case TAbstract(a, _): {kind: TypeAlias, ctor: ctorInfo(TAbstractDecl(a)).ctor};
						case _: {kind: TypeAlias, ctor: No};
					};
					{
						isExtern: false,
						isFinal: false,
						isAbstract: false,
						kind: r.kind,
						ctor: r.ctor
					};
				case TAbstractDecl(a):
					var kind = a.aEnum ? EnumAbstract : Abstract;
					var r = switch core.Abstract.followWithForwardCtor(TAbstract(a, extractParamTypes(a.aParams))) {
						case TInst(c, _):
							var i = ctorInfo(TClassDecl(c));
							{
								isExtern: i.isExtern,
								isFinal: i.isFinal,
								isAbstract: i.isAbstract,
								ctor: i.ctor
							};
						case TAbstract(a, _): {
								isExtern: false,
								isFinal: false,
								isAbstract: false,
								ctor: actor(a)
							};
						case _: {
								isExtern: false,
								isFinal: false,
								isAbstract: false,
								ctor: No
							};
					};
					{
						isExtern: r.isExtern,
						isFinal: r.isFinal,
						isAbstract: r.isAbstract,
						kind: kind,
						ctor: r.ctor
					};
			};
		}
		var info = ctorInfo(mt);
		var infos = tInfos(mt);
		function convertTypeParam(ttp:TypedTypeParam):TypeParam {
			return {
				tpName: {name: ttp.ttpName, pos: Globals.nullPos},
				tpParams: vector(),
				tpConstraints: null, // TODO?
				tpDefault: null, // TODO?
				tpMeta: ttp.ttpClass.clMeta
			};
		}
		return {
			pack: infos.mtPath.pack,
			name: infos.mtPath.name,
			moduleName: infos.mtModule.mPath.name,
			pos: infos.mtPos,
			isPrivate: infos.mtPrivate,
			params: infos.mtParams.map(convertTypeParam),
			meta: infos.mtMeta,
			doc: infos.mtDoc,
			isExtern: info.isExtern,
			isFinal: info.isFinal,
			isAbstract: info.isAbstract,
			kind: info.kind,
			hasConstructor: info.ctor
		};
	}

	public static function getPath(cm:CompletionModuleTypeData):GlobalTypePath return {pack: cm.pack, name: cm.name};

	public static function toJson(ctx:GenjsonContext, cm:CompletionModuleTypeData, is:ImportStatus):JsonValue {
		var fields = [
			kv("path",
				jobject([
					kv("pack", jlist(jstring, cm.pack)),
					kv("moduleName", jstring(cm.moduleName)),
					kv("typeName", jstring(cm.name)),
					kv("importStatus", jint(ImportStatusTools.toInt(is)))
				])),
			kv("kind", jint(CompletionModuleKindTools.toInt(cm.kind))),
			kv("meta", generateMetadata(ctx, cm.meta)),
			kv("pos", generatePos(ctx, cm.pos)),
			kv("params", jlist(generateAstTypeParam.bind(ctx), cm.params.toArray())),
			kv("isExtern", jbool(cm.isExtern)),
			kv("isFinal", jbool(cm.isFinal)),
			kv("isAbstract", jbool(cm.isAbstract))
		];
		if (ctx.generateDocs) fields.push(kv("doc", jopt(jstring, core.Ast.Ast.genDocTextOpt(cm.doc))));
		return jobject(fields);
	}
}

enum ClassFieldOrigin {
	Self(mt:ModuleType);
	StaticImport(mt:ModuleType);
	Parent(mt:ModuleType);
	StaticExtension(mt:ModuleType);
	AnonymousStructure(an:TAnon);
	BuiltIn;
	Unknown;
}

class ClassFieldOriginTools {
	public static function toJson(ctx:GenjsonContext, cfo:ClassFieldOrigin):JsonValue {
		var octx = ctx.clone();
		octx.generateMemberBodies = false;
		function generateModuleType_(mt:ModuleType):JsonValue return generateModuleType(octx, mt);
		var i:Int, args:Null<JsonValue> = null;
		switch cfo {
			case Self(mt):
				i = 0;
				if (ctx.generateOrigins) args = generateModuleType_(mt);
			case StaticImport(mt):
				i = 1;
				if (ctx.generateOrigins) args = generateModuleType_(mt);
			case Parent(mt):
				i = 2;
				if (ctx.generateOrigins) args = generateModuleType_(mt);
			case StaticExtension(mt):
				i = 3;
				if (ctx.generateOrigins) args = generateModuleType_(mt);
			case AnonymousStructure(an):
				i = 4;
				if (ctx.generateOrigins) args = generateAnon(ctx, an);
			case BuiltIn:
				i = 5;
			case Unknown:
				i = 6;
		}
		var fl = [kv("kind", jint(i))];
		if (args != null) fl.push(kv("args", args));
		return jobject(fl);
	}
}

@:structInit class CompletionClassField {
	public var field:TClassField;
	public var scope:ClassFieldScope;
	public var origin:ClassFieldOrigin;
	public var isQualified:Bool;

	public inline function new(field:TClassField, scope:ClassFieldScope, origin:ClassFieldOrigin, isQualified:Bool) {
		this.field = field;
		this.scope = scope;
		this.origin = origin;
		this.isQualified = isQualified;
	}

	public static function make(cf:TClassField, scope:ClassFieldScope, origin:ClassFieldOrigin,
			isQualified:Bool):CompletionClassField return {
			field: cf,
			scope: scope,
			origin: origin,
			isQualified: isQualified
		};
}

@:structInit class CompletionEnumField {
	public var efield:TEnumField;
	public var eorigin:ClassFieldOrigin;
	public var eisQualified:Bool;

	public inline function new(efield:TEnumField, eorigin:ClassFieldOrigin, eisQualified:Bool) {
		this.efield = efield;
		this.eorigin = eorigin;
		this.eisQualified = eisQualified;
	}

	public static function make(ef:TEnumField, origin:ClassFieldOrigin,
			isQualified:Bool):CompletionEnumField return {efield: ef, eorigin: origin, eisQualified: isQualified};
}

enum PackageContentKind {
	PCKModule;
	PCKPackage;
}

@:structInit class CtPathWithParams {
	public var ctPack:Array<String>;
	public var ctTypeName:String;
	public var ctModuleName:String;
	public var ctParams:haxe.ds.Vector<CompletionTypeKind>;
	public var ctImportStatus:ImportStatus;

	public inline function new(ctPack:Array<String>, ctTypeName:String, ctModuleName:String, ctParams:haxe.ds.Vector<CompletionTypeKind>,
			ctImportStatus:ImportStatus) {
		this.ctPack = ctPack;
		this.ctTypeName = ctTypeName;
		this.ctModuleName = ctModuleName;
		this.ctParams = ctParams;
		this.ctImportStatus = ctImportStatus;
	}
}

@:structInit class CtFunctionArgument {
	public var ctName:String;
	public var ctOptional:Bool;
	public var ctType:CompletionTypeKind;
	public var ctValue:Null<Expr>;

	public inline function new(ctName:String, ctOptional:Bool, ctType:CompletionTypeKind, ctValue:Null<Expr>) {
		this.ctName = ctName;
		this.ctOptional = ctOptional;
		this.ctType = ctType;
		this.ctValue = ctValue;
	}
}

@:structInit class CtFunction {
	public var ctArgs:haxe.ds.Vector<CtFunctionArgument>;
	public var ctReturn:CompletionTypeKind;

	public inline function new(ctArgs:haxe.ds.Vector<CtFunctionArgument>, ctReturn:CompletionTypeKind) {
		this.ctArgs = ctArgs;
		this.ctReturn = ctReturn;
	}
}

@:structInit class CtAnonymousField {
	public var ctfField:TClassField;
	public var ctfType:CompletionTypeKind;

	public inline function new(ctfField:TClassField, ctfType:CompletionTypeKind) {
		this.ctfField = ctfField;
		this.ctfType = ctfType;
	}
}

@:structInit class CtAnonymous {
	public var ctFields:Array<CtAnonymousField>;
	public var ctStatus:AnonStatus;

	public inline function new(ctFields:Array<CtAnonymousField>, ctStatus:AnonStatus) {
		this.ctFields = ctFields;
		this.ctStatus = ctStatus;
	}
}

// port: `CompletionType.t`.
enum CompletionTypeKind {
	CTMono;
	CTInst(pwp:CtPathWithParams);
	CTEnum(pwp:CtPathWithParams);
	CTTypedef(pwp:CtPathWithParams);
	CTAbstract(pwp:CtPathWithParams);
	CTFunction(ctf:CtFunction);
	CTAnonymous(cta:CtAnonymous);
	CTDynamic(cto:Null<CompletionTypeKind>);
}

class CompletionType {
	public static function generatePathWithParams(ctx:GenjsonContext, pwp:CtPathWithParams):JsonValue {
		return jobject([
			kv("path", jobject([
				kv("pack", jlist(jstring, pwp.ctPack)),
				kv("moduleName", jstring(pwp.ctModuleName)),
				kv("typeName", jstring(pwp.ctTypeName)),
				kv("importStatus", jint(ImportStatusTools.toInt(pwp.ctImportStatus)))
			])),
			kv("params", jlist(generateType.bind(ctx), pwp.ctParams))
		]);
	}

	public static function generateFunctionArgument(ctx:GenjsonContext, cfa:CtFunctionArgument):JsonValue {
		return jobject([
			kv("name", jstring(cfa.ctName)),
			kv("opt", jbool(cfa.ctOptional)),
			kv("t", generateType(ctx, cfa.ctType)),
			kv("value", jopt(function(e:Expr) return jobject([kv("string", jstring(core.AstPrinter.sExpr(e)))]), cfa.ctValue))
		]);
	}

	public static function generateFunction_(ctx:GenjsonContext, ctf:CtFunction):Array<JsonField> {
		return [
			kv("args", jlist(generateFunctionArgument.bind(ctx), ctf.ctArgs)),
			kv("ret", generateType(ctx, ctf.ctReturn))
		];
	}

	public static function generateFunction(ctx:GenjsonContext, ctf:CtFunction):JsonValue return jobject(generateFunction_(ctx, ctf));

	public static function generateAnonField(ctx:GenjsonContext, af:CtAnonymousField):JsonValue {
		var fields = generateClassField_(ctx, CFSMember, af.ctfField);
		var fields = fields.filter(f -> f.name != "type");
		fields.unshift(kv("type", generateType(ctx, af.ctfType)));
		return jobject(fields);
	}

	public static function generateAnon(ctx:GenjsonContext, cta:CtAnonymous):JsonValue {
		var fields = cta.ctFields.copy();
		haxe.ds.ArraySort.sort(fields, (ctf1, ctf2) -> Reflect.compare(ctf1.ctfField.cfNamePos.pmin, ctf2.ctfField.cfNamePos.pmin));
		return jobject([
			kv("status", generateAnonStatus(ctx, cta.ctStatus)),
			kv("fields", jlist(generateAnonField.bind(ctx), fields))
		]);
	}

	public static function generateType(ctx:GenjsonContext, ct:CompletionTypeKind):JsonValue {
		var name:String, args:Null<JsonValue> = null;
		switch ct {
			case CTMono:
				name = "TMono";
			case CTInst(pwp):
				name = "TInst";
				args = generatePathWithParams(ctx, pwp);
			case CTEnum(pwp):
				name = "TEnum";
				args = generatePathWithParams(ctx, pwp);
			case CTTypedef(pwp):
				name = "TType";
				args = generatePathWithParams(ctx, pwp);
			case CTAbstract(pwp):
				name = "TAbstract";
				args = generatePathWithParams(ctx, pwp);
			case CTFunction(ctf):
				name = "TFun";
				args = generateFunction(ctx, ctf);
			case CTAnonymous(cta):
				name = "TAnonymous";
				args = generateAnon(ctx, cta);
			case CTDynamic(cto):
				name = "TDynamic";
				args = cto == null ? null : generateType(ctx, cto);
		}
		return generateAdt(ctx, null, name, args);
	}

	public static function toJson(ctx:GenjsonContext, ct:CompletionTypeKind):JsonValue return generateType(ctx, ct);

	public static function fromType(getImportStatus:GlobalTypePath->ImportStatus, ?values:haxe.ds.StringMap<Expr>, t:T):CompletionTypeKind {
		var empty = new haxe.ds.StringMap<Expr>();
		// port: OCaml evaluates record fields right to left: the parameters are converted before the import status is looked up.
		function ppath(mpath:GlobalTypePath, tpath:GlobalTypePath, tl:core.TType.TParams):CtPathWithParams {
			var params = tl.map(t -> fromType_(empty, t));
			var is = getImportStatus(tpath);
			return {
				ctPack: tpath.pack,
				ctModuleName: mpath.name,
				ctTypeName: tpath.name,
				ctImportStatus: is,
				ctParams: params
			};
		}
		function funarg(value:Null<Expr>, a:{name:String, optional:Bool, type:T}):CtFunctionArgument {
			return {
				ctName: a.name,
				ctOptional: a.optional,
				ctType: fromType_(empty, a.type),
				ctValue: value
			};
		}
		function fromType__(values:haxe.ds.StringMap<Expr>, t:T):CompletionTypeKind {
			return switch t {
				case TMono(r):
					if (r.tmType == null) CTMono else fromType__(values, r.tmType);
				case TLazy(r):
					fromType__(values, lazyType(r));
				case TInst(c = {clKind: KTypeParameter(_)}, _):
					CTInst({
						ctPack: c.clPath.pack,
						ctModuleName: c.clModule.mPath.name,
						ctTypeName: c.clPath.name,
						ctImportStatus: Imported,
						ctParams: vector()
					});
				case TInst(c, tl):
					CTInst(ppath(c.clModule.mPath, c.clPath, tl));
				case TEnum(en, tl):
					CTEnum(ppath(en.eModule.mPath, en.ePath, tl));
				case TType(td, tl):
					CTTypedef(ppath(td.tModule.mPath, td.tPath, tl));
				case TAbstract(a, tl):
					CTAbstract(ppath(a.aModule.mPath, a.aPath, tl));
				case TFun(s) if (values.keys().hasNext()):
					function getArg(n:String):Null<Expr> return values.get(n);
					var ret = fromType__(empty, s.ret);
					CTFunction({
						ctArgs: s.args.map(a -> funarg(getArg(a.name), a)),
						ctReturn: ret
					});
				case TFun(s):
					var ret = fromType__(empty, s.ret);
					CTFunction({
						ctArgs: s.args.map(a -> funarg(null, a)),
						ctReturn: ret
					});
				case TAnon(an):
					function afield(af:TClassField):CtAnonymousField return {ctfField: af, ctfType: fromType__(empty, af.cfType)};
					CTAnonymous({
						ctFields: core.ds.PMap.fold(function(cf:TClassField, acc:Array<CtAnonymousField>) {
							acc.unshift(afield(cf));
							return acc;
						}, an.aFields, []),
						ctStatus: an.aStatus
					});
				case TDynamic(null):
					CTDynamic(null);
				case TDynamic(t):
					CTDynamic(fromType__(empty, t));
			};
		}
		fromType_ = fromType__;
		return fromType__(values == null ? empty : values, t);
	}

	static var fromType_:(haxe.ds.StringMap<Expr>, T) -> CompletionTypeKind;
}

enum TKind {
	ITLocal(v:TVar);
	ITClassField(ccf:CompletionClassField);
	ITEnumField(cef:CompletionEnumField);
	ITEnumAbstractField(a:TAbstract, ccf:CompletionClassField);
	ITType(cmt:CompletionModuleTypeData, is:ImportStatus);
	ITPackage(path:GlobalTypePath, contents:Array<{name:String, kind:PackageContentKind}>);
	ITModule(path:GlobalTypePath);
	ITLiteral(s:String);
	ITMetadata(meta:core.MetaList.StrictMeta);
	ITKeyword(kwd:Keyword);
	ITAnonymous(an:TAnon);
	ITExpression(e:TExpr);
	ITTypeParameter(c:TClass);
	ITDefine(n:String, v:Null<String>);
}

@:structInit class CompletionItemData {
	public var ciKind:TKind;
	public var ciType:Null<{t:T, ct:CompletionTypeKind}>;

	public inline function new(ciKind:TKind, ciType:Null<{t:T, ct:CompletionTypeKind}>) {
		this.ciKind = ciKind;
		this.ciType = ciType;
	}
}

typedef TPair = {t:T, ct:CompletionTypeKind};

class CompletionItem {
	public static function declOfClass(c:TClass):ModuleType return switch c.clKind {
		case KAbstractImpl(a): TAbstractDecl(a);
		case _: TClassDecl(c);
	};

	public static function make(kind:TKind, t:Null<TPair>):CompletionItemData return {ciKind: kind, ciType: t};

	public static function makeCiLocal(v:TVar, t:TPair):CompletionItemData return make(ITLocal(v), t);

	public static function makeCiClassField(ccf:CompletionClassField, t:TPair):CompletionItemData return make(ITClassField(ccf), t);

	public static function makeCiEnumAbstractField(a:TAbstract, ccf:CompletionClassField,
			t:TPair):CompletionItemData return make(ITEnumAbstractField(a, ccf), t);

	public static function makeCiEnumField(cef:CompletionEnumField, t:TPair):CompletionItemData return make(ITEnumField(cef), t);

	public static function makeCiType(mt:CompletionModuleTypeData, importStatus:ImportStatus,
			t:Null<TPair>):CompletionItemData return make(ITType(mt, importStatus), t);

	public static function makeCiPackage(path:GlobalTypePath,
			l:Array<{name:String, kind:PackageContentKind}>):CompletionItemData return make(ITPackage(path, l), null);

	public static function makeCiModule(path:GlobalTypePath):CompletionItemData return make(ITModule(path), null);

	public static function makeCiLiteral(lit:String, t:TPair):CompletionItemData return make(ITLiteral(lit), t);

	public static function makeCiMetadata(meta:core.MetaList.StrictMeta):CompletionItemData return make(ITMetadata(meta), null);

	public static function makeCiKeyword(kwd:Keyword):CompletionItemData return make(ITKeyword(kwd), null);

	public static function makeCiAnon(an:TAnon, t:TPair):CompletionItemData return make(ITAnonymous(an), t);

	public static function makeCiExpr(e:TExpr, t:TPair):CompletionItemData return make(ITExpression(e), t);

	public static function makeCiTypeParam(c:TClass, t:TPair):CompletionItemData return make(ITTypeParameter(c), t);

	public static function makeCiDefine(n:String, v:Null<String>, t:TPair):CompletionItemData return make(ITDefine(n, v), t);

	public static function getIndex(item:CompletionItemData):Int return switch item.ciKind {
		case ITLocal(_): 0;
		case ITClassField(_): 1;
		case ITEnumField(_): 2;
		case ITEnumAbstractField(_): 3;
		case ITType(_): 4;
		case ITPackage(_): 5;
		case ITModule(_): 6;
		case ITLiteral(_): 7;
		case ITMetadata(_): 9;
		case ITKeyword(_): 10;
		case ITAnonymous(_): 11;
		case ITExpression(_): 12;
		case ITTypeParameter(_): 13;
		case ITDefine(_): 14;
	};

	static function pad(i:Int, width:Int):String {
		// port: Printf "%0Ni"
		var neg = i < 0;
		var s = Std.string(neg ? -i : i);
		while (s.length < (neg ? width - 1 : width)) s = "0" + s;
		return neg ? "-" + s : s;
	}

	// port: the sort key `(int,string)` of upstream; compared lexicographically.
	public static function getSortIndex(tk:ToplevelKind, item:CompletionItemData, p:Pos, expectedName:Null<String>):{i:Int, s:String} {
		return switch item.ciKind {
			case ITLocal(v):
				var i = p.pmin - v.vPos.pmin;
				var i = i < 0 ? 0 : i;
				var s = pad(i, 5);
				var s = if (expectedName == null) s else {
					var i = core.StringError.levenshtein(expectedName, v.vName);
					pad(i, 5) + s;
				};
				{i: 0, s: s};
			case ITClassField(ccf):
				var i = switch [ccf.origin, ccf.scope] {
					case [Self(_), CFSMember | CFSConstructor]: 10;
					case [Parent(_), CFSMember | CFSConstructor]: 11;
					case [StaticExtension(_), _]: 12;
					case [Self(_), CFSStatic]: 13;
					case [StaticImport(_), _]: 14;
					case _: 15;
				};
				{i: i, s: ccf.field.cfName};
			case ITEnumField(ef):
				{
					i: switch tk {
						case TKPattern(_) | TKField(_): -1;
						case _: 20;
					},
					s: pad(ef.efield.efIndex, 4)
				};
			case ITEnumAbstractField(_, ccf):
				{
					i: switch tk {
						case TKPattern(_) | TKField(_): -1;
						case _: 21;
					},
					s: ccf.field.cfName
				};
			case ITTypeParameter(c):
				{i: 30, s: c.clPath.name};
			case ITType(cmt, is):
				var i = switch is {
					case Imported: 31;
					case Unimported: 32;
					case Shadowed: 33;
				};
					{
						i: i
					, s:Globals.sTypePath({pack: cmt.pack, name: cmt.name})
		};
		case ITPackage(path, _):
			{i: 40, s: Globals.sTypePath(path)};
		case ITModule(path):
			{i: 40, s: Globals.sTypePath(path)};
		case ITLiteral(name):
			{i: 50, s: name};
		case ITKeyword(name):
			{i: 60, s: core.Ast.Ast.sKeyword(name)};
		case ITAnonymous(_) | ITExpression(_) | ITMetadata(_) | ITDefine(_):
			{i: 500, s: ""};
	};
}

public static function getName(item:CompletionItemData):String return switch item.ciKind {
	case ITLocal(v): v.vName;
	case ITClassField(cf) | ITEnumAbstractField(_, cf): cf.field.cfName;
	case ITEnumField(ef): ef.efield.efName;
	case ITType(cm, _): cm.name;
	case ITPackage(path, _): path.name;
	case ITModule(path): path.name;
	case ITLiteral(s): s;
	case ITMetadata(m): Meta.toString(m);
	case ITKeyword(kwd): core.Ast.Ast.sKeyword(kwd);
	case ITAnonymous(_): "";
	case ITExpression(_): "";
	case ITTypeParameter(c): c.clPath.name;
	case ITDefine(n, _): n;
};

static function sFullDotPath(infos:TInfos):String {
	var fp = core.Path.fullDotPath(infos.mtModule.mPath.pack, infos.mtModule.mPath.name, infos.mtPath.name);
	return Globals.sTypePath({pack: fp.pack, name: fp.name});
}

public static function getType(item:CompletionItemData):Null<TPair> return item.ciType;

public static function getFilterName(item:CompletionItemData):String return switch item.ciKind {
	case ITLocal(v): v.vName;
	case ITClassField(cf) | ITEnumAbstractField(_, cf): cf.field.cfName;
	case ITEnumField(ef): ef.efield.efName;
	case ITType(cm, _): Globals.sTypePath({pack: cm.pack, name: cm.name});
	case ITPackage(path, _): Globals.sTypePath(path);
	case ITModule(path): Globals.sTypePath(path);
	case ITLiteral(s): s;
	case ITMetadata(m): Meta.toString(m);
	case ITKeyword(kwd): core.Ast.Ast.sKeyword(kwd);
	case ITAnonymous(_): "";
	case ITExpression(_): "";
	case ITTypeParameter(c): c.clPath.name;
	case ITDefine(n, _): n;
};

public static function getDocumentation(item:CompletionItemData):Documentation return switch item.ciKind {
	case ITClassField(cf) | ITEnumAbstractField(_, cf): cf.field.cfDoc;
	case ITEnumField(ef): ef.efield.efDoc;
	case ITType(mt, _): mt.doc;
	case _: null;
};

public static function toJson(ctx:GenjsonContext, index:Null<Int>, item:CompletionItemData):JsonValue {
	var kind:String, data:JsonValue;
	switch item.ciKind {
		case ITLocal(v):
			kind = "Local";
			data = generateTvar(ctx, v);
		case ITClassField(cf) | ITEnumAbstractField(_, cf):
			var name = switch item.ciKind {
				case ITClassField(_): "ClassField";
				case _: "EnumAbstractField";
			};
			var qualifier = switch [cf.scope, cf.origin] {
				case [CFSStatic, Self(mt) | Parent(mt) | StaticExtension(mt) | StaticImport(mt)]:
					var infos = tInfos(mt);
					jstring(sFullDotPath(infos));
				case [CFSMember, Self(_)]:
					jstring("this");
				case [CFSMember, Parent(_)]:
					jstring("super");
				case _:
					jnull;
			};
			kind = name;
			data = jobject([
				kv("field", generateClassField(ctx, cf.scope, cf.field)),
				kv("origin", ClassFieldOriginTools.toJson(ctx, cf.origin)),
				kv("resolution", jobject([kv("isQualified", jbool(cf.isQualified)), kv("qualifier", qualifier)]))
			]);
		case ITEnumField(ef):
			var qualifier = switch ef.eorigin {
				case Self(mt) | StaticImport(mt):
					var infos = tInfos(mt);
					jstring(sFullDotPath(infos));
				case _:
					jnull;
			};
			kind = "EnumField";
			data = jobject([
				kv("field", generateEnumField(ctx, ef.efield)),
				kv("origin", ClassFieldOriginTools.toJson(ctx, ef.eorigin)),
				kv("resolution", jobject([kv("isQualified", jbool(ef.eisQualified)), kv("qualifier", qualifier)]))
			]);
		case ITType(kind_, is):
			kind = "Type";
			data = CompletionModuleType.toJson(ctx, kind_, is);
		case ITPackage(path, contents):
			function generatePackageContent(c:{name:String, kind:PackageContentKind}):JsonValue return jobject([kv("name",
				jstring(c.name)), kv("kind", jint(std.Type.enumIndex(c.kind)))]);
			kind = "Package";
			data = jobject([
				kv("path", generatePackagePath(path.pack.concat([path.name]))),
				kv("contents", jlist(generatePackageContent, contents))
			]);
		case ITModule(path):
			kind = "Module";
			data = jobject([kv("path", generateModulePath(path))]);
		case ITLiteral(s):
			kind = "Literal";
			data = jobject([kv("name", jstring(s))]);
		case ITMetadata(m):
			var r = Meta.getInfo(m);
			var name = "@" + r.name;
			var data_ = r.info;
			kind = "Metadata";
			data = jobject([
				kv("name", jstring(name)),
				kv("doc", jstring(data_.mDoc)),
				kv("parameters", jarray(data_.mParams.map(jstring))),
				kv("platforms", jarray(data_.mPlatforms.map(p -> jstring(Globals.platformName(p))))),
				kv("targets", jarray(data_.mUsedOn.map(u -> jstring(core.MetaList.printMetaUsage(u))))),
				kv("internal", jbool(data_.mInternal)),
				kv("origin", jstring(switch data_.mOrigin {
					case Compiler: "haxe compiler";
					case UserDefined(null): "user-defined";
					case UserDefined(o): o;
				})),
				kv("links", jarray(data_.mLinks.map(jstring)))
			]);
		case ITKeyword(kwd):
			kind = "Keyword";
			data = jobject([kv("name", jstring(core.Ast.Ast.sKeyword(kwd)))]);
		case ITAnonymous(an):
			kind = "AnonymousStructure";
			data = Genjson.generateAnon(ctx, an);
		case ITExpression(e):
			kind = "Expression";
			data = generateTexpr(ctx, e);
		case ITTypeParameter(c):
			switch c.clKind {
				case KTypeParameter(ttp):
					kind = "TypeParameter";
					data = jobject([
						kv("name", jstring(c.clPath.name)),
						kv("meta", generateMetadata(ctx, c.clMeta)),
						kv("constraints", jlist(Genjson.generateType.bind(ctx), getConstraints(ttp)))
					]);
				case _:
					throw new core.Globals.InternalCompilerError("completionItem.ml: ITTypeParameter without KTypeParameter", "");
			}
		case ITDefine(n, v):
			kind = "Define";
			data = jobject([
				kv("name", jstring(n)),
				kv("value", v == null ? jnull : jstring(v)) // TODO: docs etc
			]);
	}
	var jindex = index == null ? [] : [kv("index", jint(index))];
	var fl = [kv("kind", jstring(kind)), kv("args", data)];
	if (item.ciType == null) fl = fl.concat(jindex)
	else fl = fl.concat([kv("type", CompletionType.toJson(ctx, item.ciType.ct))]).concat(jindex);
	return jobject(fl);
}
}
