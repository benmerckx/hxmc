package compiler.io;

import core.Json;
import core.Message;
import core.Timer;
import context.Common;
import context.display.DisplayResult;
import core.DisplayTypes.DisplayModeValue;
import compiler.Helper;
import compiler.io.CompilerIo.CompilerIoData;
import compiler.MessageReporting;

/** Higher-level compiler output helpers ("what to send").

	Builds on {!CompilerIo} to provide convenience functions for common
	output operations like timer reports and result delivery.

	The {!result_handler} type abstracts over how compilation results
	are delivered to clients: in JSON-RPC mode it sends structured
	responses, while in CLI/pipe mode the protocol-specific handler
	routes messages to the appropriate output channels.
	Call-sites should use the [send_*] functions below instead of
	interacting with the underlying JSON-RPC API directly. */
class CompilerOutput {
	/** Extract the ["message"] string from a JSON error object, falling back
		to the full JSON representation when the field is absent. */
	public static function extractErrorMessage(je:JsonValue):String return switch je {
		case JObject(fields):
			var value:Null<JsonValue> = null;
			for (field in fields) if (field.name == "message") {
				value = field.value;
				break;
			}
			if (value == null) Json.stringOfJson(je); else switch value {
				case JString(s): s;
				case _: Json.stringOfJson(value);
			}
		case _: Json.stringOfJson(je);
	};

	/** Collect timer report output and write it to stderr / the connection.
		Writes are wrapped in [try ... with] because in server mode the
		client connection may have been closed by the time we try to send. */
	public static function sendTimerReport(io:CompilerIoData, timerCtx:core.Timer.TimerContext):Void {
		var buf = new StringBuf();
		Timer.reportTimes(timerCtx, function(s) buf.add(s + "\n"));
		try CompilerIo.writeErr(io, buf.toString())
		catch (_:Dynamic) {}
	}

	/** Create the handler for server-pipe mode (non-JSON-RPC server).
		Messages are written to stderr, errors are signaled via the pipe protocol,
		and timer reports are sent after successful compilation. */
	public static function createServerResultHandler(io:CompilerIoData):ResultHandler {
		function sendMessage(sev:core.Message.MessageSeverity, output:String):Void switch sev {
			/* Route non-error messages via write_out (the \x01-prefixed prints channel)
				rather than write_err (raw bytes). In --server-connect mode, write_err
				writes raw bytes into the same buffer as write_result (the JSON response),
				so warning text would end up in result.stderr and corrupt JSON-RPC parsing.
				For errors we still use write_err (error signal) + ServerMessage for verbose
				server logging. Non-errors are already delivered via write_out, so we skip
				the duplicate ServerMessage call to avoid the message appearing twice. */
			case Error:
				CompilerIo.writeErr(io, output + "\n");
				compiler.server.ServerMessage.message(output);
			case Warning | Information | Hint:
				CompilerIo.writeOut(io, output + "\n");
		};
		return {
			sendResult: function(_) {},
			sendResultRaise: function(_):Dynamic throw new core.ds.Failure("send_result_raise called in non-JSON-RPC mode"),
			sendError: function(errors) {
				for (je in errors) CompilerIo.writeErr(io, extractErrorMessage(je) + "\n");
			},
			sendErrorRaise: function(_):Dynamic throw new core.ds.Failure("send_error_raise called in non-JSON-RPC mode"),
			// port: (a display result is sent with send_result_raise upstream)
			sendDisplayResultRaise: function(com, r):Dynamic throw new core.ds.Failure((isNoCompletion(com, r) ? "send_error_raise" : "send_result_raise")
				+ " called in non-JSON-RPC mode"),
			flushMessages: function(hasError, com) {
				var messages = com.partScope.messages.copy();
				messages.reverse();
				MessageReporting.displayMessagesFrom(com.defines, messages, function() {
					hasError = true;
					com.partScope.hasError = true;
				}, sendMessage);
				com.sctx.wasCompilation = com.display.dmsFullTyping;
				if (hasError) {
					com.timerCtx.measureTimes = No;
					CompilerIo.signalError(io);
				} else if (com.timerCtx.measureTimes == Yes) sendTimerReport(io, com.timerCtx);
			},
			setCom: function(_) return NoCompletionPointFound
		};
	}

	/** Create the handler for CLI mode (non-server).
		Messages are routed by severity: info to stdout, warnings/errors to stderr.
		Optionally prompts user to press enter before exiting on error. */
	public static function createCliResultHandler(io:CompilerIoData):ResultHandler {
		function sendMessage(sev:core.Message.MessageSeverity, output:String):Void switch sev {
			case Information:
				CompilerIo.writeOut(io, output + "\n");
			case Warning | Error | Hint:
				CompilerIo.writeErr(io, output + "\n");
		};
		return {
			sendResult: function(_) {},
			sendResultRaise: function(_):Dynamic throw "send_result_raise called in non-JSON-RPC mode",
			sendError: function(errors) {
				for (je in errors) CompilerIo.writeErr(io, extractErrorMessage(je) + "\n");
			},
			sendErrorRaise: function(_):Dynamic throw "send_error_raise called in non-JSON-RPC mode",
			// port: (a display result is sent with send_result_raise upstream)
			sendDisplayResultRaise: function(com, r):Dynamic throw (isNoCompletion(com, r) ? "send_error_raise" : "send_result_raise")
				+ " called in non-JSON-RPC mode",
			flushMessages: function(hasError, com) {
				var messages = com.partScope.messages.copy();
				messages.reverse();
				MessageReporting.displayMessagesFrom(com.defines, messages, function() {
					hasError = true;
					com.partScope.hasError = true;
				}, sendMessage);
				if (hasError && Helper.prompt) {
					CompilerIo.writeOut(io, "Press enter to exit...\n");
					Sys.stdin().readLine();
				}
				CompilerIo.flush(io);
			},
			setCom: function(_) return NoCompletionPointFound
		};
	}

	// port: (DisplayException.send_no_result_raise sends an error for completion, a null result otherwise)
	public static function isNoCompletion(com:CommonContext, r:context.display.DisplayResult):Bool
		return switch [r, com.display.dmsKind] {
			case [DRNone, DMDefault]: true;
			case _: false;
		}

	/** Send a display result to the client and raise {!DisplayJson.JsonCompleted}. */
	public static function sendDisplayResultRaise(com:CommonContext, r:context.display.DisplayResult):Dynamic
		return com.requestScope.resultHandler.sendDisplayResultRaise(com, r);

	/** Send a JSON result to the client (non-raising). */
	public static function sendResult(rh:ResultHandler, json:JsonValue):Void rh.sendResult(json);

	/** Send a JSON result to the client and raise {!DisplayJson.JsonCompleted}. */
	public static function sendResultRaise(rh:ResultHandler, json:JsonValue):Dynamic return rh.sendResultRaise(json);

	/** Send a list of JSON error objects to the client (non-raising). */
	public static function sendError(rh:ResultHandler, errors:Array<JsonValue>):Void rh.sendError(errors);

	/** Send a list of JSON error objects to the client and raise. */
	public static function sendErrorRaise(rh:ResultHandler, errors:Array<JsonValue>):Dynamic return rh.sendErrorRaise(errors);

	/** Flush all compiler messages through the protocol. */
	public static function flushMessages(rh:ResultHandler, hasError:Bool, com:CommonContext):Void rh.flushMessages(hasError, com);
}
