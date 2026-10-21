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

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.Globals.Pos;
import core.display.DisplayPosition;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TUnification;
import core.TUnification.*;
import core.TPrinting.*;
import core.TOther.*;
import core.TOther;
import core.Globals;
import core.Globals.*;
import core.Ast.*;
import core.Texpr;
import core.Texpr.*;
import core.TPrinting;
import core.TPrinting.Printer;
import core.Message.WarningCode;
import core.ds.NotFound;
import core.ds.Exit;
import core.ds.PMap;
import core.ds.AtomicLazy;
import core.ds.OcamlInt;
import core.ds.Record;
import core.Path;
import core.DisplayTypes.DisplayModeValue;
import core.InheritDoc as InheritDocTools;
import context.Common;
import context.CoreApiConfig;
import context.AbstractCast;
import context.display.DeprecationCheck;
import context.display.ImportHandling;
import coro.CoroConfig;
import typing.TypeloadCheck;
import core.TOther.TExprToExpr;
import core.Meta as MetadataTools;
import core.Ast as AstTools;
import core.Naming;
import codegen.Overloads;
import syntax.ParserEntry;
import coro.Coro;
import coro.CoroTypes;
import typing.Typeload.LoadInstanceMode;
import core.MetaList.StrictMeta;
import core.Error.*;
import core.Error;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import context.Common.*;
import context.Typecore.TyperManager;
import context.TyperPass;
import typing.Typeload.*;
import typing.TypeloadFields.FieldError.*;
import typing.TypeloadFields.TypeloadFields.*;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Logic for building fields.
@:structInit class ClassInitCtx {
	public var tclass:TClass; // I don't trust ctx.c.curclass because it's mutable.
	public var isLib:Bool;
	public var coreApiCheck:CoreApiCheck;
	public var isClassDebug:Bool;
	public var extendsPublic:Bool;
	public var abstractType:Null<TAbstract>;
	public var hasDisplayField:Bool;
	public var delayedExpr:Array<{ctx:Typer, lazy:Null<TLazy>}>;
	public var forceConstructor:Bool;
	public var uninitializedFinal:Array<TClassField>;

	public inline function new(tclass:TClass, isLib:Bool, coreApiCheck:CoreApiCheck, isClassDebug:Bool, extendsPublic:Bool,
			abstractType:Null<TAbstract>, hasDisplayField:Bool, delayedExpr:Array<{
			ctx:Typer,
			lazy:Null<TLazy>
		}>, forceConstructor:Bool, uninitializedFinal:Array<TClassField>) {
		this.tclass = tclass;
		this.isLib = isLib;
		this.coreApiCheck = coreApiCheck;
		this.isClassDebug = isClassDebug;
		this.extendsPublic = extendsPublic;
		this.abstractType = abstractType;
		this.hasDisplayField = hasDisplayField;
		this.delayedExpr = delayedExpr;
		this.forceConstructor = forceConstructor;
		this.uninitializedFinal = uninitializedFinal;
		}

	public inline function clone():ClassInitCtx return new ClassInitCtx(tclass, isLib, coreApiCheck, isClassDebug, extendsPublic,
		abstractType, hasDisplayField, delayedExpr, forceConstructor, uninitializedFinal);
}

@:structInit class FieldInitCtx {
	public var isInline:Bool;
	public var isFinal:Bool;
	public var isStatic:Bool;
	public var defaultPos:Null<Pos>;
	public var overridePos:Null<Pos>;
	public var overloadPos:Null<Pos>;
	public var isExtern:Bool;
	public var isAbstract:Bool;
	public var isMacro:Bool;
	public var isAbstractMember:Bool;
	public var isAbstractConstructor:Bool;
	public var isDisplayField:Bool;
	public var isFieldDebug:Bool;
	public var isGeneric:Bool;
	public var fieldKind:ClassFieldRefKind;
	public var displayModifier:Null<PlacedAccess>;
	public var doBind:Bool;
	// If true, cf_expr = None makes a difference in the logic. We insert a dummy expression in
	// display mode in order to address this.
	public var exprPresenceMatters:Bool;
	public var hadError:Bool;

	public inline function new(isInline:Bool, isFinal:Bool, isStatic:Bool, defaultPos:Null<Pos>, overridePos:Null<Pos>,
			overloadPos:Null<Pos>, isExtern:Bool, isAbstract:Bool, isMacro:Bool, isAbstractMember:Bool, isAbstractConstructor:Bool,
			isDisplayField:Bool, isFieldDebug:Bool, isGeneric:Bool, fieldKind:ClassFieldRefKind, displayModifier:Null<PlacedAccess>,
			doBind:Bool, exprPresenceMatters:Bool, hadError:Bool) {
		this.isInline = isInline;
		this.isFinal = isFinal;
		this.isStatic = isStatic;
		this.defaultPos = defaultPos;
		this.overridePos = overridePos;
		this.overloadPos = overloadPos;
		this.isExtern = isExtern;
		this.isAbstract = isAbstract;
		this.isMacro = isMacro;
		this.isAbstractMember = isAbstractMember;
		this.isAbstractConstructor = isAbstractConstructor;
		this.isDisplayField = isDisplayField;
		this.isFieldDebug = isFieldDebug;
		this.isGeneric = isGeneric;
		this.fieldKind = fieldKind;
		this.displayModifier = displayModifier;
		this.doBind = doBind;
		this.exprPresenceMatters = exprPresenceMatters;
		this.hadError = hadError;
	}

	public inline function clone():FieldInitCtx return new FieldInitCtx(isInline, isFinal, isStatic, defaultPos, overridePos, overloadPos,
		isExtern, isAbstract, isMacro, isAbstractMember, isAbstractConstructor, isDisplayField, isFieldDebug, isGeneric, fieldKind,
		displayModifier, doBind, exprPresenceMatters, hadError);
}

enum MethodKind {
	MKNormal;
	MKGetter;
	MKSetter;
}

enum EnumAbstractMode {
	EAString;
	EAInt(counter:{value:Int});
	EAOther;
}

enum EnumConstructorVisibility {
	VUnknown;
	VPublic(access:PlacedAccess);
	VPrivate(access:PlacedAccess);
}

class FieldError {
	public static function maybeDisplayError(com:CommonContext, fctx:FieldInitCtx, s:String, p:Pos):Void {
		if (!fctx.hadError) {
			fctx.hadError = true;
			displayError(com, s, p);
		}
	}

	// port: upstream also takes fctx twice.
	public static function invalidModifierCombination(first:FieldInitCtx, com:CommonContext, fctx:FieldInitCtx, a:String, b:String,
			p:Pos):Void maybeDisplayError(com, fctx, "Invalid modifier combination: " + a + " + " + b, p);

	public static function invalidModifier(com:CommonContext, fctx:FieldInitCtx, m:String, c:String,
			p:Pos):Void maybeDisplayError(com, fctx, "Invalid modifier: " + m + " on " + c, p);

	public static function invalidModifierOnly(com:CommonContext, fctx:FieldInitCtx, m:String, c:String,
			p:Pos):Void maybeDisplayError(com, fctx, "Invalid modifier: " + m + " is only supported " + c, p);

	public static function invalidModifierOnProperty(com:CommonContext, fctx:FieldInitCtx, m:String,
			p:Pos):Void maybeDisplayError(com, fctx, "Invalid modifier: " + m + " is not supported on properties", p);

	public static function missingExpression(com:CommonContext, fctx:FieldInitCtx, reason:String,
			p:Pos):Void maybeDisplayError(com, fctx, reason, p);

	public static function unexpectedExpression(com:CommonContext, fctx:FieldInitCtx, reason:String,
			p:Pos):Void maybeDisplayError(com, fctx, reason, p);
}

class TypeloadFields {
	public static function hasAccess(a:Access, access:Array<PlacedAccess>):Bool {
		for (v in access) if (v.access == a) return true;
		return false;
	}

	public static function accessPos(a:Access, access:Array<PlacedAccess>):Pos {
		for (v in access) if (v.access == a) return v.pos;
		throw NotFound.raise();
	}

	public static function meta(m:StrictMeta, ?p:Pos):MetadataEntry return {meta: m, exprs: vector(), pos: p == null ? Globals.nullPos : p};

	public static function ae(e:ExprDef, p:Pos):Expr return {expr: e, pos: p};

	public static function dumpClassContext(cctx:ClassInitCtx):String return Printer.sRecordFields("", [
		{name: "tclass", value: Printer.sTclass("\t", cctx.tclass)},
		{name: "is_lib", value: Std.string(cctx.isLib)},
		{name: "core_api_check", value: CoreApiConfig.sCoreApiCheck(cctx.coreApiCheck)},
		{name: "is_class_debug", value: Std.string(cctx.isClassDebug)},
		{name: "extends_public", value: Std.string(cctx.extendsPublic)},
		{name: "abstract", value: Printer.sOpt(function(a) return Printer.sTabstract("\t", a), cctx.abstractType)},
		{name: "force_constructor", value: Std.string(cctx.forceConstructor)}
	]);

	public static function dumpFieldContext(fctx:FieldInitCtx):String return Printer.sRecordFields("", [
		{name: "is_inline", value: Std.string(fctx.isInline)},
		{
			name: "is_static",
			value: Std.string(fctx.isStatic)
		},
		{name: "is_extern", value: Std.string(fctx.isExtern)},
		{
			name: "is_macro",
			value: Std.string(fctx.isMacro)
		},
		{name: "is_abstract_member", value: Std.string(fctx.isAbstractMember)},
		{
			name: "is_display_field",
			value: Std.string(fctx.isDisplayField)
		},
		{name: "is_field_debug", value: Std.string(fctx.isFieldDebug)},
		{
			name: "field_kind",
			value: sClassFieldRefKind(fctx.fieldKind)
		},
		{name: "do_bind", value: Std.string(fctx.doBind)},
		{
			name: "expr_presence_matters",
			value: Std.string(fctx.exprPresenceMatters)
		}
	]);

	public static function getCoroConfig(ctx:Typer, metadata:Metadata):Null<CoroConfigData>
		return TyperManager.isCoroutineContext(ctx) ? CoroConfig.getCoroutineConfig(metadata) : null;

	public static function isJavaNativeFunction(ctx:Typer, metadata:Metadata, pos:Pos):Bool {
		try {
			var m = MetadataTools.get(Native, metadata);
			if (m.exprs.length == 0) {
				warning(ctx, WDeprecated, "@:native metadata for jni functions is deprecated. Use @:java.native instead.", pos);
				return true;
			}
			return false;
		} catch (_:NotFound) {
			return MetadataTools.has(NativeJni, metadata);
		}
	}

	/**** end of strict meta handling *****/
	public static function getMethodArgs(field:TClassField):haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}> return switch field.cfExpr {
		case {eexpr: TFunction(f)}: f.tfArgs;
		case _: throw NotFound.raise();
	};

	/**
		Get super constructor data required for @:structInit descendants.
	*/
	public static function getStructInitSuperInfo(ctx:Typer, c:TClass,
			p:Pos):{args:Array<{variable:TVar, defaultValue:Null<TExpr>}>, expr:Null<TExpr>, types:Array<{name:String, optional:Bool, type:T}>} {
		if (c.clSuper == null || c.clSuper.cls.clConstructor == null) return {args: [], expr: null, types: []};
		var s = c.clSuper, ctor = s.cls.clConstructor, args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}> = try {
			getMethodArgs(ctor);
		} catch (_:NotFound) {
			vector();
		};
		var argsRev:Array<{variable:TVar, defaultValue:Null<TExpr>}> = [],
			typesRev:Array<{name:String, optional:Bool, type:T}> = [],
			exprsRev:Array<TExpr> = [];
		for (arg in args) {
			var v = arg.variable,
				value = arg.defaultValue,
				opt = value != null || MetadataTools.has(Optional, v.vMeta),
				t = opt ? ctx.t.tnull(v.vType) : v.vType,
				v2 = copyVar(v);
			argsRev.unshift({variable: v2, defaultValue: value});
			typesRev.unshift({name: v.vName, optional: opt, type: t});
			exprsRev.unshift(mk(TLocal(v2), v.vType, p));
		}
		argsRev.reverse();
		typesRev.reverse();
		exprsRev.reverse();
		return {args: argsRev, expr: mk(TCall(mk(TConst(TSuper), TInst(s.cls, s.params), p), haxe.ds.Vector.fromArrayCopy(exprsRev)), ctx.t.tvoid, p), types: typesRev};
	}

	/**
		Generates a constructor for a @:structInit class `c` if it does not have one yet.
	*/
	public static function ensureStructInitConstructor(ctx:Typer, c:TClass, astFields:Array<ClassField>, p:Pos):Void {
		if (c.clConstructor != null) return;
		inline function fieldHasDefault(name:String):Bool return core.ds.ArrayTools.exists(astFields, function(f) {
			if (f.cffName.name != name) return false;
			return switch f.cffKind {
				case FVar(_, e), FProp(_, _, _, e): e != null;
				case _: false;
			};
		});
		var sup = getStructInitSuperInfo(ctx, c, p),
			params = extractParamTypes(c.clParams),
			ethis = mk(TConst(TThis), TInst(c, params), p),
			doc = new StringBuf();
		var args:Array<{variable:TVar, defaultValue:Null<TExpr>}> = [],
			el:Array<TExpr> = [],
			tl:Array<{name:String, optional:Bool, type:T}> = [],
			ordered = c.clOrderedFields.copy();
		ordered.reverse();
		for (cf in ordered) if (isPhysicalVarField(cf)) {
			var hasDefault = fieldHasDefault(cf.cfName),
				opt = hasDefault || MetadataTools.has(Optional, cf.cfMeta),
				t = opt ? ctx.t.tnull(cf.cfType) : cf.cfType;
			var v = allocVar(VGenerated, cf.cfName, t, cf.cfNamePos),
				ef = mk(TField(ethis, FInstance(c, params, cf)), cf.cfType, p),
				ev = mk(TLocal(v), v.vType, p);
			if (opt && !MetadataTools.has(Optional, v.vMeta)) v.vMeta.unshift(meta(Optional));
			// this.field = <constructor_argument>
			var assign = mk(TBinop(OpAssign, ef, ev), cf.cfType, p),
				// <constructor_argument> != null
				// if(<constructor_argument> != null) this.field = <constructor_argument>
				e = hasDefault ? mk(TIf(mk(TBinop(OpNotEq, ev, nullExpr(t, p)), ctx.t.tbool, p), assign, null), ctx.t.tvoid, p) : assign;
			var text = genDocTextOpt(cf.cfDoc);
			if (text != null) {
				doc.add("@param ");
				doc.add(cf.cfName);
				doc.add(" ");
				doc.add(StringTools.trim(text));
				doc.add("\n");
			}
			args.unshift({variable: v, defaultValue: null});
			el.unshift(e);
			tl.unshift({name: cf.cfName, optional: opt, type: t});
		}
		if (sup.expr != null) el.unshift(sup.expr);
		var tf = ({tfArgs: haxe.ds.Vector.fromArrayCopy(args.concat(sup.args)), tfType: ctx.t.tvoid, tfExpr: mk(TBlock(haxe.ds.Vector.fromArrayCopy(el)), ctx.t.tvoid, p)} : core.TType.TFunc);
		var e = mk(TFunction(tf), TFun({args: haxe.ds.Vector.fromArrayCopy(tl.concat(sup.types)), ret: ctx.t.tvoid}), p),
			cf = mkField("new", e.etype, p, Globals.nullPos);
		cf.cfDoc = docFromString(doc.toString());
		cf.cfExpr = e;
		cf.cfType = e.etype;
		cf.cfMeta = [meta(CompilerGenerated), meta(InheritDoc)];
		cf.cfKind = Method(MethNormal);
		c.clConstructor = cf;
		delay(ctx.g, PTypeField, function() InheritDocTools.buildClassFieldDoc(ctx, c, cf));
	}

	public static function transformAbstractField(com:CommonContext, thisT:TypeHint, aT:TypeHint, a:TAbstract, f:ClassField):ClassField {
		var stat = hasAccess(AStatic, f.cffAccess), p = f.cffPos;
		return switch f.cffKind {
			case FProp(get, set, _, _) if (!stat && ["get", "never"].indexOf(get.name) >= 0 && ["set", "never"].indexOf(set.name) >= 0): f;
			case FProp(_, _, _,
				_) if (!stat && !hasAccess(AEnum, f.cffAccess)): raiseTypingError("Member property accessors must be get/set or never", p);
			case FFun(fu) if (f.cffName.name == "new" && !stat):
				inline function init(p:Pos):Expr return ae(EVars(vector(mkEvar({name: "this", pos: Globals.nullPos}, thisT, null,
					[meta(This)]))), p);
				inline function ret(p:Pos):Expr return ae(EReturn(ae(ECast(ae(EConst(Ident("this")), p), null), p)), p);
				var metadata = [meta(NoCompletion)].concat(f.cffMeta);
				if (MetadataTools.has(MultiType, a.aMeta)) {
					if (hasAccess(AInline, f.cffAccess)) raiseTypingError("inline on MultiType constructor", f.cffPos);
					if (fu.fExpr != null) displayError(com, "MultiType constructors cannot have a body", f.cffPos);
					f.cffAccess.unshift({access: AExtern, pos: Globals.nullPos});
				}
				try {
					var pos = accessPos(AMacro, f.cffAccess);
					raiseTypingError("Invalid modifier: macro on abstract constructor", pos);
				} catch (_:NotFound) {}
				// We don't want the generated expression positions to shadow the real code.
				p = Record.withFields(p, {pmax: p.pmin});
				var expr = fu.fExpr == null ? null : switch fu.fExpr.expr {
					case EBlock(el): ae(EBlock(core.ds.VectorTools.cons(init(p), el).snoc(ret(p))), p);
					case _: ae(EBlock(vector(init(p), fu.fExpr, ret(p))), p);
				};
				Record.withFields(f, {
					cffName: {name: "_hx_new", pos: f.cffName.pos},
					cffKind: FFun(Record.withFields(fu, {fExpr: expr, fType: aT})),
					cffMeta: metadata
				});
			case FFun(fu) if (!stat):
				if (MetadataTools.has(From, f.cffMeta)) raiseTypingError("@:from cast functions must be static", f.cffPos);
				Record.withFields(f, {cffKind: FFun(fu)});
			case _: f;
		}
	}

	public static function buildEnumAbstract(ctx:Typer, c:TClass, a:TAbstract, fields:Array<ClassField>, p:Pos):Expr {
		var mode = doesUnify(a.aThis, ctx.t.tint) ? EAInt({value: 0}) : doesUnify(a.aThis, ctx.t.tstring) ? EAString : EAOther;
		inline function setField(f:ClassField, ct:Null<TypeHint>, e:Expr):Void {
			f.cffAccess.unshift({access: AInline, pos: Globals.nullPos});
			f.cffKind = FVar(ct, ae(ECast(e, null), e.pos));
		}
		inline function fieldIsSet(f:ClassField):Bool return switch f.cffKind {
			case FVar(ct, {expr: ECast(_, _)}): ct != null && hasAccess(AInline, f.cffAccess);
			case _: false;
		};
		for (f in fields) switch f.cffKind {
			case FVar(ct, eo) if (!hasAccess(AStatic, f.cffAccess) && !fieldIsSet(f)):
				inline function conflict(visibility:EnumConstructorVisibility, p1:Pos):Void switch visibility {
					case VUnknown:
					case VPublic(access), VPrivate(access):
						displayErrorExt(ctx.com,
							makeError(Custom("Conflicting access modifier " + AstTools.sAccess(access.access)), p1,
								[makeError(Custom(complMsg("Conflicts with this")), access.pos)]));
				}
				var visibility = VUnknown;
				for (access in f.cffAccess) switch access.access {
					case AExtern: displayError(ctx.com, "Invalid modifier: extern on field of enum abstract", access.pos);
					case APrivate:
						conflict(visibility, access.pos);
						visibility = VPrivate(access);
					case APublic:
						conflict(visibility, access.pos);
						visibility = VPublic(access);
					case _:
				}
				f.cffAccess = [
					{access: AEnum, pos: Globals.nullPos},
					switch visibility {
						case VPublic(acc), VPrivate(acc):
							acc;
						case VUnknown:
							{access: APublic, pos: Globals.nullPos};
					}
				];
				f.cffMeta.unshift(meta(Enum));
				if (ct == null) ct = {type: TExprToExpr.convertType(TAbstract(a, extractParamTypes(a.aParams))), pos: Globals.nullPos};
				if (eo == null) {
					if (!hasClassFlag(c, CExtern)) switch mode {
						case EAString: setField(f, ct, ae(EConst(String(f.cffName.name, SDoubleQuotes)), Globals.nullPos));
						case EAInt(i):
							setField(f, ct, ae(EConst(Int(Std.string(i.value), null)), Globals.nullPos));
							i.value++;
						case EAOther: displayError(ctx.com, "Value required", f.cffPos);
					}
					else f.cffKind = FProp({name: "default", pos: Globals.nullPos}, {name: "never", pos: Globals.nullPos}, ct, null);
				} else {
					switch [mode, eo.expr] {
						case [EAInt(i), EConst(Int(s, null))]: try {
								i.value = OcamlInt.ofString(s) + 1;
							} catch (_:Dynamic) {}
						case _:
					}
					setField(f, ct, eo);
				}
			case _:
		}
		return ae(EVars(vector(mkEvar({name: "", pos: Globals.nullPos}, {type: CTAnonymous(haxe.ds.Vector.fromArrayCopy(fields)), pos: p}))), p);
	}

	public static function resolveTypeImport(ctx:Typer, p:Pos, i:String):Array<String> {
		try {
			var found = ctx.m.importResolution.findTypeImport(i),
				path = tPath(found.type),
				pack = path.pack.copy();
			pack.reverse();
			return [path.name].concat(pack);
		} catch (_:NotFound) {
			return [i];
		}
	}

	public static function buildModuleDef(ctx:Typer, mt:ModuleType, metadata:Metadata, fvars:Void->Array<ClassField>,
			fbuild:Expr->Void):Void {
		var isTypedef = false, ti = switch mt {
			case TClassDecl({clKind: KAbstractImpl(a)}): tInfos(TAbstractDecl(a));
			case TTypeDecl(_):
				isTypedef = true;
				tInfos(mt);
			case _: tInfos(mt);
		};
		var builds:Array<Void->Void> = [];
		for (m in metadata) if (m.meta == core.MetaList.StrictMeta.Build && !isTypedef) builds.unshift(function() {
			var call = switch m.exprs {
				case [{expr: ECall(path, args)}]: {path: path, args: args};
				case _: raiseTypingError("Invalid build parameters", m.pos);
			};
			var sl:Array<String> = try {
				stringListOfExprPathRaise(call.path, function(i) return resolveTypeImport(ctx, m.pos, i));
			} catch (_:Exit) {
				raiseTypingError("Build call parameter must be a class path", m.pos);
			};
			if (sl.length < 2) raiseTypingError("Invalid macro path", m.pos);
			var pack = sl.slice(2);
			pack.reverse();
			var cpath:core.Globals.GlobalTypePath = {pack: pack, name: sl[1]}, meth = sl[0];
			if (ctx.com.isMacroContext)
				raiseTypingError("You cannot use @:build inside a macro : make sure that your type is not used in macro", m.pos);
			var old = ctx.c.getBuildInfos;
			ctx.c.getBuildInfos = function() return {type: mt, params: extractParamTypes(ti.mtParams), fields: fvars()};
			var r = try {
				ctx.g.doMacro(ctx, MBuild, cpath, meth, call.args, m.pos);
			} catch (e:haxe.Exception) {
				ctx.c.getBuildInfos = old;
				throw e;
			};
			ctx.c.getBuildInfos = old;
			switch r {
				case MError, MMacroInMacro:
					Common.displayError(ctx.com, "Build failure (" + Globals.sTypePath(cpath) + "." + meth + ")", m.pos);
				case MSuccess(e):
					fbuild(e);
			}
		});
		var fenum:Null<Void->Void> = switch mt {
			case TClassDecl(c) if (switch c.clKind {
					case KAbstractImpl(a): a.aEnum;
					case _: false;
				}):
				var a = switch c.clKind {
					case KAbstractImpl(a): a;
					case _: throw NotFound.raise();
				};
				function() fbuild(buildEnumAbstract(ctx, c, a, fvars(), a.aNamePos));
			case TClassDecl(c):
				// Go for @:using in parents and interfaces
				// port: tInfos is a projection object in Haxe, so assigning mtUsing on it would
				// only replace the projected field. Mutate the shared array instead.
				inline function inheritUsing(s:ClassAndParams):Void for (entry in tInfos(TClassDecl(s.cls)).mtUsing) ti.mtUsing.push(entry);
				delayLate(ctx.g, PConnectField, function() {
					if (c.clSuper != null) inheritUsing(c.clSuper);
					for (s in c.clImplements) inheritUsing(s);
				});
				null;
			case _: null;
		};
		// let errors go through to prevent resume if build fails
		builds.reverse();
		for (f in builds) f();
		// port: tInfos is a projection: read the metadata again, build macros may have replaced it
		for (m in tInfos(mt).mtMeta) if (m.meta == core.MetaList.StrictMeta.Using) for (e in m.exprs) try {
			var path = stringPosListOfExprPathRaise(e);
			var r = ImportHandling.handleUsing(ctx, VectorTools.ofArrayReversed(path), e.pos);
			// Delay for #10107, but use delay_late to make sure base classes run before their children do.
			delayLate(ctx.g, PConnectField, function() {
				var filtered = r.filterClasses(r.types);
				filtered.reverse();
				for (entry in filtered) ti.mtUsing.unshift(entry);
			});
		} catch (_:Exit) {
			raiseTypingError("dot path expected", e.pos);
		}
		if (fenum != null) fenum();
	}

	public static function createClassContext(c:TClass, p:Pos):ClassInitCtx {
		function extendsPublic(c:TClass):Bool return MetadataTools.has(PublicFields, c.clMeta)
			|| (c.clSuper != null && extendsPublic(c.clSuper.cls));
		return {
			tclass: c,
			isLib: MetadataTools.has(LibType, c.clMeta),
			coreApiCheck: CoreApiConfig.getCoreApiCheck(c.clMeta, Path.UniqueKey.lazyPath(c.clModule.mExtra.mFile)),
			isClassDebug: MetadataTools.has(Custom(":debug.typeload"), c.clMeta),
			extendsPublic: extendsPublic(c),
			abstractType: switch c.clKind {
				case KAbstractImpl(a): a;
				case _: null;
			},
			forceConstructor: false,
			uninitializedFinal: [],
			delayedExpr: [],
			hasDisplayField: false
		};
	}

	public static function createTyperContextForClass(ctx:Typer, cctx:ClassInitCtx, p:Pos):Typer {
		ctx.com.requestScope.stats.sClassesBuilt++;
		var c = cctx.tclass;
		if (cctx.isLib && !hasClassFlag(c, CExtern)) ctx.com.error("@:libType can only be used in extern classes", c.clPos);
		return TyperManager.cloneForClass(ctx, c);
	}

	public static function createFieldContext(ctx:Typer, cctx:ClassInitCtx, cff:ClassField, isDisplayFile:Bool,
			displayModifier:Null<PlacedAccess>):FieldInitCtx {
		var isStatic = hasAccess(AStatic, cff.cffAccess),
			isAbstractMember = cctx.abstractType != null && !isStatic;
		if (isAbstractMember) isStatic = true;
		var isExtern = hasAccess(AExtern, cff.cffAccess),
			isAbstract = hasAccess(AAbstract, cff.cffAccess),
			isFinal = hasAccess(AFinal, cff.cffAccess);
		for (m in cff.cffMeta) switch m.meta {
			case Final:
				isFinal = true;
				if (m.pos != Globals.nullPos) warning(ctx, WDeprecated, "`@:final` is deprecated in favor of `final`", m.pos);
			case Extern:
				if (m.pos != Globals.nullPos) warning(ctx, WDeprecated, "`@:extern` is deprecated in favor of `extern`", m.pos);
				isExtern = true;
			case _:
		}
		var isInline = hasAccess(AInline, cff.cffAccess), overridePos = try {
			accessPos(AOverride, cff.cffAccess);
		} catch (_:NotFound) {
			null;
		}, overloadPos = try {
			accessPos(AOverload, cff.cffAccess);
		} catch (_:NotFound) {
			null;
			};
		var isMacro = hasAccess(AMacro, cff.cffAccess),
			kind = switch cff.cffName.name {
				case "new": CfrConstructor;
				case "__init__" if (isStatic): CfrInit;
				case _: isStatic ? CfrStatic : CfrMember;
			};
		var defaultPos = try {
			MetadataTools.get(JavaDefault, cff.cffMeta).pos;
		} catch (_:NotFound) {
			null;
		}, c = cctx.tclass;
		var fc:FieldInitCtx = {
			isInline: isInline,
			isStatic: isStatic,
			defaultPos: defaultPos,
			overridePos: overridePos,
			overloadPos: overloadPos,
			isMacro: isMacro,
			isExtern: isExtern,
			isAbstract: isAbstract,
			isFinal: isFinal,
			isDisplayField: isDisplayFile && DisplayPosition.displayPosition.enclosedIn(cff.cffPos),
			isFieldDebug: cctx.isClassDebug || MetadataTools.has(Custom(":debug.typeload"), cff.cffMeta),
			displayModifier: displayModifier,
			isAbstractMember: isAbstractMember,
			isAbstractConstructor: isAbstractMember && cff.cffName.name == "_hx_new",
			isGeneric: MetadataTools.has(Generic, cff.cffMeta),
			fieldKind: kind,
			doBind: ((!(hasClassFlag(c, CExtern) || isExtern) || isInline) && !isAbstract && !hasClassFlag(c, CInterface))
			|| kind == CfrInit,
			exprPresenceMatters: false,
			hadError: false
		};
		if (fc.isDisplayField) cctx.hasDisplayField = true;
		return fc;
	}

	public static function createTyperContextForField(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, cff:ClassField,
			cf:TClassField):Typer {
		DeprecationCheck.checkIs(ctx.com, ctx.m.curmod, ctx.c.curclass.clMeta, cff.cffMeta, cff.cffName.name, cff.cffMeta, cff.cffName.pos);
		var params = fctx.isStatic && !fctx.isAbstractMember && !MetadataTools.has(LibType, cctx.tclass.clMeta) /* TODO: remove this */ ? vector() : ctx.typeParams;
		ctx = TyperManager.cloneForField(ctx, cf, params);
		var c = cctx.tclass;
		if (fctx.isAbstract && !MetadataTools.has(LibType, c.clMeta)) {
			if (fctx.isStatic) invalidModifierCombination(fctx, ctx.com, fctx, "abstract", "static", cff.cffName.pos);
			else if (fctx.isFinal) invalidModifierCombination(fctx, ctx.com, fctx, "abstract", "final", cff.cffName.pos);
			else if (fctx.isInline) invalidModifierCombination(fctx, ctx.com, fctx, "abstract", "inline", cff.cffName.pos);
			else if (!hasClassFlag(c, CAbstract)) {
				displayErrorExt(ctx.com,
					makeError(Custom("This class should be declared abstract because it has at least one abstract field"), c.clNamePos,
						[makeError(Custom(complMsg("First abstract field was here")), cff.cffName.pos)]));
				addClassFlag(c, CAbstract);
			}
		}
		return ctx;
	}

	public static function isPublic(cctx:ClassInitCtx, access:Array<PlacedAccess>, parent:Null<TClassField>):Bool {
		var c = cctx.tclass;
		if (hasAccess(APrivate, access)) return false;
		if (hasAccess(APublic, access)) return true;
		if (parent != null) return hasClassFieldFlag(parent, CfPublic);
		return hasClassFlag(c, CExtern) || hasClassFlag(c, CInterface) || cctx.extendsPublic || switch c.clKind {
			case KModuleFields(_): true;
			case _: false;
		};
	}

	public static function getParent(c:TClass, name:String):Null<TClassField> {
		if (c.clSuper == null) return null;
		try {
			return PMap.find(name, c.clSuper.cls.clFields);
		} catch (_:NotFound) {
			return getParent(c.clSuper.cls, name);
		}
	}

	public static function transformAbstractField2(ctx:Typer, a:TAbstract,
			cff:ClassField):ClassField return transformAbstractField(ctx.com, TExprToExpr.convertTypeHint(a.aThis), // TODO: better pos?
			TExprToExpr.convertTypeHint(TAbstract(a, extractParamTypes(a.aParams))), a, cff);

	public static function transformField(ctx:Typer, cctx:ClassInitCtx, c:TClass, f:ClassField, fields:Array<ClassField>,
			p:Pos):ClassField {
		if (cctx.abstractType != null) f = transformAbstractField2(ctx, cctx.abstractType, f);
		if (hasAccess(AMacro, f.cffAccess) && ctx.g.macros != null && ctx.g.macros.typer.com.moduleLut.getTypeLut().mem(c.clPath)) {
			// assume that if we had already a macro with the same name, it has not been changed during the @:build operation
			// port: cff_name is a (name, pos) pair compared structurally upstream
			if (!core.ds.ArrayTools.exists(fields,
				function(f2) return f2.cffName.name == f.cffName.name
					&& f2.cffName.pos.pfile == f.cffName.pos.pfile
					&& f2.cffName.pos.pmin == f.cffName.pos.pmin
					&& f2.cffName.pos.pmax == f.cffName.pos.pmax
					&& hasAccess(AMacro, f2.cffAccess)))
				raiseTypingError("Class build macro cannot return a macro function when the class has already been compiled into the macro context",
					p);
		}
		return f;
	}

	public static function typeVarField(ctx:Typer, t:T, e:Expr, stat:Bool, doDisplay:Bool, p:Pos):TExpr {
		var save = TypeloadFunction.saveFieldState(ctx);
		try {
			var e = doDisplay ? context.display.Display.preprocessExpr(ctx.com, e) : e;
			var result = AbstractCast.castOrUnify(ctx, t, typeExpr(ctx, e, WithTypeTools.withType(t)), p);
			save();
			return result;
		} catch (err:haxe.Exception) {
			save();
			throw err;
		}
	}

	public static function buildFields(ctx:Typer, cctx:ClassInitCtx, c:TClass, fields:Array<ClassField>):Array<ClassField> {
		var pending:Array<Void->Void> = [];
		c.clBuild = function() return BuildMacro(pending);
		buildModuleDef(ctx, TClassDecl(c), c.clMeta, function() return fields, function(e) switch e.expr {
			case EVars([{evType: {type: CTAnonymous(f), pos: p}, evExpr: null}]):
				fields = f.mapToArray(function(v) return transformField(ctx, cctx, c, v, fields, p));
			case _:
				raiseTypingError("Class build macro must return a single variable with anonymous fields", e.pos);
		});
		c.clBuild = function() return Building([c]);
		for (f in pending) f();
		return fields;
	}

	public static function checkFieldDisplay(ctx:Typer, fctx:FieldInitCtx, c:TClass, cf:TClassField):Void {
		if (fctx.isDisplayField) {
			var r:{scope:ClassFieldScope, cf:TClassField} = switch c.clKind {
				case KAbstractImpl(_):
					if (hasClassFieldFlag(cf, CfImpl)) {
						if (fctx.isAbstractConstructor) {
							var cf2 = cf.clone();
							cf2.cfName = "new";
							{scope: CFSConstructor, cf: cf2};
						} else {scope: CFSMember, cf: cf};
					} else {scope: CFSStatic, cf: cf};
				case _:
					{scope: fctx.isStatic ? CFSStatic : (fctx.fieldKind == CfrConstructor ? CFSConstructor : CFSMember), cf: cf};
			};
			var scope = r.scope, cf = r.cf;
			var origin:core.display.CompletionItem.ClassFieldOrigin = switch c.clKind {
				case KAbstractImpl(a): Self(TAbstractDecl(a));
				case _: Self(TClassDecl(c));
			};
			context.display.DisplayEmitter.maybeDisplayField(ctx, origin, scope, cf, cf.cfNamePos);
			context.display.DisplayEmitter.checkFieldModifiers(ctx, c, cf, fctx.overridePos, fctx.displayModifier);
		}
	}

	public static function loadVariableTypeHint(ctx:Typer, fctx:FieldInitCtx, eo:Null<Expr>, p:Pos, t:Null<TypeHint>):T {
		if (t == null && eo == null) {
			missingExpression(ctx.com, fctx, "Variable requires type-hint or initialization", p);
			return tDynamic;
		}
		if (t == null) return mkMono();
		return loadTypeHint(ctx, p, LoadNormal, t);
	}

	public static function createVariable(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, c:TClass, f:ClassField, cf:TClassField,
			t:Null<TypeHint>, eo:Null<Expr>, p:Pos):TClassField {
		var isEnum = hasAccess(AEnum, f.cffAccess);
		if (fctx.isAbstractMember && !isEnum) raiseTypingError("Cannot declare member variable in abstract", p);
		if (fctx.isInline && !fctx.isStatic) invalidModifier(ctx.com, fctx, "inline", "non-static variable", p);
		if (fctx.isInline && eo == null) missingExpression(ctx.com, fctx, "Inline variable must be initialized", p);
		var missing = fctx.isFinal && !(fctx.isExtern || hasClassFlag(c, CExtern) || hasClassFlag(c, CInterface)) && eo == null;
		if (missing && fctx.isStatic && fctx.isFinal) missingExpression(ctx.com, fctx, "Static final variable must be initialized", p);
		var type = loadVariableTypeHint(ctx, fctx, eo, f.cffName.pos, t);
		var kind = fctx.isInline ? ({vRead: AccInline, vWrite: AccNever} : core.TType.VarKind) : fctx.isFinal ? ({
			vRead: AccNormal,
			vWrite: fctx.isStatic ? AccNever : AccCtor
		} : core.TType.VarKind) : ({
			vRead: AccNormal,
			vWrite: AccNormal
			} : core.TType.VarKind);
		cf.cfType = type;
		cf.cfKind = Var(kind);
		if (fctx.isFinal) {
			if (missing && !fctx.isStatic) cctx.uninitializedFinal.unshift(cf);
			addClassFieldFlag(cf, CfFinal);
		}
		if (fctx.isExtern) addClassFieldFlag(cf, CfExtern);
		if (fctx.isAbstractMember) {
			cf.cfMeta.unshift(meta(Custom(":impl")));
			addClassFieldFlag(cf, CfImpl);
		}
		if (isEnum) addClassFieldFlag(cf, CfEnum);
		TypeBinding.bindVar(ctx, cctx, fctx, cf, eo);
		return cf;
	}

	public static function checkAbstract(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, a:TAbstract, c:TClass, cf:TClassField, fd:Func,
			t:T, ret:T, p:Pos):Void {
		if (fctx.isAbstractConstructor && a.aConstructor == null) a.aConstructor = cf; // TODO: this is pretty dumb, it deals with the overload case
		var m = mkMono(), ta = TAbstract(a, a.aParams.map(function(_) return mkMono())),
			tthis = fctx.isAbstractMember || MetadataTools.has(To, cf.cfMeta) ? monomorphs(a.aParams, a.aThis) : a.aThis;
		var allowsNoExpr = MetadataTools.has(CoreType, a.aMeta);
		inline function allowNoExpr():Void {
			if (!hasClassFieldFlag(cf, CfExtern)) {
				allowsNoExpr = true;
				fctx.exprPresenceMatters = true;
			}
		}
		inline function handleFrom():Void {
			var r = makeLazy(ctx.g, t, function() {
				// the return type of a from-function must be the abstract, not the underlying type
				if (!fctx.isMacro) try {
					typeEq(EqStrict, ret, ta);
				} catch (e:Unify_error) {
					raiseTypingErrorExt(makeError(Unify(e.errors), p));
				}
				return switch t {
					case TFun({args: [arg]}): arg.type;
					case TFun({args: [arg, {optional: true, type: t2}]}) if (isPosInfos(t2)): arg.type;
					case _: raiseTypingError("@:from cast functions must accept exactly one argument", p);
				}
			}, "@:from");
			a.aFromField.unshift({type: TLazy(r), field: cf});
		}
		function handleTo():Void {
			if (fctx.isMacro) invalidModifier(ctx.com, fctx, "macro", "cast function", p);
			inline function validArgs(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>):Bool return args.length == 1
				|| (args.length == 2 && args[1].optional && isPosInfos(args[1].type));
			switch [cf.cfKind, cf.cfType] {
				case [Var(_), _]:
					raiseTypingError("Invalid metadata: @:to must be used on method of abstract", p);
				case [Method(_), TFun(s)] if (!fctx.isAbstractMember && !validArgs(s.args)):
					if (!MetadataTools.has(MultiType, a.aMeta)) // TODO: get rid of this check once multitype is removed
						raiseTypingError("static @:to method should have one argument", p);
				case [Method(_), TFun(s)] if (fctx.isAbstractMember && !validArgs(s.args)):
					if (!MetadataTools.has(MultiType, a.aMeta)) // TODO: get rid of this check once multitype is removed
						raiseTypingError("@:to method should have no arguments", p);
				case _:
			}
			// TODO: this doesn't seem quite right...
			if (!hasClassFieldFlag(cf, CfImpl)) addClassFieldFlag(cf, CfImpl);
			inline function resolveM(args:core.TType.TParams):T {
				try {
					unifyRaise(t, tfun(VectorTools.cons(tthis, args), m), cf.cfPos);
				} catch (e:core.Error.TypingError) {
					switch e.error.errMessage {
						case Unify(_):
							raiseTypingErrorExt(e.error);
						case _:
							throw e;
					}
				}
				return switch follow(m) {
					case TMono(_) if (switch t {
							case TFun(s): s.ret == tDynamic;
							case _: false;
						}): tDynamic;
					case m: m;
				};
			}
			var isMulti = MetadataTools.has(MultiType, a.aMeta) && !fctx.isAbstractMember;
			if (isMulti && !MetadataTools.has(MultiType, cf.cfMeta)) cf.cfMeta.unshift(meta(MultiType));
			var r = makeLazy(ctx.g, t, function() {
				var args:core.TType.TParams;
				if (isMulti) {
					var ctor = a.aConstructor;
					if (ctor == null)
						raiseTypingError("Constructor of multi-type abstract must be defined before the individual @:to-functions are",
							cf.cfPos);
					// delay ctx PFinal (fun () -> unify ctx m tthis f.cff_pos);
					args = switch follow(monomorphs(a.aParams, ctor.cfType)) {
						case TFun(s): s.args.map(function(v) return v.type);
						case _: Globals.die("", "typeloadFields.ml");
					};
				} else args = switch cf.cfType {
					case TFun({args: [_, {optional: true, type: t}]}) if (isPosInfos(t)): vector(t);
					case _: vector();
				};
				return resolveM(args);
			}, "@:to");
			a.aToField.unshift({type: TLazy(r), field: cf});
		}
		inline function handleArrayAccess():Void {
			if (fctx.isMacro) invalidModifier(ctx.com, fctx, "macro", "array-access function", p);
			a.aArray.unshift(cf);
			allowNoExpr();
		}
		inline function handleResolve():Void {
			var targ = fctx.isAbstractMember ? tthis : ta;
			inline function checkFun(t1:T, t2:T):Void if (!fctx.isMacro) {
				if (!typeIseq(targ, t1)) raiseTypingError("First argument type must be " + sType(printContext(), targ), cf.cfPos);
				if (!typeIseq(ctx.t.tstring, t2)) raiseTypingError("Second argument type must be String", cf.cfPos);
			}
			switch follow(t) {
				case TFun(s) if (s.args.length >= 2 && isEmptyOrPosInfos(s.args, 2)):
					if (a.aRead != null) displayError(ctx.com, "Multiple resolve-read methods are not supported", cf.cfPos);
					checkFun(s.args[0].type, s.args[1].type);
					a.aRead = cf;
				case TFun(s) if (s.args.length >= 3 && isEmptyOrPosInfos(s.args, 3)):
					if (a.aWrite != null) displayError(ctx.com, "Multiple resolve-write methods are not supported", cf.cfPos);
					checkFun(s.args[0].type, s.args[1].type);
					a.aWrite = cf;
				case _:
					raiseTypingError("Field type of resolve must be " + sType(printContext(), targ) + " -> String -> T", cf.cfPos);
			}
		}
		inline function handleOp(e:Expr):Void switch e.expr {
			case EArrayDecl(_):
				handleArrayAccess();
			case EBinop(OpAssign, _, _):
				raiseTypingError("Assignment overloading is not supported", p);
			case EBinop(OpAssignOp(OpNullCoal), _, _), EBinop(OpNullCoal, _, _):
				raiseTypingError("Null coalescing overloading is not supported", p);
			case ETernary(_, _, _):
				raiseTypingError("Ternary overloading is not supported", p);
			case EBinop(op, _, _):
				if (fctx.isMacro) invalidModifier(ctx.com, fctx, "macro", "operator function", p);
				var targ = fctx.isAbstractMember ? tthis : ta;
				var eq = switch follow(t) {
					case TFun({args: [v1, v2]}): {left: typeIseq(targ, v1.type), right: typeIseq(targ, v2.type)};
					case TFun({args: [v1, v2, {optional: true, type: t3}]}) if (isPosInfos(t3)): {
							left: typeIseq(targ, v1.type),
							right: typeIseq(targ, v2.type)
						};
					case _: raiseTypingError(fctx.isAbstractMember ? "Member @:op functions must accept exactly one argument" : "Static @:op functions must accept exactly two arguments",
							cf.cfPos);
				};
				if (!(eq.left || eq.right)) raiseTypingError("The left or right argument type must be " + sType(printContext(), targ),
					cf.cfPos);
				if (eq.right
					&& MetadataTools.has(Commutative,
						cf.cfMeta)) raiseTypingError("Invalid metadata: @:commutative is only allowed if the right argument is not "
						+ sType(printContext(), targ),
						cf.cfPos);
				a.aOps.unshift({op: op, field: cf});
				allowNoExpr();
			case EUnop(op, flag, _):
				if (fctx.isMacro) invalidModifier(ctx.com, fctx, "macro", "operator function", p);
				var targ = fctx.isAbstractMember ? tthis : ta;
				try {
					typeEq(EqStrict, t, tfun(vector(targ), mkMono()));
				} catch (e:Unify_error) {
					raiseErrorMsg(Unify(e.errors), cf.cfPos);
				}
				a.aUnops.unshift({op: op, flag: flag, field: cf});
				allowNoExpr();
			case ECall(_, _):
				if (a.aCall == null) a.aCall = cf;
				else a.aCall.cfOverloads.unshift(cf);
				allowNoExpr();
			case EField(_, _, _):
				handleResolve();
			case _:
				raiseTypingError("Invalid @:op expresssions, should be an operator or a call", e.pos);
		}
		// port: iterate a snapshot: handleTo may prepend @:multiType, and upstream iterates an immutable list.
		for (entry in cf.cfMeta.copy()) switch entry.meta {
			case From:
				handleFrom();
			case To:
				handleTo();
			case Op:
				if (entry.exprs.length == 1) handleOp(entry.exprs[0]);
			case ArrayAccess:
				handleArrayAccess();
			case Resolve:
				handleResolve();
			case _:
		}
		if (fctx.isAbstractConstructor && MetadataTools.has(MultiType, a.aMeta)) fctx.doBind = false;
		if (fd.fExpr == null) {
			if (fctx.isInline) missingExpression(ctx.com, fctx, "Inline functions must have an expression", cf.cfPos);
			if (fd.fType == null) raiseTypingError("Functions without expressions must have an explicit return type", cf.cfPos);
			if (allowsNoExpr) {
				cf.cfMeta.unshift(meta(NoExpr));
				fctx.doBind = false;
			}
		}
	}

	public static function typeOpt(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, p:Pos, mode:LoadInstanceMode, t:Null<TypeHint>):T {
		var c = cctx.tclass,
			trulyExtern = (hasClassFlag(c, CExtern) || fctx.isExtern) && !fctx.isInline; // if it's inline, we can infer the type from the expression
		if (t == null && (trulyExtern || hasClassFlag(c, CInterface))) {
			displayError(ctx.com, "Type required for extern classes and interfaces", p);
			return tDynamic;
		}
		if (t == null && cctx.coreApiCheck == CoreApiCheck.On) {
			displayError(ctx.com, "Type required for core api classes", p);
			return tDynamic;
		}
		if (t == null && fctx.isAbstract) {
			displayError(ctx.com, "Type required for abstract functions", p);
			return tDynamic;
		}
		return Typeload.loadTypeHint(ctx, p, mode, t);
	}

	public static function setupArgsRet(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, name:String, fd:Func,
			p:Pos):{args:FunctionArguments, ret:T} {
		var c = cctx.tclass, kind = AtomicLazy.fromFun(function() {
			if (name.length < 4) return MKNormal;
			return switch name.substr(0, 4) {
				case "get_": fd.fArgs.length == 0 ? MKGetter : MKNormal;
				case "set_": fd.fArgs.length == 1 ? MKSetter : MKNormal;
				case _: MKNormal;
			};
		});
		inline function propertyType():T {
			var property = name.substr(4),
				cf = PMap.find(property, fctx.isStatic ? c.clStatics : c.clFields); // TODO: inheritance?
			return switch [kind.force(), cf.cfKind] {
				case [MKGetter, Var({vRead: AccCall | AccPrivateCall})] | [MKSetter, Var({vWrite: AccCall | AccPrivateCall})]: cf.cfType;
				case _: throw NotFound.raise();
			};
		}
		inline function maybeProperty(th:Null<TypeHint>, check:Void->Bool, def:Void->T):T {
			if (th == null && check()) {
				try return propertyType()
				catch (_:NotFound) return def();
			}
			return def();
		}
		var ret = fctx.fieldKind == CfrConstructor ? ctx.t.tvoid : maybeProperty(fd.fType, function() return switch kind.force() {
			case MKGetter | MKSetter: true;
			case _: false;
		}, () -> typeOpt(ctx, cctx, fctx, p, LoadReturn, fd.fType));
		var abstractThis = cctx.abstractType != null
			&& fctx.isAbstractMember
			&& !fctx.isAbstractConstructor
			&& !fctx.isMacro ? cctx.abstractType.aThis : null;
		var isExtern = fctx.isExtern || hasClassFlag(ctx.c.curclass, CExtern);
		function typeArg(i:Int, opt:Bool, cto:Null<TypeHint>, p:Pos):T {
			function def():T return typeOpt(ctx, cctx, fctx, p, LoadNormal, cto);
			return i == 0 ? maybeProperty(cto, () -> kind.force() == MKSetter, def) : def();
		}
		var args = new FunctionArguments(ctx.com, typeArg, isExtern, fctx.isDisplayField, abstractThis, fd.fArgs);
		return {args: args, ret: ret};
	}

	public static function createMethod(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, c:TClass, f:ClassField, cf:TClassField, fd:Func,
			p:Pos):TClassField {
		var name = f.cffName.name;
		var params:TypeParams = TypeloadFunction.typeFunctionParams(ctx, fd, TPHMethod, name);
		if (fctx.isGeneric && params.length == 0) raiseTypingError("Generic functions must have type parameters", p);
		// remove display of first argument which will contain the "this" expression
		if (fctx.isMacro && !ctx.com.isMacroContext && !fctx.isStatic) fd = Record.withFields(fd,
			{fArgs: fd.fArgs.length == 0 ? vector() : fd.fArgs.slice(1)});
		if (fctx.isMacro) {
			if (ctx.com.isMacroContext) {
				// a class with a macro cannot be extern in macro context (issue #2015)
				removeClassFlag(c, CExtern);
				var texpr = makePtpCt(mkTypePath(["haxe", "macro"], "Expr"), Globals.nullPos);
				// ExprOf type parameter might contain platform-specific type, let's replace it by Expr
				inline function noExprOf(th:TypeHint):TypeHint return switch th.type {
					case CTPath({
						path: {
							tpackage: ["haxe", "macro"],
							tname: "Expr",
							tsub: "ExprOf",
							tparams: [TPType(_)]
						}
					}) | CTPath({
						path: {
							tpackage: [],
							tname: "ExprOf",
							tsub: null,
							tparams: [TPType(_)]
						}
					}): {type: texpr, pos: th.pos};
					case _: th;
				};
				function convert(th:Null<TypeHint>):TypeHint return th == null ? {type: texpr, pos: Globals.nullPos} : noExprOf(th);
				fd = {
					fParams: fd.fParams,
					fType: convert(fd.fType),
					fArgs: fd.fArgs.map(arg -> Record.withFields(arg, {type: convert(arg.type)})),
					fExpr: fd.fExpr
				};
			} else {
				var dynamicHint = makePtpTh(mkTypePath([], "Dynamic"), Globals.nullPos);
				inline function toDynamic(p:Pos, ptp:PlacedTypePath):TypeHint return switch ptp.path {
					case {
						tpackage: ["haxe", "macro"],
						tname: "Expr",
						tsub: "ExprOf",
						tparams: [TPType(t)]
					}
						| {
							tpackage: [],
							tname: "ExprOf",
							tsub: null,
							tparams: [TPType(t)]
						}: t;
					case {
						tpackage: ["haxe"],
						tname: "PosInfos",
						tsub: null,
						tparams: []
					}: raiseTypingError("haxe.PosInfos is not allowed on macro functions, use Context.currentPos() instead", p);
					case _: dynamicHint;
				};
				function convert(th:Null<TypeHint>):TypeHint return th == null ? dynamicHint : switch th.type {
					case CTPath(ptp): toDynamic(th.pos, ptp);
					case _: dynamicHint;
				};
				fd = {
					fParams: fd.fParams,
					fType: convert(fd.fType),
					fArgs: fd.fArgs.map(arg -> Record.withFields(arg, {type: convert(arg.type), expr: null})),
					fExpr: null
				};
			}
		}
		if (hasClassFlag(c, CInterface)) {
			if (fctx.fieldKind == CfrConstructor) raiseTypingError("An interface cannot have a constructor", p);
			if (!fctx.isStatic && fd.fExpr != null) unexpectedExpression(ctx.com, fctx, "An interface method cannot have a body", p);
			if (fctx.isInline && hasClassFlag(c, CInterface)) invalidModifier(ctx.com, fctx, "inline", "method of interface", p);
		} else if (fctx.fieldKind == CfrConstructor) {
			if (fctx.isStatic) invalidModifier(ctx.com, fctx, "static", "constructor", p);
			if (MetadataTools.has(Coroutine, f.cffMeta)) raiseTypingError("Invalid modifier: @:coroutine on constructor", p);
			if (fd.fType != null) switch fd.fType {
				case {type: CTPath({path: tp}), pos: p} if (tp.tpackage.length == 0 && tp.tname == "Void"):
					if (ctx.m.isDisplayFile
						&& DisplayPosition.displayPosition.enclosedIn(p)) Typeload.loadInstance(ctx, makePtp(tp, p), ParamNormal,
							LoadReturn, true); // VOIDTODO
				case _:
					raiseTypingError("A class constructor can't have a return type", p);
			}
		}
		var parent = fctx.isStatic ? null : getParent(c, name),
			isDynamic = hasAccess(ADynamic, f.cffAccess) || (parent != null && (switch parent.cfKind {
				case Method(MethDynamic): true;
				case _: false;
			}));
		if (isDynamic) {
			if (fctx.isAbstract) invalidModifierCombination(fctx, ctx.com, fctx, "abstract", "dynamic", p);
			if (fctx.isInline) invalidModifierCombination(fctx, ctx.com, fctx, "dynamic", "inline", p);
			if (fctx.isAbstractMember) invalidModifier(ctx.com, fctx, "dynamic", "method of abstract", p);
		}
		if (fctx.overridePos != null) {
			if (fctx.isStatic) invalidModifierCombination(fctx, ctx.com, fctx, "override", "static", p);
			addClassFieldFlag(cf, CfOverride);
		}
		ctx.typeParams = params.concat(ctx.typeParams);
		var setup = setupArgsRet(ctx, cctx, fctx, name, fd, p), args = setup.args, ret = setup.ret,
			isCoroutine = MetadataTools.has(Coroutine, f.cffMeta), functionMode = isCoroutine ? FunCoroutine : FunFunction,
			targs = args.forType(), t:T;
		if (!isCoroutine) t = TFun({args: targs, ret: ret});
		else if (CoroConfig.ofMetaList(cf.cfMeta).transformed) {
			if (targs.length == 0) throw new haxe.Exception("Invalid transformed coroutine signature");
			// Ignore leading continuation for actual signature
			var tail = targs.slice(1), actualRet = switch follow(ret) {
				case TInst({clPath: {pack: ["haxe", "coro"], name: "SuspensionResult"}}, [ret]): ret;
				case t: raiseTypingError("Return type of @:coroutine(transformed) functions must be SuspensionResult (found "
						+ sType(printContext(), t)
						+ ")",
						p);
			};
			tail.reverse();
			t = ctx.t.tcoro.tcoro.force()({args: tail, ret: actualRet});
		} else t = ctx.t.tcoro.tcoro.force()({args: targs, ret: ret});
		cf.cfType = t;
		cf.cfKind = Method(fctx.isMacro ? MethMacro : fctx.isInline ? MethInline : isDynamic ? MethDynamic : MethNormal);
		cf.cfParams = params;
		if (isPublic(cctx, f.cffAccess, parent)) addClassFieldFlag(cf, CfPublic);
		if (fctx.isFinal) addClassFieldFlag(cf, CfFinal);
		if (fctx.isExtern) addClassFieldFlag(cf, CfExtern);
		if (fctx.isAbstract) {
			if (fctx.fieldKind == CfrConstructor) {
				var position = try accessPos(AAbstract, f.cffAccess) catch (_:NotFound) p;
				invalidModifier(ctx.com, fctx, "abstract", "constructor", position);
			}
			addClassFieldFlag(cf, CfAbstract);
			if (MetadataTools.has(CallSuper, cf.cfMeta)) invalidModifier(ctx.com, fctx, "@:callSuper", "abstract method", cf.cfNamePos);
		}
		if (fctx.isAbstractMember) addClassFieldFlag(cf, CfImpl);
		if (fctx.isAbstractConstructor) addClassFieldFlag(cf, CfAbstractConstructor);
		if (fctx.isGeneric) addClassFieldFlag(cf, CfGeneric);
		if (fctx.defaultPos != null) {
			if (ctx.com.platform == Jvm) {
				if (!hasClassFlag(ctx.c.curclass, CExtern)
					|| !hasClassFlag(c, CInterface)) invalidModifierOnly(ctx.com, fctx, "default", "on extern interfaces", fctx.defaultPos);
				addClassFieldFlag(cf, CfDefault);
			} else invalidModifierOnly(ctx.com, fctx, "default", "on the Java target", fctx.defaultPos);
		}
		if (fctx.overloadPos != null) {
			if (ctx.com.config.pfOverload) addClassFieldFlag(cf, CfOverload);
			else if (fctx.fieldKind == CfrConstructor) {
				if ((hasClassFlag(c, CExtern) || fctx.isExtern) && !fctx.isInline) addClassFieldFlag(cf, CfOverload);
				else invalidModifierOnly(ctx.com, fctx, "overload", "on extern non-inline constructors", fctx.overloadPos);
			} else {
				addClassFieldFlag(cf, CfOverload);
				if (!(hasClassFlag(c,
					CExtern) || fctx.isExtern)) invalidModifierOnly(ctx.com, fctx, "overload", "on extern functions", fctx.overloadPos);
			}
		}
		cf.cfMeta = cf.cfMeta.map(m -> m.meta == core.MetaList.StrictMeta.AstSource
			&& m.exprs.length == 0 ? Record.withFields(m, {exprs: fd.fExpr == null ? vector() : vector(fd.fExpr)}) : m);
		if (parent != null && !MetadataTools.has(Native, cf.cfMeta)) try cf.cfMeta.unshift(MetadataTools.get(Native, parent.cfMeta))
		catch (_:NotFound) {}
		Typeload.generateArgsMeta(ctx.com, c, m -> cf.cfMeta.unshift(m), fd.fArgs);
		var fmode:CurrentFun;
		if (cctx.abstractType != null) {
			checkAbstract(ctx, cctx, fctx, cctx.abstractType, c, cf, fd, t, ret, p);
			fmode = fctx.isAbstractMember ? FunMemberAbstract : FunStatic;
		} else fmode = fctx.fieldKind == CfrConstructor ? FunConstructor : fctx.isStatic ? FunStatic : FunMember;
		Typeload.initMetaOverloads(ctx, c, cf);
		if (fctx.doBind) TypeBinding.bindMethod(ctx, cctx, fctx, fmode, cf, t, args, ret, fd.fExpr, functionMode,
			fd.fExpr == null ? f.cffPos : fd.fExpr.pos);
		else {
			if (fctx.isDisplayField) {
				delay(ctx.g, PTypeField, function() {
					// We never enter type_function so we're missing out on the argument processing there. Let's do it here.
					var local = TyperManager.cloneForExpr(ctx, fmode, functionMode);
					args.forExpr(local);
				});
				checkFieldDisplay(ctx, fctx, c, cf);
			} else delay(ctx.g, PTypeField, function() {
				var local = TyperManager.cloneForExpr(ctx, fmode, functionMode);
				args.verifyExtern(local);
			});
			if (fd.fExpr != null) {
				if (fctx.isAbstract) unexpectedExpression(ctx.com, fctx, "Abstract methods may not have an expression", p);
				else if (!(fctx.isInline || fctx.isMacro)) warning(ctx, WExternWithExpr,
					"Extern non-inline function may not have an expression", p);
			}
		}
		return cf;
	}

	public static function createProperty(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, c:TClass, f:ClassField, cf:TClassField,
			get:PlacedName, set:PlacedName, t:Null<TypeHint>, eo:Null<Expr>, p:Pos):TClassField {
		var name = f.cffName.name, ret:T;
		if (t == null && eo == null) ret = raiseTypingError("Property requires type-hint or initialization", p);
		else if (t == null) ret = mkMono();
		else ret = Typeload.loadTypeHint(ctx, p, LoadNormal, t);
		cf.cfType = ret;
		var tget:T, tset:T;
		if (cctx.abstractType != null && fctx.isAbstractMember) {
			var a = cctx.abstractType;
			if (MetadataTools.has(IsVar, f.cffMeta)) raiseTypingError("Abstract properties cannot be real variables", f.cffPos);
			var ta = applyParams(a.aParams, extractParamTypes(a.aParams), a.aThis);
			tget = tfun(vector(ta), ret);
			tset = tfun(vector(ta, ret), ret);
		} else {
			tget = tfun(vector(), ret);
			tset = TFun({args: vector({name: "value", optional: false, type: ret}), ret: ret});
		}
		inline function findAccessor(name:String):Array<CastField> {
			if (fctx.isStatic) {
				var cf = PMap.find(name, c.clStatics);
				return [{type: cf.cfType, field: cf}].concat(cf.cfOverloads.map(cf -> {type: cf.cfType, field: cf}));
			}
			return getOverloads(ctx.com, c, name);
		}
		if (fctx.isAbstractMember) addClassFieldFlag(cf, CfImpl);
		inline function checkMethod(m:String, t:T, isGetter:Bool):Void {
			try {
				var overloads = findAccessor(m), found:Null<CastField> = null;
				for (i in 0...overloads.length) if (i == overloads.length - 1 || typeIseq(t, overloads[i].type)) {
					found = overloads[i];
					break;
				}
				if (found == null) throw NotFound.raise();
				var t2 = found.type, f2 = found.field;
				for (m in f.cffMeta) if (m.meta == core.MetaList.StrictMeta.Deprecated) f2.cfMeta.unshift(m);
				// Now that we know there is a field, we have to delay the actual unification even further. The reason is that unification could resolve
				// TLazy, which would then cause field typing before we're done with our PConnectField pass. This could cause interface fields to not
				// be generated in time.
				delay(ctx.g, PForce, function() {
					try {
						switch f2.cfKind {
							case Method(MethMacro):
								displayErrorExt(ctx.com,
									makeError(Custom(f2.cfName + ": Macro methods cannot be used as property accessor"), p,
										[makeError(Custom(complMsg(f2.cfName + ": Accessor method is here")), f2.cfPos)]));
							case _:
						}
						unifyRaise(t2, t, f2.cfPos);
						if ((fctx.isAbstractMember && !hasClassFieldFlag(f2, CfImpl))
							|| (hasClassFieldFlag(f2,
								CfImpl) && !fctx.isAbstractMember)) displayError(ctx.com,
								"Mixing abstract implementation and static properties/accessors is not allowed", f2.cfPos);
					} catch (exc:Dynamic) {
						switch exc {
							case(core.ds.ExceptionTools.typing(_) => Some(err)):
								switch err.errMessage {
									case Unify(_): raiseError(makeError(Custom("In method " + m + " required by property " + name),
											err.errPos, [err]));
									case _: throw exc;
								}
							case _:
								throw exc;
						}
					}
				});
			} catch (_:NotFound) {
				inline function generate():TClassField {
					var cf = mkField(m, t, p, Globals.nullPos);
					cf.cfMeta = [meta(CompilerGenerated), meta(NoCompletion)];
					cf.cfKind = Method(MethNormal);
					return cf;
				}
				if (hasClassFlag(c, CInterface)) {
					var cf = generate();
					c.clFields = PMap.add(cf.cfName, cf, c.clFields);
					c.clOrderedFields.unshift(cf);
				} else if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, f.cffPos)) {
					var cfAccessor = generate();
					removeClassFieldFlag(cfAccessor, CfPublic);
					if (fctx.isStatic) addClassFieldFlag(cfAccessor, CfStatic);
					var diag:core.DisplayTypes.MissingFieldsDiagnostics = {
						mfPos: f.cffName.pos,
						mfOn: TClassDecl(c),
						mfFields: [
							{
								field: cfAccessor,
								type: t,
								completion: core.display.CompletionItem.CompletionType.fromType(context.display.Display.getImportStatus.bind(ctx),
									null, t)
							}
						],
						mfCause: PropertyAccessor(cf, isGetter)
					};
					var cm = context.display.DiagnosticsPrinter.makeMissingFieldsMessage(diag);
					compiler.io.CompilerMessage.addModuleDiagnostic(ctx.com, c.clModule, cm);
				} else if (!hasClassFlag(c, CExtern)) {
					try {
						var f2 = fctx.isStatic ? classField(c, extractParamTypes(c.clParams), m).field : PMap.find(m, c.clStatics);
						displayError(ctx.com,
							"Method "
							+ m
							+ " is no valid accessor for "
							+ name
							+ " because it is "
							+ (fctx.isStatic ? "not " : "")
							+ "static",
							f2.cfPos);
					} catch (_:NotFound) displayError(ctx.com, "Method " + m + " required by property " + name + " is missing", p);
				}
			}
		}
		function displayAccessor(m:String, p:Pos):Void {
			try {
				var l = findAccessor(m);
				var cf:TClassField = if (l.length == 1) l[0].field else throw NotFound.raise();
				context.display.DisplayEmitter.displayField(ctx, Self(TClassDecl(c)), fctx.isStatic ? CFSStatic : CFSMember, cf, p);
			} catch (_:NotFound) {}
		}
		inline function resolvedAccessor(part:PlacedName, getter:Bool, privateCall:Bool):VarAccess {
			var m = (getter ? "get_" : "set_") + name;
			if (fctx.isDisplayField
				&& DisplayPosition.displayPosition.enclosedIn(part.pos)) delay(ctx.g, PConnectField, () -> displayAccessor(m, part.pos));
			if (!cctx.isLib) delay(ctx.g, PConnectField, () -> checkMethod(m, getter ? tget : tset, getter));
			return privateCall ? AccPrivateCall : AccCall;
		}
		var getAccess = switch get.name {
			case "null": AccNo;
			case "dynamic": AccCall;
			case "never": AccNever;
			case "default": AccNormal;
			case "get": resolvedAccessor(get, true, false);
			case "private get": resolvedAccessor(get, true, true);
			case _:
				displayError(ctx.com, name + ": Custom property accessor is no longer supported, please use `get`", get.pos);
				AccCall;
		};
		var setAccess = switch set.name {
			case "null":
				// standard flash library read-only variables can't be accessed for writing, even in subclasses
				hasClassFlag(c, CExtern)
				&& c.clPath.pack.length > 0
				&& c.clPath.pack[0] == "flash"
				&& ctx.com.platform == Flash ? AccNever : AccNo;
			case "never": AccNever;
			case "dynamic": AccCall;
			case "default": AccNormal;
			case "set": resolvedAccessor(set, false, false);
			case "private set": resolvedAccessor(set, false, true);
			case _:
				displayError(ctx.com, name + ": Custom property accessor is no longer supported, please use `set`", set.pos);
				AccCall;
		};
		if (setAccess == AccNever && getAccess == AccNever) raiseTypingError(name + ": Unsupported property combination", p);
		if (setAccess == AccPrivateCall && getAccess == AccPrivateCall && hasClassFieldFlag(cf,
			CfPublic)) raiseTypingError(name + ": (private get, private set) property cannot be public", p);
		cf.cfKind = Var({vRead: getAccess, vWrite: setAccess});
		if (fctx.isExtern) addClassFieldFlag(cf, CfExtern);
		if (hasAccess(AEnum, f.cffAccess)) addClassFieldFlag(cf, CfEnum);
		TypeBinding.bindVar(ctx, cctx, fctx, cf, eo);
		return cf;
	}

	/**
		Emit compilation error on `final static function`
	*/
	public static function rejectFinalStaticMethod(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, f:ClassField):Void {
		if (fctx.isStatic && fctx.isFinal && !hasClassFlag(cctx.tclass, CExtern)) {
			var p:Pos;
			try p = accessPos(AFinal, f.cffAccess)
			catch (_:NotFound) {
				try p = MetadataTools.get(Final, f.cffMeta).pos
				catch (_:NotFound) {
					try p = accessPos(AStatic, f.cffAccess)
					catch (_:NotFound) p = f.cffPos;
				}
			}
			invalidModifierCombination(fctx, ctx.com, fctx, "final", "static", p);
		}
	}

	public static function initField(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, f:ClassField, cf:TClassField):Void {
		var c = cctx.tclass, name = f.cffName.name, p = f.cffPos;
		TypeloadCheck.checkGlobalMetadata(ctx, f.cffMeta, m -> cf.cfMeta.unshift(m), c.clModule.mPath, c.clPath, name);
		if (!hasClassFlag(c, CExtern) && !MetadataTools.has(Native, f.cffMeta)) Naming.checkFieldName(ctx.com, name, p);
		for (acc in f.cffAccess) switch [acc.access, f.cffKind] {
			case [AFinal, FProp(_)] if (!hasClassFlag(c, CExtern) && ctx.com.platform != Jvm):
				invalidModifierOnProperty(ctx.com, fctx, AstTools.sPlacedAccess(acc), acc.pos);
			case [APublic | APrivate | AStatic | AFinal | AExtern, _]:
			case [ADynamic | AOverride | AMacro | AInline | AAbstract | AOverload, FFun(_)]:
			case [AInline, FVar(_)]:
			case [AEnum, FVar(_) | FProp(_)]:
			case [_, FVar(_)]:
				displayError(ctx.com, "Invalid accessor '" + AstTools.sPlacedAccess(acc) + "' for variable " + name, acc.pos);
			case [_, FProp(_)]:
				displayError(ctx.com, "Invalid accessor '" + AstTools.sPlacedAccess(acc) + "' for property " + name, acc.pos);
			case [_, FFun(_)]:
				displayError(ctx.com, "Invalid accessor '" + AstTools.sPlacedAccess(acc) + "' for function " + name, acc.pos);
		}
		if (fctx.overridePos != null && c.clSuper == null) {
			var position = try accessPos(AOverride, f.cffAccess) catch (_:NotFound) p;
			invalidModifier(ctx.com, fctx, "override", "field of class that has no parent", position);
		}
		cf = switch f.cffKind {
			case FVar(_) | FProp(_) if (fctx.fieldKind == CfrConstructor): raiseTypingError("A constructor must be a function", p);
			case FVar(t, e): createVariable(ctx, cctx, fctx, c, f, cf, t, e, p);
			case FFun(fd):
				rejectFinalStaticMethod(ctx, cctx, fctx, f);
				createMethod(ctx, cctx, fctx, c, f, cf, fd, p);
			case FProp(get, set, t, eo): createProperty(ctx, cctx, fctx, c, f, cf, get, set, t, eo, p);
		};
		if (fctx.isStatic || (fctx.isMacro && ctx.com.isMacroContext)) addClassFieldFlag(cf, CfStatic);
		if (MetadataTools.has(InheritDoc, cf.cfMeta)) delay(ctx.g, PTypeField, () -> InheritDocTools.buildClassFieldDoc(ctx, c, cf));
	}

	public static function checkOverload(ctx:Typer, f:TClassField, fs:Array<TClassField>, externClass:Bool):Bool {
		for (f2 in fs) if (f != f2 && Overloads.sameOverloadArgs(f.cfType, f2.cfType, f, f2)) {
			displayErrorExt(ctx.com,
				makeError(Custom("Another overloaded field of same signature was already declared : " + f.cfName), f.cfPos,
					[makeError(Custom(complMsg("The second field is declared here")), f2.cfPos)]));
			return false;
		}
		if (ctx.com.platform != Jvm || externClass) return true;
		for (f2 in fs) if (f != f2 && Overloads.sameOverloadArgs(f.cfType, f2.cfType, f, f2, ambiguateFuns)) {
			// Don't bother checking this on externs and assume the users know what they're doing (issue #11131)
			if (hasClassFieldFlag(f, CfExtern) && hasClassFieldFlag(f2, CfExtern)) return true;
			displayErrorExt(ctx.com,
				makeError(Custom("Another overloaded field of similar signature was already declared : "
					+ f.cfName
					+ "\nThe signatures are different in Haxe, but not in the target language"),
					f.cfPos, [makeError(Custom(complMsg("The second field is declared here")), f2.cfPos)]));
			return false;
		}
		return true;
	}

	public static function checkOverloads(ctx:Typer, c:TClass):Void {
		// check if field with same signature was declared more than once
		var isExtern = hasClassFlag(c, CExtern);
		function checkField(f:TClassField):Void {
			if (hasClassFieldFlag(f, CfOverload)) {
				var all:Array<TClassField> = [f].concat(f.cfOverloads), ok = true;
				for (candidate in all) ok = ok && checkOverload(ctx, candidate, all, isExtern);
			}
		}
		for (f in c.clOrderedFields) checkField(f);
		for (f in c.clOrderedStatics) checkField(f);
		if (c.clConstructor != null) checkField(c.clConstructor);
	}

	public static function finalizeClass(cctx:ClassInitCtx):Void {
		// push delays in reverse order so they will be run in correct order
		for (pair in cctx.delayedExpr) if (pair.lazy != null) delay(pair.ctx.g, PTypeField, function() {
			lazyType(pair.lazy);
		});
	}

	public static function createClassField(cctx:ClassInitCtx, f:ClassField):TClassField {
		var cf = mkField(f.cffName.name, tDynamic, f.cffPos, f.cffName.pos, isPublic(cctx, f.cffAccess, null));
		cf.cfDoc = f.cffDoc;
		cf.cfMeta = f.cffMeta.copy();
		return cf;
	}

	public static function initClass(ctxC:Typer, cctx:ClassInitCtx, c:TClass, p:Pos, herits:haxe.ds.Vector<ClassFlag>,
			fields:Array<ClassField>):Void {
		var com:CommonContext = ctxC.com;
		if (cctx.isClassDebug) Sys.println("Created class context: " + dumpClassContext(cctx));
		fields = buildFields(ctxC, cctx, c, fields);
		switch cctx.coreApiCheck {
			case CoreApiCheck.On:
				if (com.display.dmsCheckCoreApi) delay(ctxC.g, PForce, () -> Typeload.initCoreApi(ctxC, c));
			case CoreApiCheck.Implied:
				if (com.display.dmsCheckCoreApi) delay(ctxC.g, PForce, function() {
					try Typeload.initCoreApi(ctxC, c)
					catch (exc:Dynamic) {
						switch exc {
							case(core.ds.ExceptionTools.typing(_) => Some(err)):
								switch err.errMessage {
									case ModuleNotFound(_) | TypeNotFound(_):
									case _: com.errorExt(err);
								}
							case _:
								throw exc;
						}
					}
				});
			case CoreApiCheck.Off:
		}
		if (!cctx.isLib) {
			delay(ctxC.g, PForce, () -> checkOverloads(ctxC, c));
			if (c.clSuper != null) {
				var sup = c.clSuper;
				if (hasClassFlag(sup.cls,
					CAbstract) && !hasClassFlag(c,
						CAbstract)) delay(ctxC.g, PForce, () -> TypeloadCheck.Inheritance.checkAbstractClass(ctxC, c, sup.cls, sup.params));
			}
		}
		function hasField(name:String, sup:Null<ClassAndParams>):Bool {
			if (sup == null) return false;
			var c = sup.cls;
			if (PMap.exists(name, c.clFields) || hasField(name, c.clSuper)) return true;
			for (pair in c.clImplements) if (hasField(name, pair)) return true;
			return false;
		}
		function checkRequire(metadata:Metadata):Null<{condition:String, message:Null<String>}> {
			for (m in metadata) if (m.meta == core.MetaList.StrictMeta.Require) {
				var conditions = m.exprs;
				for (i in 0...conditions.length) {
					var e = conditions[i], sc = switch e.expr {
						case EConst(Ident(s)): s;
						case EBinop(op, {expr: EConst(Ident(s))}, {expr: EConst(c)})
							if ([OpEq, OpNotEq, OpGt, OpGte, OpLt, OpLte].contains(op)):
							switch c {
								case Int(_) | Float(_) | String(_): s + sBinop(op) + sConstant(c);
								case _: "";
							}
						case _: "";
					};
					if (!ParserEntry.isTrue(ParserEntry.eval(com.defines, e))) {
						var msg:Null<String> = null;
						if (i + 1 < conditions.length) switch conditions[conditions.length - 1].expr {
							case EConst(String(s, _)):
								msg = s;
							case _:
						}
						return {condition: sc, message: msg};
					}
				}
			}
			return null;
		}
		var classRequire = checkRequire(c.clMeta), hasInit = false;
		for (f in fields) {
			var p = f.cffPos, displayModifier = Typeload.checkFieldAccess(ctxC, f),
				fctx = createFieldContext(ctxC, cctx, f, ctxC.m.isDisplayFile, displayModifier), cf = createClassField(cctx, f),
				ctx = createTyperContextForField(ctxC, cctx, fctx, f, cf);
			try {
				if (fctx.isFieldDebug) Sys.println("Created field context: " + dumpFieldContext(fctx));
				initField(ctx, cctx, fctx, f, cf);
				if (fctx.fieldKind == CfrInit) {
					if (hasInit) displayError(ctx.com,
						"Duplicate class field declaration : " + Globals.sTypePath(c.clPath) + "." + cf.cfName, cf.cfNamePos);
					else hasInit = true;
				}
				if (fctx.isFieldDebug) Sys.println("Created field: " + Printer.sTclassField("", cf));
				if (fctx.isStatic && hasClassFlag(c,
					CInterface) && fctx.fieldKind != CfrInit && !cctx.isLib && !hasClassFlag(c,
						CExtern)) raiseTypingError("You can only declare static fields in extern interfaces", p);
				var req = checkRequire(f.cffMeta);
				if (req == null && (fctx.isStatic || fctx.fieldKind == CfrConstructor)) req = classRequire;
				if (req != null) cf.cfKind = Var({
					vRead: AccRequire(req.condition, req.message),
					vWrite: AccRequire(req.condition, req.message)
				});
				switch fctx.fieldKind {
					case CfrConstructor:
						var sup = c.clSuper;
						if (sup != null
							&& sup.cls.clConstructor != null
							&& !hasClassFlag(sup.cls, CExtern)
							&& hasClassFieldFlag(sup.cls.clConstructor,
								CfFinal)) ctx.com.error("Cannot override final constructor", cf.cfPos);
						if (c.clConstructor == null) c.clConstructor = cf;
						else {
							var ctor = c.clConstructor;
							if (ctx.com.config.pfOverload || ((hasClassFlag(c, CExtern) || fctx.isExtern) && !fctx.isInline)) {
								if (hasClassFieldFlag(cf, CfOverload) && hasClassFieldFlag(ctor, CfOverload)) ctor.cfOverloads.unshift(cf);
								else displayError(ctx.com,
									"If using overloaded constructors, all constructors must be declared with 'overload'",
									hasClassFieldFlag(cf, CfOverload) ? ctor.cfPos : cf.cfPos);
							} else displayError(ctx.com, "Duplicate constructor", p);
						}
					case CfrInit:
					case CfrStatic | CfrMember:
						var duplicate = fctx.isStatic ? (PMap.exists(cf.cfName,
							c.clFields) || hasField(cf.cfName, c.clSuper)) : PMap.exists(cf.cfName, c.clStatics);
						if (!hasClassFlag(c,
							CExtern) && duplicate) raiseTypingError("Same field name can't be used for both static and instance : "
								+ cf.cfName, p);
						if (fctx.overridePos != null) addClassFieldFlag(cf, CfOverride);
						inline function isVar(cf:TClassField):Bool return switch cf.cfKind {
							case Var({vRead: AccRequire(_), vWrite: AccRequire(_)}): false;
							case Var(_): true;
							case _: false;
						};
						var table = fctx.isStatic ? c.clStatics : c.clFields;
						if (PMap.mem(cf.cfName, table)) {
							if (hasClassFieldFlag(cf, CfOverload) && !isVar(cf)) {
								var main = PMap.find(cf.cfName, table);
								if (isVar(main)) displayError(ctx.com, "Cannot declare a variable with same name as a method", main.cfPos);
								if (!hasClassFieldFlag(main,
									CfOverload)) displayError(ctx.com, "Overloaded methods must have 'overload' accessor", main.cfPos);
								main.cfOverloads = [cf].concat(cf.cfOverloads).concat(main.cfOverloads);
							} else {
								var desc = switch c.clKind {
									case KAbstractImpl(a): {kind: "abstract", path: a.aPath};
									case KModuleFields(m): {kind: "module", path: m.mPath};
									case _: {kind: "class", path: c.clPath};
								};
								displayError(ctx.com,
									"Duplicate " + desc.kind + " field declaration : " + Globals.sTypePath(desc.path) + "." + cf.cfName,
									cf.cfNamePos);
							}
						} else TClassTools.addField(c, cf);
				}
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						switch err.errMessage {
							case Custom(_) if (err.errPos == p): displayErrorExt(ctx.com, err);
							case _: throw exc;
						}
					case _:
						throw exc;
				}
			}
		}
		if (cctx.abstractType != null) {
			var a = cctx.abstractType;
			a.aToField.reverse();
			a.aFromField.reverse();
			a.aOps.reverse();
			a.aUnops.reverse();
			a.aArray.reverse();
		}
		c.clOrderedStatics.reverse();
		c.clOrderedFields.reverse();
		delay(ctxC.g, PConnectField, function() switch follow(c.clType) {
			case TAnon(an):
				an.aFields = c.clStatics;
			case _:
				throw new haxe.Exception("Invalid class static type");
		});
		/*
			make sure a default contructor with same access as super one will be added to the class structure at some point.
		*/
		var hasStructInit = false, structInitPos = Globals.nullPos;
		try {
			structInitPos = MetadataTools.get(StructInit, c.clMeta).pos;
			hasStructInit = true;
		} catch (_:NotFound) {}
		if (hasStructInit) {
			if (hasClassFlag(c, CInterface)) displayError(com, "@:structInit is not allowed on interfaces", structInitPos);
			else ensureStructInitConstructor(ctxC, c, fields, p);
		}
		if (cctx.uninitializedFinal.length > 0 && c.clConstructor == null && !hasClassFlag(c, CAbstract)) {
			var cf = cctx.uninitializedFinal[0];
			if (context.display.Diagnostics.errorInDiagnosticsRun(com, cf.cfNamePos)) {
				var diag:core.DisplayTypes.MissingFieldsDiagnostics = {
					mfPos: c.clNamePos,
					mfOn: TClassDecl(c),
					mfFields: [],
					mfCause: FinalFields(cctx.uninitializedFinal.copy())
				};
				var cm = context.display.DiagnosticsPrinter.makeMissingFieldsMessage(diag);
				compiler.io.CompilerMessage.addModuleDiagnostic(com, c.clModule, cm);
			} else displayErrorExt(com,
				makeError(Custom("This class has uninitialized final vars, which requires a constructor"), p,
					[makeError(Custom("Example of an uninitialized final var"), cf.cfNamePos)]));
		}
		// add_constructor does not deal with overloads correctly
		if (!hasStructInit && !com.config.pfOverload) delayLate(ctxC.g, PConnectField,
			() -> TypeloadFunction.addConstructor(ctxC, c, cctx.forceConstructor, p));
		finalizeClass(cctx);
	}
}

// port: module TypeBinding of typeloadFields.ml
class TypeBinding {
	public static function bindType(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, cf:TClassField, r:TLazy, p:Pos):Void {
		var c = cctx.tclass;
		var deferred:TLazy = r;
		function isFullType(t:T):Bool return switch t {
			case TFun(signature): isFullType(signature.ret) && core.ds.ArrayTools.foreach(signature.args,
					function(arg) return isFullType(arg.type));
			case TMono(mono): mono.tmType != null && isFullType(mono.tmType);
			case TAbstract(_, _) | TInst(_, _) | TEnum(_, _) | TLazy(_) | TDynamic(_) | TAnon(_) | TType(_, _): true;
		};
		// force macro system loading of this class in order to get completion
		inline function forceMacro(display:Bool):Void delay(ctx.g, PTypeField, function() {
			try {
				ctx.g.doMacro(ctx, MDisplay, c.clPath, cf.cfName, vector(), p);
			} catch (_:Exit) {} catch (error:core.Error.TypingError) {
				if (!display) throw error;
			}
		});
		function handleDisplayField():Void {
			if (fctx.isMacro && !ctx.com.isMacroContext) forceMacro(true);
			else {
				cf.cfType = TLazy(deferred);
				cctx.delayedExpr.unshift({ctx: ctx, lazy: deferred});
			}
		}
		if (ctx.com.display.dmsFullTyping) {
			if (fctx.isMacro && !ctx.com.isMacroContext) forceMacro(false);
			else {
				cf.cfType = TLazy(deferred);
				cctx.delayedExpr.unshift({ctx: ctx, lazy: deferred});
			}
		} else if (ctx.com.display.dmsForceMacroTyping && fctx.isMacro && !ctx.com.isMacroContext) forceMacro(true);
		else if (fctx.isDisplayField) handleDisplayField();
		else if (!isFullType(cf.cfType)) {
			cctx.delayedExpr.unshift({ctx: ctx, lazy: null});
			cf.cfType = TLazy(deferred);
		} else if (fctx.exprPresenceMatters) cf.cfExpr = mk(TConst(TNull), tDynamic, Globals.nullPos);
	}

	public static function checkRedefinition(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, cf:TClassField):Void {
		var c = cctx.tclass;
		function getDeclared(name:String, superType:Null<{cls:TClass, params:TParams}>):Null<{cls:TClass, params:TParams}> {
			if (superType == null) return null;
			if (superType.cls.clFields.exists(name)) return superType;
			var found = getDeclared(name, superType.cls.clSuper);
			if (found != null) return found;
			for (iface in superType.cls.clImplements) {
				var found = getDeclared(name, iface);
				if (found != null) return found;
			}
			return null;
		}
		if (!fctx.isStatic && !cctx.isLib) {
			var declared = getDeclared(cf.cfName, c.clSuper);
			if (declared != null) displayError(ctx.com,
				"Redefinition of variable "
				+ cf.cfName
				+ " in subclass is not allowed. Previously declared at "
				+ Globals.sTypePath(declared.cls.clPath),
				cf.cfNamePos);
		}
	}

	public static function bindVarExpression(ctxField:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, cf:TClassField, astExpr:Expr):Void {
		var c = cctx.tclass;
		var t = cf.cfType;
		var p = cf.cfPos;
		var ctx = TyperManager.cloneForExpr(ctxField, fctx.isStatic ? FunStatic : FunMember, FunNotFunction);
		if (hasClassFlag(c, CInterface)) unexpectedExpression(ctx.com, fctx, "Initialization on field of interface", astExpr.pos);
		cf.cfMeta.unshift({meta: StrictMeta.Value, exprs: vector(astExpr), pos: Globals.mkZeroRangePos(cf.cfPos)});
		inline function checkCast(e:TExpr):TExpr {
			// insert cast to keep explicit field type (issue #1901)
			if (typeIseq(e.etype, cf.cfType)) return e;
			return switch [e.eexpr, follow(cf.cfType)] {
				case [TConst(TInt(i)), TAbstract({aPath: {pack: [], name: "Float"}},
					_)]:
					// turn int constant to float constant if expected type is float
					Record.withFields(e, {eexpr: TConst(TFloat(Std.string(i))), etype: cf.cfType});
				case _: mkCast(e, cf.cfType, e.epos);
			};
		}
		var r = makeUnforcedLazy(t, function() {
			// type constant init fields (issue #1956)
			if (!ctx.g.returnPartialType || switch astExpr.expr {
					case EConst(_): true;
					case _: false;
				}) {
				enterFieldTypingPass(ctx.g, {
					name: "bind_var_expression",
					path: ctx.c.curclass.clPath.pack.concat([ctx.c.curclass.clPath.name, ctx.f.curfield.cfName])
				});
				if (ctx.com.verbose) Common.log(ctx.com,
					"Typing " + (ctx.com.isMacroContext ? "macro " : "") + Globals.sTypePath(c.clPath) + "." + cf.cfName);
				var e = typeVarField(ctx, t, astExpr, fctx.isStatic, fctx.isDisplayField, p);
				inline function maybeRunAnalyzer(e:TExpr):TExpr return switch e.eexpr {
					case TConst(_) | TLocal(_) | TFunction(_): e;
					case _: analyzerRunOnExprRef(ctx.com, Globals.sTypePath(cctx.tclass.clPath) + "." + cf.cfName, e);
				};
				inline function requireConstantExpression(e:TExpr, msg:String):TExpr {
					var constant = optimization.Optimizer.makeConstantExpression(context.SafeCom.ofTyper(ctx), maybeRunAnalyzer(e));
					if (constant != null) return constant;
					displayError(ctx.com, msg, p);
					return e;
				}
				e = switch cf.cfKind {
					case Var(_) if (hasClassFlag(c, CExtern) || fctx.isExtern):
						if (!fctx.isStatic) {
							unexpectedExpression(ctx.com, fctx, "on extern non-static variable", p);
							e;
						} else if (!fctx.isInline) {
							unexpectedExpression(ctx.com, fctx, "on extern non-inline variable", p);
							e;
						} else requireConstantExpression(e, "Extern variable initialization must be a constant value");
					case Var(_) if (!isPhysicalField(cf)):
						// disallow initialization of non-physical fields (issue #1958)
						unexpectedExpression(ctx.com, fctx, "on field that is not a real variable", p);
						e;
					case Var(_) if (!fctx.isStatic):
						function checkThis(e:TExpr):Void switch e.eexpr {
							case TConst(TThis):
								displayError(ctx.com, "Cannot access this or other member field in variable initialization", e.epos);
								throw Exit.raise();
							case TLocal(v) if (ctx.f.vthis != null && v == ctx.f.vthis):
								displayError(ctx.com, "Cannot access this or other member field in variable initialization", e.epos);
								throw Exit.raise();
							case _:
								core.Texpr.iter(checkThis, e);
						}
						try checkThis(e)
						catch (_:Exit) {}
						e;
					case Var({vRead: AccInline}) if (ctx.com.doinline || isForcedInline(c, cf)):
						var constant = requireConstantExpression(e, "Inline variable initialization must be a constant value");
						switch c.clKind {
							case KAbstractImpl(a) if (hasClassFieldFlag(cf, CfEnum) && a.aEnum):
								unify(ctx, t, TAbstract(a, TUnification.Monomorph.spawnConstrainedMonos(t -> t, a.aParams)), p);
								var inner = switch constant.eexpr {
									case TCast(e1, null): e1;
									case _: constant;
								};
								unify(ctx, inner.etype, a.aThis, inner.epos);
							case _:
						}
						constant;
					case _: e;
				};
				e = checkCast(e);
				cf.cfExpr = e;
				cf.cfType = t;
				checkFieldDisplay(ctx, fctx, c, cf);
				}
			return t;
		}, "bind_var");
		if (!fctx.isStatic) cctx.forceConstructor = true;
		bindType(ctx, cctx, fctx, cf, r, astExpr.pos);
	}

	public static function bindVar(ctx:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, cf:TClassField, e:Null<Expr>):Void {
		var c = cctx.tclass;
		checkRedefinition(ctx, cctx, fctx, cf);
		if (e == null) checkFieldDisplay(ctx, fctx, c, cf);
		else bindVarExpression(ctx, cctx, fctx, cf, e);
	}

	public static function bindMethod(ctxField:Typer, cctx:ClassInitCtx, fctx:FieldInitCtx, fmode:CurrentFun, cf:TClassField, t:T,
			args:FunctionArguments, ret:T, e:Null<Expr>, functionMode:FunctionMode, p:Pos):Void {
		var c = cctx.tclass;
		var ctx = TyperManager.cloneForExpr(ctxField, fmode, functionMode);
		inline function bind():Void {
			ctxField.com.requestScope.stats.sMethodsTyped++;
			if (ctx.com.verbose) Common.log(ctx.com,
				"Typing " + (ctx.com.isMacroContext ? "macro " : "") + Globals.sTypePath(c.clPath) + "." + cf.cfName);
			switch ctx.com.platform {
				case Jvm if (isJavaNativeFunction(ctx, cf.cfMeta, cf.cfPos)):
					if (e != null) warning(ctx, WDeprecated,
						"@:java.native function definitions shouldn't include an expression. This behaviour is deprecated.", cf.cfPos);
					cf.cfExpr = null;
					cf.cfType = t;
				case _:
					if (MetadataTools.has(DisplayOverride,
						cf.cfMeta)) context.display.DisplayEmitter.checkFieldModifiers(ctx, c, cf, fctx.overridePos, fctx.displayModifier);
					var checkResult = fctx.fieldKind == CfrMember ? TypeloadCheck.checkOverriding(ctx, c, cf) : NothingToDo;
					inline function check():Void switch checkResult {
						case NothingToDo:
						case NormalOverride(rctx):
							TypeloadCheck.checkOverrideField(ctx, cf.cfNamePos, rctx);
						case OverloadOverride(f):
							f();
					}
					var body = TypeloadFunction.typeFunction(ctx, args, ret, e, fctx.isDisplayField, p);
					check();
					switch checkResult {
						case NormalOverride(rctx): TypeloadCheck.checkCallSuper(ctx.com, rctx, body);
						case _:
					}
					// Disabled for now, see https://github.com/HaxeFoundation/haxe/issues/3033
					// List.iter (fun (v,_) ->
					//	if v.v_name <> "_" && has_mono v.v_type then warning ctx WTemp "Uninferred function argument, please add a type-hint" v.v_pos;
					// ) fargs;
					var tf:TFunc = {tfArgs: args.forExpr(ctx), tfType: ret, tfExpr: body};
					if (fctx.fieldKind == CfrInit) switch body.eexpr {
						case TBlock([]) | TBlock([{eexpr: TConst(_)}]) | TConst(_) | TObjectDecl([]):
						case _: TClassTools.setClInit(c, body);
					}
					var expression = mk(TFunction(tf), t, p);
					var config = getCoroConfig(ctx, cf.cfMeta);
					if (config != null) expression = Coro.funToCoro(Coro.createCoroContext(ctx, config,
						coro.CoroTypes.CoroFor.ClassField(c, cf, tf, p)));
					cf.cfExpr = expression;
					cf.cfType = t;
					checkFieldDisplay(ctx, fctx, c, cf);
			}
		}
		function maybeBind():T {
			if (!ctx.g.returnPartialType) bind();
			return t;
		}
		var r = makeUnforcedLazy(t, maybeBind, "type_fun");
		bindType(ctx, cctx, fctx, cf, r, p);
	}
}
