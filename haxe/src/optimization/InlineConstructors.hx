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

package optimization;

import core.Ast;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.Texpr;
import core.Texpr.*;
import core.TFunctions.NotFound;
import core.Meta;
import core.Error;
import context.SafeCom;
import context.SafeCom.*;
import optimization.Inline as InlineOps;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// INLINE CONSTRUCTORS

/*
	First pass:
	Finds all inline objects and variables that alias them.
	Inline objects reference instances of TNew TObjectDecl and TArrayDecl.
	When an inline object is assigned to a variable, this variable is considered an alias of it.
	If an aliasing variable is assigned more than once then inlining will be cancelled for the inline
	object the variable would have aliased.
	The algorithm supports unassigned variables to be used as aliases 'var a; a = new Inl();'. For this
	reason variable declarations without assignment are tracked as IVKUnassigned inline variables.
	When an unassigned inline variable is assigned an alias it's scope is limited to that in which the
	assignment happened, after which the variable is set as "closed" and any appearance will cancel inlining.
	Fields of inline objects behave in the same way as unassigned inline variables, allowing nested object
	inlining.

	Second pass:
	Replaces inline objects with their inlined constructor expressions.
	Replaces field access of aliasing variables with the respective field inline variable or inlined methods.
	Because some replacements turn a single expression into many, this pass will map texpr into texpr list,
	which is converted into TBlocks by the caller as needed.
*/

@:structInit class InlineObjectCtor {
	public var iocClass:TClass;
	public var iocTparams:TParams;
	public var iocField:TClassField;
	public var iocForced:Bool; // Cancelling a forced constructor should produce an error

	public inline function new(iocClass:TClass, iocTparams:TParams, iocField:TClassField, iocForced:Bool) {
		this.iocClass = iocClass;
		this.iocTparams = iocTparams;
		this.iocField = iocField;
		this.iocForced = iocForced;
	}

	public inline function clone():InlineObjectCtor return new InlineObjectCtor(iocClass, iocTparams, iocField, iocForced);
}

enum InlineObjectKind {
	IOKCtor(ctor:InlineObjectCtor);
	IOKStructure;
	IOKArray(length:Int);
}

/*
	inline_object
	Represents an instance of TNew TObjectDecl or TArrayDecl that has potential to be inlined.
	Wether the inlining is cancelled or not is decided during the analysis phase.
*/
@:structInit class InlineObject {
	public var ioKind:InlineObjectKind;
	public var ioExpr:TExpr; // This is the inlined constructor expression
	public var ioPos:Pos; // The original position of the constructor expression
	public var ioHasUntyped:Bool; // Wether inlining this object would bring untyped expressions into the parent expression
	public var ioCancelled:Bool; // Wether this inline object has been cancelled
	public var ioDeclared:Bool; // Wether the variable declarations for this inline object's fields have already been output. (Used in final_map)
	public var ioAliases:Array<InlineVar>; // List of variables that are aliasing/referencing this inline object
	public var ioFields:haxe.ds.StringMap<InlineVar>; // The fields that this inline object supports, fields are inline variables which might alias other inline_objects
	public var ioInlineMethods:Array<TExpr>; // List of inlined method calls. Populated during analysis and consumed by the final_map phase
	public var ioDependentVars:Array<TVar>; // List of variables that should be cancelled if this inline object is cancelled

	public inline function new(ioKind:InlineObjectKind, ioExpr:TExpr, ioPos:Pos, ioHasUntyped:Bool, ioCancelled:Bool, ioDeclared:Bool,
			ioAliases:Array<InlineVar>, ioFields:haxe.ds.StringMap<InlineVar>, ioInlineMethods:Array<TExpr>, ioDependentVars:Array<TVar>) {
		this.ioKind = ioKind;
		this.ioExpr = ioExpr;
		this.ioPos = ioPos;
		this.ioHasUntyped = ioHasUntyped;
		this.ioCancelled = ioCancelled;
		this.ioDeclared = ioDeclared;
		this.ioAliases = ioAliases;
		this.ioFields = ioFields;
		this.ioInlineMethods = ioInlineMethods;
		this.ioDependentVars = ioDependentVars;
	}

	public inline function clone():InlineObject return new InlineObject(ioKind, ioExpr, ioPos, ioHasUntyped, ioCancelled, ioDeclared,
		ioAliases, ioFields, ioInlineMethods, ioDependentVars);
}

enum InlineVarKind {
	IVKField(io:InlineObject, name:String, // The field name
		constant:Null<TExpr>); // If this is Some _ then this field is a constant. (Used for Array .length property)
	IVKLocal;
}

enum InlineVarState {
	IVSUnassigned; // The variable isn't yet assigned
	IVSAliasing(io:InlineObject); // The variable is aliasing an inline object
	IVSCancelled; // The variable was cancelled and should no longer be considered for aliasing inline objects
}

/*
	inline_var
	Represents a local variable that is tracked by the inline constructor analysis.
	It's main purpose is to track variables that are considered aliases of inline objects.
	It also tracks all unassigned variables in the program.
*/
@:structInit class InlineVar {
	public var ivVar:TVar;
	public var ivState:InlineVarState;
	public var ivKind:InlineVarKind;
	public var ivClosed:Bool; // Inline variables are marked as closed when the scope they were first assigned on ends, any appearance of this variable after it has been closed causes cancellation

	public inline function new(ivVar:TVar, ivState:InlineVarState, ivKind:InlineVarKind, ivClosed:Bool) {
		this.ivVar = ivVar;
		this.ivState = ivState;
		this.ivKind = ivKind;
		this.ivClosed = ivClosed;
	}

	public inline function clone():InlineVar return new InlineVar(ivVar, ivState, ivKind, ivClosed);
}

enum InlineObjectField {
	IOFInlineMethod(io:InlineObject, iv:InlineVar, c:TClass, tl:TParams, cf:TClassField, tf:TFunc);
	IOFInlineVar(iv:InlineVar);
	IOFNone;
}

/*
	inline_expression_handled
	Defines what will happen to the expression being analized by analyze_aliases
*/
enum InlineExpressionHandled {
	IEHCaptured; // The expression will be assigned to a variable
	IEHIgnored; // The result of the expression will not be used
	IEHNotHandled; // Cases that are not handled (usually leads to cancelling inlining
}

private typedef FinalMapResult = {var exprs:Array<TExpr>; var object:Null<InlineObject>;}

class InlineConstructors {
	public static function inlineConstructors(scom:SafeContext, e:TExpr):TExpr return new ConstructorInlining(scom).run(e);
}

private class ConstructorInlining {
	var scom:SafeContext;
	var inlineObjs = new haxe.ds.IntMap<InlineObject>();
	var vars = new haxe.ds.IntMap<InlineVar>();
	var markedVars = new haxe.ds.IntMap<Bool>();
	var scopedIvs:Array<InlineVar> = [];
	var currIoId = 0;
	var includedUntyped = false;

	public function new(scom:SafeContext) this.scom = scom;

	function abs(i:Int):Int return i < 0 ? -i : i;

	function isMarked(id:Int):Bool return markedVars.exists(abs(id));

	function toggleMark(id:Int):Void {
		id = abs(id);
		if (markedVars.exists(id)) markedVars.remove(id);
		else markedVars.set(id, true);
	}

	function getIo(id:Int):InlineObject {
		if (!inlineObjs.exists(id)) throw NotFound.raise();
		return inlineObjs.get(id);
	}

	function getIv(id:Int):InlineVar {
		id = abs(id);
		if (!vars.exists(id)) throw NotFound.raise();
		return vars.get(id);
	}

	function fieldKeys(io:InlineObject):Array<String> {
		var keys = [for (k in io.ioFields.keys()) k];
		keys.sort(core.ds.Key.compareStrings);
		return keys;
	}

	function cancelIo(io:InlineObject, p:Pos):Void if (!io.ioCancelled) {
		io.ioCancelled = true;
		for (iv in io.ioAliases) cancelIv(iv, p);
		for (k in fieldKeys(io)) cancelIv(io.ioFields.get(k), p);
		switch io.ioKind {
			case IOKCtor(ctor):
				for (v in io.ioDependentVars) if (isMarked(v.vId)) cancelV(v, p);
				if (ctor.iocForced) SafeCom.addError(scom,
					Error.makeError(Custom("Forced inline constructor could not be inlined"), io.ioPos,
						[Error.makeError(Custom(Error.complMsg("Cancellation happened here")), p)]));
			case _:
		}
	}

	function cancelIv(iv:InlineVar, p:Pos):Void if (iv.ivState != IVSCancelled) {
		var old = iv.ivState;
		iv.ivState = IVSCancelled;
		switch old {
			case IVSAliasing(io):
				cancelIo(io, p);
			case _:
		}
		var remove = switch iv.ivKind {
			case IVKField(io, _, _): io.ioCancelled;
			case IVKLocal: true;
		};
		if (remove) {
			vars.remove(abs(iv.ivVar.vId));
			markedVars.remove(abs(iv.ivVar.vId));
		}
	}

	function cancelV(v:TVar, p:Pos):Void {
		try cancelIv(getIv(v.vId), p)
		catch (_:NotFound) {}
	}

	function setIvAlias(iv:InlineVar, io:InlineObject):Void {
		if (iv.ivState != IVSUnassigned || io.ioCancelled) {
			cancelIo(io, io.ioPos);
			cancelIv(iv, io.ioPos);
		} else {
			iv.ivState = IVSAliasing(io);
			io.ioAliases.unshift(iv);
		}
	}

	function add(v:TVar, kind:InlineVarKind):InlineVar {
		var iv = ({
			ivVar: v,
			ivState: IVSUnassigned,
			ivKind: kind,
			ivClosed: false
		} : optimization.InlineConstructors.InlineVar);
		toggleMark(v.vId);
		vars.set(abs(v.vId), iv);
		return iv;
	}

	function getIoField(io:InlineObject, s:String):InlineVar {
		if (!io.ioFields.exists(s)) throw NotFound.raise();
		return io.ioFields.get(s);
	}

	function allocIoFieldFull(io:InlineObject, name:String, constant:Null<TExpr>, t:T, p:Pos):InlineVar {
		var iv = add(allocVar(VInlined, name, t, p), IVKField(io, name, constant));
		io.ioFields.set(name, iv);
		return iv;
	}

	function allocConstIoField(io:InlineObject, name:String, e:TExpr):InlineVar {
		var iv = allocIoFieldFull(io, name, e, e.etype, e.epos);
		iv.ivState = IVSCancelled;
		return iv;
	}

	function allocIoField(io:InlineObject, name:String, t:T, p:Pos):InlineVar return allocIoFieldFull(io, name, null, t, p);

	function intFieldName(i:Int):String return i < 0 ? "n" + -i : Std.string(i);

	function isExternCtor(c:TClass, cf:TClassField):Bool return hasClassFlag(c, CExtern) || hasClassFieldFlag(cf, CfExtern);

	function makeExprForList(el:Vector<TExpr>, t:T, p:Pos):TExpr return switch el {
		case []: mk(TBlock(vector()), scom.basic.tvoid, p);
		case [e]: e;
		case _: mk(TBlock(el), t, p);
	};

	function makeExprForRevList(el:Array<TExpr>, t:T, p:Pos):TExpr {
		return makeExprForList(VectorTools.ofArrayReversed(el), t, p);
	}

	/*
		check_for_ctors
		Returns true if there are any potential inline objects in the expression.
		It is used to save work before running mark_ctors and analyze_aliases.
	*/
	function checkForCtors(e:TExpr, forceInline:Bool = false):Bool {
		var isCtor = false;
		var metaInline = false;
		switch e.eexpr {
			case TMeta({meta: core.MetaList.StrictMeta.Inline}, _):
				metaInline = true;
			case TObjectDecl(_) | TArrayDecl(_):
				isCtor = true;
			case TNew(_, _, _) if (forceInline):
				isCtor = true;
			case TNew(c = {clConstructor: cf = {cfKind: Method(MethInline), cfExpr: {eexpr: TFunction(_)}}}, _, _):
				isCtor = needsInline(scom, c, cf);
			case _:
		}
		return isCtor || checkExpr(e -> checkForCtors(e, metaInline), e);
	}

	var markInline:Null<TExpr->TExpr> = null;
	var markPlain:Null<TExpr->TExpr> = null;

	/*
		mark_ctors
		Finds all instances of potential inline objects in an expression and wraps them with metadata @:inlineObject(id).
		The id is incremented each time and is used later in the final_map phase to identify the correct inline_object.
	*/
	function markCtors(e:TExpr, forceInline:Bool = false):TExpr {
		switch e.eexpr {
			case TMeta({meta: core.MetaList.StrictMeta.InlineConstructorArgument(_, _)}, _):
				return e;
			case _:
		}
		var isInline = switch e.eexpr {
			case TMeta({meta: core.MetaList.StrictMeta.Inline}, _): true;
			case _: false;
		};
		// port: the two mapping closures are created once (a closure per node otherwise)
		if (markInline == null) {
			markInline = e -> markCtors(e, true);
			markPlain = e -> markCtors(e, false);
		}
		e = mapExpr(isInline ? markInline : markPlain, e);
		inline function mark():TExpr {
			currIoId++;
			var id:Expr = {expr: EConst(Int(Std.string(currIoId), null)), pos: e.epos};
			return mk(TMeta({meta: core.MetaList.StrictMeta.InlineObject, exprs: vector(id), pos: e.epos}, e), e.etype, e.epos);
		}
		return switch e.eexpr {
			case TObjectDecl(_) | TArrayDecl(_): mark();
			case TNew(_, _, _) if (forceInline): mark();
			case TNew(c = {clConstructor: cf = {cfKind: Method(MethInline), cfExpr: {eexpr: TFunction(_)}}}, _,
				_): needsInline(scom, c, cf) ? mark() : e;
			case _: e;
		};
	}

	/*
		analyze_aliases is the main work-horse of the constructor inliner analysis.
		It runs recursively over all expressions, it must do so in code execution order.
		The expression being analyzed should have been processed with mark_ctors before hand.

		returns: Some(inline variable) if the expression being analyzed returns an inline variable. None otherwise.

		seen_ctors: used to avoid infinite constructor inlining loops.

		captured: Wether the caller is ready to accept an inline variable. If analysis results in an inline
		variable and this argument is false then the inline variable must be cancelled before returning.

		is_lvalue: Wether the expression being analyzed is on the left side of an assignment.

		e: The expression to analyze
	*/
	function analyzeAliases(seen:Array<TClassField>, captured:InlineExpressionHandled, isLvalue:Bool, e:TExpr):Null<InlineVar> {
		inline function analyze(cap:InlineExpressionHandled, e:TExpr):Null<InlineVar> return analyzeAliases(seen, cap, false, e);
		inline function mkIo(kind:InlineObjectKind, id:Int, expr:TExpr, hasUntyped:Bool = false):InlineObject {
			var io:InlineObject = {
				ioKind: kind,
				ioExpr: expr,
				ioPos: expr.epos,
				ioCancelled: false,
				ioDeclared: false,
				ioFields: new haxe.ds.StringMap(),
				ioAliases: [],
				ioHasUntyped: hasUntyped,
				ioInlineMethods: [],
				ioDependentVars: []
			};
			inlineObjs.set(id, io);
			return io;
		}
		inline function getInlineMethod(io:InlineObject, name:String):Null<{
			c:TClass,
			tl:TParams,
			cf:TClassField,
			tf:TFunc
		}> return switch io.ioKind {
			case IOKCtor(ctor):
				var f = ctor.iocClass.clFields.get(name);
				if (f == null) null; else switch [f.cfParams, f.cfKind, f.cfExpr] {
					case [[], Method(MethInline), {eexpr: TFunction(tf)}]: needsInline(scom, ctor.iocClass, f) ? {
							c: ctor.iocClass,
							tl: ctor.iocTparams,
							cf: f,
							tf: tf
						} : null;
					case _: null;
				}
			case _: null;
		};
		inline function handleField(ef:TExpr, ethis:TExpr, name:String, validate:InlineObject->Bool,
				cap:InlineExpressionHandled = IEHNotHandled, lvalue:Bool = false):InlineObjectField {
			var iv = analyze(IEHCaptured, ethis);
			if (iv == null) return IOFNone;
			return switch iv.ivState {
				case IVSAliasing(io) if (validate(io)):
					var method = getInlineMethod(io, name);
					if (method != null) {
						var mt = applyParams(method.c.clParams, method.tl, method.cf.cfType);
						var isFun = switch ef.etype {
							case TFun(_): true;
							case _: false;
						};
						if (isFun && doesUnify(mt, ef.etype)) IOFInlineMethod(io, iv, method.c, method.tl, method.cf, method.tf);
						else {
							cancelIv(iv, ef.epos);
							IOFNone;
						}
					} else try {
						var fiv = getIoField(io, name);
						if (!typeIseqStrict(fiv.ivVar.vType, ef.etype)) throw NotFound.raise();
						var constant = switch fiv.ivKind {
							case IVKField(_, _, e) if (e != null): true;
							case _: false;
						};
						if (lvalue && constant || fiv.ivClosed) throw NotFound.raise();
						if (!lvalue && fiv.ivState == IVSUnassigned) {
							SafeCom.addWarning(scom, WConstructorInliningCancelled,
								"Constructor inlining cancelled because of use of uninitialized member field " + name, ethis.epos);
							throw NotFound.raise();
						}
						if (cap == IEHNotHandled) cancelIv(fiv, ef.epos);
						IOFInlineVar(fiv);
					} catch (_:NotFound) {
						cancelIv(iv, ef.epos);
						IOFNone;
					}
				case _:
					cancelIv(iv, ef.epos);
					IOFNone;
			};
		}
		inline function noMethods(ef:TExpr, ethis:TExpr, name:String,
				validate:InlineObject->Bool):Null<InlineVar> return switch handleField(ef, ethis, name, validate, captured, isLvalue) {
				case IOFInlineMethod(io, _, _, _, _, _):
					cancelIo(io, ef.epos);
					null;
				case IOFInlineVar(iv): iv;
				case IOFNone: null;
			};
		inline function defaultCase(e:TExpr):Null<InlineVar> {
			var old = scopedIvs;
			scopedIvs = [];
			iter(function(e) {
				analyze(IEHNotHandled, e);
			}, e);
			for (iv in scopedIvs) iv.ivClosed = true;
			scopedIvs = old;
			return null;
		}
		inline function analyzeCallArgs(el:Vector<TExpr>):{vars:Array<TVar>, exprs:Vector<TExpr>} {
			var vs = [];
			var es = new Vector<TExpr>(el.length);
			for (i in 0...el.length) {
				var e = el[i];
				switch e.eexpr {
					case TConst(_):
						es[i] = e;
					case _:
						var v = allocVar(VGenerated, "arg", e.etype, e.epos);
						analyze(IEHIgnored, mk(TVar(v, e), scom.basic.tvoid, e.epos));
						var m:MetadataEntry = {meta: core.MetaList.StrictMeta.InlineConstructorArgument(v.vId, 0), exprs: vector(), pos: e.epos};
						vs.unshift(v);
						es[i] = mk(TMeta(m, e), e.etype, e.epos);
				}
			}
			return {vars: vs, exprs: es};
		}
		inline function handleObject(id:Int, force:Bool, e:TExpr):Null<InlineVar> return switch [e.eexpr, e.etype] {
			case [TNew(c = {clConstructor: cf = {cfExpr: {eexpr: TFunction(tf)}}}, tl, pl), _]
				if (captured != IEHNotHandled && !seen.contains(cf)):
				var args = analyzeCallArgs(pl);
				var v = allocVar(VGenerated, "inl" + c.clPath.name, e.etype, e.epos);
				var inlined = InlineOps.typeInlineCtor(InlineOps.contextOfScom(scom), c, cf, tf, mk(TLocal(v), TInst(c, tl), e.epos),
					args.exprs, e.epos);
				inlined = markCtors(inlined);
				var io = mkIo(IOKCtor({
					iocClass: c,
					iocTparams: tl,
					iocField: cf,
					iocForced: isExternCtor(c, cf) || force}), id, inlined, Meta.has(HasUntyped, cf.cfMeta));
				io.ioDependentVars = args.vars;
				function fields(c:TClass, tl:TParams):Void {
					function apply(t:T):T return applyParams(c.clParams, tl, t);
					for (cf in c.clOrderedFields) switch cf.cfKind {
						case Var(_):
							allocIoField(io, cf.cfName, apply(cf.cfType), v.vPos);
						case _:
					}
					if (c.clSuper != null) fields(c.clSuper.cls, c.clSuper.params.map(apply));
				}
				fields(c, tl);
				var iv = add(v, IVKLocal);
				setIvAlias(iv, io);
				analyzeAliases([cf].concat(seen), IEHIgnored, false, io.ioExpr);
				iv;
			case [
				TNew(c = {clConstructor: cf = {cfKind: Method(MethInline), cfExpr: expr}}, _, _),
				_
			] if (expr != null && isExternCtor(c, cf)): Error.raiseTypingError("Extern constructor could not be inlined", e.epos);
			case [TObjectDecl(fl), _]
				if (captured != IEHNotHandled && fl.length > 0 && all(f -> syntax.Lexer.isValidIdentifier(f.key.name), fl)):
				var v = allocVar(VGenerated, "inlobj", e.etype, e.epos);
				var ev = mk(TLocal(v), v.vType, e.epos);
				var el = fl.map(f -> mk(TBinop(OpAssign, mk(TField(ev, FDynamic(f.key.name)), f.expr.etype, f.expr.epos), f.expr),
					f.expr.etype, f.expr.epos));
				var io = mkIo(IOKStructure, id, makeExprForList(el, scom.basic.tvoid, e.epos));
				for (f in fl) allocIoField(io, f.key.name, f.expr.etype, v.vPos);
				var iv = add(v, IVKLocal);
				setIvAlias(iv, io);
				for (e in el) analyze(IEHIgnored, e);
				iv;
			case [TArrayDecl(el), TInst(_, [elem])] if (captured != IEHNotHandled):
				var len = el.length;
				var v = allocVar(VGenerated, "inlarr", e.etype, e.epos);
				var ev = mk(TLocal(v), v.vType, e.epos);
				el = el.mapi((i, a) -> {
						var ef = mk(TArray(ev, mk(TConst(TInt(i)), a.etype, a.epos)), elem, a.epos);
						mk(TBinop(OpAssign, ef, a), elem, a.epos);
				});
				var io = mkIo(IOKArray(len), id, makeExprForList(el, scom.basic.tvoid, e.epos));
				allocConstIoField(io, "length", mk(TConst(TInt(len)), scom.basic.tint, e.epos));
				for (i in 0...len) allocIoField(io, intFieldName(i), elem, v.vPos);
				var iv = add(v, IVKLocal);
				setIvAlias(iv, io);
				for (e in el) analyze(IEHIgnored, e);
				iv;
			case _: defaultCase(e);
		};
		return switch e.eexpr {
			case TMeta({meta: core.MetaList.StrictMeta.Inline}, {
				eexpr: TMeta({meta: core.MetaList.StrictMeta.InlineObject, exprs: [{expr: EConst(Int(id, null))}]}, inner)
			}): handleObject(Std.parseInt(id), true, inner);
			case TMeta({meta: core.MetaList.StrictMeta.InlineObject, exprs: [{expr: EConst(Int(id, null))}]},
				inner): handleObject(Std.parseInt(id), false, inner);
			case TVar(v, null):
				add(v, IVKLocal);
				null;
			case TVar(v, rve):
				var rhs = analyze(IEHCaptured, rve);
				if (rhs != null) switch rhs.ivState {
					case IVSAliasing(io): setIvAlias(add(v, IVKLocal), io);
					case _:
				}
				null;
			case TBinop(OpAssign, lve, rve):
				var lhs = analyzeAliases(seen, captured, true, lve);
				if (lhs == null) {
					analyze(IEHNotHandled, rve);
					null;
				} else switch lhs.ivState {
					case IVSUnassigned:
						var rhs = analyze(IEHCaptured, rve);
						if (rhs != null) switch rhs.ivState {
							case IVSAliasing(io):
								scopedIvs.unshift(lhs);
								setIvAlias(lhs, io);
							case _: cancelIv(lhs, lve.epos);
						}
						else cancelIv(lhs, lve.epos);
						lhs;
					case _:
						cancelIv(lhs, e.epos);
						analyze(IEHNotHandled, rve);
						null;
				}
			case TField(ethis, fa): noMethods(e, ethis, fieldName(fa), _ -> true);
			case TArray(ethis, {eexpr: TConst(TInt(i))}): noMethods(e, ethis, intFieldName(i), io -> switch io.ioKind {
					case IOKArray(l): i >= 0 && i < l;
					case _: false;
				});
			case TLocal(v) if (isMarked(v.vId)):
				var iv = getIv(v.vId);
				if (iv.ivClosed || captured == IEHNotHandled) cancelIv(iv, e.epos);
				iv;
			case TBlock(el):
				for (i in 0...el.length - 1) analyze(IEHIgnored, el[i]);
				el.length == 0 ? null : analyze(captured, el[el.length - 1]);
			// The contents have already been analyzed, so we must skip the wrapped expression
			case TMeta({meta: core.MetaList.StrictMeta.InlineConstructorArgument(id, _)}, _): try {
					var iv = getIv(id);
					if (iv.ivClosed || captured == IEHNotHandled) cancelIv(iv, e.epos);
					getIv(id);
				} catch (_:NotFound) {
					null;
				}
			case TParenthesis(inner) | TMeta(_, inner) | TCast(inner, null): analyze(captured, inner);
			case TCall(ef = {eexpr: TField(ethis, fa)}, callArgs): switch handleField(ef, ethis, fieldName(fa), _ -> true) {
					case IOFInlineMethod(io, ioVar, c, tl, cf, tf):
						var args = analyzeCallArgs(callArgs);
						io.ioDependentVars = io.ioDependentVars.concat(args.vars);
						io.ioHasUntyped = io.ioHasUntyped || Meta.has(HasUntyped, cf.cfMeta);
						var inlined = InlineOps.typeInline(InlineOps.contextOfScom(scom), cf, tf,
							mk(TLocal(ioVar.ivVar), TInst(c, tl), e.epos), args.exprs, e.etype, null, e.epos, true);
						inlined = markCtors(inlined);
						io.ioInlineMethods.push(inlined);
						var iv = analyze(captured, inlined);
						if (iv != null) {
							/*
								The parent inline object might have been cancelled while analyzing the inlined method body
								If the parent inline object is cancelled the inlining of this method will no longer happen,
								so the return value must be cancelled.
							*/
							if (io.ioCancelled) {
								cancelIv(iv, inlined.epos);
								null;
							} else {
								io.ioDependentVars.unshift(iv.ivVar);
								iv;
							}
						} else null;
					case IOFInlineVar(iv):
						cancelIv(iv, e.epos);
						for (ca in callArgs) analyze(IEHNotHandled, ca);
						null;
					case IOFNone:
						for (ca in callArgs) analyze(IEHNotHandled, ca);
						null;
				}
			case TFunction(tf):
				var old = scopedIvs;
				scopedIvs = [];
				analyze(IEHIgnored, tf.tfExpr);
				for (iv in scopedIvs) iv.ivClosed = true;
				scopedIvs = old;
				null;
			case TWhile(cond, body, _):
				analyze(IEHNotHandled, cond);
				analyze(IEHIgnored, body);
				null;
			case TIf(cond, a, b) if (captured == IEHIgnored):
				analyze(IEHNotHandled, cond);
				analyze(IEHIgnored, a);
				if (b != null) analyze(IEHIgnored, b);
				null;
			case TTry(a, catches) if (captured == IEHIgnored):
				analyze(IEHIgnored, a);
				for (c in catches) analyze(IEHIgnored, c.expr);
				null;
			case _: defaultCase(e);
		};
	}

	function getIvVarDecls(iv:InlineVar):Array<TExpr> return switch [iv.ivState, iv.ivKind] {
		case [IVSAliasing(io), _]: getIoVarDecls(io);
		case [_, IVKField(_, _, e)] if (e != null): [];
		case [IVSCancelled, _]: [mk(TVar(iv.ivVar, null), scom.basic.tvoid, iv.ivVar.vPos)];
		case _: [];
	};

	function getIoVarDecls(io:InlineObject):Array<TExpr> {
		if (io.ioDeclared) return [];
		io.ioDeclared = true;
		var el = [];
		for (key in fieldKeys(io)) el = el.concat(getIvVarDecls(io.ioFields.get(key)));
		return el;
	}

	function finalMap(e:TExpr, unwrapBlock:Bool = false):FinalMapResult {
		function mapOne(e:TExpr):TExpr return makeExprForRevList(finalMap(e).exprs, e.etype, e.epos);
		inline function defaultCase(e:TExpr):FinalMapResult return {exprs: [mapExpr(mapOne, e)], object: null};
		/*
			field_case handles the final map of TField expressions.
			The last bool in the returned tuple indicates that the field was handled as an inlined method.
		*/
		inline function fieldCase(ethis:TExpr, fa:TFieldAccess, ef:TExpr):{exprs:Array<TExpr>, object:Null<InlineObject>, method:Bool} {
			var tr = finalMap(ethis);
			if (tr.object != null) {
				var io = tr.object;
				try {
					var iv = getIoField(io, fieldName(fa));
					return switch iv.ivState {
						case IVSAliasing(io): {exprs: tr.exprs, object: io, method: false};
						case _:
							var expr = switch iv.ivKind {
								case IVKField(_, _,
									constant) if (constant != null): ({eexpr: constant.eexpr, etype: constant.etype, epos: e.epos} : TExpr);
								case _: mk(TLocal(iv.ivVar), ef.etype, ef.epos);
							};
							{exprs: [expr].concat(tr.exprs), object: null, method: false};
					};
				} catch (_:NotFound) {
					// Since the field is not an inline variable then it must be an inlined method call
					if (io.ioInlineMethods.length == 0) throw "InlineConstructors.missing inline method";
					// method fields will appear in the same order as they did during analysis, so we consume the first and remove it from the list
					var method = io.ioInlineMethods.shift();
					var r = finalMap(method);
					return {exprs: r.exprs.concat(tr.exprs), object: r.object, method: true};
				}
			}
			return {
				exprs: [
					mk(TField(makeExprForRevList(tr.exprs, ethis.etype, ethis.epos), fa), ef.etype, ef.epos)
				],
				object: null,
				method: false
			};
		}
		return switch e.eexpr {
			case TMeta({meta: core.MetaList.StrictMeta.InlineObject, exprs: [{expr: EConst(Int(id, _))}]}, inner): try {
					var io = getIo(Std.parseInt(id));
					if (io.ioCancelled) throw NotFound.raise();
					if (io.ioHasUntyped) includedUntyped = true;
					var r = finalMap(io.ioExpr, true);
					{exprs: r.exprs.concat(getIoVarDecls(io)), object: io};
				} catch (_:NotFound) {
					defaultCase(inner);
				}
			case TVar(v, null) if (isMarked(v.vId)):
				var iv = getIv(v.vId);
				// If the variable is unassigned, leave the expression unchanged
				{exprs: iv.ivState == IVSUnassigned ? [e] : getIvVarDecls(iv), object: null};
			case TVar(v, inner) if (isMarked(v.vId)):
				var decls = getIvVarDecls(getIv(v.vId));
				var r = finalMap(inner, true);
				{exprs: r.exprs.concat(decls), object: null};
			case TBinop(OpAssign, lve, rve):
				var lhs = finalMap(lve);
				var rhs = finalMap(rve, true);
				if (lhs.object != null) {exprs: rhs.exprs.concat(lhs.exprs), object: lhs.object}; else {
					var rve = makeExprForRevList(rhs.exprs, rve.etype, rve.epos);
					if (lhs.exprs.length == 0) throw "InlineConstructors.empty assignment lhs";
					var first = lhs.exprs[0];
					{exprs: [mk(TBinop(OpAssign, first, rve), first.etype, first.epos)].concat(lhs.exprs.slice(1)), object: null};
				}
			case TCall(ef = {eexpr: TField(ethis, fa)}, args):
				var r = fieldCase(ethis, fa, ef);
				r.method ? {exprs: r.exprs, object: r.object} /* the field was an inlined method */ : { // the field was a normal field access
					exprs: [
						/*
							This is equivalent to `default_case e`, but field_case already run final_map
							on the TField expression so we must reuse those results.
						*/
						withExpr(e, TCall(makeExprForRevList(r.exprs, ef.etype, ef.epos), args.map(mapOne)))
					],
					object: null
				};
			case TField(ethis, fa):
				var r = fieldCase(ethis, fa, e);
				if (r.method) throw "assert: inlined method outside call";
				{exprs: r.exprs, object: r.object};
			case TArray(ethis, index = {eexpr: TConst(TInt(i))}):
				var tr = finalMap(ethis);
				if (tr.object != null) {
					var iv = getIoField(tr.object, intFieldName(i));
					switch iv.ivState {
						case IVSAliasing(io): {exprs: tr.exprs, object: io};
						case _: {exprs: [mk(TLocal(iv.ivVar), e.etype, e.epos)].concat(tr.exprs), object: null};
					}
				} else {
					exprs: [
						mk(TArray(makeExprForRevList(tr.exprs, ethis.etype, ethis.epos), index), e.etype, e.epos)
					],
					object: null
				};
			case TLocal(v) if (isMarked(v.vId)):
				var iv = getIv(v.vId);
				switch iv.ivState {
					case IVSAliasing(io): {exprs: [], object: io};
					case _: {exprs: [mk(TLocal(iv.ivVar), e.etype, e.epos)], object: null};
				}
			case TBlock(el):
				var acc = [];
				var io = null;
				for (i in 0...el.length) {
					var r = finalMap(el[i], unwrapBlock);
					acc = r.exprs.concat(acc);
					if (i == el.length - 1) io = r.object;
				}
				if (!unwrapBlock && io == null) {
					acc = [mk(TBlock(VectorTools.ofArrayReversed(acc)), e.etype, e.epos)];
				}
				{exprs: acc, object: io};
			case TMeta({meta: core.MetaList.StrictMeta.InlineConstructorArgument(_, _)}, inner): finalMap(inner);
			case TParenthesis(inner) | TCast(inner, null) | TMeta(_, inner):
				var r = finalMap(inner);
				if (r.object != null) r; else {
					var replacement = makeExprForRevList(r.exprs, inner.etype, inner.epos);
					{exprs: [mapExpr(_ -> replacement, e)], object: null};
				}
			case _: defaultCase(e);
		};
	}

	function isUser(iv:InlineVar):Bool return switch iv.ivVar.vKind {
		case VUser(_): true;
		case _: false;
	};

	function getPrettyName(iv:InlineVar):Array<String> return switch iv.ivKind {
		case IVKField(io, name, null):
			var selected = null;
			for (a in io.ioAliases) if (isUser(a)) {
				selected = a;
				break;
			}
			if (selected == null) for (a in io.ioAliases) if (a.ivVar.vKind == VInlined) {
				selected = a;
				break;
			}
			if (selected == null) {
				if (io.ioAliases.length == 0) throw "Failure: hd";
				selected = io.ioAliases[0];
			}
			[name].concat(getPrettyName(selected));
		case _: [iv.ivVar.vName];
	};

	function wasUser(iv:InlineVar):Bool return switch iv.ivKind {
		case IVKField(io, _, _):
			var selected = null;
			for (a in io.ioAliases) if (isUser(a)) {
				selected = a;
				break;
			}
			if (selected == null) {
				if (io.ioAliases.length == 0) throw "Failure: hd";
				selected = io.ioAliases[0];
			}
			wasUser(selected);
		case _: isUser(iv);
	};

	public function run(original:TExpr):TExpr {
		if (!checkForCtors(original)) return original;
		var e = markCtors(original);
		analyzeAliases([], IEHNotHandled, false, e);
		var allCancelled = true;
		for (io in inlineObjs) if (!io.ioCancelled) {
			allCancelled = false;
			break;
		}
		if (allCancelled) return original;
		var result = finalMap(e);
		var cf:TClassField = scom.curfield;
		if (includedUntyped && !Meta.has(HasUntyped, cf.cfMeta)) cf.cfMeta = [
			({meta: core.MetaList.StrictMeta.HasUntyped, exprs: vector(), pos: Globals.mkZeroRangePos(e.epos)} : core.Ast.MetadataEntry)
		].concat(cf.cfMeta);
		e = makeExprForRevList(result.exprs, e.etype, e.epos);
		// port: Globals.IntMap compares keys in reverse (compare i1 i2 = i2 - i1): iterate descending.
		var ids = [for (id in vars.keys()) id];
		ids.sort((a, b) -> b - a);
		for (id in ids) {
			var iv = vars.get(id);
			var v = iv.ivVar;
			if (isMarked(v.vId)) {
				var names = getPrettyName(iv);
				names.reverse();
				v.vName = names.join("_");
				if (wasUser(iv)) v.vKind = VInlinedConstructorVariable(names);
			}
		}
		return e;
	}
}
