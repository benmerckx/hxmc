package context.display;

import haxe.display.FsPath;
import haxe.display.Display.CompletionParams;
import haxe.display.Display.DiagnosticsParams;
import haxe.display.Display.FindReferencesParams;
import haxe.display.Display.PositionParams;
import haxe.display.Display.SignatureHelpParams;
import haxe.display.Display.WorkspaceSymbolsParams;
import context.Common;
import core.DisplayTypes;
import core.display.DisplayPosition;
import compiler.DisplayProcessingGlobals;

/** What every request that names a file also takes (as the compiler reads them): without
	a file, the files of `fileContents` (with their unsaved contents) are displayed. */
typedef FileContentsParams = {
	var ?fileContents:Array<{file:FsPath, ?contents:String}>;
}

/** A request on a file without a position (diagnostics', statistics', package's, document symbols'). */
typedef FileInputParams = DiagnosticsParams;

// port: not upstream: the display/* methods of the JSON-RPC protocol as functions of their
// ... parameters (the std's haxe.display types), each setting up the context for its request
// ... as the method's handler does upstream (displayJson.ml); the compilation then runs as
// ... for any display request and finds the result (a DisplayResult). DisplayJson's handlers
// ... decode the JSON into these parameters and call them; a CompilerInstance's display calls
// ... call them directly. Design: docs/plans/compiler-instance.md.
class DisplayRequests {
	public static function completion(com:CommonContext, p:CompletionParams & FileContentsParams):Void {
		setDisplayFile(com, p.wasAutoTriggered, p.file, p.contents, p.offset, p.fileContents);
		enableDisplay(com, DMDefault);
	}

	public static function definition(com:CommonContext, p:PositionParams & FileContentsParams):Void {
		setDisplayFile(com, false, p.file, p.contents, p.offset, p.fileContents);
		enableDisplay(com, DMDefinition);
	}

	public static function diagnostics(com:CommonContext, p:FileInputParams):Void {
		setDisplayFile(com, false, p.file, p.contents, -1, p.fileContents);
		enableDisplay(com, true, DMNone);
		var d = DisplayMode.copy(com.display);
		d.dmsDisplayFilePolicy = DFPAlso;
		d.dmsPerFile = true;
		d.dmsPopulateCache = true;
		com.display = d;
		com.partScope.reportMode = RMDiagnostics(com.fileContents.map(fc -> fc.fileKey));
	}

	public static function statistics(com:CommonContext, p:FileInputParams):Void {
		setDisplayFile(com, false, p.file, p.contents, -1, p.fileContents);
		enableDisplay(com, true, DMNone);
		var d = DisplayMode.copy(com.display);
		d.dmsDisplayFilePolicy = DFPAlso;
		d.dmsPerFile = true;
		d.dmsPopulateCache = true;
		com.display = d;
		com.partScope.reportMode = RMStatistics;
	}

	public static function implementation(com:CommonContext, p:PositionParams & FileContentsParams):Void {
		setDisplayFile(com, false, p.file, p.contents, p.offset, p.fileContents);
		enableDisplay(com, DMImplementation);
	}

	public static function typeDefinition(com:CommonContext, p:PositionParams & FileContentsParams):Void {
		setDisplayFile(com, false, p.file, p.contents, p.offset, p.fileContents);
		enableDisplay(com, DMTypeDefinition);
	}

	public static function references(com:CommonContext, p:FindReferencesParams & FileContentsParams):Void {
		setDisplayFile(com, false, p.file, p.contents, p.offset, p.fileContents);
		switch (p.kind : Null<String>) {
			case "withBaseAndDescendants":
				enableDisplay(com, DMUsage(false, true, true));
			case "withDescendants":
				enableDisplay(com, DMUsage(false, true, false));
			case _:
				enableDisplay(com, DMUsage(false, false, false));
		}
	}

	public static function hover(com:CommonContext, p:PositionParams & FileContentsParams):Void {
		setDisplayFile(com, false, p.file, p.contents, p.offset, p.fileContents);
		enableDisplay(com, DMHover);
	}

	public static function determinePackage(com:CommonContext, p:FileInputParams):Void {
		setDisplayFile(com, false, p.file, p.contents, -1, p.fileContents);
		enableDisplay(com, DMPackage);
	}

	public static function documentSymbols(com:CommonContext, p:FileInputParams):Void {
		setDisplayFile(com, false, p.file, p.contents, -1, p.fileContents);
		enableDisplay(com, DMModuleSymbols(null));
	}

	public static function workspaceSymbols(com:CommonContext, p:WorkspaceSymbolsParams):Void {
		enableDisplay(com, DMModuleSymbols(p.filter));
	}

	public static function signatureHelp(com:CommonContext, p:SignatureHelpParams & FileContentsParams):Void {
		setDisplayFile(com, p.wasAutoTriggered, p.file, p.contents, p.offset, p.fileContents);
		enableDisplay(com, DMSignature);
	}

	public static function enableDisplay(com:CommonContext, ?skipDefine:Bool = false, mode:DisplayModeValue):Void {
		com.display = DisplayMode.create(mode);
		if (!skipDefine) Common.defineValue(com, core.Define.Display, "1");
	}

	/** The file (or files) and position of a request: `offset` -1 for none; without a file,
		`fileContents`'. */
	public static function setDisplayFile(com:CommonContext, wasAutoTriggered:Bool, file:Null<FsPath>, contents:Null<String>, offset:Int,
			fileContents:Null<Array<{file:FsPath, ?contents:String}>>):Void {
		var file = file == null ? DisplayProcessingGlobals.fileInputMarker : core.Path.getFullPath(file.toString());
		var pos = offset;
		com.partScope.parserState.wasAutoTriggered = wasAutoTriggered;
		if (file != DisplayProcessingGlobals.fileInputMarker) {
			var fileUnique = com.partScope.fileKeys.get(file);
			DisplayPosition.displayPosition.set({pfile: file, pmin: pos, pmax: pos});
			com.fileContents = [{fileKey: fileUnique, content: contents}];
		} else {
			var fileContents:Array<{fileKey:String, content:Null<String>}> = (fileContents == null ? [] : fileContents).map(function(fc)
				return {fileKey: com.partScope.fileKeys.get(core.Path.getFullPath(fc.file.toString())), content: fc.contents});
			var files = fileContents.map(fc -> fc.fileKey);
			com.fileContents = fileContents;
			if (files.length == 0) DisplayPosition.displayPosition.set({pfile: file, pmin: pos, pmax: pos})
			else DisplayPosition.displayPosition.setFiles(files);
		}
	}
}
