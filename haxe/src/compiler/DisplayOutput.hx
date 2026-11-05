package compiler;

import core.Ast.Keyword;
import core.Globals;
import core.Globals.Pos;
import core.display.DisplayPosition;
import core.json.Genjson;
import compiler.io.CompilerOutput;
import context.Common;
import context.display.DisplayException;
import context.display.DisplayJson;
import context.display.DisplayResult;
import syntax.Parser;
import core.DisplayTypes;
import core.display.CompletionItem;

class DisplayOutput {
	// Mode processing
	public static function handleSyntaxCompletion(com:CommonContext, kind:SyntaxCompletion, subj:CompletionSubject):Void {
		var r:{l:Array<Keyword>, kind:CompletionResultKindValue} = switch kind {
			case SCClassRelation:
				{l: [Extends, Implements], kind: CRTypeRelation};
			case SCInterfaceRelation:
				{l: [Extends], kind: CRTypeRelation};
			case SCComment:
				{l: [], kind: CRTypeRelation};
			case SCTypeDecl(mode):
				var inImportHx = haxe.io.Path.withoutDirectory(subj.sInsertPos.pfile) == "import.hx";
				var l:Array<Keyword> = inImportHx ? [] : [Private, Extern, Class, Interface, Enum, Abstract, Typedef, Final];
				var l:Array<Keyword> = switch mode {
					case TCBeforePackage: [Package, Import, Using].concat(l);
					case TCAfterImport: [Import, Using].concat(l);
					case TCAfterType: l;
				};
				{l: l, kind: CRTypeDecl};
			case SCAfterTypeFlag(flags):
				var l:Array<Keyword> = [Class, Interface];
				var l = flags.contains(DPrivate) ? l : [Private].concat(l);
				var l = flags.contains(DExtern) ? l : [Extern].concat(l);
				var l = flags.contains(DFinal) ? l : ([Final, Enum, Abstract, Typedef] : Array<Keyword>).concat(l);
				{l: l, kind: CRTypeDecl};
		};
		switch r.l {
			case []:
			case _:
				var l = r.l.map(CompletionItem.makeCiKeyword);
				CompilerOutput.sendDisplayResultRaise(com, DRFields({fitems: l, fkind: r.kind, fsubject: subj}, false));
		}
	}

	public static function handleDisplayExceptionJson(com:CommonContext, dex:DisplayExceptionKind, rh:ResultHandler):Void {
		DisplayPosition.displayPosition.reset();
		// port: as a value (DisplayResult); its JSON: DisplayException.resultToJson
		rh.sendDisplayResultRaise(com, switch dex {
			case DisplayHover(hover): DRHover(hover);
			case DisplayFields(fields): DRFields(fields, true);
		});
	}

	public static function handleDisplayException(com:CommonContext,
			dex:DisplayExceptionKind):Void handleDisplayExceptionJson(com, dex, com.requestScope.resultHandler);

	public static function handleTypePathException(com:CommonContext, p:Array<String>, c:Null<{name:String, isSub:Bool}>, isImport:Bool,
			pos:Pos):Void {
		var fields = try {
			if (c == null) context.display.DisplayPath.TypePathHandler.completeTypePath(com, p)
			else {
				var ctx = typing.TyperEntry.create(com, null);
				context.display.DisplayPath.TypePathHandler.completeTypePathInner(ctx, p, c.name, c.isSub, isImport);
			}
		} catch (err:core.Error.FatalError) {
			com.errorExt(err.error);
			null;
		};
		if (fields != null) {
			var path:GlobalTypePath = if (p.length > 0) {pack: p.slice(0, p.length - 1), name: p[p.length - 1]} else {pack: [], name: ""};
			var kind = CRField(CompletionItem.makeCiModule(path), pos, null, null);
			CompilerOutput.sendDisplayResultRaise(com, DRFields({fitems: fields, fkind: kind, fsubject: DisplayTypes.makeSubject(null, pos)}, false));
		}
	}

	public static function emitDiagnostics(com:CommonContext):Void {
		var dctx = context.display.Diagnostics.run(com);
		DisplayPosition.displayPosition.reset();
		CompilerOutput.sendDisplayResultRaise(com, DRDiagnostics(dctx));
	}

	public static function emitStatistics(tctx:CommonContext):Void {
		var stats = context.display.Statistics.collectStatistics(tctx, [SFFile(DisplayPosition.displayPosition.get().pfile)], true);
		DisplayPosition.displayPosition.reset();
		CompilerOutput.sendDisplayResultRaise(tctx, DRStatistics(stats));
	}
}
