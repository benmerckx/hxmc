package context.display;

import core.Ast.Metadata;
import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.display.DisplayPosition;
import context.Common;
import context.Typecore;
import context.Typecore.Typer;
import context.TyperPass;
import context.display.Display.ReferencePosition;
import core.Meta;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;

class DisplayEmitter {
	public static function symbolOfModuleType(mt:ModuleType):Symbol return switch mt {
		case TClassDecl(c): SKClass(c);
		case TEnumDecl(en): SKEnum(en);
		case TTypeDecl(td): SKTypedef(td);
		case TAbstractDecl(a): SKAbstract(a);
	};

	public static function displayAlias(ctx:Typer, name:String, t:T, p:Pos):Void {
		switch ctx.com.display.dmsKind {
			case DMDefinition | DMTypeDefinition:
				DisplayException.sendPositionsRaise(ctx.com, [p]);
			case DMUsage(_) | DMImplementation:
				ReferencePosition.set(name, p, SKOther);
			case DMHover:
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), t);
				DisplayException.raiseHover(CompletionItem.makeCiLiteral(name, {t: t, ct: ct}), null, p);
			case _:
		}
	}

	public static function displayModuleType(ctx:Typer, mt:ModuleType, p:Pos):Void {
		switch ctx.com.display.dmsKind {
			case DMDefinition | DMTypeDefinition:
				switch mt {
					case TClassDecl(c) if (Meta.has(core.MetaList.StrictMeta.CoreApi, c.clMeta)):
						var c_ = ctx.g.doLoadCoreClass(ctx, c);
						DisplayException.sendPositionsRaise(ctx.com, [c.clNamePos, c_.clNamePos]);
					case _:
						DisplayException.sendPositionsRaise(ctx.com, [tInfos(mt).mtNamePos]);
				}
			case DMUsage(_) | DMImplementation:
				var infos = tInfos(mt);
				ReferencePosition.set(infos.mtPath.name, infos.mtNamePos, symbolOfModuleType(mt));
			case DMHover:
				var t = typeOfModuleType(mt);
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), t);
				DisplayException.raiseHover(CompletionItem.makeCiType(CompletionModuleType.ofModuleType(mt), Imported, {t: t, ct: ct}),
					null, p);
			case DMDefault:
				DisplayToplevel.collectAndRaise(ctx, TKType, WithTypeTools.value, CRTypeHint, Globals.sTypePath(tInfos(mt).mtPath), p, p);
			case _:
		}
	}

	public static function displayType(ctx:Typer, t:T, p:Pos):Void {
		var dm = ctx.com.display;
		try {
			displayModuleType(ctx, moduleTypeOfType(t), p);
		} catch (_:core.ds.Exit) {
			switch [follow(t), follow(ctx.g.tDynamicDef)] {
				case [_, TDynamic(_)]: // sanity check in case it's still t_dynamic
				case [TDynamic(_), _]:
					displayType(ctx, ctx.g.tDynamicDef, p);
				case _:
					switch dm.dmsKind {
						case DMHover:
							var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), t);
							var ci = CompletionItem.makeCiExpr(mk(TConst(TNull), t, p), {t: t, ct: ct});
							DisplayException.raiseHover(ci, null, p);
						case _:
					}
			}
		}
	}

	public static function checkDisplayType(ctx:Typer, t:T, ptp:core.Ast.PlacedTypePath):Void {
		function addTypeHint():Void {
			// port: appended (typeHints is the OCaml list reversed; see Typecore)
			ctx.g.typeHints.push({display: ctx.m.curmod.mExtra.mDisplay, pos: ptp.posFull, type: t});
		}
		function maybeDisplayType():Void {
			if (ctx.m.isDisplayFile && DisplayPosition.displayPosition.enclosedIn(ptp.posFull)) displayType(ctx, t, ptp.posPath);
		}
		addTypeHint();
		maybeDisplayType();
	}

	public static function raisePositionOfType<R>(ctx:Typer, t:T):R {
		var mt = {
			function followNull(t:T):T {
				return switch t {
					case TMono(r): r.tmType == null ? DisplayException.sendPositionsRaise(ctx.com,
							[Globals.nullPos]) : followNull(r.tmType);
					case TLazy(f): followNull(lazyType(f));
					case TAbstract({aPath: {pack: [], name: "Null"}}, [t]): followNull(t);
					case TDynamic(_): ctx.g.tDynamicDef;
					case _: t;
				};
			}
			try {
				moduleTypeOfType(followNull(t));
			} catch (_:core.ds.Exit) {
				DisplayException.sendPositionsRaise(ctx.com, [Globals.nullPos]);
			}
		};
		return DisplayException.sendPositionsRaise(ctx.com, [tInfos(mt).mtNamePos]);
	}

	public static function displayVariable(ctx:Typer, v:TVar, p:Pos):Void {
		switch ctx.com.display.dmsKind {
			case DMDefinition:
				DisplayException.sendPositionsRaise(ctx.com, [v.vPos]);
			case DMTypeDefinition:
				raisePositionOfType(ctx, v.vType);
			case DMUsage(_):
				ReferencePosition.set(v.vName, v.vPos, SKVariable(v));
			case DMHover:
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), core.Ast.Ast.getValueMeta(v.vMeta), v.vType);
				DisplayException.raiseHover(CompletionItem.makeCiLocal(v, {t: v.vType, ct: ct}), null, p);
			case _:
		}
	}

	public static function displayField(ctx:Typer, origin:ClassFieldOrigin, scope:ClassFieldScope, cf:TClassField, p:Pos):Void {
		switch ctx.com.display.dmsKind {
			case DMDefinition:
				DisplayException.sendPositionsRaise(ctx.com, [cf.cfNamePos]);
			case DMTypeDefinition:
				raisePositionOfType(ctx, cf.cfType);
			case DMUsage(_) | DMImplementation:
				var r = switch [cf.cfName, origin] {
					case ["new", Self(TClassDecl(c)) | Parent(TClassDecl(c))]:
						// For constructors, we care about the class name so we don't end up looking for "new".
						{name: c.clPath.name, kind: SKConstructor(cf)};
					case [_, Self(TClassDecl(c)) | Parent(TClassDecl(c))]:
						{name: cf.cfName, kind: SKField(cf, c)};
					case _:
						{name: cf.cfName, kind: SKField(cf, null)};
				};
				ReferencePosition.set(r.name, cf.cfNamePos, r.kind);
			case DMHover:
				var cf = if (hasClassFieldFlag(cf, CfImpl)) Typecore.prepareUsingField(cf) else cf;
				var cf = switch [origin, scope, follow(cf.cfType)] {
					case [Self(TClassDecl(c)), CFSConstructor, TFun(s)]:
						var cf2 = cf.clone();
						cf2.cfType = TFun({args: s.args, ret: TInst(c, extractParamTypes(c.clParams))});
						cf2;
					case _: cf;
				};
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), core.Ast.Ast.getValueMeta(cf.cfMeta), cf.cfType);
				DisplayException.raiseHover(CompletionItem.makeCiClassField(CompletionClassField.make(cf, scope, origin, true),
					{t: cf.cfType, ct: ct}), null, p);
			case _:
		}
	}

	public static function maybeDisplayField(ctx:Typer, origin:ClassFieldOrigin, scope:ClassFieldScope, cf:TClassField, p:Pos):Void {
		if (DisplayPosition.displayPosition.enclosedIn(p)) displayField(ctx, origin, scope, cf, p);
	}

	public static function displayEnumField(ctx:Typer, en:TEnum, ef:TEnumField, p:Pos):Void {
		switch ctx.com.display.dmsKind {
			case DMDefinition:
				DisplayException.sendPositionsRaise(ctx.com, [ef.efNamePos]);
			case DMTypeDefinition:
				raisePositionOfType(ctx, ef.efType);
			case DMUsage(_):
				ReferencePosition.set(ef.efName, ef.efNamePos, SKEnumField(ef));
			case DMHover:
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), ef.efType);
				DisplayException.raiseHover(CompletionItem.makeCiEnumField(CompletionEnumField.make(ef, Self(TEnumDecl(en)), true),
					{t: ef.efType, ct: ct}), null,
					p);
			case _:
		}
	}

	public static function displayMeta(com:CommonContext, meta:core.MetaList.StrictMeta, p:Pos):Void {
		switch com.display.dmsKind {
			case DMHover:
				switch meta {
					case Custom(_) | Dollar(_):
					case _:
						DisplayException.raiseHover(CompletionItem.makeCiMetadata(meta), null, p);
				}
			case DMDefault:
				var all = Meta.getAll(com.userMetas);
				var all = all.map(CompletionItem.makeCiMetadata);
				var subject = meta == HxCompletion ? null : Meta.toString(meta);
				DisplayException.raiseFields(all, CRMetadata, DisplayTypes.makeSubject(subject, p));
			case _:
		}
	}

	public static function checkDisplayMetadata(ctx:Typer, meta:Metadata):Void {
		for (m in meta) {
			if (DisplayPosition.displayPosition.enclosedIn(m.pos)) displayMeta(ctx.com, m.meta, m.pos);
			for (e in m.exprs) {
				if (DisplayPosition.displayPosition.enclosedIn(e.pos)) {
					var e = Display.preprocessExpr(ctx.com, e);
					Typecore.delay(ctx.g, PTypeField, function() Typecore.typeExpr(ctx, e, WithTypeTools.value));
				}
			}
		}
	}

	public static function checkFieldModifiers(ctx:Typer, c:TClass, cf:TClassField, override_:Null<Pos>,
			displayModifier:Null<core.Ast.PlacedAccess>):Void {
		if (override_ != null && DisplayPosition.displayPosition.enclosedIn(override_) && ctx.com.display.dmsKind == DMDefinition) {
			if (c.clSuper != null) {
				var r = rawClassField(function(cf) return cf.cfType, c.clSuper.cls, c.clSuper.params, cf.cfName);
				displayField(ctx, Parent(TClassDecl(c.clSuper.cls)), CFSMember, r.field, override_);
			}
		} else if (override_ != null && ctx.com.display.dmsKind == DMDefault) {
			// port: upstream removes from the map it got, persistently; the map is new.
			var missingFields = core.TOther.TClassTools.getAllSuperFields(c);
			for (cf in c.clOrderedFields) missingFields.remove(cf.cfName);
			var l = missingFields.fold(function(e:{cls:TClass, field:TClassField}, fields:Array<CompletionItemData>) {
				var origin = Parent(TClassDecl(e.cls));
				follow(e.field.cfType);
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), core.Ast.Ast.getValueMeta(e.field.cfMeta),
					e.field.cfType);
				fields.unshift(CompletionItem.makeCiClassField(CompletionClassField.make(e.field, CFSMember, origin, true),
					{t: e.field.cfType, ct: ct}));
				return fields;
			}, []);
			var l = Display.sortFields(l, NoValue, TKOverride);
			DisplayException.raiseFields(l, CROverride, DisplayTypes.makeSubject(cf.cfName, cf.cfNamePos));
		}
	}
}
