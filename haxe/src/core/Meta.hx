package core;

import Type as StdType;
import core.Ast.Metadata;
import core.Ast.MetadataEntry;
import core.Globals.Platform;
import core.Globals.Pos;
import core.MetaList;
import haxe.ds.StringMap;

// port: from haxe/src/core/meta.ml.
@:structInit class UserMeta {
	public var doc:String;
	public var flags:Array<MetaParameter>;
	public var source:Null<String>;

	public inline function new(doc:String, flags:Array<MetaParameter>, source:Null<String>) {
		this.doc = doc;
		this.flags = flags;
		this.source = source;
	}

	public inline function clone():UserMeta return new UserMeta(doc, flags, source);
}

enum MetaOrigin {
	Compiler;
	UserDefined(source:Null<String>);
}

@:structInit class MetaInfos {
	public var mInternal:Bool;
	public var mDoc:String;
	public var mParams:Array<String>;
	public var mPlatforms:Array<Platform>;
	public var mUsedOn:Array<MetaUsage>;
	public var mOrigin:MetaOrigin;
	public var mLinks:Array<String>;

	public inline function new(mInternal:Bool, mDoc:String, mParams:Array<String>, mPlatforms:Array<Platform>, mUsedOn:Array<MetaUsage>,
			mOrigin:MetaOrigin, mLinks:Array<String>) {
		this.mInternal = mInternal;
		this.mDoc = mDoc;
		this.mParams = mParams;
		this.mPlatforms = mPlatforms;
		this.mUsedOn = mUsedOn;
		this.mOrigin = mOrigin;
		this.mLinks = mLinks;
	}

	public inline function clone():MetaInfos return new MetaInfos(mInternal, mDoc, mParams, mPlatforms, mUsedOn, mOrigin, mLinks);
}

class MetaNotFound extends core.ds.NotFound {
	public static final instance = new MetaNotFound();

	public static inline function raise():MetaNotFound {#if hl hl.Api.rethrow(instance); #end return instance;
	}

	public function new() super();
}

class Meta {
	// port: structural equality (OCaml's =); comparing indices first avoids the deep
	// comparison for the common mismatch.
	// The legacy bootstrap stores some metadata names as plain strings, which never match.
	#if hl
	// port: one type-pointer test instead of a checked Dynamic->enum cast per entry.
	// hl.Type comparison calls hl_same_type; the type pointers are compared directly.
	static final strictMetaType:hl.Bytes = untyped $unsafecast(hl.Type.getDynamic(StrictMeta.Used));

	public static inline function metaEq(a:StrictMeta, b:Dynamic):Bool {
		if (b == null || (untyped $unsafecast(hl.Type.getDynamic(b)) : hl.Bytes) != strictMetaType) return false;
		var e:StrictMeta = untyped $unsafecast(b);
		return StdType.enumIndex(a) == StdType.enumIndex(e) && StdType.enumEq(a, e);
	}
	#elseif (target.name == "hxmc")
	// port: on hxmc (hxmc/) the constructors without arguments are singletons: the identical
	// value matches without a call. No string test: a plain string's index is its runtime
	// type's, and enumEq rejects values of another type.
	public static inline function metaEq(a:StrictMeta,
			b:Dynamic):Bool return hxmc.Native.refEq(a, b) || StdType.enumIndex(a) == StdType.enumIndex(b) && StdType.enumEq(a, b);
	#else
	public static inline function metaEq(a:StrictMeta,
			b:Dynamic):Bool return core.ds.Key.asString(b) == null && StdType.enumIndex(a) == StdType.enumIndex(b) && StdType.enumEq(a, b);
	#end

	public static function has(m:StrictMeta, ml:Metadata):Bool {
		for (entry in ml) if (metaEq(m, entry.meta)) return true;
		return false;
	}

	public static function hasOneOf(ml1:Array<StrictMeta>, ml2:Metadata):Bool {
		for (entry in ml2) for (meta in ml1) if (metaEq(meta, entry.meta)) return true;
		return false;
	}

	// port: Meta.get without the exception, for callers that catch MetaNotFound.
	public static function getOpt(m:StrictMeta, ml:Metadata):Null<MetadataEntry> {
		for (entry in ml) if (metaEq(m, entry.meta)) return entry;
		return null;
	}

	public static function get(m:StrictMeta, ml:Metadata):MetadataEntry {
		for (entry in ml) if (metaEq(m, entry.meta)) return entry;
		throw MetaNotFound.raise();
	}

	public static function remove(m:StrictMeta, ml:Metadata):Metadata {
		if (ml.length == 0) return [];
		if (metaEq(m, ml[0].meta)) return ml.slice(1);
		return [ml[0]].concat(remove(m, ml.slice(1)));
	}

	public static function registerUserMeta(userMetas:StringMap<UserMeta>, s:String, data:UserMeta):Void userMetas.set(s, data);

	public static function getInfo(m:StrictMeta, ?userMetas:StringMap<UserMeta>):{name:String, info:MetaInfos} {
		var origin:MetaOrigin = Compiler;
		var raw = switch m {
			case StrictMeta.Custom(s) if (userMetas != null && userMetas.exists(s)):
				var data = userMetas.get(s);
				origin = UserDefined(data.source);
				{name: s, doc: data.doc, flags: data.flags};
			case _: MetaList.getInfo(m);
		};
		var params = [], used = [], platforms = [], links = [];
		var internal = false;
		for (flag in raw.flags) switch flag {
			case HasParam(s):
				params.unshift(s);
			case Platforms(values):
				platforms = values.concat(platforms);
			case UsedOn(values):
				used = values.concat(used);
			case UsedInternally:
				internal = true;
			case Link(url):
				links.unshift(url);
		}
		return {
			name: raw.name,
			info: {
				mInternal: internal,
				mDoc: raw.doc,
				mParams: params,
				mPlatforms: platforms,
				mUsedOn: used,
				mOrigin: origin,
				mLinks: links
			}
		};
	}

	public static function toString(m:StrictMeta):String return getInfo(m).name;

	static final hmeta:StringMap<StrictMeta> = makeMetaMap();

	static function makeMetaMap():StringMap<StrictMeta> {
		var h = new StringMap<StrictMeta>();
		for (m in MetaList.all) h.set(toString(m), m);
		return h;
	}

	public static function parse(s:String):StrictMeta {
		var m = hmeta.get(":" + s);
		return m == null ? Custom(":" + s) : m;
	}

	public static function fromString(s:String):StrictMeta {
		if (s == "") return Custom("");
		return switch s.charAt(0) {
			case ":":
				var m = hmeta.get(s);
				m == null ? Custom(s) : m;
			case "$": Dollar(s.substr(1));
			case _: Custom(s);
		};
	}

	public static function getDocumentation(userMetas:StringMap<UserMeta>, m:StrictMeta):Null<{name:String, description:String}> {
		var pair = getInfo(m, userMetas);
		var data = pair.info;
		if (data.mInternal) return null;
		var params = data.mParams.copy();
		params.reverse();
		var parameterText = params.length == 0 ? "" : "(<" + params.join(">, <") + ">) ";
		var platforms = data.mPlatforms.copy();
		platforms.reverse();
		var pfs = Globals.platformListHelp(platforms);
		var origin = switch data.mOrigin {
			case UserDefined(s) if (s != null): " (from " + s + ")";
			case _: "";
		};
		return {name: "@" + pair.name, description: parameterText + data.mDoc + pfs + origin};
	}

	public static function getDocumentationList(userMetas:StringMap<UserMeta>):{all:Array<{name:String, description:String}>, maxLength:Int} {
		var maxLength = 0;
		var all = [];
		for (m in MetaList.all) {
			var doc = getDocumentation(userMetas, m);
			if (doc != null) {
				if (doc.name.length > maxLength) maxLength = doc.name.length;
				all.push(doc);
			}
		}
		all.sort(function(a, b) return core.ds.Key.compareStrings(a.name, b.name));
		return {all: all, maxLength: maxLength};
	}

	public static function getMetaList(userMetas:StringMap<UserMeta>):Array<{name:String, info:MetaInfos}> {
		var all = [for (m in MetaList.all) getInfo(m, userMetas)];
		for (s in userMetas.keys()) all.push(getInfo(Custom(s), userMetas));
		all.sort(function(a, b) return core.ds.Key.compareStrings(a.name, b.name));
		return all;
	}

	public static function getAll(userMetas:StringMap<UserMeta>):Array<StrictMeta> {
		var all = MetaList.all.copy();
		for (s in userMetas.keys()) all.push(Custom(s));
		all.sort(function(a, b) return core.ds.Key.compareStrings(toString(a), toString(b)));
		return all;
	}

	public static function getUserDocumentationList(userMetas:StringMap<UserMeta>):{all:Array<{name:String, description:String}>, maxLength:Int} {
		var maxLength = 0;
		var all = [];
		for (s in userMetas.keys()) {
			var doc = getDocumentation(userMetas, Custom(s));
			if (doc != null) {
				if (doc.name.length > maxLength) maxLength = doc.name.length;
				all.unshift(doc);
			}
		}
		all.sort(function(a, b) return core.ds.Key.compareStrings(a.name, b.name));
		return {all: all, maxLength: maxLength};
	}

	public static function maybeGetPos(m:StrictMeta, ml:Metadata):Null<Pos> {
		try return get(m, ml).pos
		catch (_:MetaNotFound) return null;
	}

	public static function Custom(s:String):StrictMeta return StrictMeta.Custom(s);

	public static function Dollar(s:String):StrictMeta return StrictMeta.Dollar(s);

	public static function InlineConstructorArgument(variable:Int,
			index:Int):StrictMeta return StrictMeta.InlineConstructorArgument(variable, index);

	public static final Abi:StrictMeta = StrictMeta.Abi;
	public static final Access:StrictMeta = StrictMeta.Access;
	public static final Accessor:StrictMeta = StrictMeta.Accessor;
	public static final Allow:StrictMeta = StrictMeta.Allow;
	public static final Analyzer:StrictMeta = StrictMeta.Analyzer;
	public static final Annotation:StrictMeta = StrictMeta.Annotation;
	public static final ArrayAccess:StrictMeta = StrictMeta.ArrayAccess;
	public static final Ast:StrictMeta = StrictMeta.Ast;
	public static final AstSource:StrictMeta = StrictMeta.AstSource;
	public static final AutoBuild:StrictMeta = StrictMeta.AutoBuild;
	public static final Bind:StrictMeta = StrictMeta.Bind;
	public static final Bitmap:StrictMeta = StrictMeta.Bitmap;
	public static final Build:StrictMeta = StrictMeta.Build;
	public static final BuildXml:StrictMeta = StrictMeta.BuildXml;
	public static final BypassAccessor:StrictMeta = StrictMeta.BypassAccessor;
	public static final Callable:StrictMeta = StrictMeta.Callable;
	public static final CallSuper:StrictMeta = StrictMeta.CallSuper;
	public static final Commutative:StrictMeta = StrictMeta.Commutative;
	public static final CompilerGenerated:StrictMeta = StrictMeta.CompilerGenerated;
	public static final Const:StrictMeta = StrictMeta.Const;
	public static final CoreApi:StrictMeta = StrictMeta.CoreApi;
	public static final CoreType:StrictMeta = StrictMeta.CoreType;
	public static final Coroutine:StrictMeta = StrictMeta.Coroutine;
	public static final CoroutineScope:StrictMeta = StrictMeta.CoroutineScope;
	public static final CppFileCode:StrictMeta = StrictMeta.CppFileCode;
	public static final CppInclude:StrictMeta = StrictMeta.CppInclude;
	public static final CppNamespaceCode:StrictMeta = StrictMeta.CppNamespaceCode;
	public static final Dce:StrictMeta = StrictMeta.Dce;
	public static final Debug:StrictMeta = StrictMeta.Debug;
	public static final Decl:StrictMeta = StrictMeta.Decl;
	public static final DefParam:StrictMeta = StrictMeta.DefParam;
	public static final Depend:StrictMeta = StrictMeta.Depend;
	public static final Deprecated:StrictMeta = StrictMeta.Deprecated;
	public static final DirectlyUsed:StrictMeta = StrictMeta.DirectlyUsed;
	public static final DisplayOverride:StrictMeta = StrictMeta.DisplayOverride;
	public static final Eager:StrictMeta = StrictMeta.Eager;
	public static final Enum:StrictMeta = StrictMeta.Enum;
	public static final Exhaustive:StrictMeta = StrictMeta.Exhaustive;
	public static final Expose:StrictMeta = StrictMeta.Expose;
	public static final Extern:StrictMeta = StrictMeta.Extern;
	public static final File:StrictMeta = StrictMeta.File;
	public static final FileXml:StrictMeta = StrictMeta.FileXml;
	public static final Final:StrictMeta = StrictMeta.Final;
	public static final Fixed:StrictMeta = StrictMeta.Fixed;
	public static final FlashProperty:StrictMeta = StrictMeta.FlashProperty;
	public static final FlatEnum:StrictMeta = StrictMeta.FlatEnum;
	public static final Font:StrictMeta = StrictMeta.Font;
	public static final ForLoopVariable:StrictMeta = StrictMeta.ForLoopVariable;
	public static final Forward:StrictMeta = StrictMeta.Forward;
	public static final ForwardNew:StrictMeta = StrictMeta.ForwardNew;
	public static final ForwardStatics:StrictMeta = StrictMeta.ForwardStatics;
	public static final ForwardVariance:StrictMeta = StrictMeta.ForwardVariance;
	public static final From:StrictMeta = StrictMeta.From;
	public static final FromNull:StrictMeta = StrictMeta.FromNull;
	public static final FunctionalInterface:StrictMeta = StrictMeta.FunctionalInterface;
	public static final FunctionCode:StrictMeta = StrictMeta.FunctionCode;
	public static final FunctionTailCode:StrictMeta = StrictMeta.FunctionTailCode;
	public static final Generic:StrictMeta = StrictMeta.Generic;
	public static final GenericBuild:StrictMeta = StrictMeta.GenericBuild;
	public static final GenericInstance:StrictMeta = StrictMeta.GenericInstance;
	public static final GenericClassPerMethod:StrictMeta = StrictMeta.GenericClassPerMethod;
	public static final Getter:StrictMeta = StrictMeta.Getter;
	public static final Hack:StrictMeta = StrictMeta.Hack;
	public static final HasUntyped:StrictMeta = StrictMeta.HasUntyped;
	public static final HeaderClassCode:StrictMeta = StrictMeta.HeaderClassCode;
	public static final HeaderCode:StrictMeta = StrictMeta.HeaderCode;
	public static final HeaderInclude:StrictMeta = StrictMeta.HeaderInclude;
	public static final HeaderNamespaceCode:StrictMeta = StrictMeta.HeaderNamespaceCode;
	public static final HlNative:StrictMeta = StrictMeta.HlNative;
	public static final HxbId:StrictMeta = StrictMeta.HxbId;
	public static final HxCompletion:StrictMeta = StrictMeta.HxCompletion;
	public static final HxGen:StrictMeta = StrictMeta.HxGen;
	public static final IfFeature:StrictMeta = StrictMeta.IfFeature;
	public static final PythonImport:StrictMeta = StrictMeta.PythonImport;
	public static final ImplicitCast:StrictMeta = StrictMeta.ImplicitCast;
	public static final ImplicitReturn:StrictMeta = StrictMeta.ImplicitReturn;
	public static final Include:StrictMeta = StrictMeta.Include;
	public static final InheritDoc:StrictMeta = StrictMeta.InheritDoc;
	public static final InitPackage:StrictMeta = StrictMeta.InitPackage;
	public static final Inline:StrictMeta = StrictMeta.Inline;
	public static final InlineObject:StrictMeta = StrictMeta.InlineObject;
	public static final IsVar:StrictMeta = StrictMeta.IsVar;
	public static final JavaDefault:StrictMeta = StrictMeta.JavaDefault;
	public static final JvmSynthetic:StrictMeta = StrictMeta.JvmSynthetic;
	public static final JsRequire:StrictMeta = StrictMeta.JsRequire;
	public static final JsImport:StrictMeta = StrictMeta.JsImport;
	public static final LuaRequire:StrictMeta = StrictMeta.LuaRequire;
	public static final LuaDotMethod:StrictMeta = StrictMeta.LuaDotMethod;
	public static final Keep:StrictMeta = StrictMeta.Keep;
	public static final KeepInit:StrictMeta = StrictMeta.KeepInit;
	public static final KeepSub:StrictMeta = StrictMeta.KeepSub;
	public static final LibType:StrictMeta = StrictMeta.LibType;
	public static final LoopLabel:StrictMeta = StrictMeta.LoopLabel;
	public static final Markup:StrictMeta = StrictMeta.Markup;
	public static final Meta:StrictMeta = StrictMeta.Meta;
	public static final MergeBlock:StrictMeta = StrictMeta.MergeBlock;
	public static final MultiReturn:StrictMeta = StrictMeta.MultiReturn;
	public static final MultiType:StrictMeta = StrictMeta.MultiType;
	public static final Native:StrictMeta = StrictMeta.Native;
	public static final NativeJni:StrictMeta = StrictMeta.NativeJni;
	public static final NativeGen:StrictMeta = StrictMeta.NativeGen;
	public static final NativeProperty:StrictMeta = StrictMeta.NativeProperty;
	public static final NativeStaticExtension:StrictMeta = StrictMeta.NativeStaticExtension;
	public static final NoCompletion:StrictMeta = StrictMeta.NoCompletion;
	public static final NoClosure:StrictMeta = StrictMeta.NoClosure;
	public static final NoDebug:StrictMeta = StrictMeta.NoDebug;
	public static final NoDoc:StrictMeta = StrictMeta.NoDoc;
	public static final NoExpr:StrictMeta = StrictMeta.NoExpr;
	public static final NoImportGlobal:StrictMeta = StrictMeta.NoImportGlobal;
	public static final NonVirtual:StrictMeta = StrictMeta.NonVirtual;
	public static final NoPackageRestrict:StrictMeta = StrictMeta.NoPackageRestrict;
	public static final NoPrivateAccess:StrictMeta = StrictMeta.NoPrivateAccess;
	public static final NoStack:StrictMeta = StrictMeta.NoStack;
	public static final NotNull:StrictMeta = StrictMeta.NotNull;
	public static final NoUsing:StrictMeta = StrictMeta.NoUsing;
	public static final Ns:StrictMeta = StrictMeta.Ns;
	public static final NullSafety:StrictMeta = StrictMeta.NullSafety;
	public static final Objc:StrictMeta = StrictMeta.Objc;
	public static final ObjcProtocol:StrictMeta = StrictMeta.ObjcProtocol;
	public static final Op:StrictMeta = StrictMeta.Op;
	public static final Optional:StrictMeta = StrictMeta.Optional;
	public static final Overload:StrictMeta = StrictMeta.Overload;
	public static final Persistent:StrictMeta = StrictMeta.Persistent;
	public static final PhpAttribute:StrictMeta = StrictMeta.PhpAttribute;
	public static final PhpGlobal:StrictMeta = StrictMeta.PhpGlobal;
	public static final PhpClassConst:StrictMeta = StrictMeta.PhpClassConst;
	public static final PhpMagic:StrictMeta = StrictMeta.PhpMagic;
	public static final PhpNoConstructor:StrictMeta = StrictMeta.PhpNoConstructor;
	public static final Pos:StrictMeta = StrictMeta.Pos;
	public static final Public:StrictMeta = StrictMeta.Public;
	public static final PublicFields:StrictMeta = StrictMeta.PublicFields;
	public static final Private:StrictMeta = StrictMeta.Private;
	public static final PrivateAccess:StrictMeta = StrictMeta.PrivateAccess;
	public static final Protected:StrictMeta = StrictMeta.Protected;
	public static final Pure:StrictMeta = StrictMeta.Pure;
	public static final RealPath:StrictMeta = StrictMeta.RealPath;
	public static final Remove:StrictMeta = StrictMeta.Remove;
	public static final Require:StrictMeta = StrictMeta.Require;
	public static final Resolve:StrictMeta = StrictMeta.Resolve;
	public static final Rtti:StrictMeta = StrictMeta.Rtti;
	public static final Runtime:StrictMeta = StrictMeta.Runtime;
	public static final RuntimeValue:StrictMeta = StrictMeta.RuntimeValue;
	public static final Scalar:StrictMeta = StrictMeta.Scalar;
	public static final SelfCall:StrictMeta = StrictMeta.SelfCall;
	public static final Semantics:StrictMeta = StrictMeta.Semantics;
	public static final Setter:StrictMeta = StrictMeta.Setter;
	public static final Sound:StrictMeta = StrictMeta.Sound;
	public static final SourceFile:StrictMeta = StrictMeta.SourceFile;
	public static final StackOnly:StrictMeta = StrictMeta.StackOnly;
	public static final StaticExtension:StrictMeta = StrictMeta.StaticExtension;
	public static final StoredTypedExpr:StrictMeta = StrictMeta.StoredTypedExpr;
	public static final Strict:StrictMeta = StrictMeta.Strict;
	public static final Struct:StrictMeta = StrictMeta.Struct;
	public static final StructAccess:StrictMeta = StrictMeta.StructAccess;
	public static final NativeArrayAccess:StrictMeta = StrictMeta.NativeArrayAccess;
	public static final CppValueType:StrictMeta = StrictMeta.CppValueType;
	public static final CppPointerType:StrictMeta = StrictMeta.CppPointerType;
	public static final CppManagedType:StrictMeta = StrictMeta.CppManagedType;
	public static final StructInit:StrictMeta = StrictMeta.StructInit;
	public static final TailRecursion:StrictMeta = StrictMeta.TailRecursion;
	public static final TemplatedCall:StrictMeta = StrictMeta.TemplatedCall;
	public static final This:StrictMeta = StrictMeta.This;
	public static final To:StrictMeta = StrictMeta.To;
	public static final ToString:StrictMeta = StrictMeta.ToString;
	public static final Transitive:StrictMeta = StrictMeta.Transitive;
	public static final ValueUsed:StrictMeta = StrictMeta.ValueUsed;
	public static final Volatile:StrictMeta = StrictMeta.Volatile;
	public static final UnifyMinDynamic:StrictMeta = StrictMeta.UnifyMinDynamic;
	public static final Unreflective:StrictMeta = StrictMeta.Unreflective;
	public static final Used:StrictMeta = StrictMeta.Used;
	public static final Using:StrictMeta = StrictMeta.Using;
	public static final Value:StrictMeta = StrictMeta.Value;
	public static final HaxeArguments:StrictMeta = StrictMeta.HaxeArguments;
	public static final HaxeWarning:StrictMeta = StrictMeta.HaxeWarning;
	public static final Void:StrictMeta = StrictMeta.Void;
	public static final NeedsExceptionStack:StrictMeta = StrictMeta.NeedsExceptionStack;
	public static final WrappedException:StrictMeta = StrictMeta.WrappedException;
	public static final ExceptionTypeCheck:StrictMeta = StrictMeta.ExceptionTypeCheck;
}
