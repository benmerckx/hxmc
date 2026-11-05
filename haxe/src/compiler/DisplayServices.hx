package compiler;

import haxe.display.Display.CompletionParams;
import haxe.display.Display.FindReferencesParams;
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

typedef ModuleSymbols = Array<{file:String, symbols:Array<SymbolInformationData>}>;

/** The display/* methods of the JSON-RPC protocol: the parameters are the std's
	(haxe.display), the results the compiler's own values, which the protocol's results
	are the JSON of (context.display.DisplayException.resultToJson). A failed compilation
	throws a DisplayError. */
interface DisplayApi {
	/** null: no completion point */
	function completion(p:CompletionParams & FileContentsParams):Null<FieldsResult>;

	function definition(p:PositionParams & FileContentsParams):Array<Pos>;
	function implementation(p:PositionParams & FileContentsParams):Array<Pos>;
	function typeDefinition(p:PositionParams & FileContentsParams):Array<Pos>;
	function references(p:FindReferencesParams & FileContentsParams):Array<Pos>;

	/** null: nothing to hover */
	function hover(p:PositionParams & FileContentsParams):Null<HoverResult>;

	/** null: no call or array access at the position */
	function signatureHelp(p:SignatureHelpParams & FileContentsParams):Null<SignatureHelp>;

	function determinePackage(p:FileInputParams):Array<String>;
	function documentSymbols(p:FileInputParams):ModuleSymbols;
	function workspaceSymbols(p:WorkspaceSymbolsParams):ModuleSymbols;
	function diagnostics(p:FileInputParams):DiagnosticsContext;
	function statistics(p:FileInputParams):context.display.Statistics.StatisticsResult;
}

class DisplayError extends haxe.Exception {
	/** the compilation's errors, oldest first */
	public final messages:Array<CompilerMessage>;

	public function new(messages:Array<CompilerMessage>) {
		super(messages.length == 0 ? "Display request failed" : messages[0].cmMessage);
		this.messages = messages;
	}
}

// port: not upstream: a CompilerInstance's display requests (CompilerInstance.displayRequest),
// ... each set up by the method's DisplayRequests function
class DisplayServices implements DisplayApi {
	final instance:CompilerInstance;

	public function new(instance:CompilerInstance)
		this.instance = instance;

	public function completion(p:CompletionParams & FileContentsParams):Null<FieldsResult>
		return switch request(com -> DisplayRequests.completion(com, p)) {
			case DRFields(fields, _): fields;
			case DRNone: null;
			case r: unexpected("completion", r);
		}

	public function definition(p:PositionParams & FileContentsParams):Array<Pos>
		return positions("definition", request(com -> DisplayRequests.definition(com, p)));

	public function implementation(p:PositionParams & FileContentsParams):Array<Pos>
		return positions("implementation", request(com -> DisplayRequests.implementation(com, p)));

	public function typeDefinition(p:PositionParams & FileContentsParams):Array<Pos>
		return positions("typeDefinition", request(com -> DisplayRequests.typeDefinition(com, p)));

	public function references(p:FindReferencesParams & FileContentsParams):Array<Pos>
		return positions("references", request(com -> DisplayRequests.references(com, p)));

	public function hover(p:PositionParams & FileContentsParams):Null<HoverResult>
		return switch request(com -> DisplayRequests.hover(com, p)) {
			case DRHover(hover): hover;
			case DRNone: null;
			case r: unexpected("hover", r);
		}

	public function signatureHelp(p:SignatureHelpParams & FileContentsParams):Null<SignatureHelp>
		return switch request(com -> DisplayRequests.signatureHelp(com, p)) {
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

	public function determinePackage(p:FileInputParams):Array<String>
		return switch request(com -> DisplayRequests.determinePackage(com, p)) {
			case DRPackage(pack): pack;
			case DRNone: [];
			case r: unexpected("determinePackage", r);
		}

	public function documentSymbols(p:FileInputParams):ModuleSymbols
		return symbols("documentSymbols", request(com -> DisplayRequests.documentSymbols(com, p)));

	public function workspaceSymbols(p:WorkspaceSymbolsParams):ModuleSymbols
		return symbols("workspaceSymbols", request(com -> DisplayRequests.workspaceSymbols(com, p)));

	public function diagnostics(p:FileInputParams):DiagnosticsContext
		return switch request(com -> DisplayRequests.diagnostics(com, p)) {
			case DRDiagnostics(dctx): dctx;
			case r: unexpected("diagnostics", r);
		}

	public function statistics(p:FileInputParams):context.display.Statistics.StatisticsResult
		return switch request(com -> DisplayRequests.statistics(com, p)) {
			case DRStatistics(stats): stats;
			case r: unexpected("statistics", r);
		}

	function request(configure:context.Common.CommonContext->Void):DisplayResult
		return switch instance.displayRequest(configure) {
			case DOResult(r): r;
			case DOErrors(messages): throw new DisplayError(messages);
		}

	static function positions(method:String, r:DisplayResult):Array<Pos>
		return switch r {
			case DRPositions(pl): pl;
			case DRNone: [];
			case r: unexpected(method, r);
		}

	static function symbols(method:String, r:DisplayResult):ModuleSymbols
		return switch r {
			case DRModuleSymbols(symbols, _): symbols;
			case DRNone: [];
			case r: unexpected(method, r);
		}

	static function unexpected(method:String, r:DisplayResult):Dynamic
		throw new core.Globals.InternalCompilerError('display/$method found ${Type.enumConstructor(r)}', "");
}
