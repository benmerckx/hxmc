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

package filters;

import haxe.ds.StringMap;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Texpr;
import core.Texpr.Builder;
import generators.Gctx;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

private class AccessedThis extends haxe.Exception {
	public final e:TExpr;

	public function new(e:TExpr) {
		super("Accessed_this");
		this.e = e;
	}
}

private class ExitException extends haxe.Exception {
	public function new() super("Exit");
}

class ES6Ctors {
	/* name of the method to which the constructor is extracted */
	public static final ctorMethodName = "_hx_constructor";

	/* name of the static bool flag to skip constructor body execution */
	public static final skipCtorFlagName = "_hx_skip_constructor";

	/* replace super(a,b,c) with super._hx_constructor(a,b,c) */
	public static function replaceSuperCall(e:TExpr):TExpr {
		return switch e.eexpr {
			case TCall(eSuper = {eexpr: TConst(TSuper)}, args):
				var eSuperHxctor:TExpr = {eexpr: TField(eSuper, FDynamic(ctorMethodName)), etype: eSuper.etype, epos: eSuper.epos};
				{eexpr: TCall(eSuperHxctor, args), etype: e.etype, epos: e.epos};
			case _:
				Texpr.mapExpr(replaceSuperCall, e);
		}
	}

	public static function removeDefaultArgValues(args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>):haxe.ds.Vector<{
		variable:TVar,
		defaultValue:Null<TExpr>
	}>
		return args.map(a -> {variable: a.variable, defaultValue: null});

	/* return whether given expression has `this` access before calling `super` */
	public static function hasThisBeforeSuper(e:TExpr):Null<TExpr> {
		function loop(e:TExpr):Void {
			switch e.eexpr {
				case TCall({eexpr: TConst(TSuper)}, args):
					for (a in args) loop(a);
					throw new ExitException();
				case TConst(TThis):
					throw new AccessedThis(e);
				case _:
					Texpr.iter(loop, e);
			}
		}
		try {
			loop(e);
			return null;
		} catch (_:ExitException) {
			return null;
		} catch (a:AccessedThis) {
			return a.e;
		}
	}

	public static function getNumArgs(cf:TClassField):Int {
		return switch follow(cf.cfType) {
			case TFun(sig): sig.args.length;
			case _: die("", "ES6Ctors.ml");
		}
	}

	// port: the Hashtbls below are keyed by class path; only Hashtbl.iter over `inject_super` reaches
	// the output order, and each of its entries rewrites a different class, so the order is immaterial.
	static inline function key(p:GlobalTypePath):String return p.pack.join(".") + ":" + p.name;

	/*
		the filter works in two passes:
		- mark classes whether they need to support constructor skipping and/or they skip parent's constructor
		- change the constructors of marked classes (extract body into method and/or add skipping super calls)
	 */
	public static function rewriteCtors(com:Gctx):Void {
		/* we mark classes that need changing by storing them in these two maps */
		var needsCtorSkipping = new StringMap<TClass>(),
			doesCtorSkipping = new StringMap<TClass>(),
			injectSuper:Array<TClass> = [];
		var injectSuperKeys = new StringMap<Bool>();

		/*
			we're using a reference to the root of the inheritance chain so we can easily
			generate RootClass._hx_skip_constructor expressions
		 */
		function markDoesCtorSkipping(cl:TClass, clSuper:TClass, pThisAccess:Pos):Void {
			function markNeedsCtorSkipping(cl:TClass):TClass {
				/* for non haxe-generated extern classes we can't generate any valid code, so just fail */
				if ((hasClassFlag(cl, CExtern)) && !(Meta.has(Meta.HxGen, cl.clMeta))) {
					core.Error.abort("Must call `super()` constructor before accessing `this` in classes derived from an extern class with constructor",
						pThisAccess);
				}
				var found = needsCtorSkipping.get(key(cl.clPath));
				if (found != null) return found;
				var root = switch cl.clSuper {
					case {cls: clSuper} if (clSuper.clConstructor != null):
						var ctorSuper = clSuper.clConstructor;
						var root = markNeedsCtorSkipping(clSuper);
						if (cl.clConstructor != null) {
							var ctor = cl.clConstructor;
							/* if parent's constructor receives less arguments than needed for this - we need to override the constructor */
							if (getNumArgs(ctor) > getNumArgs(ctorSuper)) addOnce(doesCtorSkipping, key(cl.clPath), root);
						}
						root;
					case _:
						cl;
				}
				addOnce(needsCtorSkipping, key(cl.clPath), root);
				return root;
			}
			var rootCl = markNeedsCtorSkipping(clSuper);
			addOnce(doesCtorSkipping, key(cl.clPath), rootCl);
		}

		var eEmptySuperCall = /* super() */ {
			var eSuper = mk(TConst(TSuper), tDynamic, nullPos);
			mk(TCall(eSuper, vector()), com.basic.tvoid, nullPos);
		}

		var activated = false;
		function mark(t:ModuleType):Void {
			switch t {
				case TClassDecl(cl) if (cl.clSuper != null && cl.clConstructor != null && cl.clConstructor.cfExpr != null
					&& cl.clConstructor.cfExpr.eexpr.match(TFunction(_))):
					var tf = switch cl.clConstructor.cfExpr.eexpr {
						case TFunction(tf): tf;
						case _: throw "assert";
					}
					var clSuper = cl.clSuper.cls;
					if (hasConstructor(clSuper)) {
						/* if parent class has a constructor, check for `this` accesses before calling `super()` */
						var thisBeforeSuper = hasThisBeforeSuper(tf.tfExpr);
						if (thisBeforeSuper != null) {
							activated = true;
							markDoesCtorSkipping(cl, clSuper, thisBeforeSuper.epos);
						}
					} else {
						/* if there was no ctor in the parent class, we still gotta call `super` */
						var k = key(cl.clPath);
						injectSuper.push(cl);
						injectSuperKeys.set(k, true);
					}
				case _:
			}
		}
		for (t in com.types) mark(t);

		if (activated) {
			/* just some helper common exprs */
			var eFalse = (Builder.makeBool(com.basic, false, nullPos));
			var eTrue = (Builder.makeBool(com.basic, true, nullPos));
			var eHxCtor = /* this._hx_constructor */ {
				var ethis = mk(TConst(TThis), tDynamic, nullPos);
				mk(TField(ethis, FDynamic(ctorMethodName)), tDynamic, nullPos);
			}

			function change(t:ModuleType):Void {
				switch t {
					case TClassDecl(cl) if (cl.clConstructor != null && cl.clConstructor.cfExpr != null
						&& cl.clConstructor.cfExpr.eexpr.match(TFunction(_))):
						var cfCtor = cl.clConstructor;
						var ctorExpr = cfCtor.cfExpr;
						var tfCtor = switch ctorExpr.eexpr {
							case TFunction(tf): tf;
							case _: throw "assert";
						}
						var doesCtorSkipping = doesCtorSkipping.get(key(cl.clPath));

						function addHxCtorMethod():Void {
							var cfFunCtor = mkField(ctorMethodName, cfCtor.cfType, cfCtor.cfPos, nullPos);
							cfFunCtor.cfExpr = replaceSuperCall(ctorExpr);
							cfFunCtor.cfKind = Method(MethNormal);
							cl.clOrderedFields.unshift(cfFunCtor);
							cl.clFields = core.ds.PMap.add(cfFunCtor.cfName, cfFunCtor, cl.clFields);
						}

						function makeHxCtorCall(eSkipFlag:TExpr):TExpr { /* this._hx_constructor(a,b,c) */
							var hxctorCallArgs = tfCtor.tfArgs.map(a -> Builder.makeLocal(a.variable, nullPos));
							var hxCtorCall = mk(TCall(eHxCtor, hxctorCallArgs), com.basic.tvoid, nullPos);
							return if (doesCtorSkipping != null) mk(TBlock(vector(
								mk(TBinop(OpAssign, eSkipFlag, eTrue), com.basic.tbool, nullPos),
								eEmptySuperCall,
								mk(TBinop(OpAssign, eSkipFlag, eFalse), com.basic.tbool, nullPos),
								hxCtorCall
							)), com.basic.tvoid, nullPos) else hxCtorCall;
						}

						function makeSkipFlag(rootCl:TClass):TExpr { /* TopClass._hx_skip_constructor */
							var eTop = mk(TTypeExpr(TClassDecl(rootCl)), tDynamic, nullPos);
							return mk(TField(eTop, FDynamic(skipCtorFlagName)), com.basic.tbool, nullPos);
						}

						switch needsCtorSkipping.get(key(cl.clPath)) {
							case null:
								switch doesCtorSkipping {
									case null:
									case root:
										addHxCtorMethod();

										var eSkipFlag = makeSkipFlag(root);

										var eCtorReplaced:TExpr = {eexpr: TBlock(vector(makeHxCtorCall(eSkipFlag))), etype: tfCtor.tfExpr.etype, epos: tfCtor.tfExpr.epos};
										cfCtor.cfExpr = {
											eexpr: TFunction({tfArgs: removeDefaultArgValues(tfCtor.tfArgs), tfType: tfCtor.tfType, tfExpr: eCtorReplaced}),
											etype: ctorExpr.etype,
											epos: ctorExpr.epos
										};
								}
							case root:
								addHxCtorMethod();

								if (doesCtorSkipping == null && cl != root)
									/* for intermediate classes that support skipping but don't do skipping themselves, we can just remove the constructor altogether,
										because the skipping logic is implemented in the parent constructor, and the actual constructor body is moved into _hx_constructor */
									cfCtor.cfExpr = null;
								else {
									var eSkip = {
										var eReturn = (mk(TReturn(null), tDynamic, nullPos));
										if (cl.clSuper == null || (injectSuperKeys.exists(key(cl.clPath))))
											/* just `return` */
											eReturn
										else
											/* `{ super(); return; }` */
											mk(TBlock(vector(eEmptySuperCall, eReturn,)), com.basic.tvoid, nullPos);
									}

									var eSkipFlag = makeSkipFlag(root);

									var eCtorReplaced:TExpr = {
										eexpr: TBlock(vector(
											mk(TIf(Builder.mkParent(eSkipFlag), eSkip, null), com.basic.tvoid, nullPos),
											makeHxCtorCall(eSkipFlag)
										)),
										etype: tfCtor.tfExpr.etype,
										epos: tfCtor.tfExpr.epos
									};

									cfCtor.cfExpr = {
										eexpr: TFunction({tfArgs: removeDefaultArgValues(tfCtor.tfArgs), tfType: tfCtor.tfType, tfExpr: eCtorReplaced}),
										etype: ctorExpr.etype,
										epos: ctorExpr.epos
									};
								}

								if (cl == root) {
									var cfSkipCtor = mkField(skipCtorFlagName, com.basic.tbool, nullPos, nullPos, true, true);
									cfSkipCtor.cfExpr = eFalse;
									cl.clOrderedStatics.unshift(cfSkipCtor);
									cl.clStatics = core.ds.PMap.add(cfSkipCtor.cfName, cfSkipCtor, cl.clStatics);
								}
						}
					case _:
				}
			}
			for (t in com.types) change(t);
		}

		for (cl in injectSuper) {
			switch cl {
				case {clConstructor: cfCtor, clSuper: sup} if (sup != null && cfCtor != null && cfCtor.cfExpr != null
					&& cfCtor.cfExpr.eexpr.match(TFunction(_))):
					var eCtor = cfCtor.cfExpr;
					var tf = switch eCtor.eexpr {
						case TFunction(tf): tf;
						case _: throw "assert";
					}
					var cf2 = cfCtor.clone();
					cf2.cfExpr = {
						eexpr: TFunction({
							tfArgs: tf.tfArgs,
							tfType: tf.tfType,
							tfExpr: {eexpr: TBlock(vector(eEmptySuperCall, tf.tfExpr)), etype: tf.tfExpr.etype, epos: tf.tfExpr.epos}
						}),
						etype: eCtor.etype,
						epos: eCtor.epos
					};
					cl.clConstructor = cf2;
				case _:
					die("", "ES6Ctors.ml");
			}
		}
	}

	// port: Hashtbl.add on a key already present shadows the previous binding; Hashtbl.find returns the newest one.
	static inline function addOnce(h:StringMap<TClass>, k:String, v:TClass):Void h.set(k, v);
}
