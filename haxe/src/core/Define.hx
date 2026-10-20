package core;

import haxe.crypto.Md5;
import haxe.ds.StringMap;
import core.DefineRegistry;
import core.Globals.Platform;

// port: the generated DefineList (prebuild.ml over src-json/define.json) is DefineRegistry. A
// strict_defined is its key string (Define.Custom is the identity), so `infos` looks a key up in the
// user defines first, then in the registry. Signatures are hexadecimal MD5 digests.
@:structInit class UserDefine {
	public var doc:String;
	public var flags:Array<DefineParameter>;
	public var source:Null<String>;

	public inline function new(doc:String, flags:Array<DefineParameter>, source:Null<String>) {
		this.doc = doc;
		this.flags = flags;
		this.source = source;
	}

	public inline function clone():UserDefine return new UserDefine(doc, flags, source);
}

enum DefineOrigin {
	Compiler;
	UserDefined(source:Null<String>);
}

@:structInit class DefineInfos {
	public var dDoc:String;
	public var dParams:Array<String>;
	public var dPlatforms:Array<Platform>;
	public var dOrigin:DefineOrigin;
	public var dLinks:Array<String>;
	public var dDeprecated:Null<String>;
	public var dDefault:Null<String>;
	public var dReserved:Null<Bool>;

	public inline function new(dDoc:String, dParams:Array<String>, dPlatforms:Array<Platform>, dOrigin:DefineOrigin, dLinks:Array<String>,
			dDeprecated:Null<String>, dDefault:Null<String>, dReserved:Null<Bool>) {
		this.dDoc = dDoc;
		this.dParams = dParams;
		this.dPlatforms = dPlatforms;
		this.dOrigin = dOrigin;
		this.dLinks = dLinks;
		this.dDeprecated = dDeprecated;
		this.dDefault = dDefault;
		this.dReserved = dReserved;
	}

	public inline function clone():DefineInfos return new DefineInfos(dDoc, dParams, dPlatforms, dOrigin, dLinks, dDeprecated, dDefault,
		dReserved);
}

// port: `define`; `values` is a persistent map (copied on write) as PMap is
@:structInit class DefineContext {
	public var values:StringMap<String>;
	public var definesSignature:Null<String>;

	public inline function new(values:StringMap<String>, definesSignature:Null<String>) {
		this.values = values;
		this.definesSignature = definesSignature;
	}

	public inline function clone():DefineContext return new DefineContext(values, definesSignature);
}

class Define {
	public static final deprecationLut = DefineRegistry.deprecationLut;
	public static final defaultValues = DefineRegistry.defaultValues;

	public static function infos(key:String, ?userDefines:StringMap<UserDefine>):{name:String, info:DefineInfos} {
		var doc = "";
		var flags:Array<DefineParameter> = [];
		var origin:DefineOrigin = Compiler;
		if (userDefines != null && userDefines.exists(key)) {
			var data = userDefines.get(key);
			doc = data.doc;
			flags = data.flags;
			origin = UserDefined(data.source);
		} else for (entry in DefineRegistry.all) if (entry.key == key) {
			doc = entry.doc;
			flags = entry.flags;
			break;
		}
		var params = [], platforms = [], links = [];
		var deprecated:Null<String> = null,
			defaultValue:Null<String> = null,
			reserved:Null<Bool> = null;
		for (flag in flags) switch flag {
			case HasParam(s):
				params.unshift(s);
			case Platforms(pfs):
				platforms = pfs.concat(platforms);
			case Link(s):
				links.unshift(s);
			case Deprecated(s):
				deprecated = s;
			case DefaultValue(s):
				defaultValue = s;
			case Reserved(b):
				reserved = b;
		}
		return {
			name: key,
			info: {
				dDoc: doc,
				dParams: params,
				dPlatforms: platforms,
				dOrigin: origin,
				dLinks: links,
				dDeprecated: deprecated,
				dDefault: defaultValue,
				dReserved: reserved
			}
		};
	}

	public static function registerUserDefine(userDefines:StringMap<UserDefine>, key:String,
			data:UserDefine):Void userDefines.set(key, data);

	public static function getDocumentation(userDefines:StringMap<UserDefine>, key:String):{name:String, description:String} {
		var result = infos(key, userDefines),
			data = result.info,
			params = data.dParams.copy(),
			platforms = data.dPlatforms.copy();
		params.reverse();
		platforms.reverse();
		var origin = switch data.dOrigin {
			case UserDefined(s) if (s != null): " (from " + s + ")";
			case _: "";
		};
		return {
			name: key.split("_").join("-"),
			description: (params.length == 0 ? "" : "<" + params.join(">, <") + "> ")
				+ data.dDoc
				+ core.Globals.platformListHelp(platforms)
				+ origin};
	}

	static function documentationList(userDefines:StringMap<UserDefine>,
			keys:Array<String>):{all:Array<{name:String, description:String}>, maxLength:Int} {
		var maxLength = 0, all = [];
		for (key in keys) {
			var doc = getDocumentation(userDefines, key);
			maxLength = Std.int(Math.max(maxLength, doc.name.length));
			all.push(doc);
		}
		all.sort((a, b) -> core.ds.Key.compareStrings(a.name, b.name));
		return {all: all, maxLength: maxLength};
	}

	public static function getDocumentationList(userDefines:StringMap<UserDefine>):{all:Array<{name:String, description:String}>, maxLength:Int}
		return documentationList(userDefines, [for (entry in DefineRegistry.all) entry.key]);

	public static function getUserDocumentationList(userDefines:StringMap<UserDefine>):{all:Array<{name:String, description:String}>, maxLength:Int}
		return documentationList(userDefines, [for (key in userDefines.keys()) key]);

	public static function getDefineList(userDefines:StringMap<UserDefine>):Array<{name:String, info:DefineInfos}> {
		var all = [for (entry in DefineRegistry.all) infos(entry.key, userDefines)];
		for (key in userDefines.keys()) all.push(infos(key, userDefines));
		// port: List.sort is stable
		haxe.ds.ArraySort.sort(all, (a, b) -> core.ds.Key.compareStrings(a.name, b.name));
		return all;
	}

	// port: DefineList.is_signature_neutral
	public static final signatureNeutral:Array<String> = [
		"times.analyzer",
		"analyzer_times",
		"dce_debug",
		"disable_hxb_cache",
		"disable_hxb_optimizations",
		"disable_parallelism",
		"enable_parallel_abstract_cast",
		"enable_parallel_analyzer",
		"display",
		"display_stdin",
		"display_details",
		"dump",
		"dump.stage",
		"dump_path",
		"dump_dependencies",
		"dump_ignore_var_ids",
		"times.eval",
		"eval_times",
		"fail_fast",
		"times.filter",
		"filter_times",
		"times.hxb",
		"hxb_times",
		"hxb.stats",
		"times.macro",
		"macro_times",
		"no_compilation",
		"message.reporting",
		"message.color",
		"message.no_color",
		"message.absolute_positions",
		"message.log_file",
		"message.log_format"
	];
	public static final AbsolutePath:String = "absolute_path";
	public static final AdvancedTelemetry:String = "advanced_telemetry";
	public static final AnalyzerOptimize:String = "analyzer_optimize";
	public static final AnalyzerTimes:String = "times.analyzer";
	public static final AnnotateSource:String = "annotate_source";
	public static final CheckXmlProxy:String = "check_xml_proxy";
	public static final CoreApi:String = "core_api";
	public static final Cppia:String = "cppia";
	public static final NoCppiaAst:String = "nocppiaast";
	public static final Dce:String = "dce";
	public static final DceDebug:String = "dce_debug";
	public static final Debug:String = "debug";
	public static final DisableHxbCache:String = "disable_hxb_cache";
	public static final DisableHxbOptimizations:String = "disable_hxb_optimizations";
	public static final DisableParallelism:String = "disable_parallelism";
	public static final EnableParallelAbstractCast:String = "enable_parallel_abstract_cast";
	public static final EnableParallelAnalyzer:String = "enable_parallel_analyzer";
	public static final DisableUnicodeStrings:String = "disable_unicode_strings";
	public static final Display:String = "display";
	public static final DisplayStdin:String = "display_stdin";
	public static final DisplayDetails:String = "display_details";
	public static final DllExport:String = "dll_export";
	public static final DocGen:String = "doc_gen";
	public static final Dump:String = "dump";
	public static final DumpStage:String = "dump.stage";
	public static final DumpPath:String = "dump_path";
	public static final DumpDependencies:String = "dump_dependencies";
	public static final DumpIgnoreVarIds:String = "dump_ignore_var_ids";
	public static final DynamicInterfaceClosures:String = "dynamic_interface_closures";
	public static final EvalCallStackDepth:String = "eval_call_stack_depth";
	public static final EvalDebugger:String = "eval_debugger";
	public static final EvalPrintDepth:String = "eval_print_depth";
	public static final EvalPrettyPrint:String = "eval_pretty_print";
	public static final EvalStack:String = "eval_stack";
	public static final EvalTimes:String = "times.eval";
	public static final FailFast:String = "fail_fast";
	public static final FilterTimes:String = "times.filter";
	public static final Fdb:String = "fdb";
	public static final FileExtension:String = "file_extension";
	public static final FlashStrict:String = "flash_strict";
	public static final FlashUseStage:String = "flash_use_stage";
	public static final ForceNativeProperty:String = "force_native_property";
	public static final Haxe3Compat:String = "haxe3compat";
	public static final HaxeBoot:String = "haxe_boot";
	public static final HaxeVer:String = "haxe_ver";
	public static final Haxe:String = "haxe";
	public static final Haxe3:String = "haxe3";
	public static final Haxe4:String = "haxe4";
	public static final Haxe5:String = "haxe5";
	public static final HaxeNext:String = "haxe_next";
	public static final HaxeOutputFile:String = "HAXE_OUTPUT_FILE";
	public static final HaxeOutputPart:String = "HAXE_OUTPUT_PART";
	public static final Hlc:String = "hlc";
	public static final HlVer:String = "hl_ver";
	public static final HxbTimes:String = "times.hxb";
	public static final HxbStats:String = "hxb.stats";
	public static final HxcppApiLevel:String = "hxcpp_api_level";
	public static final HxcppGcGenerational:String = "HXCPP_GC_GENERATIONAL";
	public static final HxcppDebugger:String = "HXCPP_DEBUGGER";
	public static final HxcppGcMoving:String = "HXCPP_GC_MOVING";
	public static final HxcppGcSummary:String = "HXCPP_GC_SUMMARY";
	public static final HxcppGcDynamicSize:String = "HXCPP_GC_DYNAMIC_SIZE";
	public static final HxcppGcBigBlocks:String = "HXCPP_GC_BIG_BLOCKS";
	public static final HxcppGcDebugLevel:String = "HXCPP_GC_DEBUG_LEVEL";
	public static final HxcppDebugLink:String = "HXCPP_DEBUG_LINK";
	public static final HxcppStackTrace:String = "HXCPP_STACK_TRACE";
	public static final HxcppStackLine:String = "HXCPP_STACK_LINE";
	public static final HxcppCheckPointer:String = "HXCPP_CHECK_POINTER";
	public static final HxcppProfiler:String = "HXCPP_PROFILER";
	public static final HxcppTelemetry:String = "HXCPP_TELEMETRY";
	public static final HxcppCpp11:String = "HXCPP_CPP11";
	public static final HxcppVerbose:String = "HXCPP_VERBOSE";
	public static final HxcppTimes:String = "HXCPP_TIMES";
	public static final HxcppM32:String = "HXCPP_M32";
	public static final HxcppM64:String = "HXCPP_M64";
	public static final HxcppArm64:String = "HXCPP_ARM64";
	public static final HxcppLinuxArm64:String = "HXCPP_LINUX_ARM64";
	public static final HxcppSmartStings:String = "hxcpp_smart_strings";
	public static final IncludePrefix:String = "include_prefix";
	public static final Interp:String = "interp";
	public static final JsClassic:String = "js_classic";
	public static final JsEs:String = "js_es";
	public static final JsEnumsAsArrays:String = "js_enums_as_arrays";
	public static final JsGlobal:String = "js_global";
	public static final JsUnflatten:String = "js_unflatten";
	public static final JsSourceMap:String = "js_source_map";
	public static final SourceMap:String = "source_map";
	public static final JvmCompressionLevel:String = "jvm.compression_level";
	public static final JvmDynamicLevel:String = "jvm.dynamic_level";
	public static final LoopUnrollMaxCost:String = "loop_unroll_max_cost";
	public static final LuaJit:String = "lua_jit";
	public static final LuaVanilla:String = "lua_vanilla";
	public static final LuaVer:String = "lua_ver";
	public static final LuaWindowsUtf8Io:String = "lua.windows_utf8_io";
	public static final Macro:String = "macro";
	public static final MacroTimes:String = "times.macro";
	public static final NekoSource:String = "neko_source";
	public static final NekoNoHaxelibPaths:String = "neko_no_haxelib_paths";
	public static final NekoV1:String = "neko_v1";
	public static final NetworkSandbox:String = "network_sandbox";
	public static final NoCompilation:String = "no_compilation";
	public static final NoDebug:String = "no_debug";
	public static final NoDeprecationWarnings:String = "no_deprecation_warnings";
	public static final NoFlashOverride:String = "no_flash_override";
	public static final NoOpt:String = "no_opt";
	public static final NoInline:String = "no_inline";
	public static final KeepInlinePositions:String = "keep_inline_positions";
	public static final NoMacroCache:String = "no_macro_cache";
	public static final NoSwfCompress:String = "no_swf_compress";
	public static final NoTraces:String = "no_traces";
	public static final Objc:String = "objc";
	public static final OldErrorFormat:String = "old_error_format";
	public static final PhpPrefix:String = "php_prefix";
	public static final PhpLib:String = "php_lib";
	public static final PhpFront:String = "php_front";
	public static final PythonVersion:String = "python_version";
	public static final RealPosition:String = "real_position";
	public static final RetainUntypedMeta:String = "retain_untyped_meta";
	public static final Scriptable:String = "scriptable";
	public static final ShallowExpose:String = "shallow_expose";
	public static final SourceHeader:String = "source_header";
	public static final SourceMapContent:String = "source_map_content";
	public static final Static:String = "static";
	public static final StdEncodingUtf8:String = "std_encoding_utf8";
	public static final Swc:String = "swc";
	public static final SwfCompressLevel:String = "swf_compress_level";
	public static final SwfDebugPassword:String = "swf_debug_password";
	public static final SwfDirectBlit:String = "swf_direct_blit";
	public static final SwfGpu:String = "swf_gpu";
	public static final SwfHeader:String = "swf_header";
	public static final SwfMetadata:String = "swf_metadata";
	public static final SwfPreloaderFrame:String = "swf_preloader_frame";
	public static final SwfProtected:String = "swf_protected";
	public static final SwfScriptTimeout:String = "swf_script_timeout";
	public static final SwfUseDoAbc:String = "swf_use_doabc";
	public static final Sys:String = "sys";
	public static final UseNekoc:String = "use_nekoc";
	public static final Utf16:String = "utf16";
	public static final Vcproj:String = "vcproj";
	public static final WarnVarShadowing:String = "warn_var_shadowing";
	public static final NoTre:String = "no_tre";
	public static final MessageReporting:String = "message.reporting";
	public static final MessageColor:String = "message.color";
	public static final MessageNoColor:String = "message.no_color";
	public static final MessageAbsolutePositions:String = "message.absolute_positions";
	public static final MessageLogFile:String = "message.log_file";
	public static final MessageLogFormat:String = "message.log_format";

	public static function Custom(key:String):String return key;

	public static function getDefineKey(key:String):String return key;

	public static function defined(ctx:DefineContext, key:String):Bool return rawDefined(ctx, key);

	public static function definedValue(ctx:DefineContext, key:String):String return rawDefinedValue(ctx, key);

	public static function definedValueSafe(ctx:DefineContext, key:String,
			?defaultValue:String = ""):String return rawDefinedValueSafe(ctx, key, defaultValue);

	public static function define(ctx:DefineContext, key:String):Void rawDefine(ctx, key);

	public static function defineValue(ctx:DefineContext, key:String, value:String):Void rawDefineValue(ctx, key, value);

	public static function emptyDefines():DefineContext {
		return {values: new StringMap(), definesSignature: null};
	}

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) records here the defines the
	// ... compiler reads; always null in the compiler itself.
	public static var readHook:Null<(ctx:DefineContext, key:String) -> Void> = null;

	public static inline function rawDefined(ctx:DefineContext, key:String):Bool {
		if (readHook != null) readHook(ctx, key);
		return ctx.values.exists(key);
	}

	// port: throws when the define is absent, like PMap.find in the OCaml source.
	public static function rawDefinedValue(ctx:DefineContext, key:String):String {
		if (readHook != null) readHook(ctx, key);
		var value = ctx.values.get(key);
		if (value == null && !ctx.values.exists(key)) throw core.ds.NotFound.raise();
		return value;
	}

	public static function rawDefinedValueSafe(ctx:DefineContext, key:String, ?defaultValue = ""):String {
		return rawDefined(ctx, key) ? rawDefinedValue(ctx, key) : defaultValue;
	}

	public static function rawDefineValue(ctx:DefineContext, key:String, value:String):Void {
		var values = ctx.values.copy();
		values.set(key, value);
		ctx.values = values;
		ctx.definesSignature = null;
	}

	public static inline function rawDefine(ctx:DefineContext, key:String):Void {
		rawDefineValue(ctx, key, "1");
	}

	public static function rawUndefine(ctx:DefineContext, key:String):Void {
		var values = ctx.values.copy();
		values.remove(key);
		ctx.values = values;
		ctx.definesSignature = null;
	}

	public static function getSignature(ctx:DefineContext):String {
		if (ctx.definesSignature != null) return ctx.definesSignature;

		var defines:Array<String> = [];
		for (k => v in ctx.values) {
			/* don't make much difference between these special compilation flags */
			var sanitized = k.split("-").join("_");
			/* If we add something here that might be used in conditional compilation it should be added to
				Grammar.parse_macro_ident as well (issue #5682).
			*/
			if (signatureNeutral.indexOf(sanitized) >= 0) continue;
			defines.push(sanitized + "=" + v);
		}
		// port: `Ast.remove_duplicates (fun a b -> a != b)` compares physically and so removes
		// nothing from these freshly built strings.
		defines.sort(core.ds.Key.compareStrings);
		ctx.definesSignature = Md5.encode(defines.join("@"));
		return ctx.definesSignature;
	}
}
