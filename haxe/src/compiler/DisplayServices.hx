package compiler;

import haxe.display.Display.CompletionParams;
import haxe.display.Display.DefinesParams;
import haxe.display.Display.FindReferencesParams;
import haxe.display.Display.MetadataParams;
import haxe.display.Display.PositionParams;
import haxe.display.Display.SignatureHelpParams;
import haxe.display.Display.WorkspaceSymbolsParams;
import compiler.CompilerInstance;
import context.display.DisplayRequests;
import context.display.DisplayResult;
import core.DisplayTypes;
import core.Globals.Pos;
import core.Message.CompilerMessage;

typedef SignatureHelp = {
	signatures:Array<context.display.DisplayException.SignatureInfo>,
	activeSignature:Int,
	activeParameter:Int,
	kind:SignatureKind
}

typedef Completion = {
	fields:FieldsResult,

	/** the items are the typer's (not keywords or a type path's): completionItem/resolve
		can detail them, so the protocol sends them minimal when the client resolves */
	resolvable:Bool
}

typedef ModuleSymbols = Array<{file:String, symbols:Array<SymbolInformationData>}>;
typedef MetadataInfo = {name:String, info:core.Meta.MetaInfos};
typedef DefineInfo = {name:String, info:core.Define.DefineInfos};

/** The display/* methods of the JSON-RPC protocol: the parameters are the std's
	(haxe.display), the results the compiler's own values, which the protocol's results
	are the JSON of (context.display.DisplayJson). Null: nothing found (the protocol's null
	result; for completion its "No completion point" error). A failed compilation throws a
	CompilationError. (completionItem/resolve is the protocol's: it details an item of the
	last completion it sent.) */
interface DisplayApi {
	function completion(p:CompletionParams & FileContentsParams):Null<Completion>;

	function definition(p:PositionParams & FileContentsParams):Null<Array<Pos>>;
	function implementation(p:PositionParams & FileContentsParams):Null<Array<Pos>>;
	function typeDefinition(p:PositionParams & FileContentsParams):Null<Array<Pos>>;
	function references(p:FindReferencesParams & FileContentsParams):Null<Array<Pos>>;

	function hover(p:PositionParams & FileContentsParams):Null<HoverResult>;

	/** null: no call or array access at the position */
	function signatureHelp(p:SignatureHelpParams & FileContentsParams):Null<SignatureHelp>;

	function determinePackage(p:FileInputParams):Null<Array<String>>;
	function documentSymbols(p:FileInputParams):Null<ModuleSymbols>;

	/** the symbols whose name matches `p.filter` (a case-insensitive OCaml Str regexp) */
	function workspaceSymbols(p:WorkspaceSymbolsParams):Null<ModuleSymbols>;

	function diagnostics(p:FileInputParams):Null<DiagnosticsContext>;
	function statistics(p:FileInputParams):Null<context.display.Statistics.StatisticsResult>;

	/** after the init macros (which may define metadata) */
	function metadata(p:MetadataParams):Null<Array<MetadataInfo>>;

	/** after the init macros (which may define defines) */
	function defines(p:DefinesParams):Null<Array<DefineInfo>>;
}

/** A compilation that failed before answering. */
class CompilationError extends haxe.Exception {
	/** the compilation's errors, oldest first */
	public final messages:Array<CompilerMessage>;

	public function new(messages:Array<CompilerMessage>) {
		super(messages.length == 0 ? "Compilation failed" : messages[0].cmMessage);
		this.messages = messages;
	}
}

// port: not upstream: a CompilerInstance's display requests (CompilerInstance.request), each
// ... set up by the method's DisplayRequests function
class DisplayServices implements DisplayApi {
	final instance:CompilerInstance;
	final env:Null<RequestEnv>;

	public function new(instance:CompilerInstance, ?env:RequestEnv) {
		this.instance = instance;
		this.env = env;
	}

	public function completion(p:CompletionParams & FileContentsParams):Null<Completion>
		return switch display(com -> DisplayRequests.completion(com, p)) {
			case DRFields(fields, resolvable): {fields: fields, resolvable: resolvable};
			case DRNone: null;
			case r: unexpected("completion", r);
		}

	public function definition(p:PositionParams & FileContentsParams):Null<Array<Pos>>
		return positions("definition", display(com -> DisplayRequests.definition(com, p)));

	public function implementation(p:PositionParams & FileContentsParams):Null<Array<Pos>>
		return positions("implementation", display(com -> DisplayRequests.implementation(com, p)));

	public function typeDefinition(p:PositionParams & FileContentsParams):Null<Array<Pos>>
		return positions("typeDefinition", display(com -> DisplayRequests.typeDefinition(com, p)));

	public function references(p:FindReferencesParams & FileContentsParams):Null<Array<Pos>>
		return positions("references", display(com -> DisplayRequests.references(com, p)));

	public function hover(p:PositionParams & FileContentsParams):Null<HoverResult>
		return switch display(com -> DisplayRequests.hover(com, p)) {
			case DRHover(hover): hover;
			case DRNone: null;
			case r: unexpected("hover", r);
		}

	public function signatureHelp(p:SignatureHelpParams & FileContentsParams):Null<SignatureHelp>
		return switch display(com -> DisplayRequests.signatureHelp(com, p)) {
			case DRSignatures(signatures, activeSignature, activeParameter, kind):
				{
					signatures: signatures,
					activeSignature: activeSignature,
					activeParameter: activeParameter,
					kind: kind
				};
			case DRNone: null;
			case r: unexpected("signatureHelp", r);
		}

	public function determinePackage(p:FileInputParams):Null<Array<String>>
		return switch display(com -> DisplayRequests.determinePackage(com, p)) {
			case DRPackage(pack): pack;
			case DRNone: null;
			case r: unexpected("determinePackage", r);
		}

	public function documentSymbols(p:FileInputParams):Null<ModuleSymbols>
		return symbols("documentSymbols", display(com -> DisplayRequests.documentSymbols(com, p)));

	public function workspaceSymbols(p:WorkspaceSymbolsParams):Null<ModuleSymbols>
		return symbols("workspaceSymbols", display(com -> DisplayRequests.workspaceSymbols(com, p)));

	public function diagnostics(p:FileInputParams):Null<DiagnosticsContext>
		return switch display(com -> DisplayRequests.diagnostics(com, p)) {
			case DRDiagnostics(dctx): dctx;
			case DRNone: null;
			case r: unexpected("diagnostics", r);
		}

	public function statistics(p:FileInputParams):Null<context.display.Statistics.StatisticsResult>
		return switch display(com -> DisplayRequests.statistics(com, p)) {
			case DRStatistics(stats): stats;
			case DRNone: null;
			case r: unexpected("statistics", r);
		}

	public function metadata(p:MetadataParams):Null<Array<MetadataInfo>>
		return Services.answer(instance, env, "metadata", com -> After(AfterInitMacros, function() {
			return core.Meta.getMetaList(com.userMetas).filter(m -> switch m.info.mOrigin {
				case Compiler if (p.compiler): true;
				case UserDefined(_) if (p.user): true;
				case _: false;
			});
		}));

	public function defines(p:DefinesParams):Null<Array<DefineInfo>>
		return Services.answer(instance, env, "defines", com -> After(AfterInitMacros, function() {
			return core.Define.getDefineList(com.userDefines).filter(d -> switch d.info.dOrigin {
				case Compiler if (p.compiler): true;
				case UserDefined(_) if (p.user): true;
				case _: false;
			});
		}));

	function display(configure:context.Common.CommonContext->Void):DisplayResult
		return switch instance.displayRequest(configure, env) {
			case Found(r): r;
			case Failed(messages): throw new CompilationError(messages);
			case Answered(_): throw new core.Globals.InternalCompilerError("a display request answered", "");
		}

	static function positions(method:String, r:DisplayResult):Null<Array<Pos>>
		return switch r {
			case DRPositions(pl): pl;
			case DRNone: null;
			case r: unexpected(method, r);
		}

	static function symbols(method:String, r:DisplayResult):Null<ModuleSymbols>
		return switch r {
			case DRModuleSymbols(symbols, filter): context.display.DocumentSymbols.DocumentSymbolsPrinter.filterModuleSymbols(symbols, filter);
			case DRNone: null;
			case r: unexpected(method, r);
		}

	static function unexpected(method:String, r:DisplayResult):Dynamic
		throw new core.Globals.InternalCompilerError('display/$method found ${Type.enumConstructor(r)}', "");
}

// port: not upstream: the answering of a request that is not a display request's
class Services {
	/** `start`'s answer; null: none (the compilation ended without one) */
	public static function answer<T>(instance:CompilerInstance, env:Null<RequestEnv>, method:String,
			start:context.Common.CommonContext->RequestStep<T>):Null<T>
		return switch instance.request(start, env) {
			case Answered(v): v;
			case Found(DRNone): null;
			case Found(r): throw new core.Globals.InternalCompilerError('$method found ${Type.enumConstructor(r)}', "");
			case Failed(messages): throw new CompilationError(messages);
		}
}
