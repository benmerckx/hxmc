package macros.eval;

import core.Ast;
import core.Globals;
import core.Globals.Pos;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.ds.GlobalsIntMap;
import core.ds.NotFound;
import core.ds.OcamlHashtbl;
import core.json.JsonRpc;
import core.json.JsonRpcSocket;
import core.json.JsonrpcHandler;
import macros.eval.EvalContext;
import macros.eval.EvalValue;
import macros.eval.EvalHash;
import macros.eval.EvalDebugMisc;

using macros.eval.EvalValue.EvalValueTools;

// port: deviations:
// - Event channels are `EvalContext.EventChannel`; the socket thread holds the
//   Eval lock (EvalLock) while it handles a request, as an OCaml thread holds
//   the runtime lock, and gives it up while it reads the socket or waits.
// - `Printexc.to_string` is `printexc` below (the exceptions the debugger can
//   meet); a host thread that dies on an exception prints OCaml's
//   "Thread N killed on uncaught exception" line with the host's thread
//   numbering.
private typedef Completion = {n:Int, k:String, column:Null<Int>};

class EvalDebugSocket {
	/* Printing */
	static function printexc(exc:Dynamic):String {
		if (Std.isOfType(exc, NotFound)) return "Not_found";
		if (Std.isOfType(exc, core.ds.Failure)) return 'Failure("${(exc : core.ds.Failure).message}")';
		if (Std.isOfType(exc, core.ds.InvalidArgument)) return 'Invalid_argument("${(exc : core.ds.InvalidArgument).message}")';
		if (Std.isOfType(exc, EvalDebugMisc.Exit)) return "Stdlib.Exit";
		if (Std.isOfType(exc, ParseExprError)) return 'EvalDebugMisc.Parse_expr_error("${(exc : ParseExprError).msg}")';
		if (Std.isOfType(exc, haxe.Exception)) return (exc : haxe.Exception).message;
		return Std.string(exc);
	}

	public static function handleInTempThread(ctx:Context, env:Env, f:Void->Value):Value {
		var channel = new EventChannel<Value>();
		EvalThread.spawnThread(ctx, function() {
			var eval = EvalContext.getEval(ctx);
			eval.env = env;
			var v = try {
				f();
			} catch (_:NoValueExpr) {
				VNull;
			} catch (e:RunTimeException) {
				Sys.stderr().writeString(EvalExceptions.getExcErrorMessage(ctx, e.value, e.envs, e.pos) + "\n");
				VNull;
			} catch (exc:Dynamic) {
				Sys.stderr().writeString(printexc(exc) + "\n");
				VNull;
			}
			channel.poll(v);
			return VNull;
		});
		return channel.receive();
	}

	static function threadSafeValueString(env:Env, v:Value):String {
		var ctx = EvalContext.getCtx();
		return switch handleInTempThread(ctx, env, () -> VString(EvalPrinting.sValue(0, v))) {
			case VString(s): s.sstring;
			case _: Globals.die("", "evalDebugSocket.ml");
		}
	}

	static function stringOfFloat(f:Float):String return core.Numeric.stringOfFloat(f);

	public static function varToJson(name:String, value:Value, vio:Null<VarInfo>, env:Env):JsonValue {
		function jv(t:String, v:String, numChildren:Int):JsonValue {
			var id = if (numChildren == 0) 0 else (EvalContext.getCtx()).debug.debugContext.addValue(value, env);
			var fields:Array<JsonField> = [
				{name: "id", value: JInt(id)},
				{name: "name", value: JString(name)},
				{name: "type", value: JString(t)},
				{name: "value", value: JString(v)},
				{name: "numChildren", value: JInt(numChildren)},
			];
			var fields = switch vio {
				case null:
					fields;
				case vi:
					var coords = syntax.Lexer.getPosCoords(vi.viPos);
					([
						{name: "generated", value: JBool(vi.viGenerated)},
						{name: "line", value: JInt(coords.lineStart)},
						{name: "column", value: JInt(coords.columnStart)}
					] : Array<JsonField>).concat(fields);
			}
			return JObject(fields);
		}
		function stringRepr(s:String):String return "\"" + (core.StringHelper.sEscape(s)) + "\"";
		function level2ValueRepr(v:Value):String {
			return switch v {
				case VNull: "null";
				case VTrue: "true";
				case VFalse: "false";
				case VInt32(i): Std.string(i);
				case VInt64(i): haxe.Int64.toStr(i);
				case VUInt64(u): EvalIntegers.uint64ToString(u);
				case VFloat(f): stringOfFloat(f);
				case VEnumValue(ve):
					var name = EvalPrinting.sEnumCtorName(ve);
					switch ve.eargs {
						case []: name;
						case vl: name + "(...)";
					}
				case VObject(o): "{...}";
				case VString(s): stringRepr(s.sstring);
				case VArray(_) | VVector(_): "[...]";
				case VInstance(vi): (EvalHash.revHash(vi.iproto.ppath)) + " {...}";
				case VPrototype(proto): (EvalPrinting.sProtoKind(proto)).sstring;
				case VFunction(_) | VFieldClosure(_): "<fun>";
				case VLazy(f): level2ValueRepr(f.force());
				case VNativeString(s): stringRepr(s.toString());
				case VHandle(_): "<handle>";
			}
		}
		function fieldsString(fields:Array<{name:Int, value:Value}>):String {
			var l = fields.map(f -> '${EvalHash.revHash(f.name)}: ${level2ValueRepr(f.value)}');
			return '{${l.join(", ")}}';
		}
		function arrayElems(l:Array<Value>):String {
			var l = l.map(level2ValueRepr);
			return '[${l.join(", ")}]';
		}
		function valueString(v:Value):JsonValue {
			switch v {
				case VNull:
					return jv("NULL", "null", 0);
				case VTrue:
					return jv("Bool", "true", 0);
				case VFalse:
					return jv("Bool", "false", 0);
				case VInt32(i):
					return jv("Int", Std.string(i), 0);
				case VInt64(i):
					return jv("Int64", haxe.Int64.toStr(i), 0);
				case VUInt64(u):
					return jv("UInt64", EvalIntegers.uint64ToString(u), 0);
				case VFloat(f):
					return jv("Float", stringOfFloat(f), 0);
				case VEnumValue(ve):
					var typeS = EvalHash.revHash(ve.epath);
					var name = EvalPrinting.sEnumCtorName(ve);
					var valueS = switch ve.eargs {
						case []: name;
						case vl:
							var l = vl.map(level2ValueRepr);
							var s = '$name(${l.join(", ")})';
							s;
					}
					return jv(typeS, valueS, ve.eargs.length);
				case VObject(o):
					try {
						var e = (EvalContext.getCtx()).curapi.decodeExpr(v);
						return jv("Expr", core.AstPrinter.sExpr(e), 2);
					} catch (_:Dynamic) {
						var fields = EvalContext.objectFields(o);
						return jv("Anonymous", fieldsString(fields), fields.length);
					}
				case VString(s):
					return jv("String", stringRepr(s.sstring), 2);
				case VArray(va):
					return jv("Array", arrayElems(EvalArray.toList(va)), va.alength);
				case VVector(vv):
					return jv("Vector", arrayElems(vv.copy()), vv.length);
				case VInstance(vi):
					function className() return threadSafeValueString(env, v);
					var r = switch vi.ikind {
						case IMutex(_): {n: 1, s: className()};
						case IThread(_): {n: 1, s: className()};
						case IBytes(bytes):
							var max = 40;
							var s = if (bytes.length >= max) bytes.sub(0, max).toString() + "..." else bytes.toString();
							{n: EvalContext.instanceFields(vi).length, s: s};
						case _: {n: EvalContext.instanceFields(vi).length, s: className()};
					}
					var className = r.s;
					var numChildren = switch vi.ikind {
						case IMutex(_): 1;
						case IThread(_): 1;
						case _: EvalContext.instanceFields(vi).length;
					}
					return jv(className, className, numChildren);
				case VPrototype(proto):
					var fields = EvalContext.protoFields(proto);
					return jv("Anonymous", (EvalPrinting.sProtoKind(proto)).sstring, fields.length);
				case VFunction(_) | VFieldClosure(_):
					return jv("Function", "<fun>", 0);
				case VLazy(f):
					return valueString(f.force());
				case VNativeString(s):
					return jv("NativeString", stringRepr(s.toString()), 0);
				case VHandle(_):
					return jv("Handle", "<handle>", 0);
			}
		}
		return valueString(value);
	}

	public static function getCallStackEnvs(eval:Eval, p:Pos):Array<Env> {
		var envs = EvalContext.callStack(eval);
		return envs;
	}

	public static function outputCallStack(ctx:Context, eval:Eval, p:Pos):JsonValue {
		var envs = getCallStackEnvs(eval, p);
		function stackItem(env:Env, p:Pos):JsonValue {
			var id = ctx.debug.debugContext.addStackFrame(env);
			var kind = env.envInfo.kind;
			var coords = syntax.Lexer.getPosCoords(p);
			var path = core.Path.getRealPath(p.pfile);
			var artificial, name;
			switch kind {
				case EKMethod(_) | EKLocalFunction(_) | EKMacro(_):
					artificial = false;
					name = EvalContext.kindName(eval, kind);
				case EKEntrypoint:
					artificial = true;
					name = p.pfile;
			}
			var source = if (sys.FileSystem.exists(path)) JString(path) else JNull;
			return JObject([
				{name: "id", value: JInt(id)},
				{name: "name", value: JString(name)},
				{name: "source", value: source},
				{name: "line", value: JInt(coords.lineStart)},
				{name: "column", value: JInt(coords.columnStart)},
				{name: "endLine", value: JInt(coords.lineEnd)},
				{name: "endColumn", value: JInt(coords.columnEnd)},
				{name: "artificial", value: JBool(artificial)},
			]);
		}
		var first = true;
		var stack = [];
		for (env in envs) {
			var p:Pos = if (first) p else {pmin: env.envLeavePmin, pmax: env.envLeavePmax, pfile: EvalHash.revHash(env.envInfo.pfile)};
			first = false;
			stack.push(stackItem(env, p));
		}
		return JArray(stack);
	}

	public static function outputThreads(ctx:Context):JsonValue {
		function fold(id:Int, eval:Eval, acc:Array<JsonValue>):Array<JsonValue> {
			acc.unshift(JObject([
				{name: "id", value: JInt(id)},
				{name: "name", value: JString('Thread ${eval.thread.threadId}')}
			]));
			return acc;
		}
		var threads = ctx.evals.fold(fold, []);
		return JArray(threads);
	}

	static final isSimn = false;

	public static function outputScopes(ctx:Context, env:Env):JsonValue {
		var captureInfos = env.envInfo.captureInfos;
		var scopes = env.envDebug.scopes;
		function mkScope(id:Int, name:String, pos:Pos):JsonValue {
			var fl:Array<JsonField> = [{name: "id", value: JInt(id)}, {name: "name", value: JString(name)}];
			var fl = if (!(pos.pfile == Globals.nullPos.pfile && pos.pmin == Globals.nullPos.pmin && pos.pmax == Globals.nullPos.pmax)) {
				var coords = syntax.Lexer.getPosCoords(pos);
				([
					{
						name: "pos",
						value: JObject([
							{name: "source", value: JString(core.Path.getRealPath(pos.pfile))},
							{name: "line", value: JInt(coords.lineStart)},
							{name: "column", value: JInt(coords.columnStart)},
							{name: "endLine", value: JInt(coords.lineEnd)},
							{name: "endColumn", value: JInt(coords.columnEnd)},
						])
					}
				] : Array<JsonField>).concat(fl);
			} else fl;
			return JObject(fl);
		}
		// port: the scope stack's top is its last element: the fold goes from the innermost scope
		var acc:Array<JsonValue> = [];
		var k = scopes.length - 1;
		while (k >= 0) {
			var scope = scopes[k--];
			if (scope.localInfos.length() != 0) acc.unshift(mkScope(ctx.debug.debugContext.addScope(scope, env), "Locals", scope.pos));
		}
		var scopes = acc;
		var scopes = if (!isSimn) scopes else {
			var dbg:DebugScopeInfo = {
				dsExpr: env.envDebug.debugExpr,
				dsReturn: env.envEval.lastReturn,
			};
			[mkScope(ctx.debug.debugContext.addDebugScope(dbg, env), "Eval", Globals.nullPos)].concat(scopes);
		}
		scopes.reverse();
		var scopes = if (captureInfos.length() == 0) scopes else [
			mkScope(ctx.debug.debugContext.addCaptureScope(captureInfos, env), "Captures", Globals.nullPos)
		].concat(scopes);
		return JArray(scopes);
	}

	public static function outputCaptureVars(infos:OcamlHashtbl<Int, VarInfo>, env:Env):JsonValue {
		var vars = infos.fold(function(slot, vi, acc:Array<JsonValue>) {
			var value = (env.envCaptures[slot]);
			acc.unshift(varToJson(vi.viName, value, vi, env));
			return acc;
		}, []);
		return JArray(vars);
	}

	public static function outputDebugScope(dbg:DebugScopeInfo, env:Env):JsonValue {
		var ja = [
			varToJson("expr", VString(EvalString.createAscii(env.envDebug.debugExpr)), null, env),
			varToJson("last return", switch dbg.dsReturn {
				case null: VNull;
				case v: v;
			}, null, env),
		];
		return JArray(ja);
	}

	public static function outputScopeVars(env:Env, scope:Scope):JsonValue {
		var p = env.envDebug.debugPos;
		var vars = scope.localInfos.fold(function(localSlot, vi, acc:Array<JsonValue>) {
			if (EvalDebugMisc.declaredBefore(vi, p)) {
				var slot = localSlot + scope.localOffset;
				var value = env.envLocals[slot];
				acc.unshift(varToJson(vi.viName, value, vi, env));
				return acc;
			} else
				return acc;
		}, []);
		return JArray(vars);
	}

	public static function outputInnerVars(v:Value, env:Env):JsonValue {
		function loop(v:Value):Array<{n:String, v:Value}> {
			switch v {
				case VNull | VTrue | VFalse | VInt32(_) | VInt64(_) | VUInt64(_) | VFloat(_) | VFunction(_) | VFieldClosure(_) | VNativeString(_) |
					VHandle(_):
					return [];
				case VEnumValue(ve):
					return switch (EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), ve.epath)).pkind {
						case PEnum(names):
							var fields = names[ve.eindex].params;
							[
								for (i => n in fields) {
									var n = EvalHash.revHash(n);
									var v = ve.eargs[i];
									{n: n, v: v};
								}
							];
						case _: [];
					}
				case VObject(o):
					var fields = EvalContext.objectFields(o);
					return fields.map(f -> {
						var n = EvalHash.revHash(f.name);
						{n: n, v: f.value};
					});
				case VString(s):
					var l = [];
					var offsets = [for (r in [s.soffsets2, s.soffsets1]) if (r != null) r];
					for (i => r in offsets) {
						// port: the entries hold native indices: the offset is the bytes before one
						var offset = haxe.io.Bytes.ofString(s.sstring.substring(0, r.bOffset)).length;
						l.unshift({n: 'offset$i', v: EvalValueTools.vint(offset)});
						l.unshift({n: 'index$i', v: EvalValueTools.vint(r.cIndex)});
					}
					return [
						{n: "length", v: EvalValueTools.vint(s.slength)},
						{n: "byteLength", v: EvalValueTools.vint(haxe.io.Bytes.ofString(s.sstring).length)}
					].concat(l);
				case VArray(va):
					var l = EvalArray.toList(va);
					return [for (i => v in l) {n: '[$i]', v: v}];
				case VVector(vv):
					var l = vv.copy();
					return [for (i => v in l) {n: '[$i]', v: v}];
				case VInstance({ikind: IStringMap(h)}):
					return h.fold(function(s, e, acc:Array<{n:String, v:Value}>) {
						acc.unshift({n: s, v: e.value});
						return acc;
					}, []);
				case VInstance({ikind: IMutex(mutex)}):
					var owner = mutex.owner();
					return [{n: "owner", v: if (owner == -1) VNull else EvalValueTools.vint(owner)}];
				case VInstance({ikind: IThread(thread)}):
					return [{n: "id", v: EvalValueTools.vint(thread.threadId)}];
				case VInstance(vi):
					var fields = EvalContext.instanceFields(vi);
					return fields.map(f -> {
						var n = EvalHash.revHash(f.name);
						{n: n, v: f.value};
					});
				case VPrototype(proto):
					var fields = EvalContext.protoFields(proto);
					return fields.map(f -> {
						var n = EvalHash.revHash(f.name);
						{n: n, v: f.value};
					});
				case VLazy(f):
					return loop(f.force());
			}
		}
		var children = loop(v);
		var vars = children.map(c -> varToJson(c.n, c.v, null, env));
		return JArray(vars);
	}

	/* ValueCompletion */
	static function prototypeInstanceFields(proto:Vprototype):GlobalsIntMap<Completion> {
		function loop(acc:GlobalsIntMap<Completion>, proto:Vprototype):GlobalsIntMap<Completion> {
			var acc = switch proto.pparent {
				case null: acc;
				case proto: loop(acc, proto);
			}
			var acc = proto.pinstanceNames.fold((name, _, acc:GlobalsIntMap<Completion>) -> acc.add(name, {n: name, k: "field", column: null}), acc);
			return proto.pnames.fold((name, _, acc:GlobalsIntMap<Completion>) -> acc.add(name, {n: name, k: "method", column: null}), acc);
		}
		return loop(GlobalsIntMap.empty(), proto);
	}

	static function prototypeStaticFields(proto:Vprototype):GlobalsIntMap<Completion> {
		return proto.pnames.fold(function(name, offset, acc:GlobalsIntMap<Completion>) {
			var v = proto.pfields[offset];
			var kind = switch v {
				case VFunction(_): "method";
				case _: "field";
			}
			return acc.add(name, {n: name, k: kind, column: null});
		}, GlobalsIntMap.empty());
	}

	static function completionToJson(l:Array<Completion>):JsonValue {
		return JArray(l.map(function(c) {
			var fields:Array<JsonField> = [{name: "label", value: JString(EvalHash.revHash(c.n))}, {name: "type", value: JString(c.k)}];
			var fields = switch c.column {
				case null: fields;
				case column: ([{name: "start", value: JInt(column)}] : Array<JsonField>).concat(fields);
			}
			return JObject(fields);
		}));
	}

	// port: IntMap.fold (fun _ v acc -> v :: acc) m init
	static function valuesRev(m:GlobalsIntMap<Completion>, init:Array<Completion>):Array<Completion> {
		return m.fold((_, v, acc:Array<Completion>) -> {
			acc.unshift(v);
			acc;
		}, init);
	}

	static function collectIdents(ctx:Context, env:Env):JsonValue {
		var acc = new OcamlHashtbl<Int, Completion>(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
		function add(key:Int, kind:String) {
			if (!acc.mem(key)) acc.add(key, {n: key, k: kind, column: null});
		}
		/* 0. Extra locals */
		env.envExtraLocals.iter((key, _) -> add(key, "variable"));
		/* 1. Variables */
		var k = env.envDebug.scopes.length - 1;
		while (k >= 0) {
			var scope = env.envDebug.scopes[k--];
			scope.localIds.iter((key, _) -> add(EvalHash.hash(key), "variable"));
		}
		/* 2. Captures */
		env.envInfo.captureInfos.iter((slot, vi) -> add(EvalHash.hash(vi.viName), "variable"));
		/* 3. Instance */
		if (!env.envInfo.isStatic) {
			var v = env.envLocals[0];
			switch v {
				case VInstance(vi):
					var fields = prototypeInstanceFields(vi.iproto);
					fields.iter((key, c) -> add(key, c.k));
				case _:
			}
		}
		/* 4. Static */
		switch env.envInfo.kind {
			case EKMethod(i1, _):
				var proto = EvalContext.getStaticPrototypeRaise(ctx, i1);
				var fields = prototypeStaticFields(proto);
				fields.iter((key, c) -> add(key, c.k));
			case _:
				throw NotFound.raise();
		}
		/* 5. Toplevel */
		switch ctx.toplevel {
			case VObject(o):
				var fields = EvalContext.objectFields(o);
				for (f in fields) {
					var kind = switch f.value {
						case VPrototype(proto):
							switch proto.pkind {
								case PClass(_): "class";
								case PEnum(_): "enum";
								case _: "class" /* ? */;
							}
						case _: "module";
					}
					add(f.name, kind);
				}
			case _:
		}
		return completionToJson(acc.fold((_, v, acc:Array<Completion>) -> {
			acc.unshift(v);
			acc;
		}, []));
	}

	static function outputCompletion(ctx:Context, column:Int, v:Value):JsonValue {
		function fieldValueKind(v:Value):String {
			return switch v {
				case VFunction(_) | VFieldClosure(_): "function";
				case _: "field";
			}
		}
		function loop(v:Value):Array<Completion> {
			switch v {
				case VNull | VTrue | VFalse | VInt32(_) | VInt64(_) | VUInt64(_) | VFloat(_) | VFunction(_) | VFieldClosure(_) | VNativeString(_) |
					VHandle(_):
					return [];
				case VObject(o):
					var fields = EvalContext.objectFields(o);
					return fields.map(f -> ({n: f.name, k: (fieldValueKind(f.value)), column: null} : Completion));
				case VInstance(vi):
					var fields = prototypeInstanceFields(vi.iproto);
					return valuesRev(fields, []);
				case VString(_):
					var fields = prototypeInstanceFields(ctx.stringPrototype);
					return valuesRev(fields, [{n: EvalHash.key_length, k: "field", column: null}]);
				case VArray(_):
					var fields = prototypeInstanceFields(ctx.arrayPrototype);
					return valuesRev(fields, [{n: EvalHash.key_length, k: "field", column: null}]);
				case VVector(_):
					var fields = prototypeInstanceFields(ctx.vectorPrototype);
					return valuesRev(fields, [{n: EvalHash.key_length, k: "field", column: null}]);
				case VPrototype(proto):
					var fields = prototypeStaticFields(proto);
					return valuesRev(fields, []);
				case VLazy(f):
					return loop(f.force());
				case VEnumValue(ve):
					return switch (EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), ve.epath)).pkind {
						case PEnum(names):
							var fields = names[ve.eindex].params;
							fields.map(n -> ({n: n, k: "value", column: null} : Completion));
						case _: [];
					}
			}
		}
		var l = loop(v);
		return completionToJson(l);
	}

	static function getCompletionImpl(ctx:Context, text:String, column:Int, env:Env):JsonValue {
		var p = Globals.filePos("");
		var save = {
			var old = core.display.DisplayPosition.displayPosition.get();
			function() {
				core.display.DisplayPosition.displayPosition.set(old);
			}
		}
		var com = (ctx.curapi.getCom());
		var config = syntax.Parser.createConfig(com.defines, true, true, DMDefault, com.partScope.parserState.wasAutoTriggered, null);
		var offset = column + ("class X{static function main() ".length) - 1 /* this is retarded */;
		core.display.DisplayPosition.displayPosition.set({pfile: p.pfile, pmin: offset, pmax: offset});
		try {
			var e = EvalDebugMisc.parseExpr(ctx, config, text, p);
			var e = context.display.ExprPreprocessing.findBeforePos(com.partScope.parserState.wasAutoTriggered, DMDefault, e);
			save();
			function loop(e:Expr):Void {
				switch e.expr {
					case EDisplay(e1, DKDot):
						var v = handleInTempThread(ctx, env, () -> EvalDebugMisc.exprToValue(ctx, env, e1));
						var json = outputCompletion(ctx, column, v);
						throw new JsonException(json);
					case EArray(e1, {expr: EDisplay({expr: EConst(Ident("null"))}, DKMarked)}):
						var v = handleInTempThread(ctx, env, () -> EvalDebugMisc.exprToValue(ctx, env, e1));
						switch v {
							case VArray(va):
								var l = EvalArray.toList(va);
								var l = [
									for (i => v in l) {
										var n = '$i';
										({n: (EvalHash.hash(n)), k: "value", column: column} : Completion);
									}
								];
								throw new JsonException(completionToJson(l));
							case _:
								throw new EvalDebugMisc.Exit();
						}
					case EDisplay(e1, DKMarked):
						var json = collectIdents(ctx, env);
						throw new JsonException(json);
					case _:
						Ast.iterExpr(loop, e);
				}
			}
			try {
				loop(e);
				throw new EvalDebugMisc.Exit();
			} catch (e:JsonException) {
				return e.json;
			}
		} catch (_:Dynamic) {
			save();
			throw new EvalDebugMisc.Exit();
		}
	}

	static function getCompletion(ctx:Context, text:String, column:Int, env:Env):JsonValue {
		return if (text == "") collectIdents(ctx, env) else getCompletionImpl(ctx, text, column, env);
	}

	static function expectEnv<T>(hctx:HandlerContext, env:Null<Env>):Env {
		return switch env {
			case null: hctx.sendError("No frame found");
			case env: env;
		}
	}

	static final handler:OcamlHashtbl<String, HandlerContext->JsonValue> = makeHandler();

	static function makeHandler():OcamlHashtbl<String, HandlerContext->JsonValue> {
		function parseExpr(ctx:Context, s:String, p:Pos):Expr {
			return EvalDebugMisc.parseExpr(ctx, syntax.ParserConfig.defaultConfig((ctx.curapi.getCom()).defines), s, p);
		}
		function parseBreakpoint(hctx:HandlerContext, jo:JsonValue):{line:Int, column:BreakpointColumn, condition:Null<Expr>} {
			var j = hctx.jsonrpc;
			var obj = j.getObject("breakpoint", jo);
			var line = j.getIntField("line", "line", obj);
			var column = j.getOptParam(() -> BPColumn(j.getIntField("column", "column", obj)), BPAny);
			var condition = j.getOptParam(() -> {
				var s = j.getStringField("condition", "condition", obj);
				parseExpr(hctx.ctx, s, Globals.nullPos);
			}, null);
			return {line: line, column: column, condition: condition};
		}
		function selectFrame(hctx:HandlerContext):Env {
			var frameId = hctx.jsonrpc.getIntParam("frameId");
			var env = switch hctx.ctx.debug.debugContext.get(frameId) {
				case StackFrame(env): env;
				case _: hctx.sendError('Bad frame ID: $frameId');
			}
			return env;
		}
		function selectThread(hctx:HandlerContext):Eval {
			var id = hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getIntParam("threadId"), 0);
			var eval = try hctx.ctx.evals.find(id) catch (_:NotFound) hctx.sendError("Invalid thread id");
			return eval;
		}
		var h = new OcamlHashtbl<String, HandlerContext->JsonValue>(core.ds.OcamlHash.hashString, (a, b) -> a == b, 0);
		var l:Array<{name:String, f:HandlerContext->JsonValue}> = [
			{
				name: "pause",
				f: function(hctx) {
					var eval = selectThread(hctx);
					eval.debugState = DbgWaiting;
					return JNull;
				}
			},
			{
				name: "continue",
				f: function(hctx) {
					var eval = selectThread(hctx);
					eval.debugState = DbgRunning;
					eval.debugChannel.poll(true);
					return JNull;
				}
			},
			{
				name: "stepIn",
				f: function(hctx) {
					var eval = selectThread(hctx);
					eval.debugState = DbgStep;
					eval.debugChannel.poll(true);
					return JNull;
				}
			},
			{
				name: "next",
				f: function(hctx) {
					var eval = selectThread(hctx);
					var env = expectEnv(hctx, eval.env);
					eval.debugState = DbgNext(env, env.envDebug.debugPos);
					eval.debugChannel.poll(true);
					return JNull;
				}
			},
			{
				name: "stepOut",
				f: function(hctx) {
					var eval = selectThread(hctx);
					var env = expectEnv(hctx, eval.env);
					var penv = expectEnv(hctx, env.envParent);
					eval.debugState = DbgFinish(penv);
					eval.debugChannel.poll(true);
					return JNull;
				}
			},
			{
				name: "getThreads",
				f: function(hctx) {
					return outputThreads(hctx.ctx);
				}
			},
			{
				name: "stackTrace",
				f: function(hctx) {
					var eval = selectThread(hctx);
					var env = expectEnv(hctx, eval.env);
					return outputCallStack(hctx.ctx, eval, env.envDebug.debugPos);
				}
			},
			{
				name: "getScopes",
				f: function(hctx) {
					var env = selectFrame(hctx);
					return outputScopes(hctx.ctx, env);
				}
			},
			{
				name: "getVariables",
				f: function(hctx) {
					var sid = hctx.jsonrpc.getIntParam("id");
					var vars = try {
						var scope = hctx.ctx.debug.debugContext.get(sid);
						switch scope {
							case Scope(scope, env):
								outputScopeVars(env, scope);
							case CaptureScope(infos, env):
								outputCaptureVars(infos, env);
							case DebugScope(dbg, env):
								outputDebugScope(dbg, env);
							case Value(value, env):
								outputInnerVars(value, env);
							case Toplevel | StackFrame(_) | NoSuchReference:
								hctx.sendError('Bad ID: $sid');
						}
					} catch (_:EvalDebugMisc.Exit) {
						hctx.sendError("Invalid scope id");
					}
					return vars;
				}
			},
			{
				name: "setBreakpoints",
				f: function(hctx) {
					var file = hctx.jsonrpc.getStringParam("file");
					var bps = hctx.jsonrpc.getArrayParam("breakpoints");
					var bps = bps.map(parseBreakpoint.bind(hctx));
					var hash = EvalHash.hash(core.Path.UniqueKey.toString(hctx.ctx.fileKeys.get(context.Common.findFile(hctx.ctx.curapi.getCom(),
						file))));
					var h = try {
						var h = hctx.ctx.debug.breakpoints.find(hash);
						h.clear();
						h;
					} catch (_:NotFound) {
						var h = new OcamlHashtbl<Int, Breakpoint>(OcamlHashtbl.hashInt, (a, b) -> a == b, bps.length);
						hctx.ctx.debug.breakpoints.add(hash, h);
						h;
					}
					var bps = bps.map(function(b) {
						var bp = EvalDebugMisc.makeBreakpoint(hash, b.line, BPEnabled, b.column, b.condition);
						h.add(b.line, bp);
						return JObject([{name: "id", value: JInt(bp.bpid)}]);
					});
					return JArray(bps);
				}
			},
			{
				name: "setBreakpoint",
				f: function(hctx) {
					var b = parseBreakpoint(hctx, (hctx.jsonrpc.getParams()));
					var file = hctx.jsonrpc.getStringParam("file");
					var breakpoint = EvalDebugMisc.addBreakpoint(hctx.ctx, file, b.line, b.column, b.condition);
					return JObject([{name: "id", value: JInt(breakpoint.bpid)}]);
				}
			},
			{
				name: "setFunctionBreakpoints",
				f: function(hctx) {
					hctx.ctx.debug.functionBreakpoints.clear();
					var j = hctx.jsonrpc;
					var bps = j.getArray("param", (j.getParams()));
					var bps = bps.map(function(jo) {
						var obj = j.getObject("breakpoint", jo);
						var name = j.getStringField("name", "name", obj);
						var i = name.lastIndexOf(".");
						// port: String.rindex raises Not_found when there is no '.'
						if (i < 0) throw NotFound.raise();
						var keyType = name.substr(0, i);
						var keyField = name.substr(i + 1, name.length - i - 1);
						var bp = EvalDebugMisc.makeFunctionBreakpoint(BPEnabled);
						hctx.ctx.debug.functionBreakpoints.add({type: EvalHash.hash(keyType), field: EvalHash.hash(keyField)}, bp);
						return JObject([{name: "id", value: JInt(bp.fbpid)}]);
					});
					return JArray(bps);
				}
			},
			{
				name: "removeBreakpoint",
				f: function(hctx) {
					var id = hctx.jsonrpc.getIntParam("id");
					try {
						hctx.ctx.debug.breakpoints.iter(function(_, h) {
							var toDelete = [];
							h.iter((k, breakpoint) -> if (breakpoint.bpid == id) toDelete.unshift(k));
							for (k in toDelete) h.remove(k);
						});
					} catch (_:NotFound) {
						hctx.sendError('Unknown breakpoint: $id');
					}
					return JNull;
				}
			},
			{
				name: "setVariable",
				f: function(hctx) {
					var id = hctx.jsonrpc.getIntParam("id");
					var name = hctx.jsonrpc.getStringParam("name");
					var value = hctx.jsonrpc.getStringParam("value");
					function getValue(env:Env):Value {
						try {
							var e = parseExpr(hctx.ctx, value, env.envDebug.debugPos);
							return EvalDebugMisc.exprToValue(hctx.ctx, env, e);
						} catch (e:ParseExprError) {
							return hctx.sendError(e.msg);
						}
					}
					switch hctx.ctx.debug.debugContext.get(id) {
						case Toplevel | NoSuchReference:
							return hctx.sendError('Bad ID: $id');
						case Value(v, env):
							var value = getValue(env);
							function nameAsIndex():Int {
								/* The name is [1] so we have to extract the number. This is quite stupid but not really our fault... */
								var s = name.length >= 2 ? name.substr(1, name.length - 2) : null;
								var i = s == null || !~/^[-+]?[0-9]+$/.match(s) ? null : Std.parseInt(s);
								return if (i == null) hctx.sendError("integer expected") else i;
							}
							switch v {
								case VArray(va): EvalArray.set(va, nameAsIndex(), value);
								case VVector(vv):
									var i = nameAsIndex();
									if (i < 0 || i >= vv.length) throw new core.ds.InvalidArgument("index out of bounds");
									vv[i] = value;
								case _:
									EvalMisc.setField(v, EvalHash.hash(name), value);
							}
							return varToJson("", value, null, env);
						case Scope(scope, env):
							var value = getValue(env);
							var id = scope.localIds.find(name);
							var slot = scope.locals.get(id);
							if (slot == null) throw NotFound.raise();
							env.envLocals[slot + scope.localOffset] = value;
							return varToJson("", value, null, env);
						case CaptureScope(infos, env):
							var value = getValue(env);
							var slot = EvalDebugMisc.getCaptureSlotByName(infos, name);
							env.envCaptures[slot] = value;
							return varToJson("", value, null, env);
						case DebugScope(_) | StackFrame(_):
							return JNull;
					}
				}
			},
			{
				name: "setExceptionOptions",
				f: function(hctx) {
					var sl = hctx.jsonrpc.getArray("", hctx.jsonrpc.getParams());
					var sl = sl.map(hctx.jsonrpc.getString.bind(""));
					hctx.ctx.debug.exceptionMode = if (sl.indexOf("all") >= 0) CatchAll else if (sl.indexOf("uncaught") >= 0) CatchUncaught else
						CatchNone;
					return JNull;
				}
			},
			{
				name: "evaluate",
				f: function(hctx) {
					var ctx = hctx.ctx;
					var env = try selectFrame(hctx) catch (_:Dynamic) expectEnv(hctx, (EvalContext.getEval(ctx)).env);
					var s = hctx.jsonrpc.getStringParam("expr");
					try {
						var e = parseExpr(ctx, s, env.envDebug.debugPos);
						var v = handleInTempThread(ctx, env, () -> EvalDebugMisc.exprToValue(ctx, env, e));
						return varToJson("", v, null, env);
					} catch (e:ParseExprError) {
						return hctx.sendError(e.msg);
					} catch (_:EvalDebugMisc.Exit) {
						return hctx.sendError("Don't know how to handle this expression");
					}
				}
			},
			{
				name: "getCompletion",
				f: function(hctx) {
					var env = expectEnv(hctx, (EvalContext.getEval(hctx.ctx)).env);
					var text = hctx.jsonrpc.getStringParam("text");
					var column = hctx.jsonrpc.getIntParam("column");
					try {
						return getCompletion(hctx.ctx, text, column, env);
					} catch (_:EvalDebugMisc.Exit) {
						return hctx.sendError("No completion point found");
					}
				}
			},
		];
		for (e in l) h.add(e.name, e.f);
		return h;
	}

	public static function makeConnection(socket:core.Socket):DebugConnection {
		function currentEvalThreadId():Int {
			try {
				return (EvalContext.getEval(EvalContext.getCtx())).thread.threadId;
			} catch (_:Dynamic) {
				return hostThreadId();
			}
		}
		function outputThreadEvent(threadId:Int, reason:String):Void {
			JsonRpcSocket.sendEvent(socket, "threadEvent", JObject([{name: "threadId", value: JInt(threadId)}, {name: "reason", value: JString(reason)}]));
		}
		function outputBreakpointStop(debug:Debug):Void {
			/* TODO: this isn't thread-safe. We should only create these anew if all threads continued */
			debug.debugContext = new EvalDebugContext();
			JsonRpcSocket.sendEvent(socket, "breakpointStop", JObject([{name: "threadId", value: JInt(currentEvalThreadId())}]));
		}
		function outputExceptionStop(debug:Debug, v:Value, _:Pos):Void {
			debug.debugContext = new EvalDebugContext();
			JsonRpcSocket.sendEvent(socket, "exceptionStop", JObject([
				{name: "threadId", value: JInt(currentEvalThreadId())},
				{name: "text", value: JString(EvalPrinting.valueString(v))}
			]));
		}
		function wait():Void {
			function processOutcome(id:JsonValue, outcome:JsonValue):Void {
				function output(j:JsonValue) JsonRpcSocket.sendJson(socket, JsonRpc.result(id, j));
				output(outcome);
			}
			function sendOutputAndContinue(json:JsonValue):Void {
				JsonRpcSocket.sendJson(socket, json);
			}
			function sendOutputAndExit(json:JsonValue):JsonRpcRequest {
				JsonRpcSocket.sendJson(socket, json);
				throw new EvalDebugMisc.Exit();
			}
			// port: the recursion of `loop` (each outcome calls it again) is a loop
			function loop():Void {
				while (true) {
					var input = socket.readString();
					EvalLock.enter();
					try {
						var input = JsonRpc.handleJsonrpcError(() -> JsonRpc.parseRequest(input), sendOutputAndExit);
						var jsonrpc = new JsonrpcHandler(input);
						function error<T>(msg:String):T {
							throw new JsonRpcError(Custom(jsonrpc.getId(), 1, msg));
						}
						var hctx = new HandlerContext(EvalContext.getCtx(), jsonrpc, error);
						JsonRpc.handleJsonrpcError(function() {
							var methodName = jsonrpc.getMethodName();
							var f = try {
								handler.find(methodName);
							} catch (_:NotFound) {
								JsonRpc.raiseMethodNotFound(jsonrpc.getId(), methodName);
							}
							processOutcome(jsonrpc.getId(), f(hctx));
							return true;
						}, json -> {
							sendOutputAndContinue(json);
							true;
						});
					} catch (e:Dynamic) {
						EvalLock.leave();
						throw e;
					}
					EvalLock.leave();
				}
			}
			try {
				loop();
			} catch (_:EvalDebugMisc.Exit) {
				loop();
			}
		}
		EvalLock.activate();
		sys.thread.Thread.create(function() {
			try {
				wait();
			} catch (exc:Dynamic) {
				Sys.stderr().writeString('Thread ${hostThreadId()} killed on uncaught exception ${printexc(exc)}\n');
			}
		});
		return new DebugConnection(outputBreakpointStop, outputExceptionStop, outputThreadEvent);
	}

	// port: OCaml's Thread.id (Thread.self ()): the host has no thread numbers
	static function hostThreadId():Int return 0;
}

private class JsonException extends haxe.Exception {
	public final json:JsonValue;

	public function new(json:JsonValue) {
		super("JsonException");
		this.json = json;
	}
}

private class HandlerContext {
	public final ctx:Context;
	public final jsonrpc:JsonrpcHandler;
	public final sendError:(String) -> Dynamic;

	public function new(ctx, jsonrpc, sendError) {
		this.ctx = ctx;
		this.jsonrpc = jsonrpc;
		this.sendError = sendError;
	}
}
