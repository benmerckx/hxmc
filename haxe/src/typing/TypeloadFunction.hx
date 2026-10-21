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

package typing;

import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Globals.Platform;
import core.Texpr;
import core.TPrinting.MonomorphPrinting;
import core.WithType.WithTypeValue;
import context.Common.*;
import context.Typecore.Typer as TyperContext;
import syntax.Lexer;
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
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.TyperPass;
import context.Typecore.TyperManager;
import typing.FunctionArguments;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// Typing of functions and their arguments.

class TypeloadFunction {
	public static function saveFieldState(ctx:TyperContext):Void->Void {
		var locals = ctx.f.locals;
		return function() {
			ctx.f.locals = locals;
		};
	}

	public static function typeFunctionParams(ctx:TyperContext, fd:Func, host:TypeParamHost,
			fname:String):TypeParams return Typeload.typeTypeParams(ctx, host, {
			pack: [],
			name: fname
		}, fd.fParams);

	static function typeFunctionInner(ctx:TyperContext, args:FunctionArguments, ret:T, syntax:Null<Expr>, doDisplay:Bool, p:Pos):TExpr {
		ctx.e.ret = ret;
		ctx.e.opened = [];
		enterFieldTypingPass(ctx.g,
			{name: "type_function", path: ctx.c.curclass.clPath.pack.concat([ctx.c.curclass.clPath.name, ctx.f.curfield.cfName])});
		args.bringIntoContext(ctx);
		if (syntax == null) {
			if (ignoreError(ctx.com))
				// when we don't care because we're in display mode, just act like
				// the function has an empty block body. this is fine even if function
				// defines a return type, because returns aren't checked in this mode
				syntax = {expr: EBlock(vector()), pos: p};
			else if (ctx.e.curfun == FunMember && hasClassFlag(ctx.c.curclass,
				CAbstract)) raiseTypingError("Function body or abstract modifier required", p);
			else raiseTypingError("Function body required", p);
		}
		var positionDebug = Meta.has(MetaTag.Custom(":debug.position"), ctx.f.curfield.cfMeta);
		var e:TExpr;
		if (!doDisplay) {
			if (positionDebug) Sys.println("syntax:\n" + Ast.dumpWithPos(syntax));
			e = typeExpr(ctx, syntax, NoValue);
		} else {
			var displayDebug = Meta.has(MetaTag.Custom(":debug.display"), ctx.f.curfield.cfMeta);
			if (displayDebug) Sys.println("before processing:\n" + Ast.dumpWithPos(syntax));
			if (!ctx.com.partScope.parserState.hadParserResume) syntax = context.display.Display.preprocessExpr(ctx.com, syntax);
			if (displayDebug) Sys.println("after processing:\n" + Ast.dumpWithPos(syntax));
			e = typeExpr(ctx, syntax, NoValue);
		}
		switch e.eexpr {
			case TMeta({meta: MetaTag.MergeBlock}, e1 = {eexpr: TBlock(_)}):
				e = e1;
			case _:
		}
		inline function hasReturn(e:TExpr):Bool {
			function loop(e:TExpr):Void switch e.eexpr {
				case TReturn(v) if (v != null):
					throw core.ds.Exit.raise();
				case TFunction(_):
				case _:
					Texpr.iter(loop, e);
			}
			try {
				loop(e);
				return false;
			} catch (_:core.ds.Exit) {
				return true;
			}
		}
		switch follow(ret) {
			case TAbstract({aPath: {pack: [], name: "Void"}}, _):
			// We have to check for the presence of return expressions here because
			// in the case of Dynamic ctx.ret is still a monomorph. If we indeed
			// don't have a return expression we can link the monomorph to Void. We
			// can _not_ use type_iseq to avoid the Void check above because that
			// would turn Dynamic returns to Void returns.
			case TMono(_) if (!hasReturn(e)):
				unify(ctx, ctx.t.tvoid, ret, p);
			case _:
				try TypeloadCheck.returnFlow(ctx, e)
				catch (_:core.ds.Exit) {}
		}
		function findSuper(e:TExpr):Void switch e.eexpr {
			case TCall({eexpr: TConst(TSuper)}, _):
				throw core.ds.Exit.raise();
			case TFunction(_):
			case _:
				Texpr.iter(findSuper, e);
		}
		inline function superConstructor():Null<{wasForced:Bool, type:T}> {
			var sup = ctx.c.curclass.clSuper;
			if (sup == null) return null;
			try {
				var cf = getConstructor(sup.cls);
				return {wasForced: Meta.has(MetaTag.CompilerGenerated, cf.cfMeta), type: TInst(sup.cls, sup.params)};
			} catch (_:core.ds.NotFound) {
				return null;
			}
		}
		if (ctx.e.curfun == FunConstructor) {
			var constructorBody = e;
			delay(ctx.g, PForce, function() TypeloadCheck.checkFinalVars(ctx, constructorBody));
			var sup = superConstructor();
			if (sup != null) try {
				findSuper(e);
				if (sup.wasForced) e = concat(mk(TCall(mk(TConst(TSuper), sup.type, e.epos), vector()), ctx.t.tvoid, e.epos), e);
				else displayError(ctx.com, "Missing super constructor call", p);
			} catch (_:core.ds.Exit) {}
		}
		if ((ctx.e.curfun == FunMember || ctx.e.curfun == FunConstructor) && ctx.f.vthis != null) {
			var v = ctx.f.vthis;
			var ev = mk(TVar(v, mk(TConst(TThis), ctx.c.tthis, p)), ctx.t.tvoid, p);
			switch e.eexpr {
				case TBlock(l):
					if (ctx.com.config.pfThisBeforeSuper) e = mk(TBlock(VectorTools.cons(ev, l)), e.etype, e.epos);
					else {
						function hasV(e:TExpr):Bool return switch e.eexpr {
							case TLocal(v1) if (v1 == v): true;
							case _: Texpr.checkExpr(hasV, e);
						};
						function insert(l:Vector<TExpr>):Vector<TExpr> {
							if (l.length == 0) return vector(); // should not happen...
							var first = l[0];
							return hasV(first) ? VectorTools.cons(ev, l) : VectorTools.cons(first, insert(l.slice(1)));
						}
						e = mk(TBlock(insert(l)), e.etype, e.epos);
					}
				case _:
					e = mk(TBlock(vector(ev, e)), e.etype, p);
			}
		}
		for (r in ctx.e.opened) r.aStatus = Closed;
		if (Meta.has(MetaTag.Custom(":debug.mono"), ctx.f.curfield.cfMeta)) {
			var pctx = printContext();
			inline function printMono(i:Int,
					m:TMono):String return StringTools.lpad(Std.string(i), " ", 4) + ": " + MonomorphPrinting.sMono(sType, pctx, true, m);
			Sys.println("BEFORE:");
			var monos = [];
			var values = ctx.e.monomorphs;
			for (i in 0...context.Typecore.MonomorphList.size(values)) {
				var m = values.mono(i),
					mp = values.pos(i),
					s = printMono(i, m);
				var spos = "unknown";
				if (mp.pmin != -1) {
					var coords = Lexer.getPosCoords(mp);
					spos = coords.lineStart + ":" + coords.columnStart;
				}
				Sys.println(s + " (" + spos + ")");
				safeMonoClose(ctx, m, mp);
				monos.push({
					index: i,
					mono: m,
					pos: mp,
					text: s
				});
			}
			Sys.println("CHANGED:");
			for (m in monos) {
				var s = printMono(m.index, m.mono);
				if (s != m.text) Sys.println(s);
			}
		} else {
			var l = ctx.e.monomorphs;
			for (i in 0...context.Typecore.MonomorphList.size(l)) safeMonoClose(ctx, l.mono(i), l.pos(i));
		}
		if (positionDebug) Sys.println("typing:\n" + Texpr.dumpWithPos("", e));
		return e;
	}

	public static function typeFunction(ctx:TyperContext, args:FunctionArguments, ret:T, e:Null<Expr>, doDisplay:Bool, p:Pos):TExpr {
		var save = saveFieldState(ctx);
		try {
			var result = typeFunctionInner(ctx, args, ret, e, doDisplay, p);
			save();
			return result;
		} catch (err:haxe.Exception) {
			save();
			throw err;
		}
	}

	public static function addConstructor(ctxC:TyperContext, c:TClass, forceConstructor:Bool, p:Pos):Void {
		if (c.clConstructor != null) return;
		var constructor:Null<{field:TClassField, cls:TClass, params:TParams}> = null;
		try constructor = getConstructorClass(c, extractParamTypes(c.clParams))
		catch (_:core.ds.NotFound) {}
		if (constructor != null && !hasClassFlag(c, CExtern)) {
			var cfsup = constructor.field,
				csup = constructor.cls,
				cparams = constructor.params;
			var cf = mkField("new", cfsup.cfType, p, Globals.nullPos);
			cf.cfKind = cfsup.cfKind;
			cf.cfParams = cfsup.cfParams;
			cf.cfMeta = cfsup.cfMeta.filter(m -> m.meta == MetaTag.CompilerGenerated);
			var t = spawnMonomorph(ctxC, p);
			var r = makeLazy(ctxC.g, t, function() {
				var ctx = TyperManager.cloneForField(ctxC, cf, cf.cfParams);
				follow(cfsup.cfType); // make sure it's typed
				for (cf in cfsup.cfOverloads) follow(cf.cfType);
				function mapArg(arg:{variable:TVar, defaultValue:Null<TExpr>}):{variable:TVar, defaultValue:Null<TExpr>} {
					// let's optimize a bit the output by not always copying the default value
					// into the inherited constructor when it's not necessary for the platform
					var v = arg.variable, def = arg.defaultValue;
					inline function nullValue(v:TVar):TExpr return Texpr.Builder.makeNull(v.vType, v.vPos);
					if (def != null && !ctx.com.config.pfStatic) return {variable: v, defaultValue: nullValue(v)};
					switch [ctx.com.platform, def] {
						case [Flash, {eexpr: TConst(TString(_))}] if (!hasClassFlag(csup, CExtern)):
							return {variable: v, defaultValue: nullValue(v)};
						case [Cpp, {eexpr: TConst(TString(_))}]:
							return arg;
						case [Cpp, _] if (def != null):
							var v1 = core.ds.Record.copy(v);
							v1.vType = ctx.t.tnull(v.vType);
							return {variable: v1, defaultValue: nullValue(v1)};
						case _:
							return arg;
					}
				}
				var args:Vector<{variable:TVar, defaultValue:Null<TExpr>}> = switch cfsup.cfExpr {
					case {eexpr: TFunction(f)}: f.tfArgs.map(mapArg);
					case _:
						var values = getValueMeta(cfsup.cfMeta);
						switch follow(cfsup.cfType) {
							case TFun({args: args, ret: _}): args.map(function(arg) {
									var def:Null<TExpr>;
									if (values.exists(arg.name)) def = FunctionArguments.typeFunctionArgValue(ctx, arg.type,
										values.get(arg.name), false);
									else def = arg.optional ? Texpr.Builder.makeNull(arg.type, Globals.nullPos) : null;
									return mapArg({
										variable: allocVar(VUser(TVOArgument), arg.name, arg.optional ? ctx.t.tnull(arg.type) : arg.type,
											p), // TODO: var pos
										defaultValue: def
									});
								});
							case t:
								displayError(ctxC.com, "Unexpected constructor type: " + sTypeKind(t), cfsup.cfNamePos);
								vector();
						}
				};
				var cp = c.clPos;
				var vars = args.map(arg -> {
					variable: allocVar(VUser(TVOArgument), arg.variable.vName, applyParams(csup.clParams, cparams, arg.variable.vType),
						arg.variable.vPos),
					defaultValue: arg.defaultValue
				});
				var superCall = mk(TCall(mk(TConst(TSuper), TInst(csup, cparams), cp),
					vars.map(arg -> mk(TLocal(arg.variable), arg.variable.vType, cp))),
					ctx.t.tvoid, cp);
				var constr = mk(TFunction({tfArgs: vars, tfType: ctx.t.tvoid, tfExpr: superCall}), TFun({
					args: vars.map(arg -> {name: arg.variable.vName, optional: arg.defaultValue != null, type: arg.variable.vType}),
					ret: ctx.t.tvoid
				}), cp);
				cf.cfExpr = constr;
				cf.cfType = t;
				unify(ctx, t, constr.etype, cp);
				return t;
			}, "add_constructor");
			cf.cfType = TLazy(r);
			c.clConstructor = cf;
		} else if (forceConstructor) {
			var constr = mk(TFunction({tfArgs: vector(), tfType: ctxC.t.tvoid, tfExpr: mk(TBlock(vector()), ctxC.t.tvoid, p)}),
				tfun(vector(), ctxC.t.tvoid), p);
			var cf = mkField("new", constr.etype, p, Globals.nullPos);
			cf.cfExpr = constr;
			cf.cfType = constr.etype;
			cf.cfMeta = [{meta: MetaTag.CompilerGenerated, exprs: vector(), pos: Globals.nullPos}];
			cf.cfKind = Method(MethNormal);
			c.clConstructor = cf;
		}
	}

	public static function initHooks():Void {
		Typeload.typeFunctionParamsRef = typeFunctionParams;
	}

	static function __init__():Void initHooks();
}
