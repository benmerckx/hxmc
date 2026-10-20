package core.json;

import core.Json.JsonValue;
import core.Json.JsonField;

// port: from haxe/src/core/json/jsonRpc.ml
enum JsonRpcErrorKind {
	ParseError(s:String);
	InvalidRequest(s:String);

	/** id->methodname **/
	MethodNotFound(id:JsonValue, name:String);

	InvalidParams(json:JsonValue);

	/** id->code->message **/
	Custom(id:JsonValue, code:Int, message:String);
}

class JsonRpcError extends haxe.Exception {
	public final kind:JsonRpcErrorKind;

	public function new(kind:JsonRpcErrorKind) {
		// port: the message is Printexc.to_string of the exception, as the compiler's
		// catch-all reports it
		super("JsonRpc.JsonRpc_error(_)");
		this.kind = kind;
	}
}

@:structInit class JsonRpcRequest {
	public var id:JsonValue;
	public var method:String;
	public var params:Null<JsonValue>;

	public inline function new(id:JsonValue, method:String, params:Null<JsonValue>) {
		this.id = id;
		this.method = method;
		this.params = params;
	}
}

class JsonRpc {
	static inline function kv(name:String, value:JsonValue):JsonField return {name: name, value: value};

	static function jsonrpcField():JsonField return kv("jsonrpc", JString("2.0"));

	public static function notification(methodName:String, params:Null<JsonValue>):JsonValue {
		var fl = [jsonrpcField(), kv("method", JString(methodName))];
		if (params != null) fl.unshift(kv("params", params));
		return JObject(fl);
	}

	public static function result(id:JsonValue,
			data:JsonValue):JsonValue return JObject([jsonrpcField(), kv("id", id), kv("result", data)]);

	public static function error(id:JsonValue, code:Int, ?data:JsonValue, message:String):JsonValue {
		var fl = [kv("code", JInt(code)), kv("message", JString(message))];
		if (data != null) fl.push(kv("data", data));
		return JObject([jsonrpcField(), kv("id", id), kv("error", JObject(fl))]);
	}

	public static function raiseMethodNotFound<T>(id:JsonValue, name:String):T throw new JsonRpcError(MethodNotFound(id, name));

	public static function raiseCustom<T>(id:JsonValue, code:Int, message:String):T throw new JsonRpcError(Custom(id, code, message));

	public static function raiseInvalidParams<T>(json:JsonValue):T throw new JsonRpcError(InvalidParams(json));

	public static function handleJsonrpcError<T>(f:Void->T, output:JsonValue->T):T {
		try {
			return f();
		} catch (e:JsonRpcError) {
			return switch e.kind {
				case ParseError(s): output(error(JNull, -32700, s));
				case InvalidRequest(s): output(error(JNull, -32600, s));
				case MethodNotFound(id, meth): output(error(id, -32601, 'Method `$meth` not found'));
				case InvalidParams(id): output(error(id, -32602, "Invalid params"));
				case Custom(id, code, msg): output(error(id, code, msg));
			};
		}
	}

	public static function parseRequest(input:String):JsonRpcRequest {
		// port: Sedlexing.Utf8.from_string's decoding raises MalFormed where the
		// bytes are not UTF-8 (core.StringHelper.decodedUtf8), here before reading
		var input = core.StringHelper.decodedUtf8(input);
		if (core.StringHelper.utf8Error(input) >= 0) throw new syntax.Lexer.MalFormed();
		var json = try core.Json.Reader.readJson(input) catch (e:JsonRpcError) throw e catch (e:Dynamic)
			throw new JsonRpcError(ParseError(Std.string(e)));
		var fields = switch json {
			case JObject(fl): fl;
			case _: throw new JsonRpcError(InvalidRequest("not an object"));
		};
		function getField<T>(name:String, map:JsonValue->Null<T>):T {
			var field:Null<JsonField> = null;
			for (f in fields) if (f.name == name) {
				field = f;
				break;
			}
			if (field == null) throw new JsonRpcError(InvalidRequest("no `" + name + "` field"));
			var value = map(field.value);
			if (value == null) throw new JsonRpcError(InvalidRequest('`$name` field has invalid data'));
			return value;
		}
		var id = getField("id", function(v) return v);
		var meth = getField("method", function(v) return switch v {
			case JString(s): s;
			case _: null;
		});
		var params:Null<JsonValue> = null;
		for (f in fields) if (f.name == "params") {
			params = f.value;
			break;
		}
		return {id: id, method: meth, params: params};
	}
}
