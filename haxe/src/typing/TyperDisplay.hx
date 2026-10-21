package typing;

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Error;
import core.Error.ErrorMsg;
import core.TFunctions.*;
import core.TPrinting;
import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.display.DisplayPosition;
import context.Common;
import context.Typecore;
import context.Typecore.Typer as TyperContext;
import context.Typecore.AccessMode;
import context.display.Display;
import context.display.Display.ReferencePosition;
import context.display.DisplayEmitter;
import context.display.DisplayException;
import context.display.DisplayException.SignatureInfo;
import context.display.DisplayFields;
import context.display.DisplayToplevel;
import typing.FieldAccess as FieldAccessTools;
import core.MetaList.StrictMeta as MetaTag;
import core.Ast;
import core.Meta;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class TyperDisplay {
	public static function convertFunctionSignature(ctx:TyperContext, values:haxe.ds.StringMap<Expr>,
			args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>,
			ret:T):{args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, ret:T, ctf:CtFunction} {
		return switch CompletionType.fromType(Display.getImportStatus.bind(ctx), values, TFun({args: args, ret: ret})) {
			case CTFunction(ctf): {args: args, ret: ret, ctf: ctf};
			case _: throw new core.Globals.InternalCompilerError("typerDisplay.ml: function signature expected", "");
		};
	}

	static function tpair(ctx:TyperContext, ?values:haxe.ds.StringMap<Expr>, t:T):TPair {
		var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), values, t);
		return {t: t, ct: ct};
	}

	public static function completionItemOfExpr(ctx:TyperContext, e:TExpr):CompletionItemData {
		function retype(e:TExpr, s:String, t:T):Bool {
			try {
				var e_ = Typecore.typeExpr(ctx, {expr: EConst(Ident(s)), pos: Globals.nullPos}, WithTypeTools.withType(t));
				return core.Texpr.equal(e, e_);
			} catch (_:Dynamic) {
				return false;
			}
		}
		function ofField(e:TExpr, origin:ClassFieldOrigin, cf:TClassField, scope:ClassFieldScope,
				makeCi:CompletionClassField->TPair->CompletionItemData):CompletionItemData {
			var isQualified = retype(e, cf.cfName, e.etype);
			return makeCi(CompletionClassField.make(cf, scope, origin, isQualified), tpair(ctx, Ast.getValueMeta(cf.cfMeta), e.etype));
		}
		function ofEnumField(e:TExpr, origin:ClassFieldOrigin, ef:TEnumField):CompletionItemData {
			var isQualified = retype(e, ef.efName, e.etype);
			return CompletionItem.makeCiEnumField(CompletionEnumField.make(ef, origin, isQualified), tpair(ctx, e.etype));
		}
		function itexpr(e:TExpr):CompletionItemData {
			var t = tpair(ctx, e.etype);
			return CompletionItem.makeCiExpr(e, t);
		}
		function wasProbablyLiteralAbstract(v:TVar, t:T):Bool {
			return switch follow(t) {
				case TAbstract(a, tl): core.TUnification.typeIseq(core.Abstract.getUnderlyingType(a, tl), v.vType);
				case _: false;
			};
		}
		function withEtype(e:TExpr, t:T):TExpr return {eexpr: e.eexpr, etype: t, epos: e.epos};
		function loop(e:TExpr):CompletionItemData {
			return switch e.eexpr {
				case TLocal(v = {vKind: VAbstractThis}) if (wasProbablyLiteralAbstract(v, e.etype)):
					// `abstract` is typed as ((this : Underlying) : Abstract), so we detect it like that.
					// This could lead to false positives if somebody really tries, but even in that case
					// the displayed type is not wrong.
					CompletionItem.makeCiLiteral("abstract", tpair(ctx, e.etype));
				case TLocal(v) | TVar(v, _):
					CompletionItem.makeCiLocal(v, tpair(ctx, Ast.getValueMeta(v.vMeta), v.vType));
				case TField(e1, FStatic(c, cf)):
					var r = DisplayToplevel.maybeResolveMacroField(ctx, e.etype, c, cf);
					var te = r.t, cf = r.cf;
					Display.mergeCoreDoc(ctx, TClassDecl(c));
					var decl = CompletionItem.declOfClass(c);
					var origin = switch [c.clKind, e1.eexpr] {
						case [KAbstractImpl(_), _] if (hasClassFieldFlag(cf, CfImpl)): Self(decl);
						case [_, TMeta({meta: m}, _)] if (Meta.metaEq(MetaTag.StaticExtension, m)): StaticExtension(decl);
						case _: Self(decl);
					};
					var makeCi = switch c.clKind {
						case KAbstractImpl(a) if (hasClassFieldFlag(cf, CfEnum)): CompletionItem.makeCiEnumAbstractField.bind(a);
						case _: CompletionItem.makeCiClassField;
					};
					ofField(withEtype(e, te), origin, cf, CFSStatic, makeCi);
				case TField(e1, FInstance(c, _, cf) | FClosure({cls: c}, cf)):
					var r = DisplayToplevel.maybeResolveMacroField(ctx, e.etype, c, cf);
					var te = r.t, cf = r.cf;
					Display.mergeCoreDoc(ctx, TClassDecl(c));
					var origin = switch follow(e1.etype) {
						case TInst(c_, _) if (c != c_): Parent(TClassDecl(c));
						case _: Self(TClassDecl(c));
					};
					ofField(withEtype(e, te), origin, cf, CFSMember, CompletionItem.makeCiClassField);
				case TField(_, FEnum(en, ef)):
					ofEnumField(e, Self(TEnumDecl(en)), ef);
				case TField(e1, FAnon(cf) | FClosure(null, cf)):
					switch follow(e1.etype) {
						case TAnon(an):
							var origin = switch e1.etype {
								case TType(td, _): Self(TTypeDecl(td));
								case _: AnonymousStructure(an);
							};
							ofField(e, origin, cf, CFSMember, CompletionItem.makeCiClassField);
						case _: itexpr(e);
					}
				case TTypeExpr(TClassDecl({clKind: KAbstractImpl(a)})):
					Display.mergeCoreDoc(ctx, TAbstractDecl(a));
					var t = TType(abstractModuleType(a, extractParamTypes(a.aParams)), vector());
					var t = tpair(ctx, t);
					CompletionItem.makeCiType(CompletionModuleType.ofModuleType(TAbstractDecl(a)), Imported, t);
				case TTypeExpr(mt):
					Display.mergeCoreDoc(ctx, mt);
					var t = tpair(ctx, e.etype);
					CompletionItem.makeCiType(CompletionModuleType.ofModuleType(mt), Imported, t); // TODO
				case TConst(TThis | TSuper):
					itexpr(e); // TODO
				case TConst(ct):
					CompletionItem.makeCiLiteral(TPrinting.sConst(ct), tpair(ctx, e.etype));
				case TObjectDecl(_):
					switch follow(e.etype) {
						case TAnon(an): CompletionItem.makeCiAnon(an, tpair(ctx, e.etype));
						case _: itexpr(e);
					}
				case TNew(c, tl, el):
					Display.mergeCoreDoc(ctx, TClassDecl(c));
					/* begin match fst e_ast with
					| EConst (Regexp (r,opt)) ->
						let present,absent = List.partition (String.contains opt) ['g';'i';'m';'s';'u'] in
						let doc flag desc = Printf.sprintf "* %s: %s" (String.make 1 flag) desc in
						let f c = match c with
							| 'g' -> doc c "global split and replace"
							| 'i' -> doc c "case insensitive matching"
							| 'm' -> doc c "multiline matching"
							| 's' -> doc c "dot also match newlines"
							| 'u' -> doc c "use UTF-8 matching"
							| _ -> die "" __LOC__
						in
							DisplayException.send_signatures_raise ctx.com overloads 0 display_arg SKCall
						let present = match present with [] -> [] | _ -> "\n\nActive flags:\n\n" :: present in
						let absent = List.map f absent in
						let absent = match absent with [] -> [] | _ -> "\n\nInactive flags:\n\n" :: absent in
							DisplayException.send_positions_raise ctx.com []
					| _ -> */
					var fa = FieldAccessTools.getConstructorAccess(c, tl, e.epos);
					var fcc = CallUnification.unifyFieldCall(ctx, fa, el, vector(), e.epos, false);
					var cf = fcc.fcField;
					var t = switch follow(FieldAccessTools.getMapFunction(fa)(cf.cfType)) {
						case TFun(s): TFun({args: s.args, ret: TInst(c, tl)});
						case t: t;
					};
					CompletionItem.makeCiClassField(CompletionClassField.make(cf, CFSConstructor, Self(CompletionItem.declOfClass(c)),
						true),
						tpair(ctx, Ast.getValueMeta(cf.cfMeta), t));
				// end
				case TCall(e1 = {eexpr: TConst(TSuper)}, _):
					itexpr(e1); // TODO
				case TCast(e1, _):
					loop(withEtype(e1, e.etype));
				case TParenthesis(e1) | TMeta(_, e1):
					loop(e1);
				case _:
					itexpr(e);
			};
		}
		return loop(e);
	}

	public static function getExpectedType(ctx:TyperContext, withType:WithTypeValue):Null<ExpectedTypeCompletion> {
		var t = switch withType {
			case WithType(t, _): t;
			case _: null;
		};
		if (t == null) return null;
		function fromType(t:T):CompletionTypeKind return CompletionType.fromType(Display.getImportStatus.bind(ctx), t);
		var tFollowed = core.TFunctions.map(follow, follow(t));
		var compatible = switch tFollowed {
			case TInst(c, tl) if (Meta.has(MetaTag.StructInit, c.clMeta)):
				var fields = Fields.getStructInitAnonFields(c, tl);
				var ta = mkAnon(Closed, fields);
				[fromType(ta)];
			case _:
				[];
		};
		// port: OCaml evaluates record fields right to left
		var compatibleTypes = compatible;
		var expectedTypeFollowed = fromType(tFollowed);
		var expectedType = fromType(t);
		return {
			expectedType: expectedType,
			expectedTypeFollowed: expectedTypeFollowed,
			compatibleTypes: compatibleTypes
		};
	}

	public static function raiseToplevel<R>(ctx:TyperContext, dk:DisplayKind, withType:WithTypeValue, subject:String, psubject:Pos):R {
		var expectedType = getExpectedType(ctx, withType);
		return DisplayToplevel.collectAndRaise(ctx, switch dk {
			case DKPattern(_): TKPattern(psubject);
			case _: TKExpr(psubject);
		}, withType, CRToplevel(expectedType), subject, psubject, psubject);
	}

	public static function displayDollarType(ctx:TyperContext, p:Pos, makeType:T->TPair):TExpr {
		var mono = Typecore.spawnMonomorph(ctx, p);
		var doc = Ast.docFromString("Outputs type of argument as a warning and uses argument as value");
		var arg = vector({name: "expression", optional: false, type: mono});
		return switch ctx.com.display.dmsKind {
			case DMSignature:
				DisplayException.sendSignaturesRaise(ctx.com, [
					{sig: convertFunctionSignature(ctx, new haxe.ds.StringMap(), arg, mono), doc: doc}
				], 0, 0, SKCall);
			case DMHover:
				var t = TFun({args: arg, ret: mono});
				DisplayException.raiseHover(CompletionItem.makeCiExpr(mk(TIdent("trace"), t, p), makeType(t)),
					WithTypeTools.namedArgument("expression"), p);
			case DMDefinition | DMTypeDefinition:
				DisplayException.sendPositionsRaise(ctx.com, []);
			case _:
				Error.raiseTypingError("Unsupported method", p);
		};
	}

	public static function handleSignatureDisplay(ctx:TyperContext, eAst:Expr, withType:WithTypeValue):TExpr {
		ctx.f.inDisplay = true;
		var p = eAst.pos;
		function handleCall(tl:Array<{t:T, doc:Documentation, values:haxe.ds.StringMap<Expr>}>, el:haxe.ds.Vector<Expr>, p0:Pos):TExpr {
			function followWithCallable(x:{t:T, doc:Documentation, values:haxe.ds.StringMap<Expr>}):{
				args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>,
				ret:T,
				doc:Documentation,
				values:haxe.ds.StringMap<Expr>
			} {
				return switch follow(x.t) {
					case TAbstract(a,
						tl) if (Meta.has(MetaTag.Callable,
							a.aMeta)): followWithCallable({t: core.Abstract.getUnderlyingType(a, tl), doc: x.doc, values: x.values});
					case TFun(s): {
							args: s.args,
							ret: s.ret,
							doc: x.doc,
							values: x.values
						};
					case _: Error.raiseTypingError("Not a callable type: " + TPrinting.sType(TPrinting.printContext(), x.t), p);
				};
			}
			var tl = tl.map(followWithCallable);
			var r = {
				var i = 0;
				var acc = [];
				var found = -1;
				for (j in 0...el.length) {
					switch el[j].expr {
						case EDisplay(e1, DKMarked):
							found = j;
							break;
						case _:
					}
				}
				if (found >= 0) {
					var out = [for (k in 0...found) el[k]];
					switch el[found].expr {
						case EDisplay(e1, _): out.push(e1);
						case _:
					}
					for (k in found + 1...el.length) out.push(el[k]);
					{displayArg: found, el: haxe.ds.Vector.fromArrayCopy(out)};
				} else {displayArg: 0, el: el.copy()};
			};
			var displayArg = r.displayArg, el = r.el;
			// If our display position exceeds the argument number we add a null expression in order to make
			// unify_call_args error out.
			var el = if (el.length > 0 && displayArg >= el.length) el.concat(vector({expr: EConst(Ident("null")), pos: Globals.nullPos})) else el;
			var acc = [];
			for (x in tl) {
				function keep():Bool {
					try {
						CallUnification.unifyCallArgs(ctx, el, x.args, x.ret, p, false, false, false);
						return true;
					} catch (exc:Dynamic) {
						return switch core.ds.ExceptionTools.typing(exc) {
							case Some({errMessage: CallError(NotEnoughArguments(_))}): true;
							case _: false;
						};
					}
				}
				if (keep()) acc.unshift(x);
			}
			var overloads = acc.length == 0 ? tl : acc;
			var overloads:Array<SignatureInfo> = overloads.map(x -> {
				sig: convertFunctionSignature(ctx, x.values, x.args, x.ret),
				doc: x.doc
			});
			return DisplayException.sendSignaturesRaise(ctx.com, overloads, 0, displayArg, SKCall); // ?
		}
		function processOverloads(stat:Bool, co:Null<TClass>, map:T->T, cf:TClassField,
				t:T):Array<{t:T, doc:Documentation, values:haxe.ds.StringMap<Expr>}> {
			var isWackyOverload = !hasClassFieldFlag(cf, CfOverload);
			function canAccess(cf:TClassField):Bool return co == null ? true : Typecore.canAccess(ctx, co, cf, stat);
			// port: List.rev_map
			var rest = [];
			for (cf in cf.cfOverloads) rest.unshift({t: map(cf.cfType), cf: cf});
			var l = [{t: t, cf: cf}].concat(rest);
			var l = l.filter(x -> canAccess(x.cf));
			var l = l.map(function(x) {
				// Ghetto overloads have their documentation on the main field.
				var doc = isWackyOverload ? cf.cfDoc : x.cf.cfDoc;
				return {t: x.t, doc: doc, values: Ast.getValueMeta(cf.cfMeta)};
			});
			return l;
		}
		function findConstructorTypes(t:T):Array<{t:T, doc:Documentation, values:haxe.ds.StringMap<Expr>}> {
			return switch follow(t) {
				case TInst(c = {clKind: KTypeParameter(ttp)}, _):
					function loop(tl:core.TType.TParams):T {
						for (t in tl) switch follow(t) {
							case TAbstract({aPath: {pack: ["haxe"], name: "Constructible"}}, [t]):
								return t;
							case _:
						}
						return Error.raiseTypingErrorExt(Error.makeError(NoConstructor(TClassDecl(c)), p));
					}
					[{t: loop(getConstraints(ttp)), doc: null, values: new haxe.ds.StringMap()}];
				case TInst(c, tl) | TAbstract({aImpl: c}, tl) if (c != null):
					Display.mergeCoreDoc(ctx, TClassDecl(c));
					var fa = FieldAccessTools.getConstructorAccess(c, tl, p);
					var map = FieldAccessTools.getMapFunction(fa);
					var cf = fa.faField;
					processOverloads(false, c, map, cf, cf.cfType);
				case _:
					[];
			};
		}
		return switch eAst.expr {
			case ECall(e1, el):
				function def():TExpr {
					try {
						return Calls.accGet(ctx, TyperBase.typeCallTargetRef(ctx, e1, el, withType, null));
					} catch (exc:Dynamic) {
						switch core.ds.ExceptionTools.typing(exc) {
							case Some({errMessage: UnknownIdent("trace")}):
								var e = Ast.exprOfTypePath({pack: ["haxe"], name: "Log"}, p);
								var e:Expr = {expr: EField(e, "trace", EFNormal), pos: p};
								return Typecore.typeExpr(ctx, e, WithTypeTools.value);
							case Some({errMessage: UnknownIdent("$type"), errPos: p}):
								return displayDollarType(ctx, p,
									t -> ({t: t, ct: CompletionType.fromType(Display.getImportStatus.bind(ctx), t)} : TPair));
							case _:
								throw exc;
						}
					}
				}
				var e1 = switch e1.expr {
					case EField(e, "bind", _):
						var e = Typecore.typeExpr(ctx, e, WithTypeTools.value);
						switch follow(e.etype) {
							case TFun(_): e;
							case _: def();
						}
					case _: def();
				};
				var tl = switch e1.eexpr {
					case TField(_, fa):
						switch fa {
							case FStatic(c, cf):
								var r = DisplayToplevel.maybeResolveMacroField(ctx, e1.etype, c, cf);
								processOverloads(true, c, t -> t, r.cf, r.t);
							case FInstance(c, tl, cf) | FClosure({cls: c, params: tl}, cf):
								var r = DisplayToplevel.maybeResolveMacroField(ctx, e1.etype, c, cf);
								processOverloads(false, c, core.TOther.TClassTools.getMapFunction(c, tl), r.cf, r.t);
							case FAnon(cf) | FClosure(null, cf):
								processOverloads(false, null, t -> t, cf, e1.etype);
							case _:
								[{t: e1.etype, doc: null, values: new haxe.ds.StringMap()}];
						}
					case TConst(TSuper):
						findConstructorTypes(e1.etype);
					case TLocal(v):
						[{t: e1.etype, doc: null, values: Ast.getValueMeta(v.vMeta)}];
					case _:
						[{t: e1.etype, doc: null, values: new haxe.ds.StringMap()}];
				};
				handleCall(tl, el, e1.epos);
			case ENew(ptp, el):
				var t = core.Abstract.followWithForwardCtor(Typeload.loadInstance(ctx, ptp, ParamSpawnMonos, LoadNormal));
				handleCall(findConstructorTypes(t), el, ptp.posFull);
			case EArray(e1, e2):
				var e1 = Typecore.typeExpr(ctx, e1, WithTypeTools.value);
				switch follow(e1.etype) {
					case TInst({clPath: {pack: [], name: "Array"}}, [t]):
						var res = convertFunctionSignature(ctx, new haxe.ds.StringMap(),
							vector({name: "index", optional: false, type: ctx.t.tint}), t);
						DisplayException.sendSignaturesRaise(ctx.com, [{sig: res, doc: Ast.docFromString("The array index")}], 0, 0,
							SKCall);
					case TAbstract(a, tl):
						if (a.aImpl != null) a.aImpl.clBuild();
						var sigs:Array<SignatureInfo> = [];
						for (cf in a.aArray) {
							switch follow(cf.cfType) {
								case TFun(s) if (s.args.length > 0):
									var args = s.args.slice(1), r = s.ret;
									if (core.TOther.ExtType.isVoid(follow(r)) && !withType.match(NoValue)) {} else {
										function map(t:T):T return applyParams(a.aParams, tl, t);
										var tl = args.map(a -> {name: a.name, optional: a.optional, type: map(a.type)});
										var r = map(r);
										sigs.push({sig: convertFunctionSignature(ctx, new haxe.ds.StringMap(), tl, r), doc: cf.cfDoc});
									}
								case _:
							}
						}
						DisplayException.sendSignaturesRaise(ctx.com, sigs, 0, 0, SKArrayAccess);
					case _:
						DisplayException.sendSignaturesRaise(ctx.com, [], 0, 0, SKArrayAccess);
				}
			case _:
				Error.raiseTypingError("Call expected", p);
		};
	}

	public static function displayExpr(ctx:TyperContext, eAst:Expr, e:TExpr, dk:DisplayKind, mode:AccessMode, withType:WithTypeValue,
			p:Pos):TExpr {
		function getSuperConstructor():{cf:TClassField, c:TClass} {
			if (ctx.c.curclass.clSuper == null) return Error.raiseTypingError("Current class does not have a super", p);
			var c = ctx.c.curclass.clSuper.cls,
				params = ctx.c.curclass.clSuper.params;
			var fa = FieldAccessTools.getConstructorAccess(c, params, p);
			return {cf: fa.faField, c: c};
		}
		function maybeExpandOverload(elTyped:haxe.ds.Vector<TExpr>, e:TExpr, eOn:TExpr, host:context.Typecore.FieldHost, cf:TClassField):TExpr {
			return switch mode {
				case MCall(el) if (cf.cfOverloads.length > 0):
					var fa = FieldAccessTools.create(eOn, cf, host, false, p);
					var fcc = CallUnification.unifyFieldCall(ctx, fa, elTyped, el, p, false);
					var fa2 = fa.clone();
					fa2.faField = fcc.fcField;
					FieldAccessTools.getFieldExpr(fa2, FCall);
				case _:
					e;
			};
		}
		var r = switch [eAst.expr, e.eexpr] {
			case [_, TMeta({meta: m, exprs: [eSelf]}, e1)] if (Meta.metaEq(MetaTag.StaticExtension, m)):
				{e: e1, elTyped: vector(TyperBase.typeStoredExpr(ctx, eSelf))};
			case [EField(_, _, EFSafe), _]:
				// For ?. we want to extract the then-expression of the TIf.
				function loop(e1:TExpr):TExpr {
					return switch e1.eexpr {
						case TIf({eexpr: TBinop(OpNotEq, _, {eexpr: TConst(TNull)})}, e1, _ != null => true):
							e1;
						case TBlock(el):
							if (el.length > 0) loop(el[el.length - 1]) else e;
						case _:
							e;
					};
				}
				{e: loop(e), elTyped: vector()};
			case _:
				{e: e, elTyped: vector()};
		};
		var e = r.e, elTyped = r.elTyped;
		// If we display on a TField node that points to an overloaded field, let's try to unify the field call
		// in order to resolve the correct overload (issue #7753).
		var e = switch e.eexpr {
			case TField(e1, FStatic(c, cf)): maybeExpandOverload(elTyped, e, e1, FHStatic(c), cf);
			case TField(e1,
				FInstance(c, tl, cf) | FClosure({cls: c, params: tl}, cf)): maybeExpandOverload(elTyped, e, e1, FHInstance(c, tl), cf);
			case TField(e1, FAnon(cf) | FClosure(null, cf)): maybeExpandOverload(elTyped, e, e1, FHAnon, cf);
			case _: e;
		};
		return switch ctx.com.display.dmsKind {
			case DMPackage:
				throw new core.Globals.InternalCompilerError("typerDisplay.ml: DMPackage in display_expr", "");
			case DMSignature:
				handleSignatureDisplay(ctx, eAst, withType);
			case DMHover:
				var item = completionItemOfExpr(ctx, e);
				DisplayException.raiseHover(item, withType, e.epos);
			case DMUsage(_) | DMImplementation:
				function loop(e:TExpr):Void {
					switch e.eexpr {
						case TField(_, FEnum(_, ef)):
							ReferencePosition.set(ef.efName, ef.efNamePos, SKEnumField(ef));
						case TField(_, FAnon(cf) | FClosure(null, cf)):
							ReferencePosition.set(cf.cfName, cf.cfNamePos, SKField(cf, null));
						case TField(_, FInstance(c, _, cf) | FStatic(c, cf) | FClosure({cls: c}, cf)):
							ReferencePosition.set(cf.cfName, cf.cfNamePos, SKField(cf, c));
						case TLocal(v) | TVar(v, _):
							ReferencePosition.set(v.vName, v.vPos, SKVariable(v));
						case TTypeExpr(mt):
							var ti = tInfos(mt);
							ReferencePosition.set(ti.mtPath.name, ti.mtNamePos, DisplayEmitter.symbolOfModuleType(mt));
						case TNew(c, tl, _):
							try {
								var fa = FieldAccessTools.getConstructorAccess(c, tl, p);
								var cf = fa.faField;
								ReferencePosition.set(c.clPath.name, cf.cfNamePos, SKConstructor(cf));
							} catch (_:core.ds.NotFound) {}
						case TCall({eexpr: TConst(TSuper)}, _):
							try {
								var r = getSuperConstructor();
								ReferencePosition.set(r.cf.cfName, r.cf.cfNamePos, SKField(r.cf, r.c));
							} catch (_:core.ds.NotFound) {}
						case TConst(TSuper):
							if (ctx.c.curclass.clSuper != null) {
								var c = ctx.c.curclass.clSuper.cls;
								ReferencePosition.set(c.clPath.name, c.clNamePos, SKClass(c));
							}
						case TCall(e1, _):
							loop(e1);
						case TCast(e1, _):
							loop(e1);
						case _:
					}
				}
				loop(e);
				e;
			case DMDefinition:
				function loop(e:TExpr):Array<Pos> {
					return switch e.eexpr {
						case TField(_, FEnum(_, ef)): [ef.efNamePos];
						case TField(_, FStatic(c, cf)) if (Meta.has(MetaTag.CoreApi, c.clMeta)):
							var c_ = ctx.g.doLoadCoreClass(ctx, c);
							var cf2 = c_.clStatics.get(cf.cfName);
							[cf.cfNamePos].concat(cf2 != null ? [cf2.cfNamePos] : []);
						case TField(_, FInstance(c, tl, cf) | FClosure({cls: c, params: tl}, cf)) if (Meta.has(MetaTag.CoreApi, c.clMeta)):
							var c_ = ctx.g.doLoadCoreClass(ctx, c);
							var l = try {
								var r = classField(c_, tl, cf.cfName);
								[r.field.cfNamePos];
							} catch (_:core.ds.NotFound) {
								[];
							};
								[cf.cfNamePos].concat(l);
						case TField(_, FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf)): [cf.cfNamePos];
						case TLocal(v) | TVar(v, _): [v.vPos];
						case TTypeExpr(TClassDecl(c)) if (Meta.has(MetaTag.CoreApi, c.clMeta)):
							var c_ = ctx.g.doLoadCoreClass(ctx, c);
							[c.clNamePos, c_.clNamePos];
						case TTypeExpr(mt): [tInfos(mt).mtNamePos];
						case TNew(c, tl, _):
							try {
								var fa = FieldAccessTools.getConstructorAccess(c, tl, p);
								var cf = fa.faField;
								if (Meta.has(MetaTag.CoreApi, c.clMeta)) {
									var c_ = ctx.g.doLoadCoreClass(ctx, c);
									c_.clConstructor != null ? [cf.cfNamePos, c_.clConstructor.cfNamePos] : [cf.cfNamePos];
								} else [cf.cfNamePos];
							} catch (_:core.ds.NotFound) {
								[];
							}
						case TCall({eexpr: TConst(TSuper)}, _):
							try {
								var r = getSuperConstructor();
								[r.cf.cfNamePos];
							} catch (_:core.ds.NotFound) {
								[];
							}
						case TConst(TSuper):
							ctx.c.curclass.clSuper == null ? [] : [ctx.c.curclass.clSuper.cls.clNamePos];
						case TCall(e1, _):
							loop(e1);
						case TCast(e1, _):
							loop(e1);
						case _:
							[];
					};
				}
				var pl = loop(e);
				DisplayException.sendPositionsRaise(ctx.com, pl);
			case DMTypeDefinition:
				DisplayEmitter.raisePositionOfType(ctx, e.etype);
			case DMDefault if (!ctx.com.partScope.parserState.hadParserResume):
				function displayFields(eAst:Expr, e1:TExpr, so:Null<String>):TExpr {
					var l = so == null ? 0 : so.length;
					var fields = context.display.DisplayFields.collect(ctx, eAst, e1, dk, withType, p);
					var item = completionItemOfExpr(ctx, e1);
					return DisplayException.raiseFields(fields, CRField(item, e1.epos, null, null),
						DisplayTypes.makeSubject(so, {pfile: e.epos.pfile, pmin: e.epos.pmax - l, pmax: e.epos.pmax}, eAst.pos));
				}
				switch [eAst.expr, e.eexpr] {
					case [EField(e1, s, _), TField(e2, _)]:
						displayFields(e1, e2, s);
					case [
						EObjectDecl([{key: {name: name, pos: pn}, expr: {expr: EConst(Ident("null")), pos: pe}}]),
						_
					] if (pe.pmin == -1):
						// This is what the parser emits for #8651. Bit of a dodgy heuristic but should be fine.
						raiseToplevel(ctx, dk, withType, name, pn);
					case _:
						if (dk == DKDot) displayFields(eAst, e, null) else {
							// port: string_list_of_expr_path_raise is in reverse order; upstream joins it as is
							var name = try Ast.stringListOfExprPathRaise(eAst).join(".") catch (_:core.ds.Exit) "";
							var name = name == "null" ? "" : name;
							var p = eAst.pos;
							var p = name != "" ? p : DisplayPosition.displayPosition.withPos(p);
							raiseToplevel(ctx, dk, withType, name, p);
						}
				}
			case DMDefault | DMNone | DMModuleSymbols(_):
				var fields = context.display.DisplayFields.collect(ctx, eAst, e, dk, withType, p);
				var item = completionItemOfExpr(ctx, e);
				var iterator = try {
					var it = ForLoop.IterationKind.ofTexpr(ctx, e, null, e.epos, true);
					switch follow(it.itType) {
						case TDynamic(_): null;
						case t: t;
					}
				} catch (exc:Dynamic) {
					if (core.ds.ExceptionTools.typing(exc) != None || Std.isOfType(exc, core.ds.NotFound)) null
					else throw exc;
				};
				var keyValueIterator = try {
					var r = ForLoop.IterationKind.trySyncIterator(ctx, "keyValueIterator", e, true);
					switch follow(r.t) {
						case TAnon(a):
							var key = core.ds.PMap.find("key", a.aFields);
							var value = core.ds.PMap.find("value", a.aFields);
							{key: key.cfType, value: value.cfType};
						case _:
							null;
					}
				} catch (exc:Dynamic) {
					if (core.ds.ExceptionTools.typing(exc) != None || Std.isOfType(exc, core.ds.NotFound)) null
					else throw exc;
				};
				DisplayException.raiseFields(fields, CRField(item, e.epos, iterator, keyValueIterator),
					DisplayTypes.makeSubject(null, DisplayPosition.displayPosition.withPos(p)));
		};
	}

	public static function filterCtors(ctx:TyperContext, r:FieldsResult):Array<CompletionItemData> {
		return r.fitems.filter(function(item) {
			function isPrivateToCurrentModule(mt:CompletionModuleTypeData):Bool {
				// Remove the _Module nonsense from the package
				if (mt.pack.length == 0) throw new core.ds.Failure("tl");
				var pack = mt.pack.slice(0, mt.pack.length - 1);
				return compiler.CompilationCache.pathEq({pack: pack, name: mt.moduleName}, ctx.m.curmod.mPath);
			}
			return switch item.ciKind {
				case ITType(mt, _)
					if ((mt.kind == Class || mt.kind == Abstract || mt.kind == TypeAlias)
						&& (!mt.isPrivate || isPrivateToCurrentModule(mt))):
					switch mt.hasConstructor {
						case Yes: true;
						case YesButPrivate:
							if (Meta.has(MetaTag.PrivateAccess, ctx.f.meta)) true; else {
								(switch ctx.c.curclass.clKind {
									case KAbstractImpl({
										aPath: {
											pack: pack,
											name: name
										}
									}): pack.join(".") == mt.pack.join(".") && pack.length == mt.pack.length && name == mt.name;
									case _: false;
								})
								|| {
									var path:GlobalTypePath = {pack: mt.pack, name: mt.name};
									function loop(c:TClass):Bool {
										if (compiler.CompilationCache.pathEq(c.clPath, path)) return true;
										return c.clSuper == null ? false : loop(c.clSuper.cls);
									}
									loop(ctx.c.curclass);
								};
							}
						case No: false;
						case Maybe:
							try {
								var mt = ctx.g.doLoadTypeDef(ctx, Globals.nullPos, {
									tpackage: mt.pack,
									tname: mt.moduleName,
									tsub: mt.name,
									tparams: vector()
								});
								switch resolveTypedef(mt) {
									case TClassDecl(c): hasConstructor(c);
									case TAbstractDecl(a):
										switch core.Abstract.followWithForwardCtor(TAbstract(a, extractParamTypes(a.aParams)), true) {
											case TInst(c, _): hasConstructor(c);
											case TAbstract(a, _): a.aConstructor != null;
											case _: false;
										}
									case _: false;
								}
							} catch (_:Dynamic) {
								false;
							}
					}
				case ITTypeParameter({clKind: KTypeParameter(ttp)})
					if (TyperBase.getConstructibleConstraint(ctx, getConstraints(ttp), Globals.nullPos) != null):
					true;
				case _: false;
			};
		});
	}

	public static function handleDisplay(ctx:TyperContext, eAst:Expr, dk:DisplayKind, mode:AccessMode, withType:WithTypeValue):TExpr {
		var old = {inDisplay: ctx.f.inDisplay, inCallArgs: ctx.f.inCallArgs};
		ctx.f.inDisplay = true;
		ctx.f.inCallArgs = false;
		function tpair_(t:T):TPair {
			var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), t);
			return {t: t, ct: ct};
		}
		var e = switch [eAst, withType] {
			case [{expr: EConst(Ident("$type")), pos: p}, _]:
				displayDollarType(ctx, p, tpair_);
			case [{expr: EConst(Ident("trace"))}, _]:
				var doc = Ast.docFromString("Print given arguments");
				var arg = vector({name: "value", optional: false, type: tDynamic});
				var ret = ctx.com.basic.tvoid;
				var p = eAst.pos;
				switch ctx.com.display.dmsKind {
					case DMSignature:
						DisplayException.sendSignaturesRaise(ctx.com, [
							{sig: convertFunctionSignature(ctx, new haxe.ds.StringMap(), arg, ret), doc: doc}
						], 0, 0, SKCall);
					case DMHover:
						var t = TFun({args: arg, ret: ret});
						DisplayException.raiseHover(CompletionItem.makeCiExpr(mk(TIdent("trace"), t, p), tpair_(t)),
							WithTypeTools.namedArgument("value"), p);
					case DMDefinition | DMTypeDefinition:
						DisplayException.sendPositionsRaise(ctx.com, []);
					case _:
						Error.raiseTypingError("Unsupported method", p);
				}
			case [{expr: EConst(Ident("_")), pos: p}, WithType(t, _)]:
				mk(TConst(TNull), t, p); // This is "probably" a bind skip, let's just use the expected type
			case [{pos: p}, _]:
				try {
					Typecore.typeExpr(ctx, eAst, withType, mode);
				} catch (de:DisplayException) {
					switch de.kind {
						case DisplayFields(r = {fkind: CRTypeHint}) if (eAst.expr.match(ENew(_))):
							var l = core.Timer.time(ctx.com.timerCtx, ["display", "toplevel", "filter ctors"],
								function(r) return filterCtors(ctx, r), r);
							DisplayException.raiseFields(l, CRNew, r.fsubject);
						case _:
							throw de;
					}
				} catch (exc:Dynamic) {
					switch core.ds.ExceptionTools.typing(exc) {
						case Some({errMessage: UnknownIdent(n)}) if (ctx.com.display.dmsKind == DMDefault):
							raiseToplevel(ctx, dk, withType, n, p);
						case Some({errMessage: TypeNotFound(path, _, _) | ModuleNotFound(path)}) if (ctx.com.display.dmsKind == DMDefault):
							raiseToplevel(ctx, dk, withType, Globals.sTypePath(path), p);
						case _:
							throw exc;
					}
				}
		};
		var e = switch [eAst, e.eexpr] {
			case [_, TField(e1, FDynamic("bind"))] if (follow(e1.etype).match(TFun(_))): e1;
			case [
				{expr: EField(_, "new", _)},
				TFunction({tfExpr: {eexpr: TReturn(e1 = {eexpr: TNew(_)})}})
			]: e1;
			case _: e;
		};
		var isDisplayDebug = Meta.has(MetaTag.Custom(":debug.display"), ctx.f.curfield.cfMeta);
		if (isDisplayDebug) {
			Sys.println("expected type: " + WithTypeTools.toString(withType));
			Sys.println("typed expr:\n" + TPrinting.sExprAst(true, "", TPrinting.sType.bind(TPrinting.printContext()), e));
		}
		var p = e.epos;
		switch withType {
			case WithType(t, _):
				// We don't want to actually use the transformed expression which may have inserted implicit cast calls.
				// It only matters that unification takes place.
				try context.AbstractCast.castOrUnifyRaise(ctx, t, e, e.epos)
				catch (exc:Dynamic) {
					switch core.ds.ExceptionTools.typing(exc) {
						case Some({errMessage: Unify(_)}):
						case _: throw exc;
					}
				}
			case _:
		}
		if (isDisplayDebug) Sys.println("cast expr:\n" + TPrinting.sExprAst(true, "", TPrinting.sType.bind(TPrinting.printContext()), e));
		ctx.f.inDisplay = old.inDisplay;
		ctx.f.inCallArgs = old.inCallArgs;
		function f():TExpr return displayExpr(ctx, eAst, e, dk, mode, withType, p);
		if (Typecore.inOverloadCallArgs(ctx)) {
			try {
				return f();
			} catch (de:DisplayException) {
				ctx.g.delayedDisplay = de.kind;
				return e;
			}
		} else return f();
	}

	public static function handleStructureDisplay(ctx:TyperContext, e:Expr, fields:haxe.ds.StringMap<TClassField>,
			origin:ClassFieldOrigin):TExpr {
		var p = e.pos;
		var fields = core.ds.PMap.foldi(function(_, cf:TClassField, acc:Array<TClassField>) {
			acc.unshift(cf);
			return acc;
		}, fields, []);
		haxe.ds.ArraySort.sort(fields, (cf1, cf2) -> -Reflect.compare(cf1.cfPos.pmin, cf2.cfPos.pmin));
		function makeFieldItem(cf:TClassField):CompletionItemData {
			return CompletionItem.makeCiClassField(CompletionClassField.make(cf, CFSMember, origin, true),
				tpair(ctx, Ast.getValueMeta(cf.cfMeta), cf.cfType));
		}
		return switch e.expr {
			case EObjectDecl(fl):
				var fields = fields;
				var subj:Null<{name:String, p:Pos}> = null;
				for (of in fl) {
					var n = of.key.name, p = of.key.pos, e = of.expr;
					function wt():WithTypeValue {
						var cf = core.ds.ArrayTools.find(fields, cf -> cf.cfName == n);
						return cf != null ? WithTypeTools.withType(cf.cfType) : WithTypeTools.value;
					}
					if (DisplayPosition.displayPosition.enclosedIn(p)) subj = {name: n, p: p}
					else {
						if (DisplayPosition.displayPosition.enclosedIn(e.pos)) handleDisplay(ctx, e, DKMarked, MGet, wt())
						else {
							// If we are between the : and the expression, we don't want to use the actual expression as a filter string (issue #10414)
							var pBetween:Pos = {pfile: p.pfile, pmin: p.pmax + 1, pmax: e.pos.pmin - 1};
							if (DisplayPosition.displayPosition.enclosedIn(pBetween)) {
								var e:Expr = {expr: EConst(Ident("null")), pos: pBetween};
								handleDisplay(ctx, e, DKMarked, MGet, wt());
							}
						}
						fields = fields.filter(cf -> cf.cfName != n);
					}
				}
				var name:Null<String>, pinsert:Pos;
				if (subj == null) {
					name = null;
					pinsert = DisplayPosition.displayPosition.withPos(e.pos);
				} else {
					name = subj.name;
					pinsert = subj.p;
				}
				var fields = fields.map(makeFieldItem);
				DisplayException.raiseFields(fields, CRStructureField, DisplayTypes.makeSubject(name, pinsert));
			case EBlock([]):
				var items = [];
				for (cf in fields) items.unshift(makeFieldItem(cf));
				var pinsert = DisplayPosition.displayPosition.withPos(e.pos);
				DisplayException.raiseFields(items, CRStructureField, DisplayTypes.makeSubject(null, pinsert));
			case _:
				Error.raiseTypingError("Expected object expression", p);
		};
	}

	public static function handleEdisplay(ctx:TyperContext, e:Expr, dk:DisplayKind, mode:AccessMode, withType:WithTypeValue):TExpr {
		function handleDisplay_(ctx:TyperContext, e:Expr, dk:DisplayKind,
				withType:WithTypeValue):TExpr return handleDisplay(ctx, e, dk, mode, withType);
		return switch [dk, ctx.com.display.dmsKind] {
			case [DKCall, DMSignature | DMDefault]:
				handleSignatureDisplay(ctx, e, withType);
			case [DKStructure, DMDefault]:
				switch withType {
					case WithType(t, _):
						switch follow(t) {
							case TAnon(an):
								var origin = switch t {
									case TType(td, _): Self(TTypeDecl(td));
									case _: AnonymousStructure(an);
								};
								handleStructureDisplay(ctx, e, an.aFields, origin);
							case TInst(c, tl) if (Meta.has(MetaTag.StructInit, c.clMeta)):
								var fields = Fields.getStructInitAnonFields(c, tl);
								handleStructureDisplay(ctx, e, fields, Self(TClassDecl(c)));
							case _:
								handleDisplay_(ctx, e, dk, withType);
						}
					case _:
						handleDisplay_(ctx, e, dk, withType);
				}
			case [DKPattern(outermost), DMDefault]:
				try {
					handleDisplay_(ctx, e, dk, withType);
				} catch (de:DisplayException) {
					switch de.kind {
						case DisplayFields(r = {fkind: CRToplevel(_)}):
							DisplayException.raiseFields(r.fitems, CRPattern(getExpectedType(ctx, withType), outermost), r.fsubject);
						case _:
							throw de;
					}
				}
			case _:
				handleDisplay_(ctx, e, dk, withType);
		};
	}
}
