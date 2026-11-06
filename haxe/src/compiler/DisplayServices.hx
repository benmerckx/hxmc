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

typedef SignatureHelp = {
	signatures:Array<context.display.DisplayException.SignatureInfo>,
	activeSignature:Int,
	activeParameter:Int,
	kind:SignatureKind
}

typedef Completion = {
	fields:FieldsResult,

	/** the typer's items (not keywords or a type path's), which completionItem/resolve can
		detail: the protocol sends them minimal to a client that resolves */
	resolvable:Bool
}

typedef ModuleSymbols = Array<{file:String, symbols:Array<SymbolInformationData>}>;
typedef MetadataInfo = {name:String, info:core.Meta.MetaInfos};
typedef DefineInfo = {name:String, info:core.Define.DefineInfos};

// port: not upstream: the display/* methods of the JSON-RPC protocol on a CompilerInstance.
// ... The parameters are the std's (haxe.display), the results the compiler's values
// ... (DisplayJson encodes them); null: nothing found. A position's relative file is
// ... relative to the request's directory (--cwd, server/setCwd). A failed compilation
// ... throws a CompilationError. (completionItem/resolve is the protocol's.)
class DisplayServices {
	final instance:CompilerInstance;
	final env:Null<RequestEnv>;

	public function new(instance:CompilerInstance, ?env:RequestEnv) {
		this.instance = instance;
		this.env = env;
	}

	public function completion(p:CompletionParams & FileContentsParams):Null<Completion>
		return display(com -> DisplayRequests.completion(com, p), r -> switch r {
			case DRFields(fields, resolvable): {fields: fields, resolvable: resolvable};
			case _: null;
		});

	public function definition(p:PositionParams & FileContentsParams):Null<Array<Pos>>
		return display(com -> DisplayRequests.definition(com, p), positions);

	public function implementation(p:PositionParams & FileContentsParams):Null<Array<Pos>>
		return display(com -> DisplayRequests.implementation(com, p), positions);

	public function typeDefinition(p:PositionParams & FileContentsParams):Null<Array<Pos>>
		return display(com -> DisplayRequests.typeDefinition(com, p), positions);

	public function references(p:FindReferencesParams & FileContentsParams):Null<Array<Pos>>
		return display(com -> DisplayRequests.references(com, p), positions);

	public function hover(p:PositionParams & FileContentsParams):Null<HoverResult>
		return display(com -> DisplayRequests.hover(com, p), r -> switch r {
			case DRHover(hover): hover;
			case _: null;
		});

	/** null: no call or array access at the position */
	public function signatureHelp(p:SignatureHelpParams & FileContentsParams):Null<SignatureHelp>
		return display(com -> DisplayRequests.signatureHelp(com, p), r -> switch r {
			case DRSignatures(signatures, activeSignature, activeParameter, kind):
				{signatures: signatures, activeSignature: activeSignature, activeParameter: activeParameter, kind: kind};
			case _: null;
		});

	public function determinePackage(p:FileInputParams):Null<Array<String>>
		return display(com -> DisplayRequests.determinePackage(com, p), r -> switch r {
			case DRPackage(pack): pack;
			case _: null;
		});

	public function documentSymbols(p:FileInputParams):Null<ModuleSymbols>
		return display(com -> DisplayRequests.documentSymbols(com, p), symbols);

	/** the symbols whose name matches `p.filter` (a case-insensitive OCaml Str regexp) */
	public function workspaceSymbols(p:WorkspaceSymbolsParams):Null<ModuleSymbols>
		return display(com -> DisplayRequests.workspaceSymbols(com, p), symbols);

	public function diagnostics(p:FileInputParams):Null<DiagnosticsContext>
		return display(com -> DisplayRequests.diagnostics(com, p), r -> switch r {
			case DRDiagnostics(dctx): dctx;
			case _: null;
		});

	public function statistics(p:FileInputParams):Null<context.display.Statistics.StatisticsResult>
		return display(com -> DisplayRequests.statistics(com, p), r -> switch r {
			case DRStatistics(stats): stats;
			case _: null;
		});

	/** after the init macros (which may define metadata) */
	public function metadata(p:MetadataParams):Null<Array<MetadataInfo>>
		return instance.answer(com -> After(AfterInitMacros, () -> core.Meta.getMetaList(com.userMetas).filter(m -> switch m.info.mOrigin {
			case Compiler: p.compiler;
			case UserDefined(_): p.user;
		})), env);

	/** after the init macros (which may define defines) */
	public function defines(p:DefinesParams):Null<Array<DefineInfo>>
		return instance.answer(com -> After(AfterInitMacros, () -> core.Define.getDefineList(com.userDefines).filter(d -> switch d.info.dOrigin {
			case Compiler: p.compiler;
			case UserDefined(_): p.user;
		})), env);

	/** a display request's result, as `extract` takes it (null: another, an internal error) */
	function display<T>(configure:context.Common.CommonContext->Void, extract:DisplayResult->Null<T>):Null<T>
		return switch instance.displayRequest(configure, env) {
			case Found(DRNone): null;
			case Found(r):
				var v = extract(r);
				if (v == null) throw new core.Globals.InternalCompilerError('a display request found ${Type.enumConstructor(r)}', "");
				v;
			case Failed(messages): throw new CompilationError(messages);
			case Answered(_): throw new core.Globals.InternalCompilerError("a display request answered", "");
		}

	static function positions(r:DisplayResult):Null<Array<Pos>>
		return switch r {
			case DRPositions(pl): pl;
			case _: null;
		}

	static function symbols(r:DisplayResult):Null<ModuleSymbols>
		return switch r {
			case DRModuleSymbols(symbols, filter): context.display.DocumentSymbols.DocumentSymbolsPrinter.filterModuleSymbols(symbols, filter);
			case _: null;
		}
}
