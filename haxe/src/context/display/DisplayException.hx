package context.display;

import core.Globals.Pos;
import core.Ast.Documentation;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.TFunctions.*;
import core.WithType.WithTypeValue;
import core.display.DisplayPosition;
import core.json.Genjson;
import core.json.Genjson.GenjsonContext;
import core.json.Genjson.*;
import compiler.io.CompilerOutput;
import compiler.server.ServerConfig;
import context.Common;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;
import core.ds.VectorTools.vector;

// port: `((args,ret),ctf),doc` of a signature, as produced by TyperDisplay.convert_function_signature.
typedef SignatureInfo = {sig:{args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, ret:T, ctf:CtFunction}, doc:Documentation};

class DisplayException extends haxe.Exception {
	public final kind:DisplayExceptionKind;

	public function new(kind:DisplayExceptionKind) {
		super("DisplayException");
		this.kind = kind;
	}

	public static function raiseHover<R>(item:CompletionItemData, expected:Null<WithTypeValue>,
			p:Pos):R throw new DisplayException(DisplayHover({
			hitem: item,
			hpos: p,
			hexpected: expected
		}));

	public static function raiseFields<R>(ckl:Array<CompletionItemData>, cr:CompletionResultKindValue,
			subj:CompletionSubject):R throw new DisplayException(DisplayFields({
			fitems: ckl,
			fkind: cr,
			fsubject: subj
		}));

	// global state
	public static var lastCompletionResult:haxe.ds.Vector<CompletionItemData> = vector();
	public static var lastCompletionPos:Null<Pos> = null;

	public static function reset():Void {
		lastCompletionResult = vector();
		lastCompletionPos = null;
	}

	public static function filterSomehow(ctx:GenjsonContext, items:Array<CompletionItemData>, kind:CompletionResultKindValue,
			subj:CompletionSubject):{
		items:Array<JsonValue>,
		length:Int
	} {
		var subject = subj.sName == null ? "" : subj.sName.toLowerCase();
		var subjectLength = subject.length;
		function determineCost(s:String):Int {
			function getInitialCost(o:Int):Int {
				if (o == 0) return 0; // Term starts with subject - perfect
				// Consider `.` as anchors and determine distance from closest one. Penalize starting distance by factor 2.
				var lastAnchor = s.lastIndexOf(".", o);
				return lastAnchor < 0 ? o * 2 : (o - (lastAnchor + 1)) * 2;
			}
			function indexFrom(o:Int, c:Int):{o:Int, cost:Int} {
				var cost = 0;
				while (true) {
					// port: String.get raises Invalid_argument past the end
					if (o >= s.length) throw new core.ds.InvalidArgument("index out of bounds");
					var c2 = StringTools.fastCodeAt(s, o);
					if (c2 == c) return {o: o, cost: cost};
					o++;
					cost += 3; // Holes are bad, penalize by 3.
				}
			}
			function loop(i:Int, o:Int, cost:Int):Int {
				if (i < subjectLength) {
					var r = indexFrom(o, StringTools.fastCodeAt(subject, i));
					return loop(i + 1, r.o, cost + r.cost);
				}
				return cost + (o == s.length - 1 ? 0 : 1); // Slightly penalize for not-exact matches.
			}
			if (subjectLength == 0) return 0;
			try {
				var o = s.indexOf(subject.charAt(0));
				if (o < 0) throw core.ds.NotFound.raise();
				return loop(1, o, getInitialCost(o));
			} catch (_:core.ds.NotFound) {
				return -1;
			} catch (_:core.ds.InvalidArgument) {
				return -1;
			}
		}
		var acc:Array<{item:CompletionItemData, index:Int, cost:Int}> = [];
		var index = 0;
		for (item in items) {
			var name = CompletionItem.getFilterName(item).toLowerCase();
			var cost = determineCost(name);
			if (cost >= 0) acc.unshift({item: item, index: index, cost: cost});
			index++;
		}
		if (subjectLength == 0) acc.reverse()
		else haxe.ds.ArraySort.sort(acc, (a, b) -> Reflect.compare(a.cost, b.cost));
		var ret:Array<JsonValue> = [];
		for (e in acc) {
			if (ret.length < ServerConfig.maxCompletionItems) ret.push(CompletionItem.toJson(ctx, e.index, e.item))
			else break;
		}
		return {items: ret, length: ret.length};
	}

	public static function patchCompletionSubject(subj:CompletionSubject):CompletionSubject {
		var p = syntax.Parser.cutPosAtDisplay(subj.sInsertPos);
		if (subj.sName != null) {
			var name = subj.sName;
			var delta = p.pmax - p.pmin;
			var name = delta > 0 && delta < name.length ? name.substr(0, delta) : name;
			return {sName: name, sStartPos: subj.sStartPos, sInsertPos: p};
		}
		return {sName: null, sStartPos: subj.sStartPos, sInsertPos: p};
	}

	public static function fieldsToJson(ctx:GenjsonContext, fields:Array<CompletionItemData>, kind:CompletionResultKindValue,
			subj:CompletionSubject):JsonValue {
		lastCompletionResult = haxe.ds.Vector.fromArrayCopy(fields);
		var needsFiltering = ServerConfig.maxCompletionItems > 0 && lastCompletionResult.length > ServerConfig.maxCompletionItems;
		// let p_before = subj.s_insert_pos in
		var subj = patchCompletionSubject(subj);
		var r = if (needsFiltering) filterSomehow(ctx, fields, kind, subj) else {
			var i = 0;
			{items: [for (item in fields) CompletionItem.toJson(ctx, i++, item)], length: lastCompletionResult.length};
		};
		var didFilter = r.length == ServerConfig.maxCompletionItems;
		lastCompletionPos = didFilter ? subj.sStartPos : null;
		var filterString = subj.sName == null ? "" : subj.sName;
		/* print_endline (Printf.sprintf "FIELDS OUTPUT:\n\tfilter_string: %s\n\t    num items: %i\n\t        start: %s\n\t     position: %s\n\t   before cut: %s"
			filter_string
			num_items
			(Printer.s_pos subj.s_start_pos)
			(Printer.s_pos subj.s_insert_pos)
			(Printer.s_pos p_before)
		); */
		return jobject([
			kv("items", jarray(r.items)),
			kv("isIncomplete", jbool(didFilter)),
			kv("mode", CompletionResultKind.toJson(ctx, kind)),
			kv("filterString", jstring(filterString)),
			kv("replaceRange", generatePosAsRange(subj.sInsertPos))
		]);
	}

	public static function argIndex(signatures:Array<SignatureInfo>, signatureIndex:Int, paramIndex:Int):Int {
		// port: List.nth raises Invalid_argument for a negative index and Failure past the end
		if (signatureIndex < 0) return paramIndex;
		if (signatureIndex >= signatures.length) throw new core.ds.Failure("nth");
		var args = signatures[signatureIndex].sig.args;
		var index = 0;
		var i = 0;
		while (true) {
			if (i >= args.length) return paramIndex;
			if (i == args.length - 1 && index < paramIndex && core.TOther.ExtType.isRest(follow(args[i].type))) return index;
			if (index == paramIndex) return paramIndex;
			i++;
			index++;
		}
	}

	public static function toJson(ctx:GenjsonContext, de:DisplayExceptionKind):JsonValue {
		return switch de {
			case DisplayHover(hover):
				function namedSourceKind(kind:core.WithType.WithTypeSource):{i:Int, si:core.WithType.WithTypeSourceInformation}
					return switch kind {
						case FunctionArgument(name): {i: 0, si: name};
						case StructureField(name): {i: 1, si: name};
						case LocalVariable(name): {i: 2, si: name};
						case ImplicitReturn: throw new core.Globals.InternalCompilerError("displayException.ml: ImplicitReturn has no name",
								"");
					};
				var ctx = Genjson.createFullConfig();
				function generateName(kind:core.WithType.WithTypeSource):JsonValue {
					var r = namedSourceKind(kind);
					return jobject([
						kv("name", jstring(r.si.siName)),
						kv("kind", jint(r.i)),
						kv("doc", r.si.siDoc == null ? jnull : jstring(r.si.siDoc))
					]);
				}
				var expected = switch hover.hexpected {
					case WithType(t, src):
						var fl = [kv("type", generateType(ctx, t))];
						switch src {
							case null:
							case ImplicitReturn:
							case src: fl.push(kv("name", generateName(src)));
						}
						jobject(fl);
					case Value(src = FunctionArgument(_) | StructureField(_)):
						jobject([kv("name", generateName(src))]);
					case _: jnull;
				};
				jobject([
					kv("documentation", jopt(jstring, core.Ast.Ast.genDocTextOpt(CompletionItem.getDocumentation(hover.hitem)))),
					kv("range", generatePosAsRange(hover.hpos)),
					kv("item", CompletionItem.toJson(ctx, null, hover.hitem)),
					kv("expected", expected)
				]);
			case DisplayFields(r):
				fieldsToJson(ctx, r.fitems, r.fkind, r.fsubject);
		};
	}

	public static function sendJsonResultRaise<R>(com:CommonContext, json:JsonValue):R {
		var rh = com.requestScope.resultHandler;
		return CompilerOutput.sendResultRaise(rh, json);
	}

	public static function sendModuleSymbolsRaise<R>(com:CommonContext, s:JsonValue):R {
		DisplayPosition.displayPosition.reset();
		return sendJsonResultRaise(com, s);
	}

	public static function sendHoverRaise<R>(com:CommonContext, item:CompletionItemData, expected:Null<WithTypeValue>, p:Pos):R {
		DisplayPosition.displayPosition.reset();
		var ctx = Genjson.createFullConfig();
		return sendJsonResultRaise(com, toJson(ctx, DisplayHover({hitem: item, hpos: p, hexpected: expected})));
	}

	public static function sendSignaturesRaise<R>(com:CommonContext, sigs:Array<SignatureInfo>, isig:Int, iarg:Int, kind:SignatureKind):R {
		DisplayPosition.displayPosition.reset();
		var ctx = Genjson.createFullConfig();
		function fsig(s:SignatureInfo):JsonValue {
			var fl = CompletionType.generateFunction_(ctx, s.sig.ctf);
			if (s.doc != null) fl.unshift(kv("documentation", jstring(core.Ast.Ast.genDocText(s.doc))));
			return jobject(fl);
		}
		var sigkind = switch kind {
			case SKCall: 0;
			case SKArrayAccess: 1;
		};
		return sendJsonResultRaise(com, jobject([
			kv("activeSignature", jint(isig)),
			kv("activeParameter", jint(argIndex(sigs, isig, iarg))),
			kv("signatures", jlist(fsig, sigs)),
			kv("kind", jint(sigkind))
		]));
	}

	public static function sendPositionsRaise<R>(com:CommonContext, pl:Array<Pos>):R {
		DisplayPosition.displayPosition.reset();
		return sendJsonResultRaise(com, jarray(pl.map(generatePosAsLocation)));
	}

	public static function sendPackageRaise<R>(com:CommonContext, sl:Array<String>):R {
		DisplayPosition.displayPosition.reset();
		return sendJsonResultRaise(com, jarray(sl.map(jstring)));
	}

	public static function sendNoResultRaise<R>(com:CommonContext):R {
		var rh = com.requestScope.resultHandler;
		return switch com.display.dmsKind {
			case DMDefault: CompilerOutput.sendErrorRaise(rh, [jstring("No completion point")]);
			case _: CompilerOutput.sendResultRaise(rh, jnull);
		};
	}
}
