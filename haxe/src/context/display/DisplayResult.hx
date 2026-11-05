package context.display;

import core.Globals.Pos;
import core.DisplayTypes;

// port: not upstream: what a display request found, as a value, before it is JSON.
// ... Upstream encodes each result where it is found and sends it (send_result_raise);
// ... here the request's result handler gets the value (ResultHandler
// ... .sendDisplayResultRaise), and the JSON-RPC handler encodes it as upstream does
// ... (DisplayException.resultToJson), so its output is the same. A typed caller (a
// ... CompilerInstance's display calls) keeps the value. Design:
// ... docs/plans/compiler-instance.md.
enum DisplayResult {
	/** display/hover */
	DRHover(hover:HoverResult);

	/** display/completion (and other field lists); `resolvable`: from a DisplayException,
		whose items a client supporting completionItem/resolve gets in their minimal form */
	DRFields(fields:FieldsResult, resolvable:Bool);

	/** display/signatureHelp; `activeParameter`: of the active signature, for the argument at the position */
	DRSignatures(signatures:Array<DisplayException.SignatureInfo>, activeSignature:Int, activeParameter:Int, kind:SignatureKind);

	/** display/definition, implementation, typeDefinition, references */
	DRPositions(positions:Array<Pos>);

	/** display/package */
	DRPackage(pack:Array<String>);

	/** display/documentSymbols, workspaceSymbols */
	DRModuleSymbols(symbols:Array<{file:String, symbols:Array<SymbolInformationData>}>, filter:Null<String>);

	/** display/diagnostics */
	DRDiagnostics(diagnostics:DiagnosticsContext);

	/** display/statistics */
	DRStatistics(statistics:Statistics.StatisticsResult);

	/** no result at the display position: for completion an error, otherwise null */
	DRNone;
}
