/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

package context.display;

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.ds.PMap;
import context.Common;
import context.Typecore;
import context.Typecore.Typer;
import context.Typecore.AccessMode;
import haxe.ds.StringMap;
import core.MetaList.StrictMeta as MetaTag;
import core.Ast;
import core.Meta;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class DisplayFields {
	public static function getSubmoduleFields(ctx:Typer, path:GlobalTypePath):Array<CompletionItemData> {
		var m = ctx.com.moduleLut.find(path);
		var tl = m.mTypes.filter(t -> !compiler.CompilationCache.pathEq(path, tInfos(t).mtPath) && !tInfos(t).mtPrivate);
		var tl = tl.map(mt -> CompletionItem.makeCiType(CompletionModuleType.ofModuleType(mt), Imported, null));
		return tl;
	}

	static function makeClassFieldItem(ctx:Typer, cf:TClassField, scope:ClassFieldScope, origin:ClassFieldOrigin,
			?make:CompletionClassField->TPair->CompletionItemData):CompletionItemData {
		var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(cf.cfMeta), cf.cfType);
		return (make == null ? CompletionItem.makeCiClassField : make)(CompletionClassField.make(cf, scope, origin,
			true), {t: cf.cfType, ct: ct});
	}

	public static function collectStaticExtensions(ctx:Typer, blockedItems:StringMap<Bool>, items:StringMap<CompletionItemData>, e:TExpr,
			p:Pos):StringMap<CompletionItemData> {
		function optType(t:T):T {
			return switch t {
				case TLazy(f):
					ctx.g.returnPartialType = true;
					var t = lazyType(f);
					ctx.g.returnPartialType = false;
					t;
				case _:
					t;
			};
		}
		function dup(t:T):T return core.TFunctions.map(dup, t);
		function handleField_(c:TClass, f:TClassField, acc:StringMap<CompletionItemData>):StringMap<CompletionItemData> {
			var f = {
				var f2 = f.clone();
				f2.cfType = optType(f.cfType);
				f2;
			};
			var monos = f.cfParams.map(_ -> Typecore.spawnMonomorph(ctx, p));
			function map(t:T):T return applyParams(f.cfParams, monos, t);
			var r = switch follow(map(f.cfType)) {
				case TFun(s) if (s.args.length > 0):
					var t = switch s.args[0].type {
						case TType({tPath: {pack: ["haxe", "macro"], name: "ExprOf"}}, [t]): t;
						case t: t;
					};
					{t: t, args: s.args.slice(1), ret: s.ret};
				case _:
					null;
			};
			if (r == null) return acc;
			var t = r.t, args = r.args, ret = r.ret;
			try {
				var e2 = e.clone();
				e2.etype = dup(e.etype);
				var e = typing.TyperBase.unifyStaticExtension(ctx, e2, t, p);
				for (i in 0...monos.length) {
					var m = monos[i], ttp = f.cfParams[i];
					switch getConstraints(ttp) {
						case []:
						case constr:
							for (tc in constr) Typecore.unifyRaise(m, map(tc), e.epos);
					}
				}
				if (!Typecore.canAccess(ctx, c, f, true) || (follow(e.etype) == tDynamic && follow(t) != tDynamic)) return acc;
				var f = Typecore.prepareUsingField(f);
				var f = {
					var f2 = f.clone();
					f2.cfParams = vector();
					f2.cfFlags = setFlag(f.cfFlags, intOfClassFieldFlag(CfPublic));
					f2.cfType = TFun({args: args, ret: ret});
					f2;
				};
				var decl = switch c.clKind {
					case KAbstractImpl(a): TAbstractDecl(a);
					case _: TClassDecl(c);
				};
				var origin = StaticExtension(decl);
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(f.cfMeta), f.cfType);
				var item = CompletionItem.makeCiClassField(CompletionClassField.make(f, CFSMember, origin, true), {t: f.cfType, ct: ct});
				return PMap.add(f.cfName, item, acc);
			} catch (err:core.Error.TypingError) {
				switch err.error.errMessage {
					case Unify(_):
						return acc;
					case _:
						throw err;
				}
			} catch (_:core.TUnification.Unify_error) {
				return acc;
			}
		}
		function handleField(c:TClass, cf:TClassField, acc:StringMap<CompletionItemData>):StringMap<CompletionItemData> {
			if (blockedItems.exists(cf.cfName)) return acc;
			return handleField_(c, cf, acc);
		}
		function loop(acc:StringMap<CompletionItemData>, l:Array<{cls:TClass, pos:Pos}>):StringMap<CompletionItemData> {
			for (u in l) {
				var c = u.cls;
				for (f in c.clOrderedStatics) {
					if (Meta.has(MetaTag.NoUsing, f.cfMeta)
						|| Meta.has(MetaTag.NoCompletion, f.cfMeta)
						|| hasClassFieldFlag(f, CfImpl)
						|| PMap.mem(f.cfName, acc)) {} else {
						for (f in [f].concat(f.cfOverloads)) acc = handleField(c, f, acc);
					}
				}
			}
			return acc;
		}
		return switch follow(e.etype) {
			case TMono(_):
				items;
			case _:
				var items = loop(items, ctx.m.moduleUsing);
				var items = loop(items, ctx.g.globalUsing);
				function loopModuleUsing(items:StringMap<CompletionItemData>, t:T):StringMap<CompletionItemData> {
					return switch followWithoutType(t) {
						case TInst(c, _):
							loop(items, c.clUsing);
						case TEnum(en, _):
							loop(items, en.eUsing);
						case TType(td, tl):
							var items = loop(items, td.tUsing);
							loopModuleUsing(items, applyTypedef(td, tl));
						case TAbstract(a, _):
							loop(items, a.aUsing);
						case TAnon(an):
							switch an.aStatus {
								case ClassStatics(c): loop(items, c.clUsing);
								case EnumStatics(en): loop(items, en.eUsing);
								case AbstractStatics(a): loop(items, a.aUsing);
								case _: items;
							}
						case _:
							items;
					};
				}
				var items = loopModuleUsing(items, e.etype);
				items;
		};
	}

	public static function collect(ctx:Typer, eAst:Expr, e:TExpr, dk:DisplayKind, withType:WithTypeValue, p:Pos):Array<CompletionItemData> {
		function optArgs(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>,
				ret:T):T return TFun({args: args.map(a -> {name: a.name, optional: true, type: a.type}), ret: ret});
		function shouldAccess_(c:TClass, cf:TClassField, stat:Bool):Bool {
			if (Meta.has(MetaTag.NoCompletion, cf.cfMeta)) return false;
			if (c != ctx.c.curclass && !hasClassFieldFlag(cf, CfPublic) && cf.cfName.length > 4) {
				return switch cf.cfName.substr(0, 4) {
					case "get_" | "set_": false;
					case _: Typecore.canAccess(ctx, c, cf, stat);
				};
			}
			return (!stat || !hasClassFieldFlag(cf, CfImpl)) && Typecore.canAccess(ctx, c, cf, stat);
		}
		function makeClassField(origin:ClassFieldOrigin, cf:TClassField):CompletionItemData {
			var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(cf.cfMeta), cf.cfType);
			return CompletionItem.makeCiClassField(CompletionClassField.make(cf, CFSMember, origin, true), {t: cf.cfType, ct: ct});
		}
		var blockedItems = new StringMap<Bool>();
		function shouldAccess(c:TClass, cf:TClassField, stat:Bool):Bool {
			if (blockedItems.exists(cf.cfName)) return false;
			if (shouldAccess_(c, cf, stat)) return true;
			blockedItems.set(cf.cfName, true);
			return false;
		}
		function loop(items:StringMap<CompletionItemData>, t:T):StringMap<CompletionItemData> {
			function isNewItem(items:StringMap<CompletionItemData>, name:String):Bool return !PMap.mem(name, items);
			function browseInterfaces(c:TClass, acc:StringMap<CompletionItemData>):StringMap<CompletionItemData> {
				for (i in c.clImplements) {
					var c = i.cls;
					for (cf in c.clOrderedFields) {
						if (isNewItem(acc, cf.cfName)) {
							var origin = Parent(TClassDecl(c));
							var item = makeClassField(origin, cf);
							acc = PMap.add(cf.cfName, item, acc);
						}
					}
					for (i2 in c.clImplements) acc = browseInterfaces(i2.cls, acc);
				}
				return acc;
			}
			return switch follow(t) {
				case TMono(m):
					function foldConstraints(items:StringMap<CompletionItemData>, k:TMonoConstraintKind):StringMap<CompletionItemData> {
						return switch k {
							case CStructural(fields, isOpen):
								if (!isOpen) {
									core.TUnification.Monomorph.close(m);
									m.tmType == null ? items : loop(items, m.tmType);
								} else loop(items, mkAnon(Closed, fields));
							case CTypes([{type: t}]):
								loop(items, t);
							case CTypes(tl):
								items;
							case CUnknown:
								items;
							case CMixed(l):
								var items = items;
								for (k in l) items = foldConstraints(items, k);
								items;
						};
					}
					foldConstraints(items, core.TUnification.Monomorph.classifyDownConstraints(m));
				case TInst({clKind: KTypeParameter(ttp)}, _):
					// Type parameters can access the fields of their constraints
					var acc = items;
					for (t in getConstraints(ttp)) acc = loop(acc, t);
					acc;
				case TInst(c0, tl):
					// For classes, browse the hierarchy
					var fields = core.TOther.TClassTools.getAllFields(c0, tl);
					Display.mergeCoreDoc(ctx, TClassDecl(c0));
					var acc = PMap.foldi(function(k:String, e:{cls:TClass, field:TClassField}, acc:StringMap<CompletionItemData>) {
						var c = e.cls, cf = e.field;
						if (shouldAccess(c, cf, false) && isNewItem(acc, cf.cfName)) {
							var origin = c == c0 ? Self(TClassDecl(c)) : Parent(TClassDecl(c));
							var item = makeClassField(origin, cf);
							return PMap.add(k, item, acc);
						}
						return acc;
					}, fields, items);
					var acc = if (hasClassFlag(c0, CExtern) && Meta.has(MetaTag.LibType, c0.clMeta)) browseInterfaces(c0, acc) else acc;
					acc;
				case TEnum(_):
					var t = ctx.g.doLoadTypeDef(ctx, p, {
						tpackage: [],
						tname: "EnumValue",
						tsub: null,
						tparams: vector()
					});
					switch t {
						case TAbstractDecl(a = {aImpl: c}) if (c != null):
							var cf = c.clStatics.get("match");
							if (cf != null) {
								var item = makeClassField(Self(TAbstractDecl(a)), cf);
								PMap.add("match", item, items);
							} else items;
						case _:
							items;
					}
				case TAbstract(a = {aImpl: c}, tl) if (c != null):
					Display.mergeCoreDoc(ctx, TAbstractDecl(a));
					// Abstracts should show all their @:impl fields minus the constructor.
					var items = items;
					for (cf in c.clOrderedStatics) {
						if (hasClassFieldFlag(cf, CfImpl) && !hasClassFieldFlag(cf, CfEnum) && shouldAccess(c, cf, false)
							&& isNewItem(items, cf.cfName)) {
							var origin = Self(TAbstractDecl(a));
							var cf = Typecore.prepareUsingField(cf);
							var cf = if (tl.length == 0) cf else {
								var cf2 = cf.clone();
								cf2.cfType = applyParams(a.aParams, tl, cf.cfType);
								cf2;
							};
							var item = makeClassField(origin, cf);
							items = PMap.add(cf.cfName, item, items);
						}
					}
					try {
						// If there's a @:forward, get the fields of the underlying type and filter them.
						var m = Meta.get(MetaTag.Forward, a.aMeta);
						var sl = [];
						for (e in m.exprs) switch e.expr {
							case EConst(Ident(s) | String(s, _)): sl.push(s);
							case _:
						}
						var forwardedFields = loop(PMap.empty(), applyParams(a.aParams, tl, a.aThis));
						function abstractHasOwnField(fieldName:String):Bool return c.clFields.exists(fieldName)
							|| c.clStatics.exists(fieldName);
						PMap.foldi(function(name:String, item:CompletionItemData, acc:StringMap<CompletionItemData>) {
							if ((sl.length == 0 || sl.contains(name)) && isNewItem(acc, name)
								&& !abstractHasOwnField(name)) return PMap.add(name, item, acc);
							return acc;
						}, forwardedFields, items);
					} catch (_:core.ds.NotFound) {
						items;
					}
				case TAnon(an):
					// @:forwardStatics
					var items = switch an.aStatus {
						case ClassStatics({clKind: KAbstractImpl({aMeta: meta, aThis: aThis})}) if (Meta.has(MetaTag.ForwardStatics, meta)):
							switch follow(aThis) {
								case TInst(c, _):
									var items = items;
									for (cf in c.clOrderedStatics) {
										if (shouldAccess(c, cf, true) && isNewItem(items, cf.cfName)) {
											var origin = Self(TClassDecl(c));
											var item = makeClassField(origin, cf);
											items = PMap.add(cf.cfName, item, items);
										}
									}
									PMap.foldi(function(name:String, item:CompletionItemData, acc:StringMap<CompletionItemData>) {
										if (isNewItem(acc, name)) return PMap.add(name, item, acc);
										return acc;
									}, PMap.empty(), items);
								case _: items;
							}
						case _: items;
					};
					function iterFields(origin:ClassFieldOrigin, fields:StringMap<TClassField>, fAllow:TClassField->Bool,
							fMake:CompletionClassField->TPair->CompletionItemData):StringMap<CompletionItemData> {
						var items = PMap.fold(function(cf:TClassField, acc:StringMap<CompletionItemData>) {
							if (isNewItem(acc, cf.cfName) && fAllow(cf)) {
								var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(cf.cfMeta), cf.cfType);
								return PMap.add(cf.cfName,
									fMake(CompletionClassField.make(cf, CFSMember, origin, true), {t: cf.cfType, ct: ct}), acc);
							}
							return acc;
						}, fields, items);
						return items;
					}
					switch an.aStatus {
						case ClassStatics(c = {clKind: KAbstractImpl(a)}):
							Display.mergeCoreDoc(ctx, TClassDecl(c));
							function fAllow(cf:TClassField):Bool return shouldAccess(c, cf, false)
								&& (!hasClassFieldFlag(cf, CfImpl) || hasClassFieldFlag(cf, CfEnum));
							function fMake(ccf:CompletionClassField, t:TPair):CompletionItemData {
								return if (hasClassFieldFlag(ccf.field,
									CfEnum)) CompletionItem.makeCiEnumAbstractField(a, ccf, t) else CompletionItem.makeCiClassField(ccf, t);
							}
							iterFields(Self(TClassDecl(c)), c.clStatics, fAllow, fMake);
						case ClassStatics(c):
							Display.mergeCoreDoc(ctx, TClassDecl(c));
							function fAllow(cf:TClassField):Bool return shouldAccess(c, cf, true);
							iterFields(Self(TClassDecl(c)), c.clStatics, fAllow, CompletionItem.makeCiClassField);
						case AbstractStatics(a = {aImpl: c}) if (c != null):
							Display.mergeCoreDoc(ctx, TAbstractDecl(a));
							function fAllow(cf:TClassField):Bool return shouldAccess(c, cf, true);
							iterFields(Self(TAbstractDecl(a)), c.clStatics, fAllow, CompletionItem.makeCiClassField);
						case EnumStatics(en):
							PMap.fold(function(ef:TEnumField, acc:StringMap<CompletionItemData>) {
								var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(ef.efMeta), ef.efType);
								var cef = CompletionEnumField.make(ef, Self(TEnumDecl(en)), true);
								return PMap.add(ef.efName, CompletionItem.makeCiEnumField(cef, {t: ef.efType, ct: ct}), acc);
							}, en.eConstrs, items);
						case _:
							var origin = switch t {
								case TType(td, _): Self(TTypeDecl(td));
								case _: AnonymousStructure(an);
							};
							iterFields(origin, an.aFields, _ -> true, CompletionItem.makeCiClassField);
					}
				case TFun(s):
					// A function has no field except the magic .bind one.
					if (isNewItem(items, "bind")) {
						var t = optArgs(s.args, s.ret);
						var cf = mkField("bind", tfun(vector(t), t), p, Globals.nullPos);
						cf.cfKind = Method(MethNormal);
						var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(cf.cfMeta), t);
						var item = CompletionItem.makeCiClassField(CompletionClassField.make(cf, CFSStatic, BuiltIn, true), {t: t, ct: ct});
						PMap.add("bind", item, items);
					} else items;
				case _:
					items;
			};
		}
		// Add special `.code` field if we have a string of length 1
		var items = switch eAst.expr {
			case EConst(String(s, _)) if (haxe.io.Bytes.ofString(s).length == 1):
				var cf = mkField("code", ctx.t.tint, e.epos, Globals.nullPos);
				cf.cfDoc = Ast.docFromString("The character code of this character (inlined at compile-time).");
				cf.cfKind = Var({vRead: AccNormal, vWrite: AccNever});
				var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), Ast.getValueMeta(cf.cfMeta), cf.cfType);
				var item = CompletionItem.makeCiClassField(CompletionClassField.make(cf, CFSMember, BuiltIn, true), {t: cf.cfType, ct: ct});
				PMap.add(cf.cfName, item, PMap.empty());
			case _:
				PMap.empty();
		};
		// Collect fields of the type
		var items = loop(items, e.etype);
		// Add static extensions
		var items = collectStaticExtensions(ctx, blockedItems, items, e, p);
		var items = PMap.fold(function(item:CompletionItemData, acc:Array<CompletionItemData>) {
			acc.unshift(item);
			return acc;
		}, items, []);
		var items = Display.sortFields(items, WithTypeTools.value, TKField(p));
		try {
			var sl = Ast.stringListOfExprPathRaise(eAst);
			// Add submodule fields
			return items.concat(getSubmoduleFields(ctx, {pack: sl.slice(1), name: sl[0]}));
		} catch (_:core.ds.Exit) {
			return items;
		} catch (_:core.ds.NotFound) {
			return items;
		}
	}

	public static function handleMissingFieldRaise(ctx:Typer, tthis:T, i:String, mode:AccessMode, withType:WithTypeValue, pfield:Pos):Void {
		var tret = switch withType {
			case WithType(t, _): t;
			case Value(_):
				switch mode {
					case MSet(e) if (e != null):
						try {
							var e = Typecore.typeExpr(ctx, e, WithTypeTools.value);
							e.etype;
						} catch (_:Dynamic) {
							mkMono();
						}
					case _: mkMono();
				}
			case NoValue:
				switch mode {
					case MCall(_): ctx.t.tvoid;
					case MSet(e) if (e != null):
						try {
							var e = Typecore.typeExpr(ctx, e, WithTypeTools.value);
							e.etype;
						} catch (_:Dynamic) {
							throw core.ds.Exit.raise();
						}
					case _: throw core.ds.Exit.raise();
				}
		};
		var r = switch mode {
			case MCall(el):
				try {
					var tl = new haxe.ds.Vector(el.length);
					for (i in 0...el.length) {
						var e = el[i];
						var name = switch e.expr {
							case EConst(Ident(s)): s;
							case _: 'arg$i';
						};
						var e = Typecore.typeExpr(ctx, e, WithTypeTools.value);
						tl[i] = {name: name, optional: false, type: e.etype};
					}
					{t: TFun({args: tl, ret: tret}), kind: Method(MethNormal)};
				} catch (_:Dynamic) {
					throw core.ds.Exit.raise();
				}
			case MGet:
				{t: tret, kind: Var({vRead: AccNormal, vWrite: AccNo})};
			case MSet(_):
				{t: tret, kind: Var({vRead: AccNormal, vWrite: AccNormal})};
		};
		var t = r.t;
		var cf = mkField(i, t, pfield, Globals.nullPos, false);
		cf.cfMeta = [
			{meta: MetaTag.CompilerGenerated, exprs: vector(), pos: Globals.nullPos},
			{meta: MetaTag.NoCompletion, exprs: vector(), pos: Globals.nullPos}
		];
		cf.cfKind = r.kind;
		var r = switch follow(tthis) {
			case TInst(c, _): {mt: TClassDecl(c), scope: CFSMember, pub: !Typecore.canAccess(ctx, c, cf, false)};
			case TEnum(en, _): {mt: TEnumDecl(en), scope: CFSMember, pub: true};
			case TAbstract(a, _): {mt: TAbstractDecl(a), scope: CFSMember, pub: true};
			case TAnon(an):
				switch an.aStatus {
					case ClassStatics(c): {mt: TClassDecl(c), scope: CFSStatic, pub: !Typecore.canAccess(ctx, c, cf, true)};
					case EnumStatics(en): {mt: TEnumDecl(en), scope: CFSStatic, pub: true};
					case AbstractStatics(a): {mt: TAbstractDecl(a), scope: CFSStatic, pub: true};
					case _: throw core.ds.Exit.raise();
				}
			case _:
				throw core.ds.Exit.raise();
		};
		if (r.pub) addClassFieldFlag(cf, CfPublic);
		switch r.scope {
			case CFSStatic:
				addClassFieldFlag(cf, CfStatic);
			case _:
		}
		var diag:MissingFieldsDiagnostics = {
			mfPos: pfield,
			mfOn: r.mt,
			mfFields: [
				{field: cf, type: t, completion: CompletionType.fromType(Display.getImportStatus.bind(ctx), t)}
			],
			mfCause: FieldAccess
		};
		var cm = DiagnosticsPrinter.makeMissingFieldsMessage(diag);
		compiler.io.CompilerMessage.addModuleDiagnostic(ctx.com, ctx.m.curmod, cm);
	}

	public static function handleMissingIdent(ctx:Typer, i:String, mode:AccessMode, withType:WithTypeValue, p:Pos):Void {
		switch ctx.e.curfun {
			case FunStatic:
				var eSelf = core.Texpr.Builder.makeStaticThis(ctx.c.curclass, p);
				try handleMissingFieldRaise(ctx, eSelf.etype, i, mode, withType, p)
				catch (_:core.ds.Exit) {}
			case _:
				try handleMissingFieldRaise(ctx, ctx.c.tthis, i, mode, withType, p)
				catch (_:core.ds.Exit) {}
		}
	}
}
