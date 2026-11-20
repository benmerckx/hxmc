package compiler.io;

import core.TType;
import core.Message;
import core.Error;
import core.Warning;
import core.WarningList;
import context.Common;
import core.Globals.Pos;

class Abort extends haxe.Exception {
	public function new() super("Abort");
}

/** Unified compiler message API.

	This module provides a single entry point for adding compiler messages
	(errors, warnings, info) to the compilation context.

	Messages are stored in a single buffer ([com.part_scope.messages]) and
	the output layer determines how to present them (formatted text for CLI,
	JSON diagnostics for IDE, etc.).

	Cache-bound messages are stored on module extras via
	[m_cache_bound_objects] so they survive across server compilations. */
class CompilerMessage {
	/** Add a compiler message to the message buffer.

		This is the primary entry point for recording any compiler output
		(errors, warnings, info messages).

		Sets [com.part_scope.has_error] when severity is [Error]. */
	public static function addMessage(com:CommonContext, msg:String, p:Pos, depth:Int, kind:core.Message.CompilerMessageKind):Void {
		var cm = Message.makeMessage(com.isMacroContext, msg, p, depth, kind);
		if (com.partScope.messageCapture != null) com.partScope.messageCapture.value.unshift(cm);
		else {
			if (Message.messageKindSeverity(kind) == Error) com.partScope.hasError = true;
			com.partScope.messages.unshift(cm);
		}
	}

	/** Add a compiler message that is bound to a specific module's cache.

		When [dms_full_typing] is active (i.e. during a full compilation, not
		a display request), the message is also recorded in
		[m.m_extra.m_cache_bound_objects] so that it gets replayed when the
		module is loaded from cache in subsequent server compilations.

		Use this instead of {!add_message} when the message originates from
		processing a specific module and should be preserved across
		compilations. */
	public static function addModuleMessage(com:CommonContext, m:ModuleDef, msg:String, p:Pos, depth:Int,
			kind:core.Message.CompilerMessageKind):Void {
		if (Message.messageKindSeverity(kind) == Error) com.partScope.hasError = true;
		var cm = Message.makeMessage(com.isMacroContext, msg, p, depth, kind);
		if (com.display.dmsFullTyping) m.mExtra.mCacheBoundObjects.push(Message(cm));
		com.partScope.messages.unshift(cm);
	}

	/** Add a pre-built diagnostic message bound to a specific module's cache.

		Like {!add_module_message} but takes a pre-built [Message.t]
		(e.g. from {!DiagnosticsPrinter.make_missing_fields_message}).

		During [dms_full_typing], the message is cached in
		[m.m_extra.m_cache_bound_objects] unconditionally — the
		[RMDiagnostics] filter is checked at replay time, not at store time.

		The message is only added to the current message buffer when in
		diagnostics mode ([RMDiagnostics]), matching the old behavior where
		[module_diagnostics] data was stored separately and only processed
		by the diagnostics printer.

		Use this for diagnostics-specific messages (MissingFields,
		UnresolvedIdentifier) that originate from module typing and should
		survive across server compilations. */
	public static function addModuleDiagnostic(com:CommonContext, m:ModuleDef, cm:core.Message.CompilerMessage):Void {
		if (com.display.dmsFullTyping) m.mExtra.mCacheBoundObjects.push(Message(cm));
		if (core.Message.severity(cm) == core.Message.MessageSeverity.Error && com.partScope.messageCapture == null)
			com.partScope.hasError = true;
		if (Common.isDiagnostics(com)) com.partScope.messages.unshift(cm);
	}

	/** Replay a cache-bound message into the current compilation context.

		Called from {!ServerCache.handle_cache_bound_objects} when loading
		modules from cache.

		- [MKWarning] messages are re-evaluated through [com.warning] to
		  respect current warning options.
		- Diagnostics-specific messages ([DKMissingFields],
		  [DKUnresolvedIdentifier]) are only replayed when in diagnostics
		  mode ([RMDiagnostics]), matching the filter-on-replay pattern
		  used for warning options. */
	public static function replayMessage(com:CommonContext, cm:core.Message.CompilerMessage):Void {
		switch cm.cmMessageKind {
			case MKWarning(w, options):
				com.warning(w, options, cm.cmMessage, cm.cmPos, cm.cmDepth);
			case _:
				var diagnosticsOnly = switch cm.cmDiagnosticsKind {
					case DKMissingFields | DKUnresolvedIdentifier: true;
					case _: false;
				};
				if (!diagnosticsOnly || Common.isDiagnostics(com)) com.partScope.messages.unshift(cm);
		}
	}

	// Default handlers

	public static function defaultErrorHandler(com:CommonContext):core.Error.CompilerError->Void return function(err) {
		Error.recurseError(function(depth, err) addMessage(com, Error.errorMsg(err.errMessage), err.errPos, depth, MKError), err);
		if (com.partScope.messageCapture == null) {
			com.partScope.hasError = true;
			if (Common.failFast(com)) throw new Abort();
		}
	};

	public static function defaultWarningHandler(com:CommonContext):(w:core.Message.WarningCode,
		options:Array<Array<core.Message.WarningOption>>, msg:String, p:Pos,
		?depth:Int) -> Void return function(w:core.Message.WarningCode, options:Array<Array<core.Message.WarningOption>>, msg:String,
				p:Pos, ?depth:Int) {
			if (depth == null) depth = 0;
			var mode = switch Common.scopedWarningMode(com, w, p) {
				case null: Warning.getMode(w, options.concat(com.warningOptions));
				case mode: mode;
			}
			switch mode {
				case WMEnable:
					var obj = WarningList.warningObj(w);
					if (!obj.wGeneric) msg = "(" + obj.wName + ") " + msg;
					addMessage(com, msg, p, depth, MKWarning(w, options));
				case WMDisable:
			}
		};

	public static function defaultInfoHandler(com:CommonContext):(msg:String, p:Pos,
		?depth:Int) -> Void return function(msg:String, p:Pos, ?depth:Int) addMessage(com, msg, p, depth == null ? 0 : depth, MKInfo);
}
