package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Message;
import typing.Fields.TypeFieldConfig;
import core.TUnification.TUnification.fastEq;
import core.Globals.*;
import core.Texpr;
import core.TUnification.Monomorph;
import core.TUnification.TUnification.typeIseq;
import context.Typecore.Typer as TyperContext;
import context.Typecore.FieldAccess as FieldAccessData;
import context.Common.*;
import typing.CallUnification.CallDispatcher;
import optimization.Inline as InlineTools;
import optimization.Optimizer;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TPrinting.*;
import core.Globals;
import core.Meta;
import core.WithType;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.Common;
import context.AbstractCast;
import context.SafeCom;
import typing.TyperBase;
import typing.TyperBase.*;
import typing.Fields.*;
import typing.FieldAccess;
import typing.FieldAccess.*;
import typing.CallUnification.*;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

class Calls {
	public static function makeCall(ctx:TyperContext, e:TExpr, params:Vector<TExpr>, t:T, p:Pos, ?forceInline:Bool):TExpr {
		if (forceInline == null) forceInline = false;
		switch follow(e.etype) {
			case TFun({args: args, ret: _}):
				if (args.length > 0) {
					var last = args[args.length - 1];
					if (last.optional && isPosInfos(last.type) && args.length
						- 1 == params.length) params = params.concat(vector(mkInfosT(ctx, p, [], last.type)));
				}
			case _:
		}
		try {
			var ethis:TExpr, cl:Null<TClass>, f:TClassField;
			switch e.eexpr {
				case TField(on, fa):
					ethis = on;
					switch fa {
						case FInstance(c, _, cf) | FStatic(c, cf):
							cl = c;
							f = cf;
						case FAnon(cf):
							cl = null;
							f = cf;
						case _: throw core.ds.Exit.raise();
					}
				case _:
					throw core.ds.Exit.raise();
			}
			if (!forceInline) {
				if (!needsInline(ctx, cl, f)) throw core.ds.Exit.raise();
			} else if (cl != null)
				// Delay this to filters because that's when cl_descendants is set.
				ctx.com.callbacks.addBeforeSave(function() {
				function hasOverride(c:TClass):Bool {
					if (c.clFields.exists(f.cfName)) return true;
					for (child in c.clDescendants) if (hasOverride(child)) return true;
					return false;
				}
				for (c in cl.clDescendants) if (hasOverride(c)) raiseTypingError("Cannot force inline-call to "
					+ f.cfName
					+ " because it is overridden", p);
			});
			var config = InlineTools.inlineConfig(cl, f, params, t);
			follow(f.cfType); // force evaluation
			switch [cl, ctx.c.curclass.clKind, params.length == 0 ? null : params[0]] {
				case [c, KAbstractImpl(_), {eexpr: TLocal({vMeta: vmeta})}] if (c == ctx.c.curclass):
					if (!hasClassFieldFlag(f, CfAbstractConstructor)
						&& Meta.has(MetaTag.This, vmeta)
						&& hasClassFieldFlag(f, CfModifiesThis)) {
						if (TyperBase.assignToThisIsAllowed(ctx))
							// Current method needs to infer CfModifiesThis flag, since we are calling a method, which modifies `this`
							addClassFieldFlag(ctx.f.curfield, CfModifiesThis);
						else raiseTypingError("Abstract 'this' value can only be modified inside an inline function. '"
							+ f.cfName
							+ "' modifies 'this'", p);
					}
				case _:
			}
			var reduced = params.map(e -> Optimizer.reduceExpression(SafeCom.ofTyper(ctx), e));
			var forced = isForcedInline(cl, f);
			inline function inlineFunction(fd:TFunc):TExpr return InlineTools.typeInline(InlineTools.contextOfTyper(ctx), f, fd, ethis,
				reduced, t, config, p, forced);
			switch f.cfExprUnoptimized {
				case {eexpr: TFunction(fd)}:
					return inlineFunction(fd);
				case _:
					if (hasClassFieldFlag(f,
						CfPostProcessed)) warning(ctx, WInlineOptimizedField,
							"Inlining of cached field " + f.cfName + " might lead to unexpected output", p);
					switch f.cfExpr {
						case expression = {eexpr: TFunction(fd)}:
							f.cfExprUnoptimized = expression;
							return inlineFunction(fd);
						case _:
							/*
								we can't inline because there is most likely a loop in the typing.
								this can be caused by mutually recursive vars/functions, some of them
								being inlined or not. In that case simply ignore inlining.
							*/
							throw core.ds.Exit.raise();
					}
			}
		} catch (_:core.ds.Exit) {
			return mk(TCall(e, params), t, p);
		}
	}

	public static function mkArrayGetCall(ctx:TyperContext, access:{
		field:TClassField,
		type:T,
		ret:T,
		index:TExpr
	}, c:TClass, ebase:TExpr, p:Pos):TExpr {
		var cf = access.field;
		if (cf.cfExpr == null && !hasClassFieldFlag(cf, CfExtern)) {
			if (!Meta.has(MetaTag.NoExpr, cf.cfMeta)) displayError(ctx.com, "Recursive array get method", p);
			return mk(TArray(ebase, access.index), access.ret, p);
		}
		var et = TyperBase.typeModuleType(ctx, TClassDecl(c), p),
			ef = mk(TField(et, FStatic(c, cf)), access.type, p);
		return makeCall(ctx, ef, vector(ebase, access.index), access.ret, p);
	}

	public static function mkArraySetCall(ctx:TyperContext, access:{
		field:TClassField,
		type:T,
		ret:T,
		index:TExpr,
		value:TExpr
	}, c:TClass, ebase:TExpr, p:Pos):TExpr {
		var cf = access.field;
		if (cf.cfExpr == null && !hasClassFieldFlag(cf, CfExtern)) {
			if (!Meta.has(MetaTag.NoExpr, cf.cfMeta)) displayError(ctx.com, "Recursive array set method", p);
			var ea = mk(TArray(ebase, access.index), access.ret, p);
			return mk(TBinop(OpAssign, ea, access.value), access.ret, p);
		}
		var et = TyperBase.typeModuleType(ctx, TClassDecl(c), p),
			ef = mk(TField(et, FStatic(c, cf)), access.type, p);
		return makeCall(ctx, ef, vector(ebase, access.index, access.value), access.ret, p);
	}

	public static function abstractUsingParamType(sea:StaticExtensionAccess):T return switch follow(sea.seThis.etype) {
		case TAbstract(a, tl) if (hasClassFieldFlag(sea.seAccess.faField, CfImpl)): applyParams(a.aParams, tl, a.aThis);
		case _: sea.seThis.etype;
	};

	// port: accGet's local inline_read; a static function, so accGet allocates no closure for it.
	static function accGetInlineRead(ctx:TyperContext, fa:FieldAccessData):TExpr {
		var cf = fa.faField, p = fa.faPos;
		// do not create a closure for static calls
		var apply:T->T = switch fa.faHost {
			case FHStatic(_) | FHInstance(_, _): t -> t;
			case FHAbstract(a, _, _): if (a.aEnum) {
					// Enum abstracts have to apply their type parameters because they are basically statics with type params (#8700).
					var monos = Monomorph.spawnConstrainedMonos(t -> t, a.aParams);
					t -> applyParams(a.aParams, monos, t);
				} else t->t;
			case _: throw "Invalid inline field host";
		};
		follow(cf.cfType); // force computing
		if (!ctx.com.display.dmsInline) return FieldAccess.getFieldExpr(fa, FRead);
		return switch [cf.cfKind, cf.cfExpr] {
			case [Method(_), _]:
				inline function checkClass(c:TClass):Bool return (hasClassFlag(c, CExtern) || hasClassFieldFlag(cf, CfExtern))
					&& !Meta.has(MetaTag.Runtime, cf.cfMeta);
				inline function wrapExtern(c:TClass):TExpr {
					var m = c.clModule, path:core.Globals.GlobalTypePath = {
						pack: c.clModule.mPath.pack.concat(["_" + c.clModule.mPath.name]),
						name: c.clModule.mPath.name + "_Impl_"
					};
					var c2:Null<TClass> = null;
					for (mt in m.mTypes) switch mt {
						case TClassDecl(c) if (core.ds.Key.compare(c.clPath, path) == 0):
							c2 = c;
							break;
						case _:
					}
					if (c2 == null) {
						c2 = mkClass(m, path, c.clPos, Globals.nullPos);
						m.mTypes.unshift(TClassDecl(c2));
					}
					var wrapper:TClassField = c2.clStatics.get(cf.cfName);
					if (wrapper == null) {
						wrapper = core.ds.Record.copy(cf);
						wrapper.cfKind = Method(MethNormal);
						c2.clStatics.set(wrapper.cfName, wrapper);
						c2.clOrderedStatics.unshift(wrapper);
					}
					var et = TyperBase.typeModuleType(ctx, TClassDecl(c2), p);
					return FieldAccess.getFieldExpr(FieldAccess.create(et, wrapper, FHStatic(c2), true, p), FRead);
				}
				var edef = FieldAccess.getFieldExpr(fa, FRead);
				switch follow(fa.faOn.etype) {
					case TInst(c, _) if (checkClass(c)):
						displayError(ctx.com, "Can't create closure on an extern inline member method", p);
						edef;
					case TAnon(a): switch a.aStatus {
							case ClassStatics(c) if (hasClassFieldFlag(cf, CfExtern)):
								displayError(ctx.com, "Cannot create closure on @:extern inline method", p);
								edef;
							case ClassStatics(c) if (checkClass(c)): wrapExtern(c);
							case _: edef;
						}
					case _: edef;
				}
			case [Var(_), expression] if (expression != null):
				function loop(e:TExpr):TExpr return Texpr.mapExpr(loop, mk(e.eexpr, apply(e.etype), p));
				var e = InlineTools.inlineMetadata(loop(expression), cf.cfMeta),
					tf = apply(cf.cfType);
				!typeIseq(tf, e.etype) ? mk(TCast(e, null), tf, e.epos) : e;
			case [Var(_), null]: raiseTypingError("Recursive inline is not supported", p);
			case _: throw "Invalid inline field";
		};
	}

	public static function accGet(ctx:TyperContext, g:AccessKind):TExpr {
		inline function dispatcher(p:Pos):CallDispatcher return new CallDispatcher(ctx, MGet, WithTypeTools.value, p);
		return switch g {
			case AKNo(acc,
				p): if (!Common.ignoreError(ctx.com)) raiseTypingError("This expression cannot be accessed for reading",
					p); else accGet(ctx, acc);
			case AKExpr(e): e;
			case AKSafeNav(sn): TyperBase.safeNavBranch(ctx, sn, () -> accGet(ctx, sn.snAccess));
			case AKAccess(_): throw "Unresolved abstract array access";
			case AKResolve(sea, name): dispatcher(sea.seAccess.faPos).resolveCall(sea, name);
			case AKUsingAccessor(sea) | AKUsingField(sea) if (ctx.f.inDisplay):
				// Generate a TField node so we can easily match it for position/usage completion (issue #1968)
				var field = FieldAccess.getFieldExpr(sea.seAccess, FGet),
					stored = storeTypedExpr(ctx.com, sea.seThis, field.epos);
				var meta:core.Ast.MetadataEntry = {
					meta: MetaTag.StaticExtension,
					exprs: vector(makeStoredIdExpr(stored.id, field.epos)),
					pos: Globals.nullPos
				};
				var t = switch follow(field.etype) {
					case TFun({args: args, ret: ret}) if (args.length > 0): TFun({args: args.slice(1), ret: ret});
					case t: t;
				};
				mk(TMeta(meta, field), t, field.epos);
			case AKField(fa): switch fa.faField.cfKind {
					case Method(MethMacro):
						// If we are in display mode, we're probably hovering a macro call subject. Just generate a normal field.
						ctx.f.inDisplay ? FieldAccess.getFieldExpr(fa,
							FRead) : raiseTypingError("Invalid macro access", fa.faPos);
					case _: fa.faInline ? accGetInlineRead(ctx, fa) : FieldAccess.getFieldExpr(fa, FRead);
				}
			case AKAccessor(fa): dispatcher(fa.faPos).fieldCall(fa, vector(), vector());
			case AKUsingAccessor(sea): dispatcher(sea.seAccess.faPos).fieldCall(sea.seAccess, vector(sea.seThis), vector());
			case AKUsingField(sea):
				var e = sea.seThis,
					field = FieldAccess.getFieldExpr(sea.seAccess, FGet);
				// build a closure with first parameter applied
				switch follow(field.etype) {
					case TFun({args: allArgs, ret: ret}) if (allArgs.length > 0):
						var p = sea.seAccess.faPos, args = allArgs.slice(1);
						unify(ctx, abstractUsingParamType(sea), allArgs[0].type, e.epos);
						var callbackType = TFun({args: args, ret: ret}),
							wrapperType = TFun({args: vector({name: "_e", optional: false, type: e.etype}), ret: callbackType});
						// arguments might not have names in case of variable fields of function types, so we generate one (issue #2495)
						var vars = args.map(function(arg) {
							var t = arg.optional ? ctx.t.tnull(arg.type) : arg.type;
							return {
								optional: arg.optional,
								variable: arg.name == "" ? genLocal(ctx, t, e.epos) : allocVar(VGenerated, arg.name, t, e.epos) // TODO: var pos
							};
						});
						var ve = allocVar(VGenerated, "_e", e.etype, e.epos);
						var call = makeCall(ctx, field, VectorTools.cons(mk(TLocal(ve), ve.vType, p), vars.map(a -> mk(TLocal(a.variable), a.variable.vType, p))), ret, p);
						var body = switch follow(ret) {
							case TAbstract({aPath: {pack: [], name: "Void"}}, _): call;
							case _: mk(TReturn(call), tDynamic, p);
						};
						var callback = mk(TFunction({
							tfArgs: vars.map(arg -> {
								variable: arg.variable,
								defaultValue: arg.optional ? Texpr.Builder.makeNull(arg.variable.vType, arg.variable.vPos) : null
							}),
							tfType: ret,
							tfExpr: body
						}), callbackType, p);
						var wrapper = mk(TFunction({
							tfArgs: vector({variable: ve, defaultValue: null}),
							tfType: callbackType,
							tfExpr: mk(TReturn(callback), tDynamic, p)
						}), wrapperType, p);
						makeCall(ctx, wrapper, vector(e), callbackType, p);
					case _: throw "Static extension field is not a function";
				}
		};
	}

	public static function checkDynamicSuperMethodCall(ctx:TyperContext, fa:FieldAccessData, p:Pos):Void switch fa {
		case {faOn: {eexpr: TConst(TSuper)}, faField: {cfKind: Method(MethDynamic), cfName: name}}:
			ctx.com.error("Cannot call super." + name + " since it's a dynamic method", p);
		case _:
	}

	public static function buildCallAccess(ctx:TyperContext, acc:AccessKind, el:Vector<Expr>, mode:AccessMode, withType:WithTypeValue,
			p:Pos):AccessKind {
		inline function getAccessor(fa:FieldAccessData,
				args:Vector<TExpr>):TExpr return new CallDispatcher(ctx, MGet, WithTypeTools.value, fa.faPos).fieldCall(fa, args, vector());
		var dispatch = new CallDispatcher(ctx, mode, withType, p);
		return switch acc {
			case AKField(fa):
				checkDynamicSuperMethodCall(ctx, fa, p);
				AKExpr(dispatch.fieldCall(fa, vector(), el));
			case AKUsingField(sea):
				var e = dispatch.fieldCall(sea.seAccess, vector(sea.seThis), el);
				switch sea.seAccess.faHost {
					case FHAbstract(_) if (!ctx.allowTransform):
						// transform XXXImpl.field(this,args) back into this.field(args)
						switch e.eexpr {
							case TCall(f = {eexpr: TField(_, name)},
								args) if (args.length > 0): e = mk(TCall(mk(TField(args[0], name), tDynamic, f.epos), args.slice(1)),
									e.etype, e.epos);
							case _: throw "Invalid abstract call transform";
						}
					case _:
				}
				AKExpr(e);
			case AKResolve(sea, name): AKExpr(dispatch.exprCall(dispatch.resolveCall(sea, name), vector(), el));
			case AKNo(_, p): raiseTypingError("This expression cannot be called", p);
			case AKAccess(_): raiseTypingError("This expression cannot be called", p);
			case AKAccessor(fa): AKExpr(dispatch.exprCall(getAccessor(fa, vector()), vector(), el));
			case AKUsingAccessor(sea): AKExpr(dispatch.exprCall(getAccessor(sea.seAccess, vector(sea.seThis)), vector(), el));
			case AKExpr(e): AKExpr(dispatch.exprCall(e, vector(), el));
			case AKSafeNav(sn):
				// pack the call inside the safe navigation chain
				AKSafeNav({
					snPos: sn.snPos,
					snBase: sn.snBase,
					snTempVar: sn.snTempVar,
					snAccess: buildCallAccess(ctx, sn.snAccess, el, mode, withType, p)
				});
		};
	}

	public static function buildCall(ctx:TyperContext, acc:AccessKind, el:Vector<Expr>, withType:WithTypeValue, p:Pos,
			?mode:AccessMode):TExpr return accGet(ctx, buildCallAccess(ctx, acc, el, mode == null ? MGet : mode, withType, p));

	public static function needsTempVar(e:TExpr):Bool return switch e.eexpr {
		case TLocal(_) | TTypeExpr(_) | TConst(_): false;
		case TField(e, _) | TParenthesis(e): needsTempVar(e);
		case _: true;
	};

	public static function callToString(ctx:TyperContext, e:TExpr, resume:Bool = false):TExpr {
		if (!ctx.allowTransform) return mk(e.eexpr, ctx.t.tstring, e.epos);
		inline function generate(e:TExpr):TExpr {
			// Ignore visibility of the toString field.
			ctx.f.meta.unshift({meta: MetaTag.PrivateAccess, exprs: vector(), pos: e.epos});
			var acc = Fields.typeField(TypeFieldConfig.create(resume), ctx, e, "toString", e.epos, MCall(vector()),
				WithTypeTools.withType(ctx.t.tstring));
			ctx.f.meta.shift();
			return buildCall(ctx, acc, vector(), WithTypeTools.withType(ctx.t.tstring), e.epos);
		}
		if (ctx.com.config.pfStatic && !isNullable(e.etype)) return generate(e);
		// generate `if(e == null) 'null' else e.toString()`
		var stringNull = mk(TConst(TString("null")), ctx.t.tstring, e.epos);
		if (needsTempVar(e)) {
			var tmp = allocVar(VGenerated, "tmp", e.etype, e.epos),
				local = mk(TLocal(tmp), tmp.vType, tmp.vPos);
			var check = mk(TBinop(OpEq, local, mk(TConst(TNull), tmp.vType, tmp.vPos)), ctx.t.tbool, e.epos);
			return mk(TBlock(vector(
				mk(TVar(tmp, e), tmp.vType, tmp.vPos),
				mk(TIf(check, stringNull, generate(local)), ctx.t.tstring, tmp.vPos)
			)), ctx.t.tstring, e.epos);
		}
		var check = mk(TBinop(OpEq, e, mk(TConst(TNull), e.etype, e.epos)), ctx.t.tbool, e.epos);
		return mk(TIf(check, stringNull, generate(e)), ctx.t.tstring, e.epos);
	}

	public static function typeBind(ctx:TyperContext, e:TExpr, signature:TSignature, params:Vector<Expr>, safe:Bool, p:Pos):TExpr {
		var args = signature.args, ret = signature.ret, acount = 0;
		function name(n:String):String {
			if (n == "" && !ctx.m.isDisplayFile) {
				acount++;
				return "a" + acount;
			}
			return n;
		}
		var given = [], missing = [], ordered = [], pi = 0;
		for (ai in 0...args.length) {
			var a = args[ai], param = pi < params.length ? params[pi] : null;
			if (ai == args.length - 1 && param == null && a.optional && isPosInfos(a.type)) {
				ordered.push(mkInfosT(ctx, p, [], a.type));
				continue;
			}
			var wildcard = param != null && switch param.expr {
				case EConst(Ident("_")): true;
				case _: false;
			};
			if (wildcard
				&& !ctx.com.config.pfCanSkipNonNullableArgument
				&& a.optional
				&& !isNullable(a.type)) raiseTypingError("Usage of _ is not supported for optional non-nullable arguments", param.pos);
			if (param == null || wildcard) {
				var v = allocVar(VGenerated, name(a.name), a.optional ? ctx.t.tnull(a.type) : a.type, p);
				missing.push({variable: v, optional: a.optional});
				ordered.push(mk(TLocal(v), v.vType, p));
			} else {
				var value = typeExpr(ctx, param, WithTypeTools.withArgument(a.type, a.name));
				value = AbstractCast.castOrUnify(ctx, a.type, value, param.pos);
				var v = allocVar(VGenerated, name(a.name), a.type, param.pos);
				given.push({variable: v, optional: a.optional, expr: value});
				ordered.push(mk(TLocal(v), v.vType, p));
			}
			if (param != null) pi++;
		}
		if (pi < params.length) raiseTypingError("Too many callback arguments", p);
		var declarations = given.map(pair -> mk(TVar(pair.variable, pair.expr), ctx.t.tvoid, pair.variable.vPos));
		inline function immutable(cf:TClassField):Bool return switch cf.cfKind {
			case Method(k): k != MethDynamic;
			case _: false;
		};
		switch e.eexpr {
			case TFunction(_) | TLocal({vKind: VUser(TVOLocalFunction)}):
			case TField(_, FStatic(_, cf) | FInstance(_, _, cf)) if (immutable(cf)):
			case TField(eobj, FClosure(pair, cf)) if (pair != null && immutable(cf)):
				/*
					if we're binding an instance method, we don't really need to create a closure for it,
					since we'll create a closure for the binding anyway, instead store the instance and
					call its method inside a bind-generated closure
				*/
				var vobj = allocVar(VGenerated, genLocalPrefix, eobj.etype, eobj.epos);
				declarations.unshift(mk(TVar(vobj, eobj), ctx.t.tvoid, eobj.epos));
				e = mk(TField(mk(TLocal(vobj), eobj.etype, eobj.epos), FInstance(pair.cls, pair.params, cf)), e.etype, e.epos);
			case _:
				var v = allocVar(VGenerated, genLocalPrefix, e.etype, e.epos);
				declarations.unshift(mk(TVar(v, e), ctx.t.tvoid, e.epos));
				e = mk(TLocal(v), e.etype, e.epos);
		}
		var body:TExpr;
		if (safe) {
			var base = TyperBase.getSafeNavBase(ctx, e);
			var sn:SafeNavAccess = {
				snPos: p,
				snBase: base.base,
				snTempVar: base.tempVar,
				snAccess: AKExpr(e) // This is weird, but it's not used by safe_nav_branch.
			};
			body = TyperBase.safeNavBranch(ctx, sn, () -> makeCall(ctx, base.base, Vector.fromArrayCopy(ordered), ret, p));
		} else body = makeCall(ctx, e, Vector.fromArrayCopy(ordered), ret, p);
		if (!ExtType.isVoid(follow(ret))) body = mk(TReturn(body), ret, p);
		var fn = ({
			tfArgs: missing.mapToVector(arg -> {
				variable: arg.variable,
				defaultValue: arg.optional ? Texpr.Builder.makeNull(arg.variable.vType, Globals.nullPos) : null
			}),
			tfType: ret,
			tfExpr: body
		} : core.TType.TFunc);
		var t = TFun({args: missing.mapToVector(arg -> {name: arg.variable.vName, optional: arg.optional, type: arg.variable.vType}), ret: ret});
		declarations.push(mk(TFunction(fn), t, p));
		return mk(TBlock(Vector.fromArrayCopy(declarations)), t, p);
	}

	public static function arrayAccess(ctx:TyperContext, e1:TExpr, e2:TExpr, mode:AccessMode, p:Pos):AccessKind {
		var hasAbstractArrayAccess = false;
		try return switch follow(e1.etype) {
			case TAbstract(a, pl) if (a.aImpl != null && a.aArray.length != 0): switch mode {
					case MSet(_):
						// resolve later
						AKAccess(a, pl, a.aImpl, e1, e2);
					case _:
						hasAbstractArrayAccess = true;
						var f = AbstractCast.findArrayReadAccess(ctx, a, pl, e2, p);
						AKExpr(!ctx.allowTransform ? mk(TArray(e1, e2), f.ret, p) : mkArrayGetCall(ctx, f, a.aImpl, e1, p));
				}
			case _: throw core.ds.NotFound.raise();
		} catch (_:core.ds.NotFound) {}
		var baseOk = true;
		function loop(et:T, skipAbstract:Bool = false):T return switch follow(et) {
			case TInst(c, tl) if (c.clArrayAccess != null): applyParams(c.clParams, tl, c.clArrayAccess);
			case TInst(c, tl) if (c.clSuper != null): applyParams(c.clParams, tl, loop(TInst(c.clSuper.cls, c.clSuper.params)));
			case TInst({clPath: {pack: [], name: "ArrayAccess"}}, [t]): t;
			case TInst({clPath: {pack: [], name: "Array"}}, [t]) if (t == tDynamic): tDynamic;
			case TAbstract(a, tl) if (!skipAbstract && Meta.has(MetaTag.ArrayAccess, a.aMeta)):
				var at = applyParams(a.aParams, tl, a.aThis);
				loop(at, fastEq(et, at));
			case _:
				var pt = spawnMonomorph(ctx, p), t = ctx.t.tarray(pt);
				try unifyRaise(et, t, p)
				catch (err:Dynamic) {
					switch err {
						case(core.ds.ExceptionTools.typing(_) => Some({errMessage: Unify(_)})): if (!ctx.f.isUntyped) {
								var msg = hasAbstractArrayAccess ? "No @:arrayAccess function accepts an argument of "
									+ sType(printContext(), e2.etype) : "Array access is not allowed on "
									+ sType(printContext(), e1.etype);
								baseOk = false;
								raiseOrDisplayMessage(ctx, msg, e1.epos);
							}
						case _: throw err;
					}
				}
				pt;
		};
		var pt = loop(e1.etype);
		if (baseOk) unify(ctx, e2.etype, ctx.t.tint, e2.epos);
		return AKExpr(mk(TArray(e1, e2), pt, p));
	}

	/*
		given chain of fields as the `path` argument and an `access_mode->access_kind` getter for some starting expression as `e`,
		return a new `access_mode->access_kind` getter for the whole field access chain.
	*/
	public static function fieldChain(ctx:TyperContext, path:Array<DotPathPart>, access:AccessKind, mode:AccessMode,
			withType:WithTypeValue):AccessKind {
		for (i in 0...path.length) {
			var e = accGet(ctx, access),
				part = path[i],
				intermediate = i < path.length - 1;
			// intermediate field access are just reading the value
			access = Fields.typeFieldDefaultCfg(ctx, e, part.name, part.pos, intermediate ? MGet : mode,
				intermediate ? WithTypeTools.value : withType);
		}
		return access;
	}
}
