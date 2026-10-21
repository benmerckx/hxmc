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
import context.Common;
import context.Common.*;
import core.TUnification;
import core.TUnification.*;
import core.Native as NativeTools;
import core.StringError;
import core.ds.NotFound;
import core.ds.Exit;
import core.ds.PMap;
import core.Texpr;
import core.Texpr.*;
import context.PurityState;
import core.Globals.*;
import core.DisplayTypes;
import codegen.Overloads;
import core.Texpr.DeadEnd;
import core.display.CompletionItem.TKind;
import core.display.CompletionItem.CompletionModuleKind;
import typing.Typeload;
import typing.TypeloadCheck.*;
import core.ds.VectorTools.vector;

class BuildCanceled extends haxe.Exception {
	public final state:BuildState;

	public function new(state:BuildState) {
		super("Build canceled");
		this.state = state;
	}
}

typedef RedefinitionContext = {var cNew:TClass; var cfNew:TClassField; var cOld:TClass; var cfOld:TClassField; var map:T->T; var tOld:T;}

enum CheckOverrideKind {
	NothingToDo;
	NormalOverride(ctx:RedefinitionContext);
	OverloadOverride(f:Void->Void);
}

// Various checks performed while loading types.
class TypeloadCheck {
	public static function isGenericParameter(ctx:Typer, c:TClass):Bool {
		// first check field parameters, then class parameters
		var name = c.clPath.name;
		try {
			lookupParam(name, ctx.f.curfield.cfParams);
			return hasClassFieldFlag(ctx.f.curfield, CfGeneric);
		} catch (e:Dynamic) {
			if (!Std.isOfType(e, NotFound)) throw e;
		}
		try {
			lookupParam(name, ctx.typeParams);
			return switch ctx.c.curclass.clKind {
				case KGeneric: true;
				case _: false;
			};
		} catch (e:Dynamic) {
			if (!Std.isOfType(e, NotFound)) throw e;
			return false;
		}
	}

	public static function validRedefinition(com:CommonContext, map1:T->T, map2:T->T, f1:TClassField, t1:T, f2:TClassField, t2:T):Void { // child, parent
		var tctx:TypeParamUnificationContext = {typeParamPairs: [], knownTypeParams: f1.cfParams};
		var uctx = defaultUnificationContext();
		uctx.typeParamMode = TpDefinition(tctx);
		inline function valid(a:Dynamic, b:Dynamic):Void {
			unifyCustom(uctx, a, b);
			if (isNull(a) != isNull(b)
				|| (follow(a) == tDynamic && follow(b) != tDynamic)) throw new core.TUnification.Unify_error([CannotUnify(a, b)]);
		}
		switch [
			PurityStateTools.getPurityFromMeta(f2.cfMeta),
			PurityStateTools.getPurityFromMeta(f1.cfMeta)
		] {
			case [Pure, MaybePure]:
				f1.cfMeta.unshift({
					meta: MetaTag.Pure,
					exprs: vector({expr: EConst(Ident("expect")), pos: mkZeroRangePos(f2.cfPos)}),
					pos: Globals.nullPos
				});
			case [ExpectPure(p), MaybePure]:
				f1.cfMeta.unshift({meta: MetaTag.Pure, exprs: vector({expr: EConst(Ident("expect")), pos: p}), pos: Globals.nullPos});
			case _:
		}
		switch [f1.cfKind, f2.cfKind] {
			case [Method(m1), Method(m2)] if (m1 != MethDynamic && m2 != MethDynamic):
				switch [followWithCoro(t1), followWithCoro(t2)] {
					case [Coro(_), NotCoro(_)]: throw new core.TUnification.Unify_error([UnifyCustom("Method should be coroutine")]);
					case [NotCoro(_), Coro(_)]: throw new core.TUnification.Unify_error([UnifyCustom("Method should not be coroutine")]);
					case [NotCoro(TFun({args: args1, ret: r1})), NotCoro(TFun({args: args2, ret: r2}))] |
						[Coro({args: args1, ret: r1}), Coro({args: args2, ret: r2})]:
						if (args1.length != args2.length)
							throw new core.TUnification.Unify_error([UnifyCustom("Different number of function arguments")]);
						var i = 0;
						try {
							valid(r1, r2);
							for (index in 0...args1.length) {
								var a1 = args1[index], a2 = args2[index];
								i++;
								if (a1.optional != a2.optional) throw new core.TUnification.Unify_error([
									CannotUnify(a2.type, a1.type),
									NotMatchingOptional(a2.optional, a1.optional, a1.name)
								]);
								try valid(a2.type, a1.type)
								catch (e:Dynamic) {
									switch e {
										case(core.ds.ExceptionTools.unification(_) =>
											Some(_)): throw new core.TUnification.Unify_error([CannotUnifyImplementation(a1.type,
												a2.type)]);
										case _: throw e;
									}
								}
							}
						} catch (e:Dynamic) {
							switch e {
								case(core.ds.ExceptionTools.unification(_) => Some(l)):
									var msg = i == 0 ? InvalidReturnType : InvalidFunctionArgument(i, args1.length);
									throw new core.TUnification.Unify_error([CannotUnify(t1, t2), msg].concat(l));
								case _: throw e;
							}
						}
					case _: displayError(com,
							"Unexpected types when checking redefinition of "
							+ f1.cfName
							+ ":\n\tf1: "
							+ sTypeKind(t1)
							+ "\n\tf2: "
							+ sTypeKind(t2),
							f1.cfPos);
				}
			case [_, Var({vWrite: AccNo | AccNever})]:
				// write variance
				valid(t1, t2);
			case [_, Var({vRead: AccNo | AccNever})]:
				// read variance
				valid(t2, t1);
			case [_, _] if (hasClassFieldFlag(f2, CfFinal)):
				// write variance
				valid(t1, t2);
			case _:
				// in case args differs, or if an interface var
				typeEq(EqStrict, t1, t2);
				if (isNull(t1) != isNull(t2)) throw new core.TUnification.Unify_error([CannotUnify(t1, t2)]);
		}
		inline function assignTtp(ttp1:TypedTypeParam, ttp2:TypedTypeParam):Void {
			var ct1 = getConstraints(ttp1), ct2 = getConstraints(ttp2);
			inline function fail(t:T):Void {
				throw new core.TUnification.Unify_error([
					UnifyCustom("Constraint unsatisfied for type parameter " + ttp2.ttpName + ": " + sType(printContext(), t))
				]);
			}
			if (ct2.length == 0) return;
			if (ct1.length == 0) fail(ct2[0]);
			for (t2 in ct2) {
				var mapped = map2(t2), found = false;
				for (t1 in ct1) try {
					TUnification.unifyCustom(uctx, map1(t1), mapped);
					found = true;
					break;
				} catch (e:Dynamic) {
					switch e {
						case(core.ds.ExceptionTools.unification(_) => Some(_)):
						case _:
							throw e;
					}
				}
				if (!found) fail(mapped);
			}
		}
		for (pair in tctx.typeParamPairs) assignTtp(pair.b, pair.a);
	}

	public static function copyMeta(source:Metadata, target:Metadata, selected:Array<core.MetaList.StrictMeta>):Metadata {
		var result = target.copy();
		for (m in source) if (selected.contains(m.meta)) result.unshift(m);
		return result;
	}

	public static function checkNativeNameOverride(ctx:Typer, child:TClassField, base:TClassField):Void {
		inline function error(bp:Pos,
				cp:Pos):Void displayErrorExt(ctx.com,
				makeError(Custom("Field " + child.cfName + " has different @:native value than in superclass"), cp,
					[makeError(Custom(complMsg("Base field is defined here")), bp)]));
		try {
			var cn = NativeTools.getNativeName(child.cfMeta);
			try {
				var bn = NativeTools.getNativeName(base.cfMeta);
				if (bn.name != cn.name) error(bn.pos, cn.pos);
			} catch (e:Dynamic) {
				if (!Std.isOfType(e, NotFound)) throw e;
				error(base.cfNamePos, cn.pos);
			}
		} catch (e:Dynamic) {
			if (!Std.isOfType(e, NotFound)) throw e;
		}
	}

	public static function checkOverrideField(ctx:Typer, p:Pos, r:RedefinitionContext):Void {
		var i = r.cfNew.cfName,
			hasOverride = hasClassFieldFlag(r.cfNew, CfOverride);
		checkNativeNameOverride(ctx, r.cfNew, r.cfOld);
		// allow to define fields that are not defined for this platform version in superclass
		switch r.cfNew.cfKind {
			case Var({vRead: AccRequire(_)}):
				throw NotFound.raise();
			case _:
		}
		if (hasClassFieldFlag(r.cfOld, CfAbstract)) {
			if (hasOverride) displayError(ctx.com,
				"Field "
				+ i
				+ " is declared 'override' but parent field "
				+ i
				+ " is 'abstract' and does not provide any implementation to override",
				p);
			else addClassFieldFlag(r.cfNew, CfOverride); // our spec requires users to not "override" abstract functions, but our implementation depends on implementations to be declared with "override" ¯\_(ツ)_/¯
		}
		if (hasClassFieldFlag(r.cfOld, CfOverload)
			&& !hasClassFieldFlag(r.cfNew,
				CfOverload)) displayError(ctx.com,
				"Field " + i + " should be declared with overload since it was already declared as overload in superclass", p);
		else if (!hasOverride && !hasClassFieldFlag(r.cfOld, CfAbstract)) {
			if (hasClassFlag(r.cNew, CExtern)) addClassFieldFlag(r.cfNew, CfOverride);
			else displayError(ctx.com,
				"Field "
				+ i
				+ " should be declared with 'override' since it is inherited from superclass "
				+ Globals.sTypePath(r.cOld.clPath),
				p);
		} else if (!hasClassFieldFlag(r.cfNew, CfPublic)
			&& hasClassFieldFlag(r.cfOld,
				CfPublic)) displayError(ctx.com, "Field " + i + " has less visibility (public/private) than superclass one", p);
		else switch [r.cfNew.cfKind, r.cfOld.cfKind] {
			case [_, Method(MethInline)]:
				displayError(ctx.com, "Field " + i + " is inlined and cannot be overridden", p);
			case [a, b] if (fieldKindEq(a, b)):
			case [Method(MethInline), Method(MethNormal)]: // allow to redefine a method as inlined
			case _:
				displayError(ctx.com, "Field " + i + " has different property access than in superclass", p);
		}
		if (hasClassFieldFlag(r.cfOld, CfFinal)) displayError(ctx.com, "Cannot override final method " + i, p);
		try validRedefinition(ctx.com, r.map, r.map, r.cfNew, r.cfNew.cfType, r.cfOld, r.tOld)
		catch (e:Dynamic) {
			switch e {
				case(core.ds.ExceptionTools.unification(_) => Some(l)):
					displayErrorExt(ctx.com,
						makeError(Custom("Field " + i + " overrides parent class with different or incomplete type"), p, [
							makeError(Custom(complMsg(errorMsg(Unify(l)))), p),
							makeError(Custom(complMsg("Base field is defined here")), r.cfOld.cfNamePos)
						]));
				case _:
					throw e;
			}
		}
	}

	public static function findOverrideField(ctx:Typer, cNew:TClass, cfNew:TClassField, cOld:TClass, tl:TParams,
			getSuperField:TClass->String->CastField, isOverload:Bool, p:Pos):Null<RedefinitionContext> {
		var i = cfNew.cfName;
		try {
			if (isOverload && !hasClassFieldFlag(cfNew,
				CfOverload)) displayError(ctx.com, "Missing overload declaration for field " + i, p);
			var sup = getSuperField(cOld, i),
				map = TClassTools.getMapFunction(cOld, tl);
			return {
				cNew: cNew,
				cfNew: cfNew,
				cOld: cOld,
				cfOld: sup.field,
				map: map,
				tOld: map(sup.type)
			};
		} catch (e:Dynamic) {
			if (!Std.isOfType(e, NotFound)) throw e;
			if (hasClassFieldFlag(cfNew, CfOverride)) {
				var msg:String;
				if (isOverload) msg = "Field " + i + " is declared 'override' but no compatible overload was found";
				else {
					var fields = [];
					for (pair in TClassTools.getAllSuperFields(cNew)) switch pair.field.cfKind {
						case Method(MethNormal) if (!hasClassFieldFlag(pair.field, CfFinal)):
							fields.unshift(pair.field.cfName);
						case _:
					}
					msg = StringError.stringError(i, fields, "Field " + i + " is declared 'override' but doesn't override any field");
				}
				displayError(ctx.com, msg, p);
			}
			return null;
		}
	}

	public static function hasSuperCall(name:String, e:TExpr):Bool return switch e.eexpr {
		case TCall({eexpr: TField({eexpr: TConst(TSuper)}, FInstance(_, _, cf))}, _) if (cf.cfName == name): true;
		case _: checkExpr(e -> hasSuperCall(name, e), e);
	};

	public static function checkCallSuper(com:CommonContext, r:RedefinitionContext, e:TExpr):Void {
		var name = r.cfOld.cfName;
		function active(c:TClass, cf:TClassField):Bool {
			if (hasClassFieldFlag(r.cfOld, CfAbstract)) return false;
			try {
				var m = Meta.get(MetaTag.CallSuper, cf.cfMeta);
				return switch m.exprs {
					case [{expr: EConst(Ident("false"))}]: false;
					case _: true;
				};
			} catch (e:Dynamic) {
				if (!Std.isOfType(e, NotFound)) throw e;
				var sup = c.clSuper;
				if (sup == null || !sup.cls.clFields.exists(name)) return false;
				return active(sup.cls, sup.cls.clFields.get(name));
			}
		}
		if (active(r.cOld, r.cfOld) && !hasSuperCall(name, e)) displayError(com, "Missing call to super." + name + "()", r.cfNew.cfNamePos);
	}

	public static function checkOverriding(ctx:Typer, c:TClass, f:TClassField):CheckOverrideKind {
		var sup = c.clSuper;
		if (sup == null) {
			if (hasClassFieldFlag(f,
				CfOverride)) displayError(ctx.com, "Field " + f.cfName + " is declared 'override' but doesn't override any field", f.cfPos);
			return NothingToDo;
		}
		var csup = sup.cls, params = sup.params, p = f.cfNamePos, i = f.cfName;
		if (hasClassFieldFlag(f, CfOverload)) {
			var overloads = getOverloads(ctx.com, csup, i);
			for (pair in overloads) switch pair.field.cfKind {
				// check if any super class fields are vars
				case Var(_):
					displayError(ctx.com, "A variable named '" + pair.field.cfName + "' was already declared in a superclass", f.cfPos);
				case _:
			}
			return OverloadOverride(function() {
				// find the exact field being overridden
				var r = findOverrideField(ctx, c, f, csup, params, function(csup:TClass, i:String):CastField {
					for (pair in overloads) if (Overloads.sameOverloadArgs(f.cfType, applyParams(csup.clParams, params, pair.type), f,
						pair.field)) return pair;
					throw NotFound.raise();
				}, true, p);
				if (r != null) checkOverrideField(ctx, p, r);
			});
		}
		var r = findOverrideField(ctx, c, f, csup, params, function(csup:TClass, i:String):CastField {
			var raw = rawClassField(f -> f.cfType, csup, params, i);
			return {type: raw.type, field: raw.field};
		}, false, p);
		return r == null ? NothingToDo : NormalOverride(r);
	}

	public static function classFieldNoInterf(c:TClass, i:String):{map:T->T, type:T, field:TClassField} {
		if (c.clFields.exists(i)) {
			var f = c.clFields.get(i);
			return {map: function(t:T) return t, type: f.cfType, field: f};
		}
		var sup = c.clSuper;
		if (sup == null) throw NotFound.raise();
		// rec over class_field
		var raw = rawClassField(f -> f.cfType, sup.cls, sup.params, i),
			map = TClassTools.getMapFunction(sup.cls, sup.params);
		return {map: map, type: applyParams(sup.cls.clParams, sup.params, raw.type), field: raw.field};
	}

	public static function returnFlow(ctx:Typer, e:TExpr):Void {
		inline function error():Void {
			displayError(ctx.com, "Missing return: " + sType(printContext(), ctx.e.ret), e.epos);
			throw Exit.raise();
		}
		switch e.eexpr {
			case TReturn(_) | TThrow(_):
			case TParenthesis(e) | TMeta(_, e):
				returnFlow(ctx, e);
			case TBlock(el):
				if (el.length == 0) error();
				for (i in 0...el.length) {
					if (i == el.length - 1) returnFlow(ctx, el[i]);
					else if (DeadEnd.hasDeadEnd(el[i])) return;
				}
			case TIf(_, e1, e2) if (e2 != null):
				returnFlow(ctx, e1);
				returnFlow(ctx, e2);
			case TSwitch(s) if (s.switchDefault != null):
				for (c in s.switchCases) returnFlow(ctx, c.caseExpr);
				returnFlow(ctx, s.switchDefault);
			case TSwitch(s) if (s.switchExhaustive):
				for (c in s.switchCases) returnFlow(ctx, c.caseExpr);
			case TTry(e, cases):
				returnFlow(ctx, e);
				for (c in cases) returnFlow(ctx, c.expr);
			case TWhile({eexpr: TConst(TBool(true))}, body, _):
				// a special case for "inifite" while loops that have no break
				function loop(e:TExpr):Void switch e.eexpr {
					// ignore nested loops to not accidentally get one of its breaks
					case TWhile(_):
					case TBreak:
						error();
					case _:
						iter(loop, e);
				}
				loop(body);
			case _:
				if (!DeadEnd.hasDeadEnd(e)) error();
		}
	}

	public static function checkGlobalMetadata(ctx:Typer, meta:Metadata, fAdd:MetadataEntry->Void, mpath:GlobalTypePath,
			tpath:GlobalTypePath, so:Null<String>):Void {
		var sl1 = fullDotPath2(mpath, tpath), fieldMode = so != null;
		if (fieldMode) sl1 = sl1.concat([so]);
		for (entry in ctx.com.globalMetadata) if (((fieldMode && entry.toFields) || (!fieldMode && entry.toTypes))
			&& matchPath(entry.recursive, sl1, entry.path)) fAdd(entry.meta);
		if (ctx.m.isDisplayFile) delay(ctx.g, PCheckConstraint, function() context.display.DisplayEmitter.checkDisplayMetadata(ctx, meta));
	}

	public static function checkFinalVars(ctx:Typer, e:TExpr):Void {
		var finalVars = new Map<String, Bool>(), ordered = [];
		function loop(c:TClass):Void {
			for (cf in c.clOrderedFields) switch cf.cfKind {
				case Var(_) if (hasClassFieldFlag(cf, CfFinal) && cf.cfExpr == null && !finalVars.exists(cf.cfName)):
					finalVars.set(cf.cfName, false);
					ordered.push({c: c, field: cf});
				case _:
			}
			var sup = c.clSuper;
			if (sup != null && hasClassFlag(sup.cls, CAbstract) && !hasConstructor(sup.cls)) loop(sup.cls);
		}
		loop(ctx.c.curclass);
		if (finalVars.iterator().hasNext()) {
			function findInits(e:TExpr):Void switch e.eexpr {
				case TBinop(OpAssign, {eexpr: TField({eexpr: TConst(TThis)}, fa)}, e2):
					finalVars.remove(fieldName(fa));
					findInits(e2);
				case _:
					iter(findInits, e);
			}
			findInits(e);
			if (finalVars.iterator().hasNext()) {
				var sub = ordered.filter(pair -> finalVars.exists(pair.field.cfName))
					.map(pair -> makeError(Custom("Uninitialized field"), pair.field.cfNamePos));
				sub.reverse();
				displayErrorExt(ctx.com,
					makeError(Custom("Some final fields are uninitialized in this class"), ctx.c.curclass.clNamePos, sub));
			}
		}
	}
}

class Inheritance {
	public static function isBasicClassPath(path:GlobalTypePath):Bool return path.pack.length == 0
		&& ["Array", "String", "Date", "Xml"].contains(path.name);

	public static function checkExtends(ctx:Typer, c:TClass, t:T, p:Pos):ClassAndParams return switch follow(t) {
		case TInst(csup, params):
			if (isBasicClassPath(csup.clPath)
				&& !(hasClassFlag(c, CExtern) && hasClassFlag(csup, CExtern))) raiseTypingError("Cannot extend basic class", p);
			if (extendsClass(csup, c)) raiseTypingError("Recursive class", p);
			switch csup.clKind {
				case KTypeParameter(_):
					if (TypeloadCheck.isGenericParameter(ctx,
						csup)) raiseTypingError("Extending generic type parameters is no longer allowed in Haxe 4", p);
					raiseTypingError("Cannot extend type parameters", p);
				case _: {cls: csup, params: params};
			}
		case t: raiseTypingError("Should extend by using a class, found " + sTypeKind(t), p);
	};

	public static function checkInterface(com:CommonContext, g:TyperGlobals, missing:Array<{field:TClassField, type:T}>, c:TClass,
			intf:TClass, params:TParams):Void {
		var uctx = defaultUnificationContext();
		for (pair in intf.clImplements) checkInterface(com, g, missing, c, pair.cls,
			pair.params.map(t -> applyParams(intf.clParams, params, t)));
		var p = c.clNamePos;
		inline function checkField(f:TClassField):Void {
			var t = applyParams(intf.clParams, params, f.cfType),
				isOverload = false;
			inline function implicitField():TClassField {
				var cf = core.ds.Record.copy(f);
				cf.cfOverloads = [];
				cf.cfType = applyParams(intf.clParams, params, f.cfType);
				if (c.clFields.exists(cf.cfName)) {
					var previous = c.clFields.get(cf.cfName);
					com.overloadCache.remove({path: c.clPath, name: f.cfName});
					previous.cfOverloads.unshift(cf);
				} else TClassTools.addField(c, cf);
				return cf;
			}
			inline function isMethod():Bool return switch f.cfKind {
				case Method(_): true;
				case Var(_): false;
			};
			try {
				var previous = TypeloadCheck.classFieldNoInterf(c, f.cfName),
					map2 = previous.map,
					t2 = previous.type,
					f2 = previous.field;
				if (f2.cfOverloads.length != 0 || hasClassFieldFlag(f2, CfOverload)) {
					var overloads = getOverloads(com, c, f.cfName);
					isOverload = true;
					var found = false;
					for (pair in overloads) if (Overloads.sameOverloadArgs(t, pair.type, f, pair.field)) {
						t2 = pair.type;
						f2 = pair.field;
						found = true;
						break;
					}
					if (!found) throw NotFound.raise();
				}
				delay(g, PForce, function() {
					follow(f2.cfType); // force evaluation
					var p = f2.cfNamePos;
					inline function mkind(m:core.TType.MethodKind):Int return switch m {
						case MethNormal | MethInline: 0;
						case MethDynamic: 1;
						case MethMacro: 2;
					};
					var sameKind = switch [f.cfKind, f2.cfKind] {
						case [Var(_), Var(_)]: true;
						case [Method(m1), Method(m2)]: mkind(m1) == mkind(m2);
						case _: false;
					};
					if (hasClassFieldFlag(f, CfPublic)
						&& !hasClassFieldFlag(f2, CfPublic)
						&& !Meta.has(MetaTag.CompilerGenerated,
							f.cfMeta)) displayError(com,
							"Field " + f.cfName + " should be public as requested by " + Globals.sTypePath(intf.clPath), p);
					else if (!unifyKind(uctx, f2.cfKind, f.cfKind)
						|| !sameKind) displayError(com,
							"Field "
							+ f.cfName
							+ " has different property access than in "
							+ Globals.sTypePath(intf.clPath)
							+ ": "
							+ sKind(f2.cfKind)
							+ " should be "
							+ sKind(f.cfKind),
							p);
					else try TypeloadCheck.validRedefinition(com, TClassTools.getMapFunction(intf, params), map2, f2, t2, f,
						applyParams(intf.clParams, params, f.cfType))
					catch (e:Dynamic) {
						switch e {
							case(core.ds.ExceptionTools.unification(_) => Some(l)):
								if (!hasClassFlag(c,
									CExtern)) displayErrorExt(com,
										makeError(Custom("Field "
											+ f.cfName
											+ " has different type than in "
											+ Globals.sTypePath(intf.clPath)),
											p, [
												makeError(Custom(complMsg(errorMsg(Unify(l)))), p),
												makeError(Custom(complMsg("Interface field is defined here")), f.cfNamePos)
											]));
							case _:
								throw e;
						}
					}
				});
			} catch (e:Dynamic) {
				if (!Std.isOfType(e, NotFound)) throw e;
				if (hasClassFlag(c, CAbstract) && isMethod()) addClassFieldFlag(implicitField(), CfAbstract);
				else if (hasClassFieldFlag(f, CfDefault)) {
					var cf = implicitField();
					cf.cfExpr = null;
					addClassFieldFlag(cf, CfExtern);
					addClassFieldFlag(cf, CfOverride);
				} else if (!hasClassFlag(c, CInterface)) {
					if (context.display.Diagnostics.errorInDiagnosticsRun(com, c.clPos)) missing.push({field: f, type: t});
					else {
						var msg:String;
						if (isOverload) {
							var pc = printContext();
							var args = switch follow(f.cfType) {
								case TFun({args: args, ret: _}): args.map(a -> (a.optional ? "?" : "")
										+ a.name
										+ " : "
										+ sType(pc, a.type))
										.join(", ");
								case _: throw "Invalid overload type";
							};
							msg = "No suitable overload for "
								+ f.cfName
								+ "( "
								+ args
								+ " ), as needed by "
								+ Globals.sTypePath(intf.clPath)
								+ " was found";
						} else msg = "Field " + f.cfName + " needed by " + Globals.sTypePath(intf.clPath) + " is missing";
						displayError(com, msg, p);
					}
				}
			}
		}
		// port: core.ds.PMap.iter visits keys in sorted order, like the OCaml PMap.
		PMap.iter(function(_:String, cf:TClassField) {
			checkField(cf);
			if (hasClassFieldFlag(cf, CfOverload)) {
				var list = cf.cfOverloads.copy();
				list.reverse();
				for (overloadField in list) checkField(overloadField);
			}
		}, intf.clFields);
	}

	public static function checkInterfaces(ctx:Typer, c:TClass):Void {
		for (pair in c.clImplements) {
			var missing = [];
			checkInterface(ctx.com, ctx.g, missing, c, pair.cls, pair.params);
			if (missing.length > 0) {
				var l = missing;
				var diag:core.DisplayTypes.MissingFieldsDiagnostics = {
					mfPos: c.clNamePos,
					mfOn: TClassDecl(c),
					mfFields: l.map(e -> {
						field: e.field,
						type: e.type,
						completion: core.display.CompletionItem.CompletionType.fromType(context.display.Display.getImportStatus.bind(ctx),
							null, e.type)
					}),
					mfCause: ImplementedInterface(pair.cls, pair.params)
				};
				var cm = context.display.DiagnosticsPrinter.makeMissingFieldsMessage(diag);
				compiler.io.CompilerMessage.addModuleDiagnostic(ctx.com, c.clModule, cm);
			}
		}
	}

	public static function checkAbstractClass(ctx:Typer, c:TClass, csup:TClass, params:TParams):Void {
		var missing:Array<{field:TClassField, type:T}> = [],
			map = t -> applyParams(csup.clParams, params, t);
		inline function checkField(cf1:TClassField, t1:T):Void {
			var found = false;
			if (c.clFields.exists(cf1.cfName)) {
				var cf2 = c.clFields.get(cf1.cfName);
				for (cf in [cf2].concat(cf2.cfOverloads)) if (Overloads.sameOverloadArgs(t1, cf.cfType, cf1, cf)) {
					found = true;
					break;
				}
			}
			if (!found) missing.unshift({field: cf1, type: t1});
		}
		PMap.iter(function(_:String, pair:{cls:TClass, field:TClassField}) {
			for (overloadField in Overloads.collectOverloads(map, csup,
				pair.field.cfName)) if (hasClassFieldFlag(overloadField.field,
					CfAbstract)) checkField(overloadField.field, overloadField.type);
		}, TClassTools.getAllFields(csup, params));
		if (missing.length == 0) return;
		if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, c.clPos)) {
			// port: List.rev_map over the cons-built list
			var fields = [];
			for (e in missing) fields.unshift({
				field: e.field,
				type: e.type,
				completion: core.display.CompletionItem.CompletionType.fromType(context.display.Display.getImportStatus.bind(ctx), null,
					e.type)
			});
			var diag:core.DisplayTypes.MissingFieldsDiagnostics = {
				mfPos: c.clNamePos,
				mfOn: TClassDecl(c),
				mfFields: fields,
				mfCause: AbstractParent(csup, params)
			};
			var cm = context.display.DiagnosticsPrinter.makeMissingFieldsMessage(diag);
			compiler.io.CompilerMessage.addModuleDiagnostic(ctx.com, c.clModule, cm);
		} else {
			var pctx = printContext(), sub = missing.map(function(pair) {
				var cf = pair.field;
				var s = switch follow(cf.cfType) {
					case TFun({args: tl, ret: _}): tl.map(arg -> arg.name + ":" + sType(pctx, arg.type)).join(", ");
					case t: sType(pctx, t);
				};
				return makeError(Custom(complMsg(cf.cfName + "(" + s + ")")), cf.cfNamePos);
			});
			var singular = missing.length == 1;
			var wrapped = [
				makeError(Custom("Implement "
					+ (singular ? "it" : "them")
					+ " or make "
					+ Globals.sTypePath(c.clPath)
					+ " abstract as well"),
					c.clNamePos, sub)
			];
			displayErrorExt(ctx.com,
				makeError(Custom("This class extends abstract class " + Globals.sTypePath(csup.clPath)
					+ " but doesn't implement the following method" + (singular ? "" : "s")),
					c.clNamePos, wrapped));
		}
	}

	public static function setHeritance(ctx:Typer, c:TClass, herits:haxe.ds.Vector<ClassFlag>, p:Pos):Array<Void->Void> {
		var isLib = Meta.has(MetaTag.LibType, c.clMeta),
			oldMeta = c.clMeta,
			hasInterf = false;
		inline function processMeta(csup:TClass):Void {
			var list = csup.clMeta.copy();
			list.reverse();
			for (m in list) if (m.meta == MetaTag.AutoBuild) c.clMeta = ([
				{
					meta: MetaTag.Build,
					exprs: m.exprs,
					pos: mkZeroRangePos(c.clPos)
				},
				m
			] : Array<core.Ast.MetadataEntry>).concat(c.clMeta);
			var isParam = switch c.clKind {
				case KTypeParameter(_): true;
				case _: false;
			};
			if (hasClassFlag(csup, CFinal)
				&& !((hasClassFlag(csup, CExtern) && Meta.has(MetaTag.Hack, c.clMeta))
					|| isParam)) raiseTypingError("Cannot extend a final " + (hasClassFlag(c, CInterface) ? "interface" : "class"), p);
		}
		inline function checkCancelBuild(csup:TClass):Void {
			var state = csup.clBuild();
			if (state != Built) {
				// for macros reason, our super class is not yet built - see #2177
				// let's reset our build and delay it until we are done
				c.clMeta = oldMeta;
				throw new BuildCanceled(state);
			}
		}
		// Pass 1: Check and set relations
		inline function checkHerit(t:T, isExtends:Bool, p:Pos):Void->Void {
			function checkInterfacesOrDelay():Void switch c.clBuild() {
				case BuildMacro(pending):
					// Ok listen... we're still building this class, which means we can't check its interfaces yet. However,
					// we do want to check them at SOME point. So we use this pending list which was maybe designed for this
					// purpose. However, we STILL have to delay the check because at the time pending is handled, the class
					// is not built yet. See issue #10847.
					pending.unshift(function() delay(ctx.g, PConnectField, checkInterfacesOrDelay));
				case _ if (ctx.com.display.dmsFullTyping):
					checkInterfaces(ctx, c);
				case _:
			}
			if (isExtends) {
				if (c.clSuper != null) raiseTypingError("Cannot extend several classes", p);
				var sup = checkExtends(ctx, c, t, p),
					csup = sup.cls,
					params = sup.params;
				if (hasClassFlag(c, CInterface)) {
					if (!hasClassFlag(csup,
						CInterface)) raiseTypingError("Cannot extend by using a class (" + Globals.sTypePath(c.clPath) + " extends "
							+ Globals.sTypePath(csup.clPath) + ")",
							p);
					c.clImplements.unshift({cls: csup, params: params});
					if (!hasInterf) {
						if (!isLib) delay(ctx.g, PConnectField, checkInterfacesOrDelay);
						hasInterf = true;
					}
				} else {
					if (hasClassFlag(csup,
						CInterface)) raiseTypingError("Cannot extend by using an interface (" + Globals.sTypePath(c.clPath)
							+ " extends " + Globals.sTypePath(csup.clPath) + ")",
							p);
					c.clSuper = {cls: csup, params: params};
				}
				return function() {
					checkCancelBuild(csup);
					processMeta(csup);
				};
			}
			return switch follow(t) {
				case TInst(ca, [t]) if (ca.clPath.pack.length == 0 && ca.clPath.name == "ArrayAccess" && hasClassFlag(ca, CExtern)):
					if (c.clArrayAccess != null) raiseTypingError("Duplicate array access", p);
					c.clArrayAccess = t;
					function() {};
				case TInst(intf, params):
					if (extendsClass(intf, c)) raiseTypingError("Recursive class", p);
					if (hasClassFlag(c,
						CInterface)) raiseTypingError("Interfaces cannot implement another interface (use extends instead)", p);
					if (!hasClassFlag(intf, CInterface)) raiseTypingError("You can only implement an interface", p);
					c.clImplements.unshift({cls: intf, params: params});
					if (!hasInterf && !isLib && !Meta.has(MetaTag.Custom("$do_not_check_interf"), c.clMeta)) {
						delay(ctx.g, PConnectField, checkInterfacesOrDelay);
						hasInterf = true;
					}
					function() {
						checkCancelBuild(intf);
						processMeta(intf);
					};
				case TDynamic(t):
					if (c.clDynamic != null) raiseTypingError("Cannot have several dynamics", p);
					if (!hasClassFlag(c, CExtern)) displayError(ctx.com, "In haxe 4, implements Dynamic is only supported on externs", p);
					c.clDynamic = t == null ? tDynamic : t;
					function() {};
				case _: raiseTypingError("Should implement by using an interface", p);
			};
		}
		var selected = [];
		for (h in herits) switch h {
			case HExtends(t):
				selected.push({isExtends: true, type: t});
			case HImplements(t):
				selected.push({isExtends: false, type: t});
			case _:
		}
		var fl = [];
		for (h in selected) try {
			var t:T;
			var isExtends = h.isExtends;
			t = try Typeload.loadInstance(ctx, h.type, ParamNormal, LoadNormal, true) catch (de:context.display.DisplayException) {
				switch de.kind {
					case DisplayFields(r) if (r.fkind.match(CRTypeHint)):
						// We don't allow `implements` on interfaces. Just raise fields completion with no fields.
						if (!isExtends && hasClassFlag(c,
							CInterface)) context.display.DisplayException.raiseFields([], CRImplements, r.fsubject);
						var l = r.fitems.filter(item -> switch item.ciKind {
							case ITType(cm = {kind: Interface}, _): (!isExtends || hasClassFlag(c,
									CInterface)) && !compiler.CompilationCache.pathEq(core.display.CompletionItem.CompletionModuleType.getPath(cm),
									c.clPath);
							case ITType(cm = {kind: Class}, _):
								isExtends
								&& !hasClassFlag(c, CInterface)
								&& !compiler.CompilationCache.pathEq(core.display.CompletionItem.CompletionModuleType.getPath(cm), c.clPath)
								&& (!cm.isFinal || Meta.has(MetaTag.Hack, c.clMeta))
								&& (!isBasicClassPath({
									pack: cm.pack,
									name: cm.name
								}) || (hasClassFlag(c, CExtern) && cm.isExtern));
							case _: false;
						});
						context.display.DisplayException.raiseFields(l, isExtends ? CRExtends : CRImplements, r.fsubject);
					case _:
						throw de;
				}
			};
			fl.push(checkHerit(t, h.isExtends, h.type.posFull));
		} catch (e:Dynamic) {
			switch e {
				case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound({pack: [], name: name}), errPos: p}))
					if (ctx.com.display.dmsKind != DMNone):
					if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com,
						p)) context.display.DisplayToplevel.handleUnresolvedIdentifier(ctx, name, p, true);
				case _:
					throw e;
			}
		}
		return fl;
	}
}
