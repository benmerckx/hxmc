package hxmc.ir;

import core.TType;

using core.TFunctions;

// The runtime's symbols that generated code refers to by name, per family of
// targets, and the check that the runtime a program is built with defines
// each of them (docs/hxmc.md, "The symbols generated code calls").
//
// The runtime's modules come into every program through hxmc.rt.Runtime
// (Std imports it), whose imports differ by target; hxmc compiles only the
// functions a program calls, and the @:hxmc.export ones. A symbol generated
// code calls by name but whose module only something else loads is there
// in some programs and not in others: rt_null_access, in Faults (which only
// the native targets' Start loads), was missing from a WebAssembly program
// that loaded nothing else bringing Faults in ("wasm: undefined:
// rt_null_access"). So every build (Main.generate) checks each symbol of
// its family against what the modules Runtime.hx imports for the target
// define (parsed with the build's defines: the typed program keeps no
// imports), whether or not this program calls it; it costs a parse of
// Runtime.hx and a look at those modules' statics, and changes nothing that
// is written.
//
// The list is kept by hand, next to the generators; MirBuild.call and
// GcModule.exportOf fail the build when generated code calls an exported
// function of the runtime that it does not list for the family, so a new
// one cannot be left out (the few fixed references elsewhere are listed
// below by where they are). A symbol generated code refers to only under a
// define or feature has `when`, the generator's own condition (Lower's
// statics, set before the check), and is required only then (a module
// Runtime.hx imports under a define, #if hxmc.census, is seen only with it,
// so what only it defines takes that condition); one the
// target's linker, C library or DataGen defines is not the runtime's and
// is not here (rt_types and the program's tables, _setjmp, memcpy and
// floor, wasm32's linker cells and thread-local globals, rt_throw and the
// other builtins of LinkWasm, the stubs hxmc_zero, hxmc_frame,
// hxmc_call_on_stack and hxmc_tls_base). The names the lowering makes from
// the std's externs (String_toUpperCase, Math_sin, ...) are not either: a
// missing implementation fails the build of a program that calls it, by
// its name.
class RuntimeSymbols {
	// target families
	public static inline var NATIVE = 1; // machine code over linear memory (x86-64 and arm64, every system)
	public static inline var WASM32 = 2; // wasm32-wasi over linear memory
	public static inline var WASMGC = 4; // wasm32-wasi with -D hxmc.wasm-gc
	static inline var LINEAR = NATIVE | WASM32;

	// how the runtime defines a symbol
	// an @:hxmc.export function: called by its symbol (compiled in every program)
	public static inline var FUNC = 0;
	// a Haxe implementation, @:hxmc.export or @:hxmc.host, of a function the
	// lowering calls (ECallHost), which Lower.bindHosts binds to it (unbound,
	// the call stays one by the name, which nothing defines)
	public static inline var IMPL = 1;
	// an @:hxmc.export static variable: read by its symbol
	public static inline var DATA = 2;
	// a @:hxmc.threadLocal("symbol") static: read by its symbol
	public static inline var TLS = 3;

	static function nullChecks():Bool
		return Lower.nullChecks;

	static function boundsThrow():Bool
		return Lower.bounds == Lower.BOUNDS_THROWS;

	public static final SYMBOLS:Array<RuntimeSymbol> = [
		// MirBuild (and DataGen through its builders)
		{sym: "rt_init", kind: FUNC, families: LINEAR, by: "DataGen.mainBody: main, _start"},
		{sym: "rt_run_main", kind: FUNC, families: NATIVE, by: "DataGen.mainBody: main"},
		{sym: "rt_cstack_lo", kind: FUNC, families: WASM32, by: "DataGen.mainBody: _start"},
		{sym: "rt_cstack_top", kind: FUNC, families: WASM32, by: "DataGen.mainBody: _start"},
		{sym: "rt_main_done", kind: FUNC, families: WASM32, by: "DataGen.mainBody: _start"},
		// (wasm32: LinkWasm's builtin, which calls hx_uncaught)
		{sym: "rt_throw", kind: FUNC, families: NATIVE, by: "MirBuild: a throw, a catch's rethrow"},
		{sym: "hx_uncaught", kind: FUNC, families: WASM32, by: "LinkWasm's rt_throw: no handler"},
		{sym: "rt_null_access", kind: FUNC, families: NATIVE, by: "Faults.redirect: a fault's target; MirBuild.nullBlock with -D hxmc.null-checks=1"},
		{sym: "rt_null_access", kind: FUNC, families: WASM32, by: "MirBuild.nullBlock", when: nullChecks},
		{sym: "rt_stack_overflow", kind: FUNC, families: WASM32, by: "MirBuild.raiseHw: the shadow stack's end"},
		{sym: "rt_cstack_overflow", kind: FUNC, families: WASM32, by: "WasmGen: a frame's prologue"},
		{sym: "rt_blocking_enter", kind: FUNC, families: NATIVE, by: "MirBuild.cCall: a C call's safe region"},
		{sym: "rt_blocking_leave", kind: FUNC, families: NATIVE, by: "MirBuild.cCall: a C call's safe region"},
		{sym: "hxmc_alloc_slow", kind: FUNC, families: LINEAR, by: "MirBuild.alloc, DataGen's allocators, x64.Emit, WasmEmitter"},
		{sym: "hxmc_barrier_slow", kind: FUNC, families: LINEAR, by: "MirBuild: the write barrier"},
		{sym: "rt_icache_miss", kind: FUNC, families: LINEAR, by: "MirBuild: an inline cache's miss"},
		{sym: "hx_box_int", kind: FUNC, families: LINEAR, by: "MirBuild.box"},
		{sym: "hx_box_bool", kind: FUNC, families: LINEAR, by: "MirBuild.box"},
		{sym: "hx_box_float", kind: FUNC, families: LINEAR, by: "MirBuild.box"},
		{sym: "hx_box_i64", kind: FUNC, families: LINEAR, by: "MirBuild.box"},
		{sym: "hx_unbox_int", kind: FUNC, families: LINEAR, by: "MirBuild.unbox"},
		{sym: "hx_unbox_bool", kind: FUNC, families: LINEAR, by: "MirBuild.unbox"},
		{sym: "hx_unbox_float", kind: FUNC, families: LINEAR, by: "MirBuild.unbox"},
		{sym: "hx_unbox_i64", kind: FUNC, families: LINEAR, by: "MirBuild.unbox"},
		{sym: "hx_aget_i_slow", kind: FUNC, families: LINEAR, by: "MirBuild: an Array read's slow path"},
		{sym: "hx_aget_f_slow", kind: FUNC, families: LINEAR, by: "MirBuild: an Array read's slow path"},
		{sym: "hx_aget_l_slow", kind: FUNC, families: LINEAR, by: "MirBuild: an Array read's slow path"},
		{sym: "hx_aget_p_slow", kind: FUNC, families: LINEAR, by: "MirBuild: an Array read's slow path"},
		{sym: "hx_aset_slow", kind: FUNC, families: LINEAR, by: "MirBuild: an Array write's slow path"},
		{sym: "hx_apush_slow", kind: FUNC, families: LINEAR, by: "MirBuild: an Array push's slow path"},
		{sym: "hx_arr_new_n", kind: FUNC, families: LINEAR, by: "MirBuild: an Array literal"},
		{sym: "hx_f2i_slow", kind: FUNC, families: LINEAR, by: "MirBuild: Float to Int out of range"},
		{sym: "hx_narray_get_slow", kind: FUNC, families: LINEAR, by: "MirBuild.narrayDyn"},
		{sym: "hx_narray_set_slow", kind: FUNC, families: LINEAR, by: "MirBuild.narrayDyn"},
		{sym: "hx_narray_bad_length", kind: FUNC, families: LINEAR, by: "MirBuild: a NativeArray's negative length"},
		{sym: "hx_anon_get_slow", kind: FUNC, families: LINEAR, by: "MirBuild: a structure's field read"},
		{sym: "hx_anon_set_slow", kind: FUNC, families: LINEAR, by: "MirBuild: a structure's field write"},
		{sym: "hx_anon_call_slow", kind: FUNC, families: LINEAR, by: "MirBuild.callAnon"},
		{sym: "hx_str_eq_slow", kind: FUNC, families: LINEAR, by: "MirBuild.strEq"},
		{sym: "StringBuf_addChar_slow", kind: FUNC, families: LINEAR, by: "MirBuild.stringBufAddChar"},
		{sym: "hx_array_iterator", kind: FUNC, families: LINEAR, by: "Facts: Array's method table (DataGen)"},
		{sym: "hx_arrayiter_hasNext", kind: FUNC, families: LINEAR, by: "Facts: the array iterator's method table (DataGen)"},
		{sym: "hx_arrayiter_next", kind: FUNC, families: LINEAR, by: "Facts: the array iterator's method table (DataGen)"},
		{sym: "rt_globals", kind: DATA, families: NATIVE, by: "MirBuild: a static's address; DataGen.mainBody"},
		{sym: "rt_young_start", kind: DATA, families: NATIVE, by: "MirBuild: the write barrier"},
		{sym: "rt_young_end", kind: DATA, families: NATIVE, by: "MirBuild: the write barrier"},
		{sym: "rt_sp", kind: TLS, families: NATIVE, by: "MirBuild: the shadow stack"},
		{sym: "rt_sp_hw", kind: TLS, families: NATIVE, by: "MirBuild.raiseHw"},
		{sym: "rt_hcur", kind: TLS, families: NATIVE, by: "MirBuild.tryStmt"},
		{sym: "rt_exn", kind: TLS, families: NATIVE, by: "MirBuild.tryStmt"},
		{sym: "rt_young_ptr", kind: TLS, families: NATIVE, by: "MirBuild.alloc"},
		{sym: "rt_young_limit", kind: TLS, families: NATIVE, by: "MirBuild.alloc"},
		{sym: "rt_young_rlimit", kind: TLS, families: NATIVE, by: "MirBuild.alloc"},
		// FnLower's calls of the runtime (bound by Lower.bindHosts; MirBuild and
		// FuncGen expand the others: hx_str_eq on linear memory, hx_dyn_call,
		// hx_clos_of_sig, hx_is, hx_cast and hx_is_typeobj on WasmGC, the
		// intrinsics); MirBuild.host's hx_dyn_get_fid & co. are reached only
		// where hx_dyn_get & co. are not bound, which this keeps from happening
		{sym: "hx_dyn_get", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: Dynamic's field read"},
		{sym: "hx_dyn_set", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: Dynamic's field write"},
		{sym: "hx_dyn_call_field", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: Dynamic's method call"},
		{sym: "hx_dyn_call", kind: IMPL, families: LINEAR, by: "FnLower: a Dynamic call"},
		{sym: "hx_dyn_aget", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: Dynamic's index read"},
		{sym: "hx_dyn_aset", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: Dynamic's index write"},
		{sym: "hx_dyn_op", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: an operator on Dynamic"},
		{sym: "hx_dyn_eq", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: == on Dynamic"},
		{sym: "hx_dyn_cmp", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: < on Dynamic"},
		{sym: "hx_std_string", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a value as a String"},
		{sym: "hx_str_or_null", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a String as a String"},
		{sym: "hx_str_of_int", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: an Int as a String"},
		{sym: "hx_str_of_float", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a Float as a String"},
		{sym: "hx_str_of_i64", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: an Int64 as a String"},
		{sym: "hx_str_of_bool", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a Bool as a String"},
		{sym: "hx_str_concat", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: +"},
		{sym: "hx_str_eq", kind: IMPL, families: WASMGC, by: "FnLower: == on Strings"},
		{sym: "hx_str_cmp", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: < on Strings"},
		{sym: "hx_str_hash", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a switch on Strings"},
		{sym: "hx_is", kind: IMPL, families: LINEAR, by: "FnLower: a type test"},
		{sym: "hx_cast", kind: IMPL, families: LINEAR, by: "FnLower: a checked cast"},
		{sym: "hx_is_typeobj", kind: IMPL, families: LINEAR, by: "FnLower: Std.isOfType(v, Class)"},
		{sym: "hx_clos_of_sig", kind: IMPL, families: LINEAR, by: "FnLower: a function of another signature"},
		{sym: "hx_narray_view", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a NativeArray seen typed"},
		{sym: "hx_narray_open", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a NativeArray of a type parameter"},
		{sym: "hx_narray_default", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a NativeArray read out of bounds, silent"},
		{sym: "hx_narray_oob", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: a NativeArray access out of bounds, throws", when: boundsThrow},
		{sym: "Array_resize", kind: IMPL, families: LINEAR | WASMGC, by: "FnLower: an Array's length set"},
		{sym: "fmod", kind: IMPL, families: LINEAR, by: "Lower.bindHosts: Float's %"},
		// the WasmGC generator (hxmc.wasmgc: GcGen.runtimeCalls, GcModule.exportOf)
		{sym: "gc_anon_get", kind: FUNC, families: WASMGC, by: "FuncGen: a structure's field read"},
		{sym: "gc_anon_set", kind: FUNC, families: WASMGC, by: "FuncGen: a structure's field write"},
		{sym: "gc_anon_call", kind: FUNC, families: WASMGC, by: "FuncGen, Helpers: a structure's method call"},
		{sym: "gc_dyn_eq", kind: FUNC, families: WASMGC, by: "Meta: enum comparisons"},
		{sym: "gc_is", kind: FUNC, families: WASMGC, by: "FuncGen.typeTest: a type known at run time"},
		{sym: "gc_is_int", kind: FUNC, families: WASMGC, by: "FuncGen.typeTest: Int"},
		{sym: "hx_narray_bad_length", kind: FUNC, families: WASMGC, by: "FuncGen.narray: a negative length"},
		{sym: "hx_narray_set_slow", kind: FUNC, families: WASMGC, by: "FuncGen.narray: a Dynamic NativeArray's write"},
		{sym: "rt_null_access", kind: FUNC, families: WASMGC, by: "FuncGen.derefAs, Helpers: a null test", when: nullChecks},
	];

	// the FUNC symbols, with their families (called)
	static final FUNCS:Map<String, Int> = {
		var m = new Map<String, Int>();
		for (s in SYMBOLS)
			if (s.kind == FUNC) m.set(s.sym, (m.exists(s.sym) ? m.get(s.sym) : 0) | s.families);
		m;
	};

	static function familyName(family:Int):String
		return family == NATIVE ? "the native targets" : family == WASM32 ? "wasm32-wasi" : "WasmGC";

	// the families `sym` is listed for as a FUNC (0: none; Facts keeps it on
	// the runtime's exported functions, FuncInfo.rtFamilies, for MirBuild.call)
	public static function familiesOf(sym:String):Int {
		var f = FUNCS.get(sym);
		return f == null ? 0 : f;
	}

	// generated code calls the runtime's exported function `sym` by its
	// symbol (MirBuild.call, GcModule.exportOf): it must be listed for the
	// family, which check keeps defined; else this list is wrong
	public static function called(sym:String, family:Int) {
		var f = FUNCS.get(sym);
		if (f == null || f & family == 0)
			throw 'generated code calls the runtime\'s $sym by its symbol, which hxmc.ir.RuntimeSymbols does not list for ${familyName(family)}';
	}

	static final RUNTIME:core.Globals.GlobalTypePath = {pack: ["hxmc", "rt"], name: "Runtime"};

	// Fails the build when the modules hxmc.rt.Runtime imports for this
	// target do not define each symbol of the family generated code may
	// refer to (Main.generate, once Lower's statics are set: the target's
	// runtime classes are Lower.ofTarget's); `target` names it in the message
	public static function check(com:context.Common.CommonContext, family:Int, target:String) {
		var rt = com.moduleLut.findOpt(RUNTIME);
		if (rt == null) throw "hxmc.rt.Runtime is not loaded: a program for hxmc is typed with its std (-cp bin/hxmc/std)";
		// symbol -> the module defining it, how (the kinds' bits)
		var defs = new Map<String, Def>();
		var imported = new Map<String, Bool>();
		for (path in imports(com, rt.mExtra.mFile.path)) {
			imported.set(path, true);
			var parts = path.split(".");
			var m = com.moduleLut.findOpt({pack: parts.slice(0, -1), name: parts[parts.length - 1]});
			if (m != null) define(m, defs);
		}
		// (what the other modules loaded define, for the message)
		var elsewhere:Null<Map<String, Def>> = null;
		var bad = [];
		for (s in SYMBOLS) {
			if (s.families & family == 0 || (s.when != null && !s.when())) continue;
			var d = defs.get(s.sym);
			if (d != null && d.kinds & (1 << s.kind) != 0) continue;
			if (d == null && elsewhere == null) {
				elsewhere = new Map();
				com.moduleLut.iter((_, m) -> if (!imported.exists(core.Globals.sTypePath(m.mPath))) define(m, elsewhere));
			}
			var e = d == null ? elsewhere.get(s.sym) : null;
			bad.push((d != null ? 'the runtime symbol ${s.sym} is defined in ${d.module} as ${what(d.kinds)}, but generated code needs ${need(s.kind)}'
				: e != null ? 'the runtime symbol ${s.sym} is defined in ${e.module}, which hxmc.rt.Runtime does not import'
				: 'the runtime symbol ${s.sym} is not defined: its module is not loaded by hxmc.rt.Runtime')
				+ ' (for $target; ${s.by})');
		}
		if (bad.length > 0) throw bad.join("\nhxmc: ");
	}

	// what a module's runtime classes of this target define
	static function define(m:ModuleDef, defs:Map<String, Def>) {
		function add(sym:Null<String>, kinds:Int)
			if (sym != null) {
				var d = defs.get(sym);
				if (d == null) defs.set(sym, {module: core.Globals.sTypePath(m.mPath), kinds: kinds}) else d.kinds |= kinds;
			}
		for (t in m.mTypes)
			switch t {
				case TClassDecl(c) if (Lower.runtimeClass(c) && Lower.ofTarget(c)):
					for (cf in c.clOrderedStatics) {
						if (cf.cfMeta.length == 0) continue;
						if (cf.cfKind.match(Method(_))) {
							add(Lower.metaString(":hxmc.export", cf.cfMeta), (1 << FUNC) | (1 << IMPL));
							add(Lower.metaString(":hxmc.host", cf.cfMeta), 1 << IMPL);
						} else {
							add(Lower.metaString(":hxmc.export", cf.cfMeta), 1 << DATA);
							add(Lower.metaString(":hxmc.threadLocal", cf.cfMeta), 1 << TLS);
						}
					}
				case _:
			}
	}

	static function need(kind:Int):String
		return switch kind {
			case FUNC: "an @:hxmc.export function (it calls it by its symbol)";
			case IMPL: "an @:hxmc.export or @:hxmc.host function";
			case DATA: "an @:hxmc.export variable";
			case _: "a @:hxmc.threadLocal variable";
		}

	static function what(kinds:Int):String
		return kinds & (1 << FUNC) != 0 ? "an @:hxmc.export function" : kinds & (1 << IMPL) != 0 ? "a @:hxmc.host function" : kinds & (1 << DATA) != 0 ? "an @:hxmc.export variable" : "a @:hxmc.threadLocal variable";

	// the modules the file of hxmc.rt.Runtime imports, with the build's
	// defines (its #if on the target)
	static function imports(com:context.Common.CommonContext, file:String):Array<String> {
		var src = try sys.io.File.getContent(file) catch (_:Dynamic) throw 'cannot read $file (hxmc.rt.Runtime) to check the runtime\'s symbols';
		var config = syntax.Parser.createConfig(com.defines, false, false, core.DisplayTypes.DisplayModeValue.DMNone, false, null);
		var r = syntax.ParserEntry.parseString(config, syntax.Grammar.parseFileStream, src, core.Globals.filePos(file), (msg:String, _) -> {
			throw '$file: $msg';
		}, false);
		var decls = switch r {
			case ParseSuccess(data, _): data.declarations;
			case ParseError(_, e, _): throw '$file: ' + syntax.Parser.errorMsg(e.message);
		}
		var out = [];
		for (d in decls)
			switch d.definition {
				case EImport(im):
					// (a module, or a type of one: the path to the first name of a type)
					var parts = [];
					for (n in im.path) {
						parts.push(n.name);
						if (n.name.charCodeAt(0) >= "A".code && n.name.charCodeAt(0) <= "Z".code) break;
					}
					out.push(parts.join("."));
				case _:
			}
		return out;
	}
}

typedef RuntimeSymbol = {
	sym:String,
	kind:Int,
	// the families that need it (RuntimeSymbols.NATIVE, WASM32, WASMGC)
	families:Int,
	// where generated code refers to it
	by:String,
	// required only when this holds (the generator's own condition)
	?when:() -> Bool,
}

private typedef Def = {module:String, kinds:Int};
