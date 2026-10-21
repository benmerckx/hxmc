package context.display;

import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import compiler.CompilationCache;
import context.Common;
import context.display.DeprecationCheck.DeprecationContext;
import core.Ast;
import core.Message;
import core.DisplayTypes;
import core.TType;
import core.ds.VectorTools.vector;

class Diagnostics {
	public static function addReplaceableCode(ctx:DiagnosticsContext, reason:String, replacement:String, displayRange:Pos,
			replaceRange:Pos):Void {
		ctx.replaceableCode.unshift({
			reason: reason,
			replacement: replacement,
			displayRange: displayRange,
			replaceRange: replaceRange
		});
	}

	public static function errorInDiagnosticsRun(com:CommonContext, p:Pos):Bool {
		var b = DiagnosticsPrinter.isDiagnosticsFile(com, com.partScope.fileKeys.get(p.pfile));
		if (b) com.partScope.hasError = true;
		return b;
	}

	public static function findUnusedVariables(com:DiagnosticsContext, e:TExpr):Void {
		var vars = new OcamlHashtbl<Int, {v:TVar, p:Pos, replacement:String}>(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
		var pminMap = new OcamlHashtbl<Int, TVar>(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
		function loop(e:TExpr):Void {
			switch e.eexpr {
				case TVar(v = {vKind: VUser(origin)}, eo) if (v.vName != "_" && !hasVarFlag(v, VUsedByTyper)):
					pminMap.add(e.epos.pmin, v);
					var r = if (eo != null && origin != TVOPatternVariable) {
						loop(eo);
						{p: ({pfile: e.epos.pfile, pmin: e.epos.pmin, pmax: eo.epos.pmin} : Pos), replacement: ""};
					} else {p: e.epos, replacement: "_"};
					vars.replace(v.vId, {v: v, p: r.p, replacement: r.replacement});
				case TLocal(v = {vKind: VUser(_)}):
					vars.remove(v.vId);
				case _:
					core.Texpr.iter(loop, e);
			}
		}
		loop(e);
		vars.iter(function(_, r) {
			var p = pminMap.findAll(r.p.pmin).length == 1 ? r.p : Globals.nullPos;
			addReplaceableCode(com, "Unused variable", r.replacement, r.v.vPos, p);
		});
	}

	public static function checkOtherThings(com:CommonContext, e:TExpr):Void {
		var hadEffect = false;
		function noEffect(p:Pos):Void {
			Common.addDiagnosticsMessage(com, "This code has no effect", p, MKWarning(WPointlessCode, []));
		}
		function pointlessCompound(s:String, p:Pos):Void {
			Common.addDiagnosticsMessage(com, 'This $s has no effect, but some of its sub-expressions do', p,
				MKWarning(WPointlessCode, []));
		}
		var loop:Bool->TExpr->Void = null;
		function compound(s:String, el:haxe.ds.Vector<TExpr>, p:Pos):Void {
			var old = hadEffect;
			hadEffect = false;
			for (e in el) loop(true, e);
			if (!hadEffect) noEffect(p)
			else pointlessCompound(s, p);
			hadEffect = old;
		}
		loop = function(inValue:Bool, e:TExpr):Void {
			switch e.eexpr {
				case TBlock(el):
					function loop2(i:Int):Void {
						if (i >= el.length) return;
						if (i == el.length - 1) loop(inValue, el[i])
						else {
							loop(false, el[i]);
							loop2(i + 1);
						}
					}
					loop2(0);
				case TMeta({meta: m}, _) if (core.Meta.metaEq(core.MetaList.StrictMeta.Extern, m)):
					// This is so something like `[inlineFunc()]` is not reported.
					hadEffect = true;
				case TConst(_) | TLocal({vKind: VUser(_)}) | TTypeExpr(_) | TFunction(_) | TIdent(_) if (!inValue):
					noEffect(e.epos);
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TEnumParameter(_) | TEnumIndex(_) | TVar(_) | TIdent(_):
				case TField(_, fa) if (context.PurityState.PurityStateTools.isExplicitlyImpure(fa)):
				case TFunction(tf):
					loop(false, tf.tfExpr);
				case TCall({eexpr: TField(e1, fa)}, el) if (!inValue && context.PurityState.PurityStateTools.isPureFieldAccess(fa)):
					compound("call", el, e.epos);
				case TNew(_) | TCall(_) | TBinop(OpAssignOp(_) | OpAssign, _, _) | TUnop(Increment | Decrement, _, _) | TReturn(_) |
					TBreak | TContinue | TThrow(_) | TCast(_, _ != null => true) | TIf(_) | TTry(_) | TSwitch(_) | TWhile(_):
					hadEffect = true;
					core.Texpr.iter(loop.bind(true), e);
				case TParenthesis(e1) | TMeta(_, e1):
					loop(inValue, e1);
				case TArray(_) | TCast(_, null) | TBinop(_) | TUnop(_) | TField(_) | TArrayDecl(_) | TObjectDecl(_) if (inValue):
					core.Texpr.iter(loop.bind(true), e);
				case TArray(e1, e2):
					compound("array access", vector(e1, e2), e.epos);
				case TCast(e1, null):
					compound("cast", vector(e1), e.epos);
				case TBinop(op, e1, e2):
					compound("'" + Ast.sBinop(op) + "' operator", vector(e1, e2), e.epos);
				case TUnop(op, _, e1):
					compound("'" + Ast.sUnop(op) + "' operator", vector(e1), e.epos);
				case TField(e1, _):
					compound("field access", vector(e1), e.epos);
				case TArrayDecl(el):
					compound("array declaration", el, e.epos);
				case TObjectDecl(fl):
					compound("object declaration", fl.map(f -> f.expr), e.epos);
				case _:
					throw new core.Globals.InternalCompilerError("diagnostics.ml: unexpected expression", "");
			}
		};
		loop(true, e);
	}

	public static function prepareField(dctx:DiagnosticsContext, dectx:DeprecationContext, com:CommonContext, cf:TClassField):Void {
		if (cf.cfExpr == null) return;
		var e = cf.cfExpr;
		findUnusedVariables(dctx, e);
		checkOtherThings(com, e);
		DeprecationCheck.runOnExpr({
			com: dectx.com,
			classMeta: dectx.classMeta,
			fieldMeta: cf.cfMeta,
			curmod: dectx.curmod
		}, e);
	}

	public static function collectDiagnostics(dctx:DiagnosticsContext, com:CommonContext):Void {
		var dectx = DeprecationCheck.createContext(com);
		for (t in com.types) switch t {
			case TClassDecl(c) if (DiagnosticsPrinter.isDiagnosticsFile(com, com.partScope.fileKeys.get(c.clPos.pfile))):
				var dectx:DeprecationContext = {
					com: dectx.com,
					classMeta: c.clMeta,
					fieldMeta: dectx.fieldMeta,
					curmod: dectx.curmod
				};
				for (cf in c.clOrderedFields) prepareField(dctx, dectx, com, cf);
				for (cf in c.clOrderedStatics) prepareField(dctx, dectx, com, cf);
				if (c.clConstructor != null) prepareField(dctx, dectx, com, c.clConstructor);
			case _:
		}
		function handleDeadBlocks(com:CommonContext):Void {
			if (com.cache != null) {
				var cc:ContextCache = com.cache;
				var displayDefines = Common.adaptDefinesToDisplayContext(com.defines);
				function isTrue(defines:core.Define.DefineContext,
						e:Expr):Bool return syntax.ParserEntry.isTrue(syntax.ParserEntry.eval(defines, e));
				cc.getFiles().iter(function(fileKey, cfile) {
					if (core.display.DisplayPosition.displayPosition.isInFile(com.partScope.fileKeys.get(cfile.cFilePath.file))) {
						var deadBlocks = cfile.cPdi.pdDeadBlocks;
						var deadBlocks = deadBlocks.filter(b -> !isTrue(displayDefines, b.expr));
						var deadBlocks2 = dctx.deadBlocks.findOpt(fileKey);
						if (deadBlocks2 != null) {
							// Intersect
							var deadBlocks2 = deadBlocks2.filter(b2 -> core.ds.ArrayTools.exists(deadBlocks,
								b -> b.pos.pfile == b2.pos.pfile && b.pos.pmin == b2.pos.pmin && b.pos.pmax == b2.pos.pmax));
							dctx.deadBlocks.replace(fileKey, deadBlocks2);
						} else {
							dctx.deadBlocks.add(fileKey, deadBlocks);
						}
					}
				});
			}
		}
		handleDeadBlocks(com);
	}

	public static function prepare(com:CommonContext):DiagnosticsContext {
		var dctx:DiagnosticsContext = {
			replaceableCode: [],
			importPositions: new Map(),
			deadBlocks: new OcamlHashtbl(OcamlHash.hashString, (a, b) -> a == b, 0),
			messages: []
		};
		if (!core.ds.ArrayTools.exists(com.partScope.messages,
			cm -> core.Message.Message.severity(cm) == Error)) collectDiagnostics(dctx, com);
		function processModules(com:CommonContext):Void {
			for (m in com.modules) {
				ImportHandling.iterImportPositions(m.mExtra.mDisplay.mImportPositions, function(key, p, b) {
					var e = dctx.importPositions.get(key);
					if (e == null) dctx.importPositions.set(key, {pos: p, used: {value: b}})
					else if (b) e.used.value = true;
				});
			}
		}
		processModules(com);
		var macroCom = com.getMacros();
		if (macroCom != null) processModules(macroCom);
		// We do this at the end because some of the prepare functions might add information to the common context.
		dctx.messages = com.partScope.messages;
		return dctx;
	}

	public static function print(com:CommonContext):String {
		var dctx = prepare(com);
		return core.Json.stringOfJson(DiagnosticsPrinter.jsonOfDiagnostics(com, dctx));
	}

	public static function run(com:CommonContext):DiagnosticsContext {
		var dctx = prepare(com);
		return dctx;
	}
}
