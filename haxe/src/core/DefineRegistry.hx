package core;

import core.Globals.Platform;
import haxe.ds.StringMap;

// port: generated data translated from haxe/src-json/define.json following prebuild.ml.
enum DefineParameter {
	HasParam(value:String);
	Platforms(values:Array<Platform>);
	Link(value:String);
	Deprecated(value:String);
	DefaultValue(value:String);
	Reserved(value:Bool);
}

enum DefineDeprecation {
	DueTo(reason:String);
	InFavorOf(key:String);
}

typedef DefineRegistration = {var key:String; var doc:String; var flags:Array<DefineParameter>;}

class DefineRegistry {
	public static final all:Array<DefineRegistration> = [
		{key: "absolute_path", doc: "Print absolute file path in trace output.", flags: []},
		{key: "advanced_telemetry", doc: "Allow the SWF to be measured with Monocle tool.", flags: [Platforms([Flash])]},
		{key: "analyzer_optimize", doc: "Perform advanced optimizations.", flags: []},
		{key: "times.analyzer", doc: "Record detailed timers for the analyzer", flags: [HasParam("level: 0 | 1 | 2")]},
		{key: "annotate_source", doc: "Add additional comments to generated source code.", flags: [Platforms([Cpp])]},
		{key: "check_xml_proxy", doc: "Check the used fields of the XML proxy.", flags: []},
		{key: "core_api", doc: "Defined in the core API context.", flags: []},
		{key: "cppia", doc: "Generate cpp instruction assembly.", flags: []},
		{key: "nocppiaast", doc: "Use legacy cppia generation.", flags: []},
		{
			key: "dce",
			doc: "Set the dead code elimination mode. (default: std)",
			flags: [
				HasParam("mode: std | full | no"),
				Link("https://haxe.org/manual/cr-dce.html"),
				DefaultValue("std")
			]
		},
		{key: "dce_debug", doc: "Show DCE log.", flags: [Link("https://haxe.org/manual/cr-dce.html")]},
		{key: "debug", doc: "Activated when compiling with -debug.", flags: []},
		{key: "disable_hxb_cache", doc: "Use in-memory cache instead of hxb powered cache.", flags: []},
		{key: "disable_hxb_optimizations", doc: "Disable shortcuts used by hxb cache to speed up display requests.", flags: []},
		{key: "disable_parallelism", doc: "Disable experimental uses of parallelism in the compiler.", flags: []},
		{
			key: "enable_parallel_abstract_cast",
			doc: "Enable experimental uses of parallelism in the abstract cast filter (can trigger memory leaks).",
			flags: []
		},
		{
			key: "enable_parallel_analyzer",
			doc: "Enable experimental uses of parallelism in the analyzer (can trigger memory leaks).",
			flags: []
		},
		{key: "disable_unicode_strings", doc: "Disable Unicode support in `String` type.", flags: [Platforms([Cpp])]},
		{key: "display", doc: "Activated during completion.", flags: [Link("https://haxe.org/manual/cr-completion.html")]},
		{key: "display_stdin", doc: "Read the contents of a file specified in `--display` from standard input.", flags: []},
		{
			key: "display_details",
			doc: "Not used anymore, but still sent by vshaxe.",
			flags: [Deprecated("This flag is no longer supported in Haxe 5")]
		},
		{key: "dll_export", doc: "GenCPP experimental linking.", flags: [Platforms([Cpp])]},
		{key: "doc_gen", doc: "Do not perform any removal/change in order to correctly generate documentation.", flags: []},
		{
			key: "dump",
			doc: "Dump typed AST in dump subdirectory using specified mode or non-prettified default.",
			flags: [HasParam("mode: pretty | record | position | legacy")]
		},
		{
			key: "dump.stage",
			doc: "The compiler stage after which to generate the dump",
			flags: [
				HasParam("stage: typing | casting | inlining | analyzing | dce"),
				DefaultValue("dce")
			]
		},
		{key: "dump_path", doc: "Path to generate dumps to (default: \"dump\").", flags: [HasParam("path"), DefaultValue("dump")]},
		{key: "dump_dependencies", doc: "Dump the classes dependencies in a dump subdirectory.", flags: []},
		{key: "dump_ignore_var_ids", doc: "Remove variable IDs from non-pretty dumps (helps with diff).", flags: [DefaultValue("1")]},
		{key: "dynamic_interface_closures", doc: "Use slow path for interface closures to save space.", flags: [Platforms([Cpp])]},
		{
			key: "eval_call_stack_depth",
			doc: "Set maximum call stack depth for eval. (default: 1000)",
			flags: [Platforms([Eval]), HasParam("depth"), DefaultValue("1000")]
		},
		{
			key: "eval_debugger",
			doc: "Support debugger in macro/interp mode. Allows `host:port` value to open a socket. Implies eval-stack.",
			flags: [Platforms([Eval])]
		},
		{
			key: "eval_print_depth",
			doc: "Set maximum print depth (before replacing with '<...>') for eval. (default: 5)",
			flags: [Platforms([Eval]), HasParam("depth"), DefaultValue("5")]
		},
		{key: "eval_pretty_print", doc: "Enable indented output for eval printing.", flags: [Platforms([Eval])]},
		{key: "eval_stack", doc: "Record stack information in macro/interp mode.", flags: [Platforms([Eval])]},
		{key: "times.eval", doc: "Record per-method execution times in macro/interp mode. Implies eval-stack.", flags: [Platforms([Eval])]},
		{key: "fail_fast", doc: "Abort compilation when first error occurs.", flags: []},
		{key: "times.filter", doc: "Record per-filter execution times upon --times.", flags: []},
		{key: "fdb", doc: "Enable full flash debug infos for FDB interactive debugging.", flags: [Platforms([Flash])]},
		{key: "file_extension", doc: "Output filename extension for cpp source code.", flags: [Platforms([Cpp])]},
		{key: "flash_strict", doc: "More strict typing for flash target.", flags: [Platforms([Flash])]},
		{key: "flash_use_stage", doc: "Keep the SWF library initial stage.", flags: [Platforms([Flash])]},
		{
			key: "force_native_property",
			doc: "Tag all properties with `:nativeProperty` metadata for 3.1 compatibility.",
			flags: [Platforms([Cpp])]
		},
		{
			key: "haxe3compat",
			doc: "Gives warnings about transition from Haxe 3.x to Haxe 4.0.",
			flags: [Deprecated("This flag is no longer supported in Haxe 5")]
		},
		{key: "haxe_boot", doc: "Give the name 'haxe' to the flash boot class instead of a generated name.", flags: [Platforms([Flash])]},
		{key: "haxe_ver", doc: "The current Haxe version value as decimal number. E.g. 3.407 for 3.4.7.", flags: [Reserved(true)]},
		{key: "haxe", doc: "The current Haxe version value in SemVer format.", flags: [Reserved(true)]},
		{key: "haxe3", doc: "The current Haxe major version is >= 3.", flags: [DefaultValue("1"), Reserved(true)]},
		{key: "haxe4", doc: "The current Haxe major version is >= 4.", flags: [DefaultValue("1"), Reserved(true)]},
		{key: "haxe5", doc: "The current Haxe major version is >= 5.", flags: [DefaultValue("1"), Reserved(true)]},
		{key: "haxe_next", doc: "Enable experimental features that are meant to be released on next Haxe version.", flags: []},
		{
			key: "HAXE_OUTPUT_FILE",
			doc: "Force the full output name of the executable/library without library prefix and debug suffix.",
			flags: [Platforms([Cpp]), HasParam("name")]
		},
		{
			key: "HAXE_OUTPUT_PART",
			doc: "Output name of the executable/library. (default: main class name)",
			flags: [Platforms([Cpp]), HasParam("name")]
		},
		{key: "hlc", doc: "Defined by compiler when using hl/c target.", flags: [Platforms([Hl]), Reserved(true)]},
		{key: "hl_ver", doc: "The HashLink version to target. (default: 1.15.0)", flags: [Platforms([Hl]), HasParam("version")]},
		{key: "times.hxb", doc: "Display hxb timing when used with `--times`.", flags: []},
		{key: "hxb.stats", doc: "Display some hxb related stats (only with compilation server).", flags: []},
		{key: "hxcpp_api_level", doc: "Provided to allow compatibility between hxcpp versions.", flags: [Platforms([Cpp]), Reserved(true)]},
		{key: "HXCPP_GC_GENERATIONAL", doc: "Experimental Garbage Collector.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_DEBUGGER", doc: "Include additional information for hxcpp-debugger.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_GC_MOVING", doc: "Allow garbage collector to move memory to reduce fragmentation", flags: [Platforms([Cpp])]},
		{key: "HXCPP_GC_SUMMARY", doc: "Print small profiling summary at end of program", flags: [Platforms([Cpp])]},
		{key: "HXCPP_GC_DYNAMIC_SIZE", doc: "Monitor GC times and expand memory working space if required", flags: [Platforms([Cpp])]},
		{key: "HXCPP_GC_BIG_BLOCKS", doc: "Allow working memory greater than 1 Gig", flags: [Platforms([Cpp])]},
		{key: "HXCPP_GC_DEBUG_LEVEL", doc: "Number 1-4 indicating additional debugging in GC", flags: [Platforms([Cpp])]},
		{key: "HXCPP_DEBUG_LINK", doc: "Add symbols to final binary, even in release mode.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_STACK_TRACE", doc: "Have valid function-level stack traces, even in release mode.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_STACK_LINE", doc: "Include line information in stack traces, even in release mode.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_CHECK_POINTER", doc: "Add null-pointer checks, even in release mode.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_PROFILER", doc: "Add profiler support", flags: [Platforms([Cpp])]},
		{key: "HXCPP_TELEMETRY", doc: "Add telemetry support", flags: [Platforms([Cpp])]},
		{key: "HXCPP_CPP11", doc: "Use C++11 features and link libraries", flags: [Platforms([Cpp])]},
		{key: "HXCPP_VERBOSE", doc: "Print extra output from build tool.", flags: [Platforms([Cpp])]},
		{key: "HXCPP_TIMES", doc: "Show some basic profiling information", flags: [Platforms([Cpp])]},
		{key: "HXCPP_M32", doc: "Force 32-bit compile for current desktop", flags: [Platforms([Cpp])]},
		{key: "HXCPP_M64", doc: "Force 64-bit compile for current desktop", flags: [Platforms([Cpp])]},
		{key: "HXCPP_ARM64", doc: "Compile arm-based devices for 64 bits", flags: [Platforms([Cpp])]},
		{key: "HXCPP_LINUX_ARM64", doc: "Run on a linux ARM64 device", flags: [Platforms([Cpp])]},
		{
			key: "hxcpp_smart_strings",
			doc: "Use wide strings in hxcpp. (Turned on by default unless `-D disable-unicode-strings` is specified.)",
			flags: [Platforms([Cpp])]
		},
		{key: "include_prefix", doc: "Prepend path to generated include files.", flags: [Platforms([Cpp])]},
		{key: "interp", doc: "The code is compiled to be run with `--interp`.", flags: []},
		{key: "js_classic", doc: "Don't use a function wrapper and strict mode in JS output.", flags: [Platforms([Js])]},
		{
			key: "js_es",
			doc: "Generate JS compliant with given ES standard version. (default: 5)",
			flags: [
				Platforms([Js]),
				HasParam("version: 3 | 5 | 6"),
				Link("https://haxe.org/manual/target-javascript-es6.html")
			]
		},
		{key: "js_enums_as_arrays", doc: "Generate enum representation as array instead of as object.", flags: [Platforms([Js])]},
		{key: "js_global", doc: "Customizes the global object name.", flags: [Platforms([Js])]},
		{key: "js_unflatten", doc: "Generate nested objects for packages and types.", flags: [Platforms([Js])]},
		{
			key: "js_source_map",
			doc: "Generate JavaScript source map even in non-debug mode. Deprecated in favor of `-D source-map`.",
			flags: [Platforms([Js])]
		},
		{key: "source_map", doc: "Generate source map for compiled files.", flags: [Platforms([Php, Js]), HasParam("mode: inline")]},
		{
			key: "jvm.compression_level",
			doc: "Set the compression level of the generated file between 0 (no compression) and 9 (highest compression). Default: 6",
			flags: [Platforms([Jvm])]
		},
		{
			key: "jvm.dynamic_level",
			doc: "Controls the amount of dynamic support code being generated. 0 = none, 1 = field read/write optimization (default)",
			flags: [Platforms([Jvm])]
		},
		{
			key: "loop_unroll_max_cost",
			doc: "Maximum cost (number of expressions * iterations) before loop unrolling is canceled. (default: 250)",
			flags: [HasParam("cost"), DefaultValue("250")]
		},
		{key: "lua_jit", doc: "Enable LuaJIT-specific code generation optimizations.", flags: [Platforms([Lua])]},
		{key: "lua_vanilla", doc: "Generate code lacking compiled extern lib support (e.g. utf8).", flags: [Platforms([Lua])]},
		{key: "lua_ver", doc: "The lua version to target.", flags: [Platforms([Lua]), HasParam("version")]},
		{
			key: "lua.windows_utf8_io",
			doc: "Set the utf8 locale when running on Windows to fix unicode file operations. Lua runtime must be linked to windows UCRT.",
			flags: [Platforms([Lua]), HasParam("version")]
		},
		{
			key: "macro",
			doc: "Defined when code is compiled in the macro context.",
			flags: [Link("https://haxe.org/manual/macro.html"), Reserved(true)]
		},
		{key: "times.macro", doc: "Display per-macro timing when used with `--times`.", flags: []},
		{key: "neko_source", doc: "Output neko source instead of bytecode.", flags: [Platforms([Neko])]},
		{key: "neko_no_haxelib_paths", doc: "Disable hard-coded Haxelib ndll paths.", flags: [Platforms([Neko])]},
		{key: "neko_v1", doc: "Keep Neko 1.x compatibility.", flags: [Platforms([Neko])]},
		{key: "network_sandbox", doc: "Use local network sandbox instead of local file access one.", flags: [Platforms([Flash])]},
		{key: "no_compilation", doc: "Disable final compilation.", flags: [Platforms([Cpp, Hl])]},
		{key: "no_debug", doc: "Remove all debug macros from cpp output.", flags: []},
		{
			key: "no_deprecation_warnings",
			doc: "Do not warn if fields annotated with `@:deprecated` are used.",
			flags: [
				Deprecated("Use -w to configure warnings. See https://haxe.org/manual/cr-warnings.html for more information.")
			]
		},
		{key: "no_flash_override", doc: "Change overrides on some basic classes into HX suffixed methods", flags: [Platforms([Flash])]},
		{key: "no_opt", doc: "Disable optimizations.", flags: []},
		{key: "no_inline", doc: "Disable inlining.", flags: [Link("https://haxe.org/manual/class-field-inline.html")]},
		{
			key: "keep_inline_positions",
			doc: "Don't substitute positions of inlined expressions with the position of the place of inlining.",
			flags: [Link("https://haxe.org/manual/class-field-inline.html")]
		},
		{key: "no_macro_cache", doc: "Disable macro context caching.", flags: []},
		{key: "no_swf_compress", doc: "Disable SWF output compression.", flags: [Platforms([Flash])]},
		{key: "no_traces", doc: "Disable all trace calls.", flags: []},
		{key: "objc", doc: "Sets the hxcpp output to Objective-C++ classes. Must be defined for interop.", flags: [Platforms([Cpp])]},
		{
			key: "old_error_format",
			doc: "Use Haxe 3.x zero-based column error messages instead of new one-based format.",
			flags: [Deprecated("OldErrorFormat has been removed in Haxe 5")]
		},
		{
			key: "php_prefix",
			doc: "Root namespace for generated php classes. E.g. if compiled with`-D php-prefix=some.sub`, then all classes will be generated in `\\some\\sub` namespace.",
			flags: [Platforms([Php]), HasParam("dot-separated namespace")]
		},
		{key: "php_lib", doc: "Select the name for the php lib folder.", flags: [Platforms([Php]), HasParam("folder name")]},
		{
			key: "php_front",
			doc: "Select the name for the php front file. (default: `index.php`)",
			flags: [Platforms([Php]), HasParam("filename")]
		},
		{key: "python_version", doc: "The python version to target. (default: 3.3)", flags: [Platforms([Python]), HasParam("version")]},
		{key: "real_position", doc: "Removes position comments in Php output.", flags: [Platforms([Php])]},
		{key: "retain_untyped_meta", doc: "Prevents arbitrary expression metadata from being discarded upon typing.", flags: []},
		{key: "scriptable", doc: "GenCPP internal.", flags: [Platforms([Cpp])]},
		{
			key: "shallow_expose",
			doc: "Expose types to surrounding scope of Haxe generated closure without writing to window object.",
			flags: [Platforms([Js])]
		},
		{key: "source_header", doc: "Print value as comment on top of generated files, use '' value to disable.", flags: []},
		{key: "source_map_content", doc: "Include the Haxe sources as part of the JS source map.", flags: [Platforms([Js])]},
		{key: "static", doc: "Defined if the current target is static.", flags: [Reserved(true)]},
		{key: "std_encoding_utf8", doc: "Force utf8 encoding for stdin, stdout and stderr", flags: [Platforms([Python])]},
		{key: "swc", doc: "Output a SWC instead of a SWF.", flags: [Platforms([Flash]), Reserved(true)]},
		{
			key: "swf_compress_level",
			doc: "Set the amount of compression for the SWF output.",
			flags: [Platforms([Flash]), HasParam("level: 1-9")]
		},
		{key: "swf_debug_password", doc: "Set a password for debugging.", flags: [Platforms([Flash]), HasParam("password")]},
		{key: "swf_direct_blit", doc: "Use hardware acceleration to blit graphics.", flags: [Platforms([Flash])]},
		{key: "swf_gpu", doc: "Use GPU compositing features when drawing graphics.", flags: [Platforms([Flash])]},
		{key: "swf_header", doc: "define SWF header (width:height:fps:color)", flags: [Platforms([Flash])]},
		{
			key: "swf_metadata",
			doc: "Include contents of the given file as metadata in the SWF.",
			flags: [Platforms([Flash]), HasParam("file")]
		},
		{key: "swf_preloader_frame", doc: "Insert empty first frame in SWF.", flags: [Platforms([Flash])]},
		{key: "swf_protected", doc: "Compile Haxe `private` as `protected` in the SWF instead of `public`.", flags: [Platforms([Flash])]},
		{
			key: "swf_script_timeout",
			doc: "Maximum ActionScript processing time before script stuck dialog box displays.",
			flags: [Platforms([Flash]), HasParam("time in seconds")]
		},
		{key: "swf_use_doabc", doc: "Use `DoAbc` SWF-tag instead of `DoAbcDefine`.", flags: [Platforms([Flash])]},
		{key: "sys", doc: "Defined for all system platforms.", flags: [Reserved(true)]},
		{key: "use_nekoc", doc: "Use `nekoc` compiler instead of the internal one.", flags: [Platforms([Neko])]},
		{key: "utf16", doc: "Defined for all platforms that use UTF-16 string encoding with UCS-2 API.", flags: [Reserved(true)]},
		{key: "vcproj", doc: "GenCPP internal.", flags: [Platforms([Cpp])]},
		{
			key: "warn_var_shadowing",
			doc: "Warn about shadowing variable declarations.",
			flags: [
				Deprecated("Use -w to configure warnings. See https://haxe.org/manual/cr-warnings.html for more information.")
			]
		},
		{key: "no_tre", doc: "Disable tail recursion elimination.", flags: []},
		{
			key: "message.reporting",
			doc: "Select message reporting mode for compiler output. (default: pretty)",
			flags: [HasParam("mode: classic | pretty | indent"), DefaultValue("pretty")]
		},
		{key: "message.color", doc: "Enable ANSI color codes in message reporting.", flags: []},
		{
			key: "message.no_color",
			doc: "Disable ANSI color codes in message reporting.",
			flags: [
				Deprecated("Color is now disabled by default; use -D message.color to enable ANSI coloring.")
			]
		},
		{
			key: "message.absolute_positions",
			doc: "Use absolute character positions instead of line/columns for message reporting.",
			flags: []
		},
		{key: "message.log_file", doc: "Path to a text file to write message reporting to, in addition to regular output.", flags: []},
		{
			key: "message.log_format",
			doc: "Select message reporting mode for message log file. (default: indent)",
			flags: [HasParam("format: classic | pretty | indent"), DefaultValue("indent")]
		},
	];
	public static final defaultValues:Array<{key:String, value:String}> = [
		{key: "dce", value: "std"},
		{key: "dump.stage", value: "dce"},
		{key: "dump_path", value: "dump"},
		{key: "dump_ignore_var_ids", value: "1"},
		{key: "eval_call_stack_depth", value: "1000"},
		{key: "eval_print_depth", value: "5"},
		{key: "haxe3", value: "1"},
		{key: "haxe4", value: "1"},
		{key: "haxe5", value: "1"},
		{key: "loop_unroll_max_cost", value: "250"},
		{key: "message.reporting", value: "pretty"},
		{key: "message.log_format", value: "indent"}
	];
	public static final deprecationLut:StringMap<DefineDeprecation> = makeDeprecations();

	static function makeDeprecations():StringMap<DefineDeprecation> {
		var result = new StringMap<DefineDeprecation>();
		for (entry in [
			{key: "analyzer_times", reason: InFavorOf("times.analyzer")},
			{key: "display_details", reason: DueTo("This flag is no longer supported in Haxe 5")},
			{key: "eval_times", reason: InFavorOf("times.eval")},
			{key: "filter_times", reason: InFavorOf("times.filter")},
			{key: "haxe3compat", reason: DueTo("This flag is no longer supported in Haxe 5")},
			{key: "hxb_times", reason: InFavorOf("times.hxb")},
			{key: "macro_times", reason: InFavorOf("times.macro")},
			{
				key: "no_deprecation_warnings",
				reason: DueTo("Use -w to configure warnings. See https://haxe.org/manual/cr-warnings.html for more information.")
			},
			{key: "old_error_format", reason: DueTo("OldErrorFormat has been removed in Haxe 5")},
			{
				key: "warn_var_shadowing",
				reason: DueTo("Use -w to configure warnings. See https://haxe.org/manual/cr-warnings.html for more information.")
			},
			{key: "message.no_color", reason: DueTo("Color is now disabled by default; use -D message.color to enable ANSI coloring.")}
		]) result.set(entry.key, entry.reason);
		return result;
	}
}
