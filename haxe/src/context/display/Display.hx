package context.display;

import core.Ast.Expr;
import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.display.DisplayPosition;
import context.Common;
import context.Typecore;
import context.Typecore.Typer;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;

class Display {
	public static function mergeCoreDoc(ctx:Typer, mtype:ModuleType):Void {
		DisplayPosition.displayPosition.runOutside(function() {
			Typecore.mergeCoreDoc(ctx, mtype);
			return null;
		});
	}

	public static function parseModule_(com:CommonContext, m:GlobalTypePath, p:Pos):typing.TypeloadParse.SourceModuleParts {
		return DisplayPosition.displayPosition.runOutside(function() return typing.TypeloadParse.parseModule_(com, m, p));
	}

	public static function parseModule(ctx:Typer, m:GlobalTypePath, p:Pos):typing.TypeloadParse.SourceModuleResult {
		return DisplayPosition.displayPosition.runOutside(function() return typing.TypeloadParse.parseModule(ctx.com, m, p));
	}

	public static function preprocessExpr(com:CommonContext, e:Expr):Expr return switch com.display.dmsKind {
		case DMDefinition | DMTypeDefinition | DMUsage(_) | DMImplementation | DMHover | DMDefault: ExprPreprocessing.findBeforePos(com.partScope.parserState.wasAutoTriggered,
				com.display.dmsKind, e);
		case DMSignature: ExprPreprocessing.findDisplayCall(com.partScope.parserState.wasAutoTriggered, e);
		case _: e;
	};

	// port: OCaml's polymorphic comparison of `(int,string)` sort keys.
	public static function compareSortIndex(a:{i:Int, s:String}, b:{i:Int, s:String}):Int {
		if (a.i != b.i) return a.i < b.i ? -1 : 1;
		return compareStrings(a.s, b.s);
	}

	// port: OCaml's `compare` on strings: byte-wise on the UTF-8 encoding.
	public static function compareStrings(a:String, b:String):Int return core.ds.Key.compareStrings(a, b);

	public static function sortFields(l:Array<CompletionItemData>, withType:WithTypeValue, tk:ToplevelKind):Array<CompletionItemData> {
		var p = switch tk {
			case TKExpr(p) | TKField(p): p;
			case _: null;
		};
		var expectedName = WithTypeTools.getExpectedName(withType);
		var l = l.map(ci -> {item: ci, i: CompletionItem.getSortIndex(tk, ci, p == null ? Globals.nullPos : p, expectedName)});
		function sort(l:Array<{item:CompletionItemData, i:{i2:Int, i1:{i:Int, s:String}}}>):Array<CompletionItemData> {
			haxe.ds.ArraySort.sort(l, function(a, b) {
				if (a.i.i2 != b.i.i2) return a.i.i2 < b.i.i2 ? -1 : 1;
				return compareSortIndex(a.i.i1, b.i.i1);
			});
			return l.map(x -> x.item);
		}
		// This isn't technically accurate, but I don't think it matters.
		function dynamifyTypeParams(t:T):T return switch follow(t) {
			case TInst({clKind: KTypeParameter(_)}, _): mkMono();
			case _: core.TFunctions.map(dynamifyTypeParams, t);
		};
		var l = switch withType {
			case WithType(t, _) if (!follow(t).match(TMono(_))):
				function comp(item:CompletionItemData):Int {
					if (item.ciType == null) return 9;
					var t_ = item.ciType.t;
					// For enum constructors, we consider the return type of the constructor function
					// so it has the same priority as argument-less constructors.
					var t_ = switch [item.ciKind, follow(t_)] {
						case [ITEnumField(_), TFun(s)]: s.ret;
						case _: t_;
					};
					var t_ = dynamifyTypeParams(t_);
					if (core.TUnification.typeIseq(t_, t)) return 0; // equal types - perfect
					if (t_ == tDynamic) return 5; // dynamic isn't good, but better than incompatible
					try {
						core.TUnification.unify(t_, t);
						return 1; // assignable - great
					} catch (_:core.TUnification.Unify_error) {
						return switch follow(t_) {
							case TFun(s):
								if (core.TUnification.typeIseq(s.ret, t)) 2; // function returns our exact type - alright
								else try {
									core.TUnification.unify(s.ret, t);
									3; // function returns compatible type - okay
								} catch (_:core.TUnification.Unify_error) 7; // incompatible function - useless
							case _:
								6; // incompatible type - probably useless
						};
					}
				}
				var l = l.map(x -> {item: x.item, i: {i2: comp(x.item), i1: x.i}});
				sort(l);
			case _:
				sort(l.map(x -> {item: x.item, i: {i2: 0, i1: x.i}}));
		};
		return l;
	}

	public static function getImportStatus(ctx:Typer, path:GlobalTypePath):ImportStatus {
		try {
			var mt_ = ctx.g.doLoadTypeDef(ctx, Globals.nullPos, core.Ast.Ast.mkTypePath([], path.name));
			return compiler.CompilationCache.pathEq(path, tInfos(mt_).mtPath) ? Imported : Shadowed;
		} catch (_:Dynamic) {
			return Unimported;
		}
	}
}

// port: Display.ReferencePosition
class ReferencePosition {
	static var referencePosition:{name:String, pos:Pos, kind:Symbol} = {name: "", pos: Globals.nullPos, kind: SKOther};

	public static function set(name:String, p:Pos, k:Symbol):Void {
		var p:Pos = if (p.pfile == Globals.nullPos.pfile && p.pmin == Globals.nullPos.pmin && p.pmax == Globals.nullPos.pmax) p else
			{pfile: core.Path.getFullPath(p.pfile), pmin: p.pmin, pmax: p.pmax};
		referencePosition = {name: name, pos: p, kind: k};
	}

	public static function get():{name:String, pos:Pos, kind:Symbol}
		return referencePosition;

	public static function reset():Void referencePosition = {name: "", pos: Globals.nullPos, kind: SKOther};
}
