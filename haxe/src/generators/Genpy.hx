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

package generators;

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TOther;
import core.Meta;
import core.Define;
import core.Error.abort;
import core.Texpr;
import core.Texpr.Builder;
import core.ds.Failure;
import core.ds.NotFound;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import context.Common.samePath;
import generators.Gctx;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: OCaml evaluates the arguments of an application (including `Printf.sprintf`,
// ... `^`, tuples, records and list literals) from right to left. Wherever two arguments have
// ... side effects that reach the output (`next_id` counters, the anonymous function counter,
// ... `last_debug_comment` under -debug, variable ids), they are bound to locals in that order.

class Utils {
	public static function classOfModuleType(mt:ModuleType):TClass return switch mt {
		case TClassDecl(c): c;
		case _: throw new Failure("Not a class: " + sTypePath(tInfos(mt).mtPath));
	};

	public static function findType(com:Gctx, path:GlobalTypePath):ModuleType {
		for (mt in com.types) switch mt {
			case TAbstractDecl(_):
			case _:
				if (samePath(tInfos(mt).mtPath, path)) return mt;
		}
		return abort("Could not find type " + sTypePath(path) + "\n", nullPos);
	}

	public static function mkStaticField(c:TClass, cf:TClassField, p:Pos):TExpr {
		var ethis = Builder.makeStaticThis(c, p);
		var t = monomorphs(cf.cfParams, cf.cfType);
		return mk(TField(ethis, FStatic(c, cf)), t, p);
	}

	public static function mkStaticCall(c:TClass, cf:TClassField, el:Vector<TExpr>, p:Pos):TExpr {
		var ef = mkStaticField(c, cf, p);
		var tr = switch follow(ef.etype) {
			case TFun(sig): sig.ret;
			case _: die("", "genpy.ml Utils.mk_static_call");
		};
		return mk(TCall(ef, el), tr, p);
	}

	public static function resolveStaticField(c:TClass, n:String):TClassField {
		var cf = c.clStatics.get(n);
		if (cf == null) throw new Failure("Class " + sTypePath(c.clPath) + " has no field " + n);
		return cf;
	}

	public static function mkStaticField2(c:TClass, n:String, p:Pos):TExpr return mkStaticField(c, resolveStaticField(c, n), p);

	public static function mkStaticCall2(c:TClass, n:String, el:Vector<TExpr>, p:Pos):TExpr return mkStaticCall(c, resolveStaticField(c, n), el, p);
}

class KeywordHandler {
	static final kwds:haxe.ds.StringMap<Bool> = {
		var h = new haxe.ds.StringMap();
		for (s in [
			"and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "exec", "finally", "for",
			"from", "global", "if", "import", "in", "is", "lambda", "not", "or", "pass", "raise", "return", "try", "while",
			"with", "yield", "None", "True", "False",
		]) h.set(s, true);
		h;
	};

	static final kwds2:haxe.ds.StringMap<Bool> = {
		var h = new haxe.ds.StringMap();
		for (s in [
			"len", "int", "float", "list", "bool", "str", "isinstance", "print", "min", "max",
			"hasattr", "getattr", "setattr", "delattr", "callable", "type", "ord", "chr", "iter", "map", "filter",
			"tuple", "dict", "set", "bytes", "bytearray", "self",
		]) h.set(s, true);
		h;
	};

	public static function handleKeywords(s:String):String {
		var l = s.length;
		return if (kwds.exists(s)) "_hx_" + s
		/*
			handle special __ underscore behaviour (creates private fields for objects) for fields but only if the field doesn't
			end with at least one underscores like __iter__ because these are special fields
		*/
		else if (l > 2 && s.substr(0, 2) == "__" && s.substr(l - 1, 1) != "_") "_hx_" + s
		else s;
	}

	public static function checkVarDeclaration(v:TVar):Void {
		if (!Meta.has(Meta.This, v.vMeta)) if (kwds2.exists(v.vName)) v.vName = "_hx_" + v.vName;
	}
}

@:structInit class AdjustedExpr {
	public var aExpr:TExpr;
	public var aBlocks:Array<TExpr>;
	public var aNextId:Void->String;
	public var aIsValue:Bool;

	public inline function new(aExpr:TExpr, aBlocks:Array<TExpr>, aNextId:Void->String, aIsValue:Bool) {
		this.aExpr = aExpr;
		this.aBlocks = aBlocks;
		this.aNextId = aNextId;
		this.aIsValue = aIsValue;
	}
}

// port: OCaml's `Exit` raised by collect_assignments in gen_class_constructor and by
// ... print_field/__slots__ in gen_class.
private class GenpyExit extends haxe.Exception {
	public function new() super("Exit");
}

class Transformer {
	static var como:Null<Gctx> = null;
	static var tBool:T = tDynamic;
	static var tVoid:T = tDynamic;
	static var tString:T = tDynamic;
	static var tInt:T = tDynamic;
	static var cReflect:Void->TClass = function() return nullClass;

	// port: `{ e with eexpr = ... }`.
	static inline function withExpr(e:TExpr, d:TExprDef):TExpr return new TExpr(d, e.etype, e.epos);

	public static function init(com:Gctx):Void {
		como = com;
		tBool = com.basic.tbool;
		tVoid = com.basic.tvoid;
		tString = com.basic.tstring;
		tInt = com.basic.tint;
		cReflect = function() return Utils.classOfModuleType(Utils.findType(com, {pack: [], name: "Reflect"}));
	}

	public static function debugExpr(e:TExpr):Void {
		var sType = core.TPrinting.sType.bind(core.TPrinting.printContext());
		var s = core.TPrinting.sExprPretty(false, "    ", false, sType, e);
		Sys.print(s + "\n");
	}

	public static function debugExprWithType(e:TExpr):Void {
		var sType = core.TPrinting.sType.bind(core.TPrinting.printContext());
		var es = core.TPrinting.sExprPretty(false, "    ", false, sType, e);
		var t = sType(e.etype);
		Sys.print(es + " : " + t + "\n");
	}

	public static function debugType(t:T):Void {
		var sType = core.TPrinting.sType.bind(core.TPrinting.printContext());
		var t = sType(t);
		Sys.print(t + "\n");
	}

	static function newCounter():Void->String {
		var n = -1;
		return function() {
			n++;
			return "_hx_local_" + n;
		}
	}

	// port: `blocks @ el`: the lifted blocks (a list built up here) before the
	// ... elements of a block, as the block's Vector.
	static function prependBlocks(blocks:Array<TExpr>, el:Vector<TExpr>):Vector<TExpr> {
		var r = new Vector<TExpr>(blocks.length + el.length);
		for (i in 0...blocks.length) r[i] = blocks[i];
		Vector.blit(el, 0, r, blocks.length, el.length);
		return r;
	}

	static function toExpr(ae:AdjustedExpr):TExpr {
		return switch ae.aBlocks {
			case []:
				ae.aExpr;
			case el:
				switch ae.aExpr.eexpr {
					case TBlock(el2):
						withExpr(ae.aExpr, TBlock(prependBlocks(el, el2)));
					case _:
						withExpr(ae.aExpr, TBlock(prependBlocks(el, vector(ae.aExpr))));
				}
		}
	}

	// port: `lift_expr ?(is_value = false) next_id ?(blocks = []) e`; the optional
	// ... arguments come last.
	static function liftExpr(nextId:Void->String, e:TExpr, isValue:Bool = false, ?blocks:Array<TExpr>):AdjustedExpr {
		return {
			aExpr: e,
			aBlocks: blocks == null ? [] : blocks,
			aNextId: nextId,
			aIsValue: isValue
		};
	}

	static function liftExpr1(isValue:Bool, nextId:Void->String, blocks:Array<TExpr>, e:TExpr):AdjustedExpr return liftExpr(nextId, e, isValue,
		blocks);

	static function allocVar(n:String, t:T, p:Pos):TVar return core.TFunctions.allocVar(VGenerated, n, t, p);

	static function toTvar(n:String, t:T, p:Pos, capture:Bool = false):TVar return allocVar(n, t, p);

	/* { v_name = n; v_type = t; v_id = 0; v_capture = capture; v_extra = None; v_meta = [] } */

	static function createNonLocal(n:String, pos:Pos):TExpr {
		var s = "nonlocal " + KeywordHandler.handleKeywords(n);
		// TODO: this is a hack...
		var id = mk(TLocal(toTvar("python_Syntax._pythonCode", tDynamic, pos)), tVoid, pos);
		var id2 = mk(TLocal(toTvar(s, tDynamic, pos)), tVoid, pos);
		return mk(TCall(id, vector(id2)), tDynamic, pos);
	}

	static function toTlocalExpr(n:String, t:T, p:Pos, capture:Bool = false):TExpr return mk(TLocal(toTvar(n, t, p, capture)), t, p);

	static function checkUnification(e:TExpr, t:T):TExpr {
		switch [follow(e.etype), follow(t)] {
			case [TAnon(an1), TAnon(an2)]:
				core.ds.PMap.iter(function(s, cf) {
					if (!an1.aFields.exists(s)) an1.aFields = core.ds.PMap.add(s, cf, an1.aFields);
				}, an2.aFields);
				return e;
			case _:
				return e;
		}
	}

	static function dynamicFieldRead(e:TExpr, s:String, t:T):TExpr {
		var e = Utils.mkStaticCall2(cReflect(), "field", vector(e, mk(TConst(TString(s)), tString, e.epos)), e.epos);
		return new TExpr(e.eexpr, t, e.epos);
	}

	static function dynamicFieldWrite(e1:TExpr, s:String, e2:TExpr):TExpr {
		return Utils.mkStaticCall2(cReflect(), "setField", vector(e1, mk(TConst(TString(s)), tString, e1.epos), e2), e1.epos);
	}

	static function dynamicFieldReadWrite(nextId:Void->String, e1:TExpr, s:String, op:Binop, e2:TExpr, t:T):TExpr {
		var id = nextId();
		var tempVar = toTvar(id, e1.etype, e1.epos);
		var tempVarDef = mk(TVar(tempVar, e1), e1.etype, e1.epos);
		var tempLocal = mk(TLocal(tempVar), e1.etype, e1.epos);
		var eField = dynamicFieldRead(tempLocal, s, t);
		var eOp = mk(TBinop(op, eField, e2), eField.etype, eField.epos);
		var eSetField = dynamicFieldWrite(tempLocal, s, eOp);
		return mk(TBlock(vector(tempVarDef, eSetField)), eSetField.etype, eSetField.epos);
	}

	static function dynamicFieldIncDec(nextId:Void->String, e1:TExpr, s:String, unop:Unop, unopFlag:UnopFlag, t:T, p:Pos):TExpr {
		var isPostFix = switch unopFlag {
			case Postfix: true;
			case Prefix: false;
		};
		var op = switch unop {
			case Increment: OpAdd;
			case Decrement: OpSub;
			case _: die("", "genpy.ml Transformer.dynamic_field_inc_dec");
		};
		var one = mk(TConst(TInt(1)), t, p);

		var tempVar = toTvar(nextId(), e1.etype, e1.epos);
		var tempVarDef = mk(TVar(tempVar, e1), e1.etype, e1.epos);
		var tempLocal = mk(TLocal(tempVar), e1.etype, e1.epos);

		var eField = dynamicFieldRead(tempLocal, s, t);

		var priorValVar = toTvar(nextId(), t, p);
		var priorValVarDef = mk(TVar(priorValVar, eField), t, p);
		var priorValLocal = mk(TLocal(priorValVar), t, p);

		var eValue = mk(TBinop(op, priorValLocal, one), t, e1.epos);
		var eRet = isPostFix ? priorValLocal : eValue;

		var eSetField = dynamicFieldWrite(tempLocal, s, eValue);
		return mk(TBlock(vector(tempVarDef, priorValVarDef, eSetField, eRet)), eSetField.etype, eSetField.epos);
	}

	static function addNonLocalsToFunc(e:TExpr):TExpr {
		switch e.eexpr {
			case TFunction(tf):
				// port: PMap keyed by v_id, only queried with mem.
				var cur = new haxe.ds.IntMap<TVar>();
				function save():Void->Void {
					var prev = cur;
					return function() cur = prev;
				}
				function declare(v:TVar):Void {
					var next = cur.copy();
					next.set(v.vId, v);
					cur = next;
				}
				for (a in tf.tfArgs) declare(a.variable);
				var nonLocals = new OcamlHashtbl<Int, TVar>(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
				var it:TExpr->Void = null;
				function maybeContinue(e:TExpr):Void {
					switch e.eexpr {
						case TFunction(_):
						case _:
							it(e);
					}
				}
				it = function(e:TExpr):Void {
					switch e.eexpr {
						case TVar(v, e1):
							if (e1 != null) maybeContinue(e1);
							declare(v);
						case TTry(e1, catches):
							it(e1);
							for (c in catches) {
								var restore = save();
								declare(c.variable);
								it(c.expr);
								restore();
							}
						case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, e2):
							if (!cur.exists(v.vId)) nonLocals.add(v.vId, v);
							maybeContinue(e2);
						case TFunction(_):
						case _:
							Texpr.iter(it, e);
					}
				}
				it(tf.tfExpr);
				var el = nonLocals.fold(function(k, v, acc:Array<TExpr>) {
					var x = createNonLocal(v.vName, e.epos);
					return [x].concat(acc);
				}, []);
				var el = [tf.tfExpr].concat(el);
				el.reverse();
				var tf = new TFunc(tf.tfArgs, tf.tfType, withExpr(tf.tfExpr, TBlock(Vector.fromArrayCopy(el))));
				return withExpr(e, TFunction(tf));
			case _:
				return die("", "genpy.ml Transformer.add_non_locals_to_func");
		}
	}

	static function transformFunction(tf:TFunc, ae:AdjustedExpr, isValue:Bool):AdjustedExpr {
		var p = tf.tfExpr.epos;
		var assigns:Array<TExpr> = [];
		for (a in tf.tfArgs) {
			var v = a.variable;
			KeywordHandler.checkVarDeclaration(v);
			var value = a.defaultValue;
			if (value == null || value.eexpr.match(TConst(TNull))) {} else {
				var ct = value;
				var aLocal = mk(TLocal(v), v.vType, p);
				var aNull = mk(TConst(TNull), v.vType, p);
				var aCmp = mk(TBinop(OpEq, aLocal, aNull), tBool, p);
				var aValue = ct;
				var aAssign = mk(TBinop(OpAssign, aLocal, aValue), v.vType, p);
				var aIf = mk(TIf(aCmp, aAssign, null), tVoid, p);
				assigns.unshift(aIf);
			}
		}
		var body = switch assigns {
			case []:
				tf.tfExpr;
			case _:
				var r = Vector.fromArrayCopy(assigns);
				r.reverse();
				var eb = mk(TBlock(r), tDynamic, p);
				concat(eb, tf.tfExpr);
		};
		var e1 = toExpr(transformExpr(ae.aNextId, body));
		var fn = mk(TFunction(new TFunc(tf.tfArgs, tf.tfType, e1)), ae.aExpr.etype, p);
		var fn = addNonLocalsToFunc(fn);
		if (isValue) {
			var newName = ae.aNextId();
			var newVar = allocVar(newName, tf.tfType, p);
			var newLocal = mk(TLocal(newVar), fn.etype, p);
			var def = mk(TVar(newVar, fn), fn.etype, p);
			return liftExpr1(false, ae.aNextId, [def], newLocal);
		} else
			return liftExpr(ae.aNextId, fn);
	}

	static function transformVarExpr(ae:AdjustedExpr, eo:Null<TExpr>, v:TVar):AdjustedExpr {
		KeywordHandler.checkVarDeclaration(v);
		var b:Array<TExpr>, newExpr:Null<TExpr>;
		if (eo == null) {
			b = [];
			newExpr = null;
		} else {
			var f = transformExpr1(true, ae.aNextId, [], eo);
			b = f.aBlocks;
			newExpr = f.aExpr;
		}
		var e = mk(TVar(v, newExpr), ae.aExpr.etype, ae.aExpr.epos);
		return liftExpr(ae.aNextId, e, false, b);
	}

	// port: `transform_expr ?(is_value = false) next_id ?(blocks = []) e`.
	static function transformExpr(nextId:Void->String, e:TExpr, isValue:Bool = false, ?blocks:Array<TExpr>):AdjustedExpr return transform1(liftExpr(nextId,
		e, isValue, blocks));

	static function transformExpr1(isValue:Bool, nextId:Void->String, blocks:Array<TExpr>, e:TExpr):AdjustedExpr return transformExpr(nextId, e,
		isValue, blocks);

	static function transformExprsToBlock(el:Vector<TExpr>, tb:T, isValue:Bool, p:Pos, nextId:Void->String):AdjustedExpr {
		switch el {
			case [e]:
				return transformExpr(nextId, e, isValue);
			case _:
				var size = el.length;
				var res = [];
				for (i in 0...el.length) {
					var e = el[i];
					/* this removes len(x) calls which are reproduced by the inlined return
						of Array.push even if the value is not used */
					function isRemovableStatement(e:TExpr) return (!isValue || i < size - 1) && switch e.eexpr {
						case TField(_, FInstance({clPath: {pack: [], name: "list"}}, _, {cfName: "length"})): true;
						case _: false;
					};
					if (!isRemovableStatement(e)) {
						var ae = transformExpr(nextId, e, isValue);
						for (b in ae.aBlocks) res.push(b);
						res.push(ae.aExpr);
					} else {}
				}
				return liftExpr(nextId, mk(TBlock(Vector.fromArrayCopy(res)), tb, p));
		}
	}

	static function transformSwitch(ae:AdjustedExpr, isValue:Bool, e1:TExpr, cases:Vector<TSwitchCase>, edef:Null<TExpr>):AdjustedExpr {
		var caseFunctions:Array<TExpr> = [];
		function caseToIf(c:TSwitchCase, eelse:Null<TExpr>):TExpr {
			var el = c.casePatterns, e = c.caseExpr;
			var valReversed = el.copy();
			valReversed.reverse();
			function mkEq(e:TExpr) return mk(TBinop(OpEq, e1, e), tBool, Ast.punion(e1.epos, e.epos));
			var cond = switch valReversed {
				case []:
					die("", "genpy.ml Transformer.transform_switch");
				case [e]:
					mkEq(e);
				case _:
					var acc = mkEq(valReversed[0]);
					for (i in 1...valReversed.length) {
						var e = valReversed[i];
						acc = mk(TBinop(OpBoolOr, acc, mkEq(e)), tBool, Ast.punion(acc.epos, e.epos));
					}
					acc;
			};
			var eif = if (isValue) {
				var name = ae.aNextId();
				var func = exprsToFunc([e], name, ae);
				caseFunctions = caseFunctions.concat(func.aBlocks);
				var call = func.aExpr;
				mk(TIf(cond, call, eelse), ae.aExpr.etype, ae.aExpr.epos);
			} else
				mk(TIf(cond, e, eelse), ae.aExpr.etype, e.epos);
			return eif;
		}
		var revCases = cases.copy();
		revCases.reverse();
		var edef:Null<TExpr> = if (edef == null) mk(TBlock(vector()), ae.aExpr.etype, ae.aExpr.epos) else edef;
		var res = switch revCases {
			case []:
				edef;
			case [c]:
				caseToIf(c, edef);
			case _:
				var acc = caseToIf(revCases[0], edef);
				for (i in 1...revCases.length) acc = caseToIf(revCases[i], acc);
				acc;
		};
		var res = if (isValue) {
			var l = [res].concat(caseFunctions);
			l.reverse();
			mk(TBlock(Vector.fromArrayCopy(l)), res.etype, res.epos);
		} else
			res;
		return forwardTransform(res, ae);
	}

	static function utf8Length(s:String):Int {
		var n = 0;
		for (_ in new haxe.iterators.StringIteratorUnicode(s)) n++;
		return n;
	}

	static function transformStringSwitch(ae:AdjustedExpr, isValue:Bool, e1:TExpr, cases:Vector<TSwitchCase>, edef:Null<TExpr>):AdjustedExpr {
		var lengthMap = new OcamlHashtbl<Int, {v:Array<{el:Array<TExpr>, e:TExpr}>}>(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);
		for (c in cases) {
			var e = c.caseExpr;
			for (es in c.casePatterns) {
				switch es.eexpr {
					case TConst(TString(s)):
						var l = utf8Length(s);
						var sl = lengthMap.findOpt(l);
						if (sl == null) {
							sl = {v: []};
							lengthMap.replace(l, sl);
						}
						sl.v = [{el: [es], e: e}].concat(sl.v);
					case _:
				}
			}
		}
		if (lengthMap.length() < 2) return transformSwitch(ae, isValue, e1, cases, edef) else {
			function mkEq(e1:TExpr, e2:TExpr) return mk(TBinop(OpEq, e1, e2), tBool, Ast.punion(e1.epos, e2.epos));
			function mkOr(e1:TExpr, e2:TExpr) return mk(TBinop(OpOr, e1, e2), tBool, Ast.punion(e1.epos, e2.epos));
			function mkIf(ec:{el:Array<TExpr>, e:TExpr}, eo:Null<TExpr>) {
				var el = ec.el, e = ec.e;
				var eif = mkEq(e1, el[0]);
				for (i in 1...el.length) eif = mkOr(eif, mkEq(e1, el[i]));
				return mk(TIf(Builder.mkParent(eif), e, eo), e.etype, e.epos);
			}
			var cases = lengthMap.fold(function(i, el, acc:Array<TSwitchCase>) {
				var eint = mk(TConst(TInt(i)), tInt, e1.epos);
				var eacc:Null<TExpr> = edef;
				for (ec in el.v) eacc = mkIf(ec, eacc);
				var fs = if (eacc != null) eacc else die("", "genpy.ml Transformer.transform_string_switch");
				return [({casePatterns: vector(eint), caseExpr: fs} : TSwitchCase)].concat(acc);
			}, []);
			var cString = switch tString {
				case TInst(c, _): c;
				case _: die("", "genpy.ml Transformer.transform_string_switch");
			};
			var cfLength = core.ds.PMap.find("length", cString.clFields);
			var ef = mk(TField(e1, FInstance(cString, vector(), cfLength)), tInt, e1.epos);
			var resVar = allocVar(ae.aNextId(), ef.etype, ef.epos);
			var resLocal = withExpr(ef, TLocal(resVar));
			var varExpr = withExpr(ef, TVar(resVar, ef));
			var sw = Texpr.mkSwitch(resLocal, Vector.fromArrayCopy(cases), edef, edef != null);
			var e = mk(TBlock(vector(varExpr, mk(TSwitch(sw), ae.aExpr.etype, e1.epos))), ae.aExpr.etype, e1.epos);
			return forwardTransform(e, ae);
		}
	}

	static function transformOpAssignOp(ae:AdjustedExpr, e1:TExpr, op:Binop, one:TExpr, isValue:Bool, post:Bool):AdjustedExpr {
		var e1_ = transformExpr(ae.aNextId, e1, true);
		function handleAsLocal(tempLocal:TExpr):AdjustedExpr {
			var ex = ae.aExpr;
			var resVar = allocVar(ae.aNextId(), ex.etype, ex.epos);
			var resLocal = withExpr(ex, TLocal(resVar));
			var plus = withExpr(ex, TBinop(op, tempLocal, one));
			var varExpr = withExpr(ex, TVar(resVar, tempLocal));
			var assignExpr = withExpr(ex, TBinop(OpAssign, e1_.aExpr, plus));
			var blocks = if (post) [varExpr, assignExpr, resLocal] else [assignExpr, tempLocal];
			// TODO: block is ignored in the else case?
			var block = e1_.aBlocks.concat(blocks);
			if (isValue) {
				var f = exprsToFunc(block, ae.aNextId(), ae);
				return liftExpr(ae.aNextId, f.aExpr, true, f.aBlocks);
			} else {
				var block = e1_.aBlocks.concat([assignExpr]);
				return transformExprsToBlock(Vector.fromArrayCopy(block), ex.etype, false, ex.epos, ae.aNextId);
			}
		}
		switch e1_.aExpr.eexpr {
			case TArray({eexpr: TLocal(_)}, {eexpr: TLocal(_)}) | TField({eexpr: TLocal(_)}, _) | TLocal(_):
				return handleAsLocal(e1_.aExpr);
			case TArray(e1, e2):
				var id = ae.aNextId();
				var tempVarL = allocVar(id, e1.etype, e1.epos);
				var tempLocalL = withExpr(e1, TLocal(tempVarL));
				var tempVarL = withExpr(e1, TVar(tempVarL, e1));

				var id = ae.aNextId();
				var tempVarR = allocVar(id, e2.etype, e2.epos);
				var tempLocalR = withExpr(e2, TLocal(tempVarR));
				var tempVarR = withExpr(e2, TVar(tempVarR, e2));

				var id = ae.aNextId();
				var tempVar = allocVar(id, e1_.aExpr.etype, e1_.aExpr.epos);
				var tempLocal = withExpr(e1_.aExpr, TLocal(tempVar));
				var tempVarExpr = withExpr(e1_.aExpr, TArray(tempLocalL, tempLocalR));
				var tempVar = withExpr(e1_.aExpr, TVar(tempVar, tempVarExpr));

				var plus = withExpr(ae.aExpr, TBinop(op, tempLocal, one));
				var assignExpr = withExpr(ae.aExpr, TBinop(OpAssign, tempVarExpr, plus));
				var block = e1_.aBlocks.concat([tempVarL, tempVarR, tempVar, assignExpr, post ? tempLocal : tempVarExpr]);
				if (isValue) {
					var f = exprsToFunc(block, ae.aNextId(), ae);
					return liftExpr(ae.aNextId, f.aExpr, true, f.aBlocks);
				} else
					return transformExprsToBlock(Vector.fromArrayCopy(block), ae.aExpr.etype, false, ae.aExpr.epos, ae.aNextId);
			case TField(e1, fa):
				var tempVarL = allocVar(ae.aNextId(), e1.etype, e1.epos);
				var tempLocalL = withExpr(e1, TLocal(tempVarL));
				var tempVarL = withExpr(e1, TVar(tempVarL, e1));

				var tempVar = allocVar(ae.aNextId(), e1_.aExpr.etype, e1_.aExpr.epos);
				var tempLocal = withExpr(e1_.aExpr, TLocal(tempVar));
				var tempVarExpr = withExpr(e1_.aExpr, TField(tempLocalL, fa));
				var tempVar = withExpr(e1_.aExpr, TVar(tempVar, tempVarExpr));

				var plus = withExpr(ae.aExpr, TBinop(op, tempLocal, one));
				var assignExpr = withExpr(ae.aExpr, TBinop(OpAssign, tempVarExpr, plus));
				var block = e1_.aBlocks.concat([tempVarL, tempVar, assignExpr, post ? tempLocal : tempVarExpr]);
				if (isValue) {
					var f = exprsToFunc(block, ae.aNextId(), ae);
					return liftExpr(ae.aNextId, f.aExpr, true, f.aBlocks);
				} else
					return transformExprsToBlock(Vector.fromArrayCopy(block), ae.aExpr.etype, false, ae.aExpr.epos, ae.aNextId);
			case _:
				debugExpr(e1_.aExpr);
				return die("", "genpy.ml Transformer.transform_op_assign_op");
		}
	}

	static function varToTreturnExpr(n:String, t:T, p:Pos, capture:Bool = false):TExpr {
		var x = mk(TLocal(toTvar(n, t, p, capture)), t, p);
		return mk(TReturn(x), t, p);
	}

	static function exprsToFunc(exprs:Array<TExpr>, name:String, base:AdjustedExpr):AdjustedExpr {
		function convertReturnExpr(expr:TExpr):Array<TExpr> {
			return switch expr.eexpr {
				case TWhile(_, _, _):
					var ret = withExpr(expr, TReturn(null));
					[expr, ret];
				case TFunction(f):
					var ret = varToTreturnExpr(name, f.tfType, f.tfExpr.epos);
					[expr, ret];
				case TBinop(OpAssign, l, r):
					var r = withExpr(l, TReturn(l));
					[expr, r];
				case x:
					var retExpr = withExpr(expr, TReturn(expr));
					[retExpr];
			}
		}
		// port: `def` is evaluated before the match below, as upstream.
		var def = {
			var ex = switch exprs {
				case []:
					die("", "genpy.ml Transformer.exprs_to_func");
				case [x]:
					var exs = convertReturnExpr(x);
					switch exs {
						case []: die("", "genpy.ml Transformer.exprs_to_func");
						case [x]: x;
						case x:
							var last = x[x.length - 1];
							mk(TBlock(Vector.fromArrayCopy(exs)), last.etype, base.aExpr.epos);
					}
				case x:
					var ret = x[x.length - 1];
					var tail = x.slice(0, x.length - 1);
					var block = tail.concat(convertReturnExpr(ret));
					switch block {
						case []: die("", "genpy.ml Transformer.exprs_to_func");
						case _:
							var last = block[block.length - 1];
							mk(TBlock(Vector.fromArrayCopy(block)), last.etype, base.aExpr.epos);
					}
			};
			var f1 = new TFunc(vector(), TFun({args: vector(), ret: ex.etype}), ex);
			var fexpr = mk(TFunction(f1), ex.etype, ex.epos);
			var fvar = toTvar(name, fexpr.etype, fexpr.epos);
			var f = addNonLocalsToFunc(fexpr);
			var assign = withExpr(ex, TVar(fvar, f));
			var callExpr = mk(TLocal(fvar), fexpr.etype, ex.epos);
			var substitute = mk(TCall(callExpr, vector()), ex.etype, ex.epos);
			liftExpr(base.aNextId, substitute, false, [assign]);
		};
		switch exprs {
			case [x = {eexpr: TFunction(f)}] if (f.tfArgs.length == 0):
				var l = toTlocalExpr(name, f.tfType, f.tfExpr.epos);
				var substitute = mk(TCall(l, vector()), f.tfType, f.tfExpr.epos);
				return liftExpr(base.aNextId, substitute, false, [x]);
			case _:
				return def;
		}
	}

	static function transformCall(isValue:Bool, e:TExpr, params:Vector<TExpr>, ae:AdjustedExpr):AdjustedExpr {
		function trans(isValue:Bool, blocks:Array<TExpr>, e:TExpr) return transformExpr1(isValue, ae.aNextId, blocks, e);
		function trans1(e:TExpr, params:Array<AdjustedExpr>):AdjustedExpr {
			var e = trans(true, [], e);
			var blocks = e.aBlocks.concat([for (p in params) for (b in p.aBlocks) b]);
			var params = params.mapToVector(p -> p.aExpr);
			var e = withExpr(ae.aExpr, TCall(e.aExpr, params));
			return liftExpr(ae.aNextId, e, false, blocks);
		}
		switch [e, params] {
			// the foreach block should not be handled as a value
			case [{eexpr: TField(_, FStatic({clPath: {pack: ["python"], name: "Syntax"}}, {cfName: "_foreach"}))}, [e1, e2, e3]]:
				// port: list literal elements are evaluated right to left.
				var t3 = trans(false, [], e3);
				var t2 = trans(true, [], e2);
				var t1 = trans(true, [], e1);
				return trans1(e, [t1, t2, t3]);
			case [e, params]:
				var tp = [for (p in params) trans(true, [], p)];
				return trans1(e, tp);
		}
	}

	static function isOptionalAnon(cf:TClassField):Bool return Meta.has(Meta.Optional, cf.cfMeta);

	static function transform1(ae:AdjustedExpr):AdjustedExpr {
		function trans(isValue:Bool, blocks:Array<TExpr>, e:TExpr) return transformExpr1(isValue, ae.aNextId, blocks, e);
		function lift(isValue:Bool, blocks:Array<TExpr>, e:TExpr) return liftExpr1(isValue, ae.aNextId, blocks, e);
		var aExpr = ae.aExpr;
		switch [ae.aIsValue, ae.aExpr.eexpr] {
			case [isValue, TBlock([x])]:
				return trans(isValue, [], x);
			case [false, TBlock([])]:
				return liftExpr(ae.aNextId, aExpr);
			case [true, TBlock([])]:
				return liftExpr(ae.aNextId, mk(TConst(TNull), ae.aExpr.etype, ae.aExpr.epos));
			case [false, TBlock(el)]:
				return transformExprsToBlock(el, ae.aExpr.etype, false, ae.aExpr.epos, ae.aNextId);
			case [true, TBlock(el)]:
				var name = ae.aNextId();
				var block:Vector<TExpr>, tr:T;
				switch el.length {
					case 0:
						return die("", "genpy.ml Transformer.transform1");
					case _:
						var e = el[el.length - 1];
						block = el.copy();
						block[block.length - 1] = mk(TReturn(e), tDynamic, e.epos);
						tr = e.etype;
				}
				var myBlock = transformExprsToBlock(block, tr, false, ae.aExpr.epos, ae.aNextId);
				var fn = mk(TFunction(new TFunc(vector(), tr, myBlock.aExpr)), ae.aExpr.etype, ae.aExpr.epos);
				var tVar = allocVar(name, ae.aExpr.etype, ae.aExpr.epos);
				var f = addNonLocalsToFunc(fn);
				var fnAssign = mk(TVar(tVar, f), ae.aExpr.etype, ae.aExpr.epos);
				var ev = mk(TLocal(tVar), ae.aExpr.etype, ae.aExpr.epos);
				var substitute = mk(TCall(ev, vector()), ae.aExpr.etype, ae.aExpr.epos);
				return liftExpr(ae.aNextId, substitute, false, [fnAssign]);
			case [isValue, TFunction(f)]:
				return transformFunction(f, ae, isValue);
			case [_, TVar(v, null)]:
				return transformVarExpr(ae, null, v);
			case [false, TVar(v, e1)] if (switch e1.eexpr {
					case TUnop(Increment | Decrement, _, {eexpr: TLocal(_) | TField({eexpr: TConst(TThis)}, _)}): true;
					case _: false;
				}):
				switch e1.eexpr {
					case TUnop(unop, postFixFlag, ve):
						var one = withExpr(e1, TConst(TInt(1)));
						var op = if (unop == Increment) OpAdd else OpSub;
						var inc = withExpr(e1, TBinop(op, ve, one));
						var incAssign = withExpr(e1, TBinop(OpAssign, ve, inc));
						var varAssign = withExpr(e1, TVar(v, ve));
						if (postFixFlag == Postfix)
							return lift(true, [varAssign], incAssign);
						else
							return lift(true, [incAssign], varAssign);
					case _:
						return die("", "genpy.ml Transformer.transform1");
				}
			case [_, TVar(v, eo)]:
				return transformVarExpr(ae, eo, v);
			case [_, TReturn(null)]:
				return ae;
			case [_, TReturn(ef = {eexpr: TFunction(f)})]:
				var n = ae.aNextId();
				var e1 = toExpr(trans(false, [], f.tfExpr));
				var f = mk(TFunction(new TFunc(f.tfArgs, f.tfType, e1)), ef.etype, ef.epos);
				var f1 = addNonLocalsToFunc(f);
				var varN = allocVar(n, ef.etype, ef.epos);
				var f1Assign = mk(TVar(varN, f1), tVoid, f1.epos);
				var varLocal = mk(TLocal(varN), ef.etype, f1.epos);
				var er = mk(TReturn(varLocal), tDynamic, ae.aExpr.epos);
				return lift(true, [f1Assign], er);
			case [_, TReturn(x)]:
				var x1 = trans(true, [], x);
				switch x1.aBlocks {
					case []:
						return lift(true, [], withExpr(ae.aExpr, TReturn(x1.aExpr)));
					case blocks:
						var f = exprsToFunc(blocks.concat([x1.aExpr]), ae.aNextId(), ae);
						return lift(true, f.aBlocks, withExpr(aExpr, TReturn(f.aExpr)));
				}
			case [_, TParenthesis(e1)]:
				var e1 = trans(true, [], e1);
				var p = withExpr(ae.aExpr, TParenthesis(e1.aExpr));
				return lift(true, e1.aBlocks, p);
			case [_, TEnumParameter(e1, ef, i)]:
				var e1 = trans(true, [], e1);
				var p = withExpr(ae.aExpr, TEnumParameter(e1.aExpr, ef, i));
				return lift(true, e1.aBlocks, p);
			case [_, TEnumIndex(e1)]:
				var e1 = trans(true, [], e1);
				var p = withExpr(ae.aExpr, TEnumIndex(e1.aExpr));
				return lift(true, e1.aBlocks, p);
			case [true, TIf(econd, eif, eelse)]:
				var econd1 = trans(true, [], econd);
				var eif1 = trans(true, [], eif);
				var eelse1 = if (eelse != null) trans(true, [], eelse) else null;
				var blocks:Array<TExpr> = [];
				var eif2:TExpr;
				switch eif1.aBlocks {
					case []:
						eif2 = eif1.aExpr;
					case x:
						// port: `regular` is evaluated before the match, as upstream.
						var fname = eif1.aNextId();
						var f = exprsToFunc(eif1.aBlocks.concat([eif1.aExpr]), fname, ae);
						var regularE = f.aExpr, regularB = blocks.concat(f.aBlocks);
						switch eif1.aBlocks {
							case [b = {eexpr: TVar(_, fe)}] if (fe != null && fe.eexpr.match(TFunction(_))):
								eif2 = eif1.aExpr;
								blocks = blocks.concat([b]);
							case _:
								eif2 = regularE;
								blocks = regularB;
						}
				}
				var eelse2:Null<TExpr>;
				if (eelse1 == null) {
					eelse2 = null;
				} else if (eelse1.aBlocks.length == 0) {
					eelse2 = eelse1.aExpr;
				} else {
					var b = eelse1.aBlocks;
					// port: `regular` is evaluated before the match, as upstream.
					var fname = eelse1.aNextId();
					var f = exprsToFunc(eelse1.aBlocks.concat([eelse1.aExpr]), fname, ae);
					var regularE = f.aExpr, regularB = blocks.concat(f.aBlocks);
					switch b {
						case [b = {eexpr: TVar(_, fe)}] if (fe != null && fe.eexpr.match(TFunction(_))):
							eelse2 = eelse1.aExpr;
							blocks = blocks.concat([b]);
						case _:
							eelse2 = regularE;
							blocks = regularB;
					}
				}
				var blocks = econd1.aBlocks.concat(blocks);
				var newIf = withExpr(ae.aExpr, TIf(econd1.aExpr, eif2, eelse2));
				switch blocks {
					case []:
						var meta:MetadataEntry = {meta: core.MetaList.StrictMeta.Custom(":ternaryIf"), exprs: vector(), pos: ae.aExpr.epos};
						var ternary = withExpr(ae.aExpr, TMeta(meta, newIf));
						return liftExpr(ae.aNextId, ternary, false, blocks);
					case b:
						var f = exprsToFunc(blocks.concat([newIf]), ae.aNextId(), ae);
						return liftExpr(ae.aNextId, f.aExpr, false, f.aBlocks);
				}
			case [false, TIf(econd, eif, eelse)]:
				var econd = trans(true, [], econd);
				var eif = toExpr(trans(false, [], eif));
				var eelse = if (eelse != null) toExpr(trans(false, [], eelse)) else null;
				var newIf = withExpr(ae.aExpr, TIf(econd.aExpr, eif, eelse));
				return lift(false, econd.aBlocks, newIf);
			case [false, TWhile(econd, e1, NormalWhile)]:
				var econd1 = trans(true, [], econd);
				var e11 = toExpr(trans(false, [], e1));
				var newWhile = mk(TWhile(econd1.aExpr, e11, NormalWhile), aExpr.etype, aExpr.epos);
				return lift(false, econd1.aBlocks, newWhile);
			case [true, TWhile(econd, ebody, NormalWhile)]:
				var econd = trans(true, [], econd);
				var ebody = toExpr(trans(false, [], ebody));
				var ewhile = withExpr(ae.aExpr, TWhile(econd.aExpr, ebody, NormalWhile));
				var eval = withExpr(ae.aExpr, TConst(TNull));
				var f = exprsToFunc(econd.aBlocks.concat([ewhile, eval]), ae.aNextId(), ae);
				return lift(true, f.aBlocks, f.aExpr);
			case [false, TWhile(econd, ebody, DoWhile)]:
				var notExpr = withExpr(econd, TUnop(Not, Prefix, econd));
				var breakExpr = mk(TBreak, tVoid, econd.epos);
				var ifExpr = mk(TIf(notExpr, breakExpr, null), tVoid, econd.epos);
				var newE = switch ebody.eexpr {
					case TBlock(exprs): withExpr(econd, TBlock(exprs.snoc(ifExpr)));
					case _: withExpr(econd, TBlock(vector(ebody, ifExpr)));
				};
				var trueExpr = mk(TConst(TBool(true)), econd.etype, ae.aExpr.epos);
				var newExpr = withExpr(ae.aExpr, TWhile(trueExpr, newE, NormalWhile));
				return forwardTransform(newExpr, ae);
			case [isValue, TSwitch(sw)]:
				var e = sw.switchSubject, cases = sw.switchCases, edef = sw.switchDefault;
				switch follow(e.etype) {
					case TInst({clPath: {pack: [], name: "str"}}, _):
						return transformStringSwitch(ae, isValue, e, cases, edef);
					case _:
						return transformSwitch(ae, isValue, e, cases, edef);
				}
			// anon field access on optional params
			case [isValue, TField(e, FAnon(cf))] if (isOptionalAnon(cf)):
				var e = dynamicFieldRead(e, cf.cfName, ae.aExpr.etype);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TBinop(OpAssign, {eexpr: TField(e1, FAnon(cf))}, e2)] if (isOptionalAnon(cf)):
				var e = dynamicFieldWrite(e1, cf.cfName, e2);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TBinop(OpAssignOp(op), {eexpr: TField(e1, FAnon(cf)), etype: t}, e2)] if (isOptionalAnon(cf)):
				var e = dynamicFieldReadWrite(ae.aNextId, e1, cf.cfName, op, e2, t);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TUnop(unop, unopFlag, {eexpr: TField(e1, FAnon(cf)), etype: t, epos: p})] if (unop.match(Increment | Decrement) && isOptionalAnon(cf)):
				var e = dynamicFieldIncDec(ae.aNextId, e1, cf.cfName, unop, unopFlag, t, p);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TUnop(unop, unopFlag, {eexpr: TField(e1, FDynamic(fieldName)), etype: t, epos: p})] if (unop.match(Increment | Decrement)):
				var e = dynamicFieldIncDec(ae.aNextId, e1, fieldName, unop, unopFlag, t, p);
				return transformExpr(ae.aNextId, e, isValue);
			/*
				anon field access with non optional members like iterator, length, split must be handled too, we need to Reflect on them too when it's a runtime method
			*/
			case [isValue, TUnop(unop, op, e)] if (unop.match(Increment | Decrement)):
				var one = withExpr(ae.aExpr, TConst(TInt(1)));
				var isPostfix = switch op {
					case Postfix: true;
					case Prefix: false;
				};
				var op = switch unop {
					case Increment: OpAdd;
					case Decrement: OpSub;
					case _: die("", "genpy.ml Transformer.transform1");
				};
				return transformOpAssignOp(ae, e, op, one, isValue, isPostfix);
			case [_, TUnop(op, Prefix, e)]:
				var e1 = trans(true, [], e);
				var r = withExpr(aExpr, TUnop(op, Prefix, e1.aExpr));
				return liftExpr(ae.aNextId, r, false, e1.aBlocks);

			case [isValue, TField(e, FDynamic(s))]:
				var e = dynamicFieldRead(e, s, ae.aExpr.etype);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TBinop(OpAssign, {eexpr: TField(e1, FDynamic(s))}, e2)]:
				var e = dynamicFieldWrite(e1, s, e2);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TBinop(OpAssignOp(op), {eexpr: TField(e1, FDynamic(s)), etype: t}, e2)]:
				var e = dynamicFieldReadWrite(ae.aNextId, e1, s, op, e2, t);
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TBinop(OpAssign, left, right)]:
				var left = trans(true, [], left);
				var right = trans(true, [], right);
				var r = withExpr(aExpr, TBinop(OpAssign, left.aExpr, right.aExpr));
				if (isValue) {
					var blocks = left.aBlocks.concat(right.aBlocks).concat([r]);
					var f = exprsToFunc(blocks, ae.aNextId(), ae);
					return lift(true, f.aBlocks, f.aExpr);
				} else
					return lift(false, left.aBlocks.concat(right.aBlocks), r);
			case [isValue, TBinop(OpAssignOp(x), left, right)]:
				var right = trans(true, [], right);
				var v = right.aExpr;
				var res = transformOpAssignOp(ae, left, x, v, isValue, false);
				return lift(true, right.aBlocks.concat(res.aBlocks), res.aExpr);
			case [_, TBinop(op, left, right)]:
				var left = trans(true, [], left);
				var right = trans(true, [], right);
				var r = withExpr(aExpr, TBinop(op, left.aExpr, right.aExpr));
				return lift(false, left.aBlocks.concat(right.aBlocks), r);

			case [true, TThrow(x)]:
				var block = TBlock(vector(aExpr, withExpr(aExpr, TConst(TNull))));
				var r = withExpr(aExpr, block);
				return forwardTransform(r, ae);
			case [false, TThrow(x)]:
				var x = trans(true, [], x);
				var r = withExpr(aExpr, TThrow(x.aExpr));
				return lift(false, x.aBlocks, r);
			case [_, TNew(c, tp, params)]:
				var params = [for (p in params) trans(true, [], p)];
				var blocks = [for (p in params) for (b in p.aBlocks) b];
				var params = params.mapToVector(p -> p.aExpr);
				var e = withExpr(aExpr, TNew(c, tp, params));
				return lift(false, blocks, e);
			case [isValue, TCall(e, params)]:
				return transformCall(isValue, e, params, ae);
			case [_, TArray(e1, e2)]:
				var e1 = trans(true, [], e1);
				var e2 = trans(true, [], e2);
				var r = withExpr(aExpr, TArray(e1.aExpr, e2.aExpr));
				var blocks = e1.aBlocks.concat(e2.aBlocks);
				return liftExpr(ae.aNextId, r, false, blocks);
			case [false, TTry(etry, catches)]:
				var etry = trans(false, [], etry);
				var catches = [
					for (c in catches) {
						KeywordHandler.checkVarDeclaration(c.variable);
						{v: c.variable, e: trans(false, [], c.expr)};
					}
				];
				var blocks = [for (c in catches) for (b in c.e.aBlocks) b];
				var catches = catches.mapToVector(c -> {variable: c.v, expr: c.e.aExpr});
				var r = withExpr(aExpr, TTry(etry.aExpr, catches));
				var blocks = etry.aBlocks.concat(blocks);
				return lift(false, blocks, r);
			case [true, TTry(etry, catches)]:
				var id = ae.aNextId();
				var tempVar = toTvar(id, aExpr.etype, aExpr.epos);
				var tempVarDef = withExpr(aExpr, TVar(tempVar, null));
				var tempLocal = withExpr(aExpr, TLocal(tempVar));
				function mkTempAssign(right:TExpr) return withExpr(aExpr, TBinop(OpAssign, tempLocal, right));
				var etry = mkTempAssign(etry);
				var catches = catches.map(c -> {
					KeywordHandler.checkVarDeclaration(c.variable);
					{variable: c.variable, expr: mkTempAssign(c.expr)};
				});
				var newTry = withExpr(aExpr, TTry(etry, catches));
				var block = vector(tempVarDef, newTry, tempLocal);
				var newBlock = withExpr(aExpr, TBlock(block));
				return forwardTransform(newBlock, ae);
			case [_, TObjectDecl(fields)]:
				var fields = [for (f in fields) {key: f.key, ex: trans(true, [], f.expr)}];
				var blocks = [for (f in fields) for (b in f.ex.aBlocks) b];
				var fields = fields.mapToVector(f -> {key: f.key, expr: f.ex.aExpr});
				var r = withExpr(aExpr, TObjectDecl(fields));
				return liftExpr(ae.aNextId, r, false, blocks);
			case [_, TArrayDecl(values)]:
				var values = [for (v in values) trans(true, [], v)];
				var blocks = [for (v in values) for (b in v.aBlocks) b];
				var exprs = values.mapToVector(v -> v.aExpr);
				var r = withExpr(aExpr, TArrayDecl(exprs));
				return liftExpr(ae.aNextId, r, false, blocks);
			case [isValue, TCast(e1, mt)] if (mt != null):
				var com = if (como != null) como else die("", "genpy.ml Transformer.transform1");
				var e = codegen.Codegen.defaultCast(com.basic, com.std, e1, mt, ae.aExpr.etype, ae.aExpr.epos, ae.aNextId());
				return transformExpr(ae.aNextId, e, isValue);
			case [isValue, TCast(e, _)]:
				var e = trans(isValue, [], e);
				var r = withExpr(aExpr, TCast(e.aExpr, null));
				return liftExpr(ae.aNextId, r, false, e.aBlocks);
			case [_, TField(e, f)]:
				var e = trans(true, [], e);
				var r = withExpr(aExpr, TField(e.aExpr, f));
				return liftExpr(ae.aNextId, r, false, e.aBlocks);
			case [isValue, TMeta(m, e)]:
				var e = trans(isValue, [], e);
				var r = new TExpr(TMeta(m, e.aExpr), e.aExpr.etype, aExpr.epos);
				return liftExpr(ae.aNextId, r, false, e.aBlocks);
			case [_, TLocal(_)]:
				return liftExpr(ae.aNextId, aExpr);

			case [_, TConst(_)]:
				return liftExpr(ae.aNextId, aExpr);
			case [_, TTypeExpr(_)]:
				return liftExpr(ae.aNextId, aExpr);
			case [_, TUnop(_)]:
				return die("", "genpy.ml Transformer.transform1");
			case [true, TWhile(econd, ebody, DoWhile)]:
				var newExpr = trans(false, [], aExpr);
				var f = exprsToFunc(newExpr.aBlocks.concat([newExpr.aExpr]), ae.aNextId(), ae);
				return liftExpr(ae.aNextId, f.aExpr, true, f.aBlocks);

			case [_, TBreak] | [_, TContinue] | [_, TIdent(_)]:
				return liftExpr(ae.aNextId, aExpr);
		}
	}

	public static function transform(e:TExpr):TExpr return toExpr(transform1(liftExpr(newCounter(), e)));

	static function forwardTransform(e:TExpr, base:AdjustedExpr):AdjustedExpr return transform1(liftExpr1(base.aIsValue, base.aNextId, base.aBlocks,
		e));

	public static function transformToValue(e:TExpr):TExpr return toExpr(transform1(liftExpr(newCounter(), e, true)));
}

class PrintContext {
	public final pcIndent:String;
	public final pcNextAnonFunc:Void->String;
	public final pcDebug:Bool;
	public final pcCom:Gctx;

	public function new(pcIndent:String, pcNextAnonFunc:Void->String, pcDebug:Bool, pcCom:Gctx) {
		this.pcIndent = pcIndent;
		this.pcNextAnonFunc = pcNextAnonFunc;
		this.pcDebug = pcDebug;
		this.pcCom = pcCom;
	}

	// port: `{pctx with pc_indent = ...}`.
	public function withIndent(indent:String):PrintContext return new PrintContext(indent, pcNextAnonFunc, pcDebug, pcCom);
}

class Printer {
	public static function hasFeature(pctx:PrintContext, f:String):Bool return Gctx.hasFeature(pctx.pcCom, f);

	public static function addFeature(pctx:PrintContext, f:String):Void Gctx.addFeature(pctx.pcCom, f);

	// port: the `n` counter shared by every context created by create_context.
	static var anonFuncCounter = -1;

	public static function createContext(indent:String, com:Gctx, debug:Bool):PrintContext {
		return new PrintContext(indent, function() {
			anonFuncCounter++;
			return "anon_" + anonFuncCounter;
		}, debug, com);
	}

	static var tabs = "";

	static function opt<A>(o:Null<A>, f:A->String, s:String):String return o == null ? "" : s + f(o);

	// TODO: both of these are crazy

	static function isType(p:String, t:String):ModuleType->Bool {
		return function(r) {
			var x = tInfos(r);
			return x.mtPath.pack.join(".") == p && x.mtPath.name == t;
		}
	}

	static function isType1(p:String, s:String):T->Bool {
		return function(t) return switch follow(t) {
			case TInst(c, _): isType(p, s)(TClassDecl(c));
			case TAbstract(a, _): isType(p, s)(TAbstractDecl(a));
			case TEnum(en, _): isType(p, s)(TEnumDecl(en));
			case _: false;
		}
	}

	static function isUnderlyingString(t:T):Bool return switch follow(t) {
		case TAbstract(a, tl): isType1("", "str")(core.Abstract.getUnderlyingType(a, tl));
		case _: false;
	};

	static function isUnderlyingArray(t:T):Bool return switch follow(t) {
		case TAbstract(a, tl): isType1("", "list")(core.Abstract.getUnderlyingType(a, tl));
		case _: false;
	};

	static function isAnonOrDynamic(t:T):Bool return switch follow(t) {
		case TAbstract(a, tl):
			isAnonOrDynamic(core.Abstract.getUnderlyingType(a, tl));
		case TAnon(_) | TDynamic(_): true;
		case _: false;
	};

	public static function handleKeywords(s:String):String return KeywordHandler.handleKeywords(s);

	static function printUnop(op:Unop):String return switch op {
		case Increment | Decrement: die("", "genpy.ml Printer.print_unop");
		case Not: "not ";
		case Neg: "-";
		case NegBits: "~";
		case Spread: "*";
	};

	static function printBinop(op:Binop):String return switch op {
		case OpAdd: "+";
		case OpSub: "-";
		case OpMult: "*";
		case OpDiv: "/";
		case OpAssign: "=";
		case OpEq: "==";
		case OpNotEq: "!=";
		case OpGt: ">";
		case OpGte: ">=";
		case OpLt: "<";
		case OpLte: "<=";
		case OpAnd: "&";
		case OpOr: "|";
		case OpXor: "^";
		case OpBoolAnd: "and";
		case OpBoolOr: "or";
		case OpShl: "<<";
		case OpShr: ">>";
		case OpUShr: ">>";
		case OpMod: "%";
		case OpInterval | OpArrow | OpIn | OpNullCoal | OpAssignOp(_): die("", "genpy.ml Printer.print_binop");
	};

	static function printString(s:String):String return "\"" + core.StringHelper.sEscape(s) + "\"";

	static function printConstant(c:TConstant):String return switch c {
		case TThis: "self";
		case TNull: "None";
		case TBool(true): "True";
		case TBool(false): "False";
		case TString(s): printString(s);
		case TInt(i): Std.string(i);
		case TFloat(s): s;
		case TSuper: "super";
	};

	public static function printBaseType(tp:TInfos):String {
		var native = Meta.getOpt(Meta.Native, tp.mtMeta);
		if (native != null) switch native.exprs {
			case [{expr: EConst(String(s, _))}]: return s;
			case _:
		}
		var pack = tp.mtPath.pack, name = tp.mtPath.name;
		return pack.join("_") + (pack.length == 0 ? name : "_" + name);
	}

	static function printModuleType(mt:ModuleType):String return printBaseType(tInfos(mt));

	static function printMetadata(m:MetadataEntry):String return "@" + Meta.toString(m.meta);

	static function isTernaryIf(m:MetadataEntry):Bool return Meta.metaEq(core.MetaList.StrictMeta.Custom(":ternaryIf"), m.meta);

	static function removeOuterParens(e:TExpr):TExpr return switch e.eexpr {
		case TParenthesis(e): removeOuterParens(e);
		case TMeta(m, _) if (isTernaryIf(m)): e;
		case TMeta(_, e): removeOuterParens(e);
		case _: e;
	};

	static function printArgs(pctx:PrintContext, args:Vector<{variable:TVar, defaultValue:Null<TExpr>}>, p:Pos):String {
		var hadValue = false;
		var hadVarArgs = false;
		var hadKwArgs = false;
		var sl = [
			for (a in args) {
				var v = a.variable, cto = a.defaultValue;
				function checkErr() if (hadVarArgs || hadKwArgs) abort("Arguments after KwArgs/VarArgs are not allowed", p);
				var name = handleKeywords(v.vName);
				switch follow(v.vType) {
					case TAbstract({aPath: {pack: ["python"], name: "KwArgs"}}, _):
						if (hadKwArgs) abort("Arguments after KwArgs are not allowed", p);
						hadKwArgs = true;
						"**" + name;
					case TAbstract({aPath: {pack: ["python"], name: "VarArgs"} | {pack: ["haxe"], name: "Rest"}}, _):
						checkErr();
						hadVarArgs = true;
						"*" + name;
					case _:
						checkErr();
						name + if (cto == null) {
							if (hadValue) " = None" else "";
						} else {
							hadValue = true;
							" = None";
						}
				}
			}
		];
		return sl.join(",");
	}

	static function printOpAssignRight(pctx:PrintContext, e:TExpr):String {
		switch e.eexpr {
			case TIf({eexpr: TParenthesis(econd)}, eif, eelse) | TIf(econd, eif, eelse) if (eelse != null):
				var s3 = printExpr(pctx, eelse);
				var s2 = printExpr(pctx, econd);
				var s1 = printExpr(pctx, eif);
				return s1 + " if " + s2 + " else " + s3;
			case _:
				return printExpr(pctx, removeOuterParens(e));
		}
	}

	static function printVar(pctx:PrintContext, v:TVar, eo:Null<TExpr>):String {
		if (eo != null) switch eo.eexpr {
			case TFunction(tf):
				return printFunction(pctx, tf, v.vName, eo.epos);
			case _:
		}
		var sInit = eo == null ? "None" : printOpAssignRight(pctx, eo);
		return handleKeywords(v.vName) + " = " + sInit;
	}

	public static function printFunction(pctx:PrintContext, tf:TFunc, name:Null<String>, p:Pos):String {
		var sName = name == null ? pctx.pcNextAnonFunc() : handleKeywords(name);
		var sArgs = printArgs(pctx, tf.tfArgs, p);
		var sExpr = printExpr(pctx.withIndent("    " + pctx.pcIndent), tf.tfExpr);
		return "def " + sName + "(" + sArgs + "):\n" + pctx.pcIndent + "    " + sExpr;
	}

	static function printTarrayList(pctx:PrintContext, e1:TExpr, e2:TExpr):String {
		var s1 = printExpr(pctx, e1);
		var s2 = printExpr(pctx, e2);
		var def = "python_internal_ArrayImpl._get(" + s1 + ", " + s2 + ")";

		var handleIndex = switch e2.eexpr {
			case TConst(TInt(index)):
				if (index >= 0) "(" + s1 + "[" + s2 + "] if " + s2 + " < len(" + s1 + ") else None)" else "None";
			case TLocal(_):
				"(" + s1 + "[" + s2 + "] if " + s2 + " >= 0 and " + s2 + " < len(" + s1 + ") else None)";
			case _:
				def;
		};
		return switch e1.eexpr {
			case TLocal(_): handleIndex;
			case TField({eexpr: TConst(TThis) | TLocal(_)}, _): handleIndex;
			case _: def;
		};
	}

	static function isSafeString(pctx:PrintContext, x:TExpr):Bool {
		function followParens(e:TExpr) return switch e.eexpr {
			case TParenthesis(e): e;
			case _: e;
		};
		return switch followParens(x).eexpr {
			case TBinop(OpAdd, e1, e2): isSafeString(pctx, e1) && isSafeString(pctx, e2);
			case TCall(e1, _):
				var id = printExpr(pctx, followParens(e1));
				switch id {
					case "Std.string": true;
					case _: false;
				}
			case TConst(TString(s)): true;
			case _: false;
		};
	}

	static function isTInt(t:T):Bool return switch t {
		case TAbstract({aPath: {pack: [], name: "Int"}}, _): true;
		case _: false;
	};

	public static function printExpr(pctx:PrintContext, e:TExpr):String {
		var indent = pctx.pcIndent;
		function printExprIndented(e:TExpr) return printExpr(pctx.withIndent("    " + pctx.pcIndent), e);
		switch e.eexpr {
			case TConst(ct):
				return printConstant(ct);
			case TTypeExpr(mt):
				return printModuleType(mt);
			case TLocal(v) | TParenthesis({eexpr: TLocal(v)}):
				return handleKeywords(v.vName);
			case TEnumParameter(e1, _, index):
				return printExpr(pctx, e1) + ".params[" + index + "]";
			case TEnumIndex(e1):
				return printExpr(pctx, e1) + ".index";
			case TArray(e1, e2) if (isType1("", "list")(e1.etype) || isUnderlyingArray(e1.etype)):
				return printTarrayList(pctx, e1, e2);
			case TArray(e1, e2) if (isAnonOrDynamic(e1.etype)):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "HxOverrides.arrayGet(" + s1 + ", " + s2 + ")";
			case TArray(e1, e2):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return s1 + "[" + s2 + "]";
			case TBinop(OpAssign, {eexpr: TArray(e1, e2)}, e3) if (isType1("", "list")(e1.etype) || isUnderlyingArray(e1.etype)):
				var s3 = printExpr(pctx, e3);
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "python_internal_ArrayImpl._set(" + s1 + ", " + s2 + ", " + s3 + ")";
			case TBinop(OpAssign, {eexpr: TArray(e1, e2)}, e3) if (isAnonOrDynamic(e1.etype)):
				var s3 = printExpr(pctx, e3);
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "HxOverrides.arraySet(" + s1 + "," + s2 + "," + s3 + ")";
			case TBinop(OpAssign, {eexpr: TArray(e1, e2)}, e3):
				var s3 = printExpr(pctx, removeOuterParens(e3));
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return s1 + "[" + s2 + "] = " + s3;
			case TBinop(OpAssign, {eexpr: TField(ef1, fa)}, e2):
				var s2 = printOpAssignRight(pctx, e2);
				var s1 = printField(pctx, ef1, fa, true);
				return s1 + " = " + s2;
			case TBinop(OpAssign, e1, e2):
				var s2 = printExpr(pctx, removeOuterParens(e2));
				var s1 = printExpr(pctx, e1);
				return s1 + " = " + s2;
			case TBinop(op, e1, e2 = {eexpr: TBinop(_, _, _)}):
				return printExpr(pctx, withExpr(e, TBinop(op, e1, withExpr(e2, TParenthesis(e2)))));
			case TBinop(OpEq, {eexpr: TCall({eexpr: TIdent("__typeof__")}, [e1])}, e2):
				switch e2.eexpr {
					case TConst(TString(s)):
						switch s {
							case "string": return "Std._hx_is(" + printExpr(pctx, e1) + ", str)";
							case "boolean": return "Std._hx_is(" + printExpr(pctx, e1) + ", bool)";
							case "number": return "Std._hx_is(" + printExpr(pctx, e1) + ", float)";
							case _: return die("", "genpy.ml Printer.print_expr");
						}
					case _:
						return die("", "genpy.ml Printer.print_expr");
				}
			case TBinop(OpEq, e1, e2 = {eexpr: TConst(TNull)}):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "(" + s1 + " is " + s2 + ")";
			case TBinop(OpNotEq, e1, e2 = {eexpr: TConst(TNull)}):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "(" + s1 + " is not " + s2 + ")";
			case TBinop(op, e1, e2) if (op.match(OpEq | OpNotEq)):
				var ops = switch op {
					case OpEq: {fst: "is", snd: "==", third: "HxOverrides.eq"};
					case OpNotEq: {fst: "is not", snd: "!=", third: "not HxOverrides.eq"};
					case _: die("", "genpy.ml Printer.print_expr");
				};
				function isListOrAnon(x:T) return switch x {
					case TInst({clPath: {pack: [], name: "list"}}, _): true;
					case TAnon(_): true;
					case _: false;
				};
				function isConstByte(x:TExpr) return switch x.eexpr {
					case TConst(TInt(x)): x >= 0 && x <= 256;
					case _: false;
				};
				function infix(o:String) {
					var s2 = printExpr(pctx, e2);
					var s1 = printExpr(pctx, e1);
					return "(" + s1 + " " + o + " " + s2 + ")";
				}
				function call(o:String) {
					var s2 = printExpr(pctx, e2);
					var s1 = printExpr(pctx, e1);
					return o + "(" + s1 + "," + s2 + ")";
				}
				var t1 = follow(e1.etype), t2 = follow(e2.etype);
				return switch [t1, t2] {
					case [TAbstract({aPath: {pack: [], name: "Int"}}, _), TAbstract({aPath: {pack: [], name: "Int"}}, _)] if (isConstByte(e2)
						|| isConstByte(e1)):
						infix(ops.snd);
					/* the following optimization causes a problem with polygonal unit tests
						see: https://github.com/HaxeFoundation/haxe/issues/2952
					*/
					/* Printf.sprintf "(%s %s %s)" (print_expr pctx e1) (fst ops) (print_expr pctx e2) */
					case [TInst({clPath: {pack: [], name: "list"}}, _), _]:
						infix(ops.fst);
					case [x, _] if (isUnderlyingArray(x)):
						infix(ops.fst);
					case [TInst({clKind: KTypeParameter(_)}, _), _]:
						call(ops.third);
					case [_, TInst({clKind: KTypeParameter(_)}, _)]:
						call(ops.third);
					case [TDynamic(_), TDynamic(_)]:
						call(ops.third);
					case [TDynamic(_), x] if (isListOrAnon(x)):
						call(ops.third);
					case [x, TDynamic(_)] if (isListOrAnon(x)):
						call(ops.third);
					case [_, _]:
						infix(ops.snd);
				};
			case TBinop(OpMod, e1, e2) if (isType1("", "Int")(e1.etype) && isType1("", "Int")(e2.etype)):
				switch [e1.eexpr, e2.eexpr] {
					case [TConst(TInt(x1)), TConst(TInt(x2))] if (x1 >= 0 && x2 >= 0):
						// constant optimization
						var s2 = printExpr(pctx, e2);
						var s1 = printExpr(pctx, e1);
						return s1 + " % " + s2;
					case _:
						var s2 = printExpr(pctx, e2);
						var s1 = printExpr(pctx, e1);
						return "HxOverrides.mod(" + s1 + ", " + s2 + ")";
				}
			case TBinop(OpMod, e1, e2):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "HxOverrides.modf(" + s1 + ", " + s2 + ")";
			case TBinop(OpUShr, e1, e2):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "HxOverrides.rshift(" + s1 + ", " + s2 + ")";
			case TBinop(OpAdd, e1, e2) if (isType1("", "str")(e.etype) || isUnderlyingString(e.etype)):
				function safeString(ex:TExpr):String {
					if (isSafeString(pctx, ex)) return printExpr(pctx, ex);
					switch [ex.eexpr, ex.etype] {
						case [TBinop(OpAdd, e1, e2), x] if (isType1("", "str")(x)):
							var s2 = safeString(e2);
							var s1 = safeString(e1);
							return "(" + s1 + " + " + s2 + ")";
						case [TLocal(_), x] if (isType1("", "str")(x)):
							/*
								we could add this pattern too, but is it sideeffect free??
								| TField({ eexpr = TLocal(_)},_)
							*/
							var s = printExpr(pctx, ex);
							return "(\"null\" if " + s + " is None else " + s + ")";
						case [_, x] if (isType1("", "str")(x)):
							return "HxOverrides.stringOrNull(" + printExpr(pctx, ex) + ")";
						case [_, _]:
							if (hasFeature(pctx, "Std.string"))
								return "Std.string(" + printExpr(pctx, ex) + ")";
							else
								return "str(" + printExpr(pctx, ex) + ")";
					}
				}
				var e1Str = safeString(e1);
				var e2Str = safeString(e2);
				return "(" + e1Str + " + " + e2Str + ")";
			case TBinop(OpAdd, e1, e2) if (follow(e.etype).match(TDynamic(_))):
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "python_Boot._add_dynamic(" + s1 + "," + s2 + ")";
			case TBinop(op, e1, e2):
				var s2 = printExpr(pctx, e2);
				var sop = printBinop(op);
				var s1 = printExpr(pctx, e1);
				return "(" + s1 + " " + sop + " " + s2 + ")";
			case TField(e1, fa):
				return printField(pctx, e1, fa, false);
			case TParenthesis(e1):
				return "(" + printExpr(pctx, e1) + ")";
			case TObjectDecl(fl):
				return "_hx_AnonObject(" + printExprsNamed(pctx, ", ", fl) + ")";
			case TArrayDecl(el):
				return "[" + printExprs(pctx, ", ", el) + "]";
			case TCall(e1, el):
				return printCall(pctx, e1, el, e);
			case TNew(c, _, el):
				var id = printBaseType(tInfos(TClassDecl(c)));
				return id + "(" + printCallArgs(pctx, e, el) + ")";
			case TUnop(Not, Prefix, e1):
				return "(" + printUnop(Not) + printExpr(pctx, e1) + ")";
			case TUnop(op, Prefix, e1):
				var s1 = printExpr(pctx, e1);
				return printUnop(op) + s1;
			case TFunction(tf):
				return printFunction(pctx, tf, null, e.epos);
			case TVar(v, eo):
				return printVar(pctx, v, eo);
			case TBlock([]):
				return "pass";
			case TBlock([b = {eexpr: TBlock(_)}]):
				return printExpr(pctx, b);
			case TBlock(el):
				var old = tabs;
				tabs = pctx.pcIndent;
				var s = printBlockExprs(pctx, "\n" + tabs, pctx.pcDebug, el);
				tabs = old;
				return s;
			case TIf(econd, eif, eelse) if (eelse != null && eelse.eexpr.match(TIf(_))):
				return printIfElse(pctx, econd, eif, eelse, true);
			case TIf(econd, eif, eelse):
				return printIfElse(pctx, econd, eif, eelse, false);
			case TWhile(econd, e1, NormalWhile):
				var s1 = printExprIndented(e1);
				var sc = printExpr(pctx, removeOuterParens(econd));
				return "while " + sc + ":\n" + indent + "    " + s1;
			case TWhile(econd, e1, DoWhile):
				return abort("Currently not supported", e.epos);
			case TTry(e1, catches):
				return printTry(pctx, e1, catches);
			case TReturn(eo):
				return "return" + opt(eo, printOpAssignRight.bind(pctx), " ");
			case TBreak:
				return "break";
			case TContinue:
				return "continue";
			case TThrow(e1):
				return "raise " + printExpr(pctx, e1);
			case TCast(e1, null):
				return printExpr(pctx, e1);
			case TMeta(m, {eexpr: TIf(econd, eif, eelse)}) if (isTernaryIf(m) && eelse != null):
				var s3 = printExpr(pctx, eelse);
				var s2 = printExpr(pctx, econd);
				var s1 = printExpr(pctx, eif);
				return "(" + s1 + " if " + s2 + " else " + s3 + ")";
			case TMeta(_, e1):
				return printExpr(pctx, e1);
			case TIdent(s):
				return s;
			case TSwitch(_) | TCast(_, _) | TUnop(_, Postfix, _):
				return die("", "genpy.ml Printer.print_expr");
		}
	}

	static inline function withExpr(e:TExpr, d:TExprDef):TExpr return new TExpr(d, e.etype, e.epos);

	static function printIfElse(pctx:PrintContext, econd:TExpr, eif:TExpr, eelse:Null<TExpr>, asElif:Bool):String {
		var econd1 = switch econd.eexpr {
			case TParenthesis(e): e;
			case _: econd;
		};
		var ifStr = printExpr(pctx.withIndent("    " + pctx.pcIndent), eif);
		var indent = pctx.pcIndent;
		var elseStr = if (asElif)
			opt(eelse, printExpr.bind(pctx), "el")
		else
			opt(eelse, printExpr.bind(pctx.withIndent("    " + pctx.pcIndent)), "else:\n" + indent + "    ");
		var elseStr = if (elseStr == "") "" else "\n" + indent + elseStr;
		return "if " + printExpr(pctx, removeOuterParens(econd1)) + ":\n" + indent + "    " + ifStr + elseStr;
	}

	static function printField(pctx:PrintContext, e1:TExpr, fa:TFieldAccess, isAssign:Bool):String {
		var obj = switch e1.eexpr {
			case TConst(TSuper): "super()";
			case _: printExpr(pctx, e1);
		};
		var name = fieldName(fa);
		var isExtern = switch fa {
			case FInstance(c, _, _): hasClassFlag(c, CExtern);
			case FStatic(c, _): hasClassFlag(c, CExtern);
			case _: false;
		};
		function doDefault() return obj + "." + (isExtern ? name : handleKeywords(name));
		function callOverride(s:String) return switch s {
			case "iterator" | "keyValueIterator" | "toUpperCase" | "toLowerCase" | "pop" | "shift" | "join" | "push" | "map" | "filter": true;
			case _: false;
		};
		return switch fa {
			// we need to get rid of these cases in the transformer, how is this handled in js
			case FInstance(c, _, {cfName: "length"}) if (isType("", "list")(TClassDecl(c))):
				"len(" + printExpr(pctx, e1) + ")";
			case FInstance(c, _, {cfName: "length"}) if (isType("", "str")(TClassDecl(c))):
				"len(" + printExpr(pctx, e1) + ")";
			case FAnon({cfName: "length"}) | FDynamic("length") if (!isAssign):
				"HxOverrides.length(" + printExpr(pctx, e1) + ")";
			case FStatic(c, {cfName: "fromCharCode"}) if (isType("", "str")(TClassDecl(c))):
				"HxString.fromCharCode";
			case FStatic({clPath: {pack: ["python", "internal"], name: "UBuiltins"}}, {cfName: s}):
				s;
			case FClosure(cc, cf) if (cc != null && isType("", "list")(TClassDecl(cc.cls))):
				"python_Boot.createClosure(" + obj + ", python_internal_ArrayImpl." + name + ")";
			case FClosure(cc, cf) if (cc != null && isType("", "str")(TClassDecl(cc.cls))):
				"python_Boot.createClosure(" + obj + ", HxString." + name + ")";
			case FInstance(c, _, cf) if (isType("", "list")(TClassDecl(c))):
				"python_Boot.createClosure(" + obj + ", python_internal_ArrayImpl." + name + ")";
			case FInstance(c, _, cf) if (isType("", "str")(TClassDecl(c))):
				"python_Boot.createClosure(" + obj + ", HxString." + name + ")";
			case FStatic(c, cf) if (hasClassFlag(c, CExtern) && c.clPath.pack.length == 0 && c.clPath.name == ""):
				name;
			case FInstance(_) | FStatic(_):
				doDefault();
			case FAnon(cf) if (isAssign && callOverride(name)):
				switch follow(cf.cfType) {
					case TFun({args: []}):
						"_hx_partial(HxOverrides." + name + ", " + obj + ")";
					case _:
						doDefault();
				}
			case _:
				doDefault();
		};
	}

	static function printTry(pctx:PrintContext, e1:TExpr, catches:Vector<{variable:TVar, expr:TExpr}>):String {
		function printCatch(pctx:PrintContext, c:{variable:TVar, expr:TExpr}) {
			var v = c.variable, e = c.expr;
			var sType = printModuleType(moduleTypeOfType(v.vType));
			var sExpr = pctx.pcIndent + printExpr(pctx, e);
			return "except " + sType + " as " + v.vName + ":\n" + sExpr;
		}
		var indent = pctx.pcIndent;
		function printExprIndented(e:TExpr) return printExpr(pctx.withIndent("    " + pctx.pcIndent), e);
		var tryStr = "try:\n" + indent + "    " + printExprIndented(e1) + "\n" + indent;
		var catchPctx = pctx.withIndent("    " + pctx.pcIndent);
		var catchStr = [for (c in catches) printCatch(catchPctx, c)].join("\n");
		return tryStr + catchStr;
	}

	static function printCall2(pctx:PrintContext, e1:TExpr, el:Vector<TExpr>):String {
		var id = printExpr(pctx, e1);
		switch [id, el] {
			case ["__define_feature__", [_, e]]:
				return printExpr(pctx, e);
			case ["super", _]:
				var sEl = printCallArgs(pctx, e1, el);
				return "super().__init__(" + sEl + ")";
			case ["python_Syntax._pythonCode", [ecode = {eexpr: TConst(TString(code))}, {eexpr: TArrayDecl(tl)}]]:
				return interpolate(pctx, code, tl, ecode);
			case ["python_Syntax.code", _] if (el.length > 0 && el[0].eexpr.match(TConst(TString(_)))):
				var ecode = el[0];
				var code = switch ecode.eexpr {
					case TConst(TString(code)): code;
					case _: "";
				};
				return interpolate(pctx, code, el.slice(1), ecode);
			case ["python_Syntax._pythonCode", [e]]:
				return printExpr(pctx, e);
			case ["python_Syntax.code", [e]]:
				switch e.eexpr {
					case TConst(TString(py)):
					case _:
						pctx.pcCom.error("First argument of python.Syntax.code() must be a constant string.", e1.epos);
				}
				return printExpr(pctx, e);
			case ["python_Syntax._callNamedUntyped", el]:
				var res:Vector<TExpr>, fields;
				var last = el.length > 0 ? el[el.length - 1] : null;
				switch last == null ? null : last.eexpr {
					case null:
						return die("", "genpy.ml Printer.print_call2");
					case TObjectDecl(f):
						res = el.slice(0, el.length - 1);
						fields = f;
					case _:
						return die("", "genpy.ml Printer.print_call2");
				}
				switch res {
					case [e1]:
						var s2 = printParamsNamed(pctx, ", ", fields);
						var s1 = printExpr(pctx, e1);
						return s1 + "(" + s2 + ")";
					case _ if (res.length > 0):
						var e1 = res[0], el = res.slice(1);
						var s3 = printParamsNamed(pctx, ", ", fields);
						var s2 = printExprs(pctx, ", ", el);
						var s1 = printExpr(pctx, e1);
						return s1 + "(" + s2 + ", " + s3 + ")";
					case _:
						var s2 = printParamsNamed(pctx, ", ", fields);
						var s1 = printExpr(pctx, e1);
						return s1 + "(" + s2 + ")";
				}
			case ["python_Syntax.varArgs", [e1]]:
				return "*" + printExpr(pctx, e1);
			case ["python_Syntax.call", [e1, {eexpr: TArrayDecl(el)}]]:
				var s2 = printExprs(pctx, ", ", el);
				var s1 = printExpr(pctx, e1);
				return s1 + "(" + s2 + ")";
			case ["python_Syntax.field", [e1, {eexpr: TConst(TString(id))}]]:
				return printExpr(pctx, e1) + "." + id;
			case ["python_Syntax._tuple", [{eexpr: TArrayDecl(el)}]]:
				switch el {
					case [e]:
						return "(" + printExpr(pctx, e) + ",)";
					case _:
						return "(" + printExprs(pctx, ", ", el) + ")";
				}
			case ["python_Syntax._arrayAccess", _] if (el.length >= 2 && el[1].eexpr.match(TArrayDecl(_))):
				var e1 = el[0];
				var el2 = switch el[1].eexpr {
					case TArrayDecl(l): l;
					case _: vector();
				};
				var etrail = el.slice(2);
				var trailingColon = switch etrail {
					case [{eexpr: TConst(TBool(true))}]: true;
					case _: false;
				};
				var s2 = printExprs(pctx, ":", el2);
				var s1 = printExpr(pctx, e1);
				return s1 + "[" + s2 + (trailingColon ? ":" : "") + "]";
			case ["python_Syntax.isIn", [e1, e2]]:
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "(" + s1 + " in " + s2 + ")";
			case ["python_Syntax.delete", [e1]]:
				return "del " + printExpr(pctx, e1);
			case ["python_Syntax.binop", [e0, {eexpr: TConst(TString(id))}, e2]]:
				var s2 = printExpr(pctx, e2);
				var s0 = printExpr(pctx, e0);
				return "(" + s0 + " " + id + " " + s2 + ")";
			case ["python_Syntax.assign", [e0, e1]]:
				var s1 = printExpr(pctx, e1);
				var s0 = printExpr(pctx, e0);
				return s0 + " = " + s1;
			case ["python_Syntax.arraySet", [e1, e2, e3]]:
				var s3 = printExpr(pctx, e3);
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return s1 + "[" + s2 + "] = " + s3;
			case ["python_Syntax._newInstance", [e1, {eexpr: TArrayDecl(el)}]]:
				return printConstruct(pctx, e1, el);
			case ["python_Syntax.construct", _] if (el.length > 0):
				return printConstruct(pctx, el[0], el.slice(1));
			case ["python_Syntax.opPow", [e1, e2]]:
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "(" + s1 + " ** " + s2 + ")";
			case ["python_Syntax._foreach", [e1, e2, e3]]:
				var pctx = pctx.withIndent("    " + pctx.pcIndent);
				var i = pctx.pcIndent;
				var s3 = printExpr(pctx, e3);
				var s2 = printExpr(pctx, e2);
				var s1 = printExpr(pctx, e1);
				return "for " + s1 + " in " + s2 + ":\n" + i + s3;
			case [_, el]:
				return id + "(" + printCallArgs(pctx, e1, el) + ")";
		}
	}

	// port: the body shared by the `python_Syntax._pythonCode`/`python_Syntax.code` or-pattern.
	static function interpolate(pctx:PrintContext, code:String, tl:Vector<TExpr>, ecode:TExpr):String {
		var buf = new StringBuf();
		function interpolate() {
			codegen.Codegen.interpolateCode(pctx.pcCom.error, code, tl.toArray(), function(s) buf.add(s), function(e) buf.add(printExpr(pctx, e)), ecode.epos);
		}
		interpolate();
		return buf.toString();
	}

	// port: the body shared by the `python_Syntax._newInstance`/`python_Syntax.construct` or-pattern.
	static function printConstruct(pctx:PrintContext, e1:TExpr, el:Vector<TExpr>):String {
		var cls = switch e1.eexpr {
			case TConst(TString(className)): className;
			case _: printExpr(pctx, e1);
		};
		return cls + "(" + printExprs(pctx, ", ", el) + ")";
	}

	static function printCall(pctx:PrintContext, e1:TExpr, el:Vector<TExpr>, callExpr:TExpr):String {
		function getNativeFields(t:T):haxe.ds.StringMap<String> {
			return switch follow(t) {
				case TAnon(a):
					function fold(f:String, cf:TClassField, acc:haxe.ds.StringMap<String>) {
						return if (Meta.has(Meta.Native, cf.cfMeta)) {
							var m = Meta.get(Meta.Native, cf.cfMeta);
							switch m.exprs {
								case [{expr: EConst(String(s, _))}]: core.ds.PMap.add(f, s, acc);
								case _: acc;
							}
						} else acc;
					}
					var mapping = core.ds.PMap.foldi(fold, a.aFields, core.ds.PMap.empty());
					mapping;
				case _:
					core.ds.PMap.empty();
			}
		}
		function nativeFieldsStr(nativeFields:haxe.ds.StringMap<String>):String {
			function foldDict(k:String, v:String, acc:String) {
				var prefix = if (acc == "") "" else ",";
				return acc + prefix + "\"" + handleKeywords(k) + "\":\"" + v + "\"";
			}
			return core.ds.PMap.foldi(foldDict, nativeFields, "");
		}
		switch [e1.eexpr, el] {
			case [TIdent("`trace"), [e, infos]]:
				if (hasFeature(pctx, "haxe.Log.trace")) {
					var si = printExpr(pctx, infos);
					var se = printExpr(pctx, e);
					return "haxe_Log.trace(" + se + "," + si + ")";
				} else if (isSafeString(pctx, e))
					return "print(" + printExpr(pctx, e) + ")";
				else
					return "print(str(" + printExpr(pctx, e) + "))";
			case [TField(e1, FAnon({cfName: s}) | FDynamic(s)), [x]] if (isOverride1(s)):
				var sx = printExpr(pctx, x);
				var s1 = printExpr(pctx, e1);
				return "HxOverrides." + s + "(" + s1 + ", " + sx + ")";
			case [TField(e1, FAnon({cfName: s}) | FDynamic(s)), []] if (isOverride0(s)):
				return "HxOverrides." + s + "(" + printExpr(pctx, e1) + ")";
			case [TField(_, FStatic({clPath: {pack: ["python", "_KwArgs"], name: "KwArgs_Impl_"}}, {cfName: "fromT"})), [e2]]:
				var t = switch follow(callExpr.etype) {
					case TAbstract(_, [t]): t;
					case _: die("", "genpy.ml Printer.print_call");
				};
				var nativeFields = getNativeFields(t);
				if (core.ds.PMap.isEmpty(nativeFields))
					return printCall2(pctx, e1, el);
				else {
					var s1 = nativeFieldsStr(nativeFields);
					return "python__KwArgs_KwArgs_Impl_.fromT(HxOverrides.mapKwArgs(" + printExpr(pctx, e2) + ", {" + s1 + "}))";
				}
			case [TField(_, FStatic({clPath: {pack: ["python", "_KwArgs"], name: "KwArgs_Impl_"}}, {cfName: "toDictHelper"})), [e2, et]]:
				var nativeFields = getNativeFields(et.etype);
				if (core.ds.PMap.isEmpty(nativeFields))
					return printCall2(pctx, e1, el);
				else {
					var s1 = nativeFieldsStr(nativeFields);
					return "python__KwArgs_KwArgs_Impl_.toDictHelper(HxOverrides.reverseMapKwArgs(" + printExpr(pctx, e2) + ", {" + s1 + "}), None)";
				}
			case [_, _]:
				return printCall2(pctx, e1, el);
		}
	}

	static function isOverride1(s:String):Bool return switch s {
		case "split" | "join" | "push" | "map" | "filter": true;
		case _: false;
	};

	static function isOverride0(s:String):Bool return switch s {
		case "iterator" | "keyValueIterator" | "toUpperCase" | "toLowerCase" | "pop" | "shift": true;
		case _: false;
	};

	static function printCallArgs(pctx:PrintContext, e1:TExpr, el:Vector<TExpr>):String {
		function printArg(pctx:PrintContext, i:Int, x:TExpr) {
			var e = switch [x.eexpr, follow(x.etype)] {
				case [TConst(TNull), TAbstract({aPath: {pack: ["python"], name: "KwArgs"}}, _)]: "{}";
				case [TConst(TNull), TAbstract({aPath: {pack: ["python"], name: "VarArgs"}}, _)]: "[]";
				case _: printExpr(pctx, x);
			};
			var prefix = switch [e1.eexpr, follow(x.etype)] {
				// the should not apply for the instance methods of the abstract itself
				case [TField(_, FStatic({clPath: {pack: ["python", "_KwArgs"], name: "KwArgs_Impl_"}}, f)), _] if (i == 0 && hasClassFieldFlag(f, CfImpl)): "";
				case [TField(_, FStatic({clPath: {pack: ["python", "_VarArgs"], name: "VarArgs_Impl_"}}, f)), _] if (i == 0 && hasClassFieldFlag(f, CfImpl)): "";
				case [_, TAbstract({aPath: {pack: ["python"], name: "KwArgs"}}, _)]: "**";
				case [_, TAbstract({aPath: {pack: ["python"], name: "VarArgs"}}, _)]: "*";
				case [_, _]: "";
			};
			return prefix + e;
		}
		return [for (i in 0...el.length) printArg(pctx, i, el[i])].join(",");
	}

	static function printExprs(pctx:PrintContext, sep:String, el:Vector<TExpr>):String return [for (e in el) printExpr(pctx, e)].join(sep);

	static var lastDebugComment = "";

	static function printBlockExprs(pctx:PrintContext, sep:String, printDebugComment:Bool, el:Vector<TExpr>):String {
		if (printDebugComment) {
			var acc = [];
			for (e in el) {
				var line = syntax.Lexer.getErrorLine(e.epos);
				var debugLine = "# " + e.epos.pfile + ":" + line;
				if (lastDebugComment != debugLine) {
					acc.push(debugLine);
					acc.push(printExpr(pctx, e));
				} else
					acc.push(printExpr(pctx, e));
				lastDebugComment = debugLine;
			}
			return acc.join(sep);
		} else
			return printExprs(pctx, sep, el);
	}

	static function printExprsNamed(pctx:PrintContext, sep:String,
			fl:Vector<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>):String {
		var args = [
			for (f in fl) "'" + core.StringHelper.sEscape(handleKeywords(f.key.name)) + "': " + printExpr(pctx, f.expr)
		].join(sep);
		return "{" + args + "}";
	}

	static function printParamsNamed(pctx:PrintContext, sep:String,
			fl:Vector<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>):String {
		var args = [for (f in fl) handleKeywords(f.key.name) + "= " + printExpr(pctx, f.expr)].join(sep);
		return args;
	}
}

typedef ClassFieldInfos = {
	var cfdFields:Array<String>;
	var cfdProps:Array<String>;
	var cfdMethods:Array<String>;
}

enum ImportType {
	IModule(name:String);
	IObject(module:String, object:String);
}

class GenpyContext {
	public final com:Gctx;
	public final buf:StringBuf;
	// port: `packages : (string,int) Hashtbl.t`, unused upstream.
	public final packages:haxe.ds.StringMap<Int>;
	public var staticInits:Array<Void->Void>;
	public var classInits:Array<Void->Void>;
	public var bootStaticInits:Array<Void->Void>;
	public var indentCount:Int;
	public final transformTime:Float;
	public final printTime:Float;

	public function new(com:Gctx) {
		this.com = com;
		buf = new StringBuf();
		packages = new haxe.ds.StringMap();
		staticInits = [];
		classInits = [];
		bootStaticInits = [];
		indentCount = 0;
		transformTime = 0.;
		printTime = 0.;
	}
}

class Generator {
	static function hasFeature(ctx:GenpyContext, f:String):Bool return Gctx.hasFeature(ctx.com, f);

	static function addFeature(ctx:GenpyContext, f:String):Void Gctx.addFeature(ctx.com, f);

	static function mkContext(com:Gctx):GenpyContext return new GenpyContext(com);

	/* Transformer interface */

	static function transformExpr(e:TExpr):TExpr return Transformer.transform(e);

	static function transformToValue(e:TExpr):TExpr return Transformer.transformToValue(e);

	/* Printer interface */

	static function getPath(mt:TInfos):String return Printer.printBaseType(mt);

	static function tfuncStr(f:TFunc, pctx:PrintContext, name:Null<String>, p:Pos):String return Printer.printFunction(pctx, f, name, p);

	static function texprStr(e:TExpr, pctx:PrintContext):String return Printer.printExpr(pctx, e);

	static function handleKeywords(s:String):String return Printer.handleKeywords(s);

	/* Helper */

	static function getFullName(mt:TInfos):String {
		// TODO: haxe source is crazy
		return sTypePath(mt.mtPath);
	}

	static function collectClassFieldData(cfl:Array<TClassField>):ClassFieldInfos {
		var fields = [];
		var props = [];
		var methods = [];
		for (cf in cfl) {
			switch cf.cfKind {
				case Var(_) if (!isPhysicalField(cf)):
				case Var({vRead: AccCall | AccPrivateCall}):
					if (Meta.has(Meta.IsVar, cf.cfMeta)) fields.push(cf.cfName) else props.push(cf.cfName);
				case Var(_):
					fields.push(cf.cfName);
				case _:
					methods.push(cf.cfName);
			}
		}
		return {
			cfdFields: fields,
			cfdProps: props,
			cfdMethods: methods
		};
	}

	static function collectClassStaticsData(cfl:Array<TClassField>):Array<String> {
		var fields = [];
		for (cf in cfl) if (isPhysicalField(cf)) fields.push(cf.cfName);
		return fields;
	}

	static function filterPyMetas(metas:Metadata):Metadata return metas.filter(m -> Meta.metaEq(core.MetaList.StrictMeta.Custom(":python"), m.meta));

	static function getMembersWithInitExpr(c:TClass):Array<TClassField> {
		return c.clOrderedFields.filter(cf -> switch cf.cfKind {
			case Var(_) if (!isPhysicalField(cf)): false;
			case Var(_) if (cf.cfExpr == null): true;
			case _: false;
		});
	}

	/* Printing */

	static function spr(ctx:GenpyContext, s:String):Void ctx.buf.add(s);

	static function sprLine(ctx:GenpyContext, s:String):Void {
		ctx.buf.add(s);
		ctx.buf.add("\n");
	}

	static function print(ctx:GenpyContext, s:String):Void ctx.buf.add(s);

	static function newline(ctx:GenpyContext):Void {
		if (!(ctx.buf.length == 0)) spr(ctx, "\n");
	}

	/* Generating functions */

	static function genPyMetas(ctx:GenpyContext, metas:Metadata, indent:String):Void {
		for (m in metas) {
			switch m.exprs {
				case [{expr: EConst(String(s, _))}]:
					print(ctx, indent + "@" + s + "\n");
				case _:
					abort("@:python metadata must have a string literal argument", m.pos);
			}
		}
	}

	static function genExpr(ctx:GenpyContext, e:TExpr, field:String, indent:String):Void {
		var pctx = Printer.createContext("    " + indent, ctx.com, ctx.com.debug);
		var e = switch e.eexpr {
			case TFunction(f):
				new TExpr(TBlock(vector(e)), e.etype, e.epos);
			case _:
				e;
		};
		var expr2 = transformToValue(e);
		var name = "_hx_init_" + field.split(".").join("_");
		function maybeSplitExpr(expr2:TExpr):{e1:Null<TExpr>, e2:TExpr} {
			return switch expr2.eexpr {
				case TBlock(es) if (es.length != 0 && field != ""):
					var eLast = es[es.length - 1];
					var el = es.slice(0, es.length - 1);
					var newLast = new TExpr(TReturn(eLast), eLast.etype, eLast.epos);
					var newBlock = new TExpr(TBlock(el.snoc(newLast)), expr2.etype, expr2.epos);
					var vName = core.TFunctions.allocVar(VGenerated, name, tfun(vector(), eLast.etype), eLast.epos);
					var fName = mk(TLocal(vName), vName.vType, eLast.epos);
					var callF = mk(TCall(fName, vector()), eLast.etype, eLast.epos);
					{e1: newBlock, e2: callF};
				case _:
					{e1: null, e2: expr2};
			}
		}
		var r = maybeSplitExpr(expr2);
		if (r.e1 != null) {
			var exprString1 = texprStr(r.e1, pctx);
			var exprString2 = texprStr(r.e2, pctx);
			print(ctx, indent + "def " + name + "():\n    " + exprString1);
			newline(ctx);
			print(ctx, indent + field + " = " + exprString2);
		} else {
			var exprString2 = texprStr(r.e2, pctx);
			if (field == "")
				print(ctx, indent + exprString2)
			else
				print(ctx, indent + field + " = " + exprString2);
		}
	}

	static function genFuncExpr(ctx:GenpyContext, e:TExpr, c:TClass, name:String, metas:Metadata, addSelf:Bool, indent:String, stat:Bool,
			p:Pos):Void {
		var pctx = Printer.createContext(indent, ctx.com, ctx.com.debug);
		var e = switch e.eexpr {
			case TFunction(f):
				var args = if (addSelf) {
					var v = core.TFunctions.allocVar(VGenerated, "self", tDynamic, p);
					v.vMeta = [({meta: Meta.This, exprs: vector(), pos: p} : MetadataEntry)].concat(v.vMeta);
					VectorTools.cons({variable: v, defaultValue: (null : Null<TExpr>)}, f.tfArgs);
				} else
					f.tfArgs;
				new TExpr(TFunction(new TFunc(args, f.tfType, f.tfExpr)), e.etype, e.epos);
			case _:
				e;
		};
		if (stat) {
			newline(ctx);
			spr(ctx, indent);
			spr(ctx, "@staticmethod\n");
		}
		var expr1 = transformExpr(e);
		var exprString = switch expr1.eexpr {
			case TFunction(f):
				tfuncStr(f, pctx, name, p);
			case _:
				name + " = " + texprStr(expr1, pctx);
		};
		genPyMetas(ctx, metas, indent);
		spr(ctx, indent);
		spr(ctx, exprString);
	}

	static function genClassConstructor(ctx:GenpyContext, c:TClass, cf:TClassField):Void {
		var memberInits = getMembersWithInitExpr(c);
		var pyMetas = filterPyMetas(cf.cfMeta);
		var ef = cf.cfExpr;
		switch ef == null ? null : ef.eexpr {
			case TFunction(f):
				var ethis = mk(TConst(TThis), TInst(c, extractParamTypes(c.clParams)), cf.cfPos);
				var assignedFields:Array<TClassField> = [];
				/* Collect all fields that are assigned to but panic out as soon as `this`,
					`super`, `return` or `throw` appears (regardless of control flow). */
				function collectAssignments(e:TExpr) {
					function loop(e:TExpr):Void {
						switch e.eexpr {
							case TBinop(OpAssign, {eexpr: TField({eexpr: TConst(TThis)}, FInstance(_, _, cf))}, e2):
								loop(e2);
								assignedFields.unshift(cf);
							case TConst(TSuper | TThis) | TThrow(_) | TReturn(_):
								throw new GenpyExit();
							// TODO: We could do some branch intersection stunts to make this more accurate.
							case TIf(e1, _, _) | TSwitch({switchSubject: e1}) | TWhile(e1, _, _):
								loop(e1);
							case _:
								Texpr.iter(loop, e);
						}
					}
					try loop(e) catch (_:GenpyExit) {}
				}
				collectAssignments(f.tfExpr);
				var memberData:Array<TExpr> = [];
				for (cf in memberInits) {
					if (assignedFields.indexOf(cf) == -1) {
						var ef = mk(TField(ethis, FInstance(c, vector(), cf)), cf.cfType, cf.cfPos); /* TODO */
						var e = mk(TBinop(OpAssign, ef, nullExpr(ef.etype, ef.epos)), ef.etype, ef.epos);
						memberData.unshift(e);
					}
				}
				var e = concat(mk(TBlock(Vector.fromArrayCopy(memberData)), ctx.com.basic.tvoid, cf.cfPos), f.tfExpr);
				var ef = new TExpr(TFunction(new TFunc(f.tfArgs, f.tfType, e)), ef.etype, ef.epos);
				cf.cfExpr = ef;

				newline(ctx);
				newline(ctx);
				genFuncExpr(ctx, ef, c, "__init__", pyMetas, true, "    ", false, cf.cfPos);
			case _:
				die("", "genpy.ml Generator.gen_class_constructor");
		}
	}

	static function genClassField(ctx:GenpyContext, c:TClass, p:String, cf:TClassField):Void {
		var field = handleKeywords(cf.cfName);
		var e = cf.cfExpr;
		if (e == null) {
			// print ctx "    # var %s" field
		} else {
			newline(ctx);
			newline(ctx);
			switch cf.cfKind {
				case Method(_):
					var pyMetas = filterPyMetas(cf.cfMeta);
					genFuncExpr(ctx, e, c, field, pyMetas, true, "    ", false, cf.cfPos);
				case _:
					genExpr(ctx, e, "# var " + field, "    ");
			}
		}
	}

	static function genClassEmptyConstructor(ctx:GenpyContext, p:String, cfl:Array<TClassField>):Void {
		if (hasFeature(ctx, "Type.createEmptyInstance")) {
			newline(ctx);
			newline(ctx);
			print(ctx, "    @staticmethod\n    def _hx_empty_init(_hx_o):");
			var foundFields = false;
			for (cf in cfl) switch cf.cfKind {
				case Var({vRead: AccCall | AccPrivateCall}):
				case Var(_):
					foundFields = true;
					newline(ctx);
					print(ctx, "        _hx_o." + handleKeywords(cf.cfName) + " = None");
				case _:
			}
			if (!foundFields) spr(ctx, "        pass");
		} else {
			newline(ctx);
		}
	}

	static function genClassStatics(ctx:GenpyContext, c:TClass, p:String):Bool {
		var methods = [], other = [];
		for (cf in c.clOrderedStatics) {
			var isMethod = switch cf.cfKind {
				case Method(_): cf.cfExpr != null;
				case _: false;
			};
			if (isMethod) methods.push(cf) else other.push(cf);
		}

		/* generate non methods */
		var hasEmptyStaticVars = false;
		for (cf in other) {
			var p = getPath(tInfos(TClassDecl(c)));
			var field = handleKeywords(cf.cfName);
			var e = cf.cfExpr;
			if (e == null) {
				hasEmptyStaticVars = true;
				newline(ctx);
				print(ctx, "    " + field + " = None");
			} else {
				var f = function() {
					newline(ctx);
					genExpr(ctx, e, p + "." + field, "");
				};
				if (c.clPath.pack.length == 1 && c.clPath.pack[0] == "python" && c.clPath.name == "Boot")
					ctx.bootStaticInits = [f].concat(ctx.bootStaticInits)
				else
					ctx.staticInits = [f].concat(ctx.staticInits);
			}
		}

		/* generate static methods */
		var hasStaticMethods = false;
		for (cf in methods) {
			hasStaticMethods = true;
			var field = handleKeywords(cf.cfName);
			var pyMetas = filterPyMetas(cf.cfMeta);
			var e = if (cf.cfExpr != null) cf.cfExpr else die("", "genpy.ml Generator.gen_class_statics");
			newline(ctx);
			genFuncExpr(ctx, e, c, field, pyMetas, false, "    ", true, cf.cfPos);
		}

		return hasStaticMethods || hasEmptyStaticVars;
	}

	static function genClassInit(ctx:GenpyContext, c:TClass):Void {
		var e = TOther.TClassTools.getClInit(c);
		if (e == null) {} else {
			var isMath = c.clPath.pack.length == 0 && c.clPath.name == "Math";
			var mathFeature = hasFeature(ctx, "Math");
			var f = if (isMath && !mathFeature) function() {} else function() {
				var e = transformExpr(e);
				newline(ctx);
				spr(ctx, texprStr(e, Printer.createContext("", ctx.com, ctx.com.debug)));
			};
			ctx.classInits = [f].concat(ctx.classInits);
		}
	}

	static function genClass(ctx:GenpyContext, c:TClass):Void {
		if (!hasClassFlag(c, CExtern)) {
			var isNativegen = Meta.has(Meta.NativeGen, c.clMeta);
			var mt = tInfos(TClassDecl(c));
			var p = getPath(mt);
			var pName = getFullName(mt);
			var x = collectClassFieldData(c.clOrderedFields);
			var pSuper = if (c.clSuper == null) null else getPath(tInfos(TClassDecl(c.clSuper.cls)));
			var pInterfaces = [for (i in c.clImplements) getPath(tInfos(TClassDecl(i.cls)))];

			newline(ctx);
			newline(ctx);
			newline(ctx);
			var pyMetas = filterPyMetas(c.clMeta);
			genPyMetas(ctx, pyMetas, "");
			print(ctx, "class " + p);
			if (pSuper != null) print(ctx, "(" + pSuper + ")");
			spr(ctx, ":");

			var usePass = true;

			if (!isNativegen) {
				if (hasFeature(ctx, "python._hx_class_name")) {
					usePass = false;
					print(ctx, "\n    _hx_class_name = \"" + pName + "\"");
				}
				if (hasFeature(ctx, "python._hx_is_interface")) {
					var value = if (hasClassFlag(c, CInterface)) "True" else "False";
					print(ctx, "\n    _hx_is_interface = \"" + value + "\"");
				}

				function printField(names:Array<String>, field:String, quote:Bool) {
					if (hasFeature(ctx, "python." + field)) try {
						function q(s:String) return if (quote) "\"" + s + "\"" else s;
						var s = switch names {
							case [] if (c.clSuper == null):
								// always overwrite parent's class fields
								throw new GenpyExit();
							case _:
								"[" + names.map(q).join(", ") + "]";
						};
						usePass = false;
						print(ctx, "\n    " + field + " = " + s);
					} catch (_:GenpyExit) {}
				}

				try {
					var realFields = c.clOrderedFields.filter(f -> switch f.cfKind {
						case Method(MethDynamic): throw new GenpyExit(); /* if a class has dynamic method, we can't use __slots__ because python will complain */
						case Var(_): isPhysicalField(f);
						case _: false;
					});
					var fieldNames = realFields.map(f -> handleKeywords(f.cfName));
					usePass = false;
					print(ctx, "\n    __slots__ = (");
					switch fieldNames {
						case []:
						case [name]: print(ctx, "\"" + name + "\",");
						case names: print(ctx, "\"" + names.join("\", \"") + "\"");
					}
					print(ctx, ")");
				} catch (_:GenpyExit) {}

				printField(x.cfdFields, "_hx_fields", true);
				printField(x.cfdMethods, "_hx_methods", true);
				/* TODO: It seems strange to have a separation for member fields but a plain _hx_statics for static ones */
				printField(collectClassStaticsData(c.clOrderedStatics), "_hx_statics", true);
				printField(pInterfaces, "_hx_interfaces", false);

				if (hasFeature(ctx, "python._hx_super")) if (pSuper != null) {
					usePass = false;
					print(ctx, "\n    _hx_super = " + pSuper + "\n");
				}
			}

			if (c.clConstructor != null) genClassConstructor(ctx, c, c.clConstructor);
			for (cf in c.clOrderedFields) genClassField(ctx, c, p, cf);

			var hasInnerStatic = genClassStatics(ctx, c, p);

			var hasEmptyConstructor = if (Meta.has(Meta.NativeGen, c.clMeta) || hasClassFlag(c, CInterface) || c.clOrderedFields.length == 0)
				false
			else {
				genClassEmptyConstructor(ctx, p, c.clOrderedFields);
				hasFeature(ctx, "Type.createEmptyInstance");
			};

			var usePass = usePass && !hasInnerStatic && !hasEmptyConstructor && switch x.cfdMethods {
				case []: c.clConstructor == null;
				case _: hasClassFlag(c, CInterface);
			};
			if (usePass) spr(ctx, "\n    pass");

			if (!isNativegen) {
				if (hasFeature(ctx, "python._hx_class")) print(ctx, "\n" + p + "._hx_class = " + p);
				if (hasFeature(ctx, "python._hx_classes")) print(ctx, "\n_hx_classes[\"" + pName + "\"] = " + p);
			}
		}
		genClassInit(ctx, c);
	}

	static function genEnumMetadata(ctx:GenpyContext, en:TEnum, p:String):Void {
		var meta = Texpr.buildMetadata(ctx.com.basic, TEnumDecl(en));
		if (meta == null) {} else {
			newline(ctx);
			print(ctx, p + ".__meta__ = ");
			genExpr(ctx, meta, "", "");
		}
	}

	static function genEnum(ctx:GenpyContext, en:TEnum):Void {
		var mt = tInfos(TEnumDecl(en));
		var p = getPath(mt);
		var pName = getFullName(mt);

		var enumConstructs = core.ds.PMap.foldi(function(k, ef, acc:Array<TEnumField>) return [ef].concat(acc), en.eConstrs, []);
		haxe.ds.ArraySort.sort(enumConstructs, function(a, b) return if (a.efIndex < b.efIndex) -1 else if (a.efIndex > b.efIndex) 1 else 0);

		newline(ctx);
		newline(ctx);
		print(ctx, "class " + p + "(Enum):");
		print(ctx, "\n    __slots__ = ()");

		if (hasFeature(ctx, "python._hx_class_name")) {
			print(ctx, "\n    _hx_class_name = \"" + pName + "\"");
		}
		if (hasFeature(ctx, "python._hx_constructs")) {
			var fix = enumConstructs.length == 0 ? "" : "\"";
			var enumConstructsStr = fix + enumConstructs.map(ef -> ef.efName).join("\", \"") + fix;
			print(ctx, "\n    _hx_constructs = [" + enumConstructsStr + "]");
		}

		var constConstructors = [], paramConstructors = [];
		for (ef in enumConstructs) {
			var isConst = switch follow(ef.efType) {
				case TFun(_): false;
				case _: true;
			};
			if (isConst) constConstructors.push(ef) else paramConstructors.push(ef);
		}

		for (ef in paramConstructors) {
			switch follow(ef.efType) {
				case TFun({args: args}):
					function argName(hxName:String) {
						var name = handleKeywords(hxName);
						return if (name == pName) pName + "_" + name else name;
					}
					function printArgs(args:Vector<{name:String, optional:Bool, type:T}>) {
						var hadOptional = false;
						var sl = [
							for (a in args) {
								var argValue = if (hadOptional) "= None" else if (a.optional) {
									hadOptional = true;
									" = None";
								} else "";
								argName(a.name) + argValue;
							}
						];
						return sl.join(",");
					}
					var f = handleKeywords(ef.efName);
					var paramStr = printArgs(args);
					var argsStr = switch args {
						case [a]: argName(a.name) + ",";
						case args: args.map(a -> argName(a.name)).join(",");
					};
					newline(ctx);
					newline(ctx);
					print(ctx, "    @staticmethod\n    def " + f + "(" + paramStr + "):\n");
					print(ctx, "        return " + p + "(\"" + ef.efName + "\", " + ef.efIndex + ", (" + argsStr + "))");
				case _:
					die("", "genpy.ml Generator.gen_enum");
			}
		}

		for (ef in constConstructors) {
			// TODO: haxe source has api.quoteString for ef.ef_name
			var f = handleKeywords(ef.efName);
			newline(ctx);
			print(ctx, p + "." + f + " = " + p + "(\"" + ef.efName + "\", " + ef.efIndex + ", ())");
		}

		if (hasFeature(ctx, "python._hx_class")) print(ctx, "\n" + p + "._hx_class = " + p);
		if (hasFeature(ctx, "python._hx_classes")) print(ctx, "\n_hx_classes[\"" + pName + "\"] = " + p);

		genEnumMetadata(ctx, en, p);
	}

	static function genAbstract(ctx:GenpyContext, a:TAbstract):Void {
		newline(ctx);
		newline(ctx);
		newline(ctx);
		var mt = tInfos(TAbstractDecl(a));
		var p = getPath(mt);
		print(ctx, "class " + p + ": pass");
	}

	static function isTopLevelAbstract(a:TAbstract, name:String):Bool return a.aPath.pack.length == 0 && a.aPath.name == name;

	static function genType(ctx:GenpyContext, mt:ModuleType):Void {
		switch mt {
			case TClassDecl(c):
				genClass(ctx, c);
			case TEnumDecl(en) if (!hasEnumFlag(en, EnExtern)):
				genEnum(ctx, en);
			case TAbstractDecl({aPath: {pack: [], name: "UInt"}}):
			case TAbstractDecl({aPath: {pack: ["haxe"], name: "UInt32"}}):
			case TAbstractDecl({aPath: {pack: [], name: "Enum"}}):
			case TAbstractDecl({aPath: {pack: [], name: "EnumValue"}}) if (!hasFeature(ctx, "has_enum")):
			case TAbstractDecl({aPath: {pack: [], name: "Void"}}):
			case TAbstractDecl({aPath: {pack: [], name: "Int"}}) if (!hasFeature(ctx, "Int.*")):
			case TAbstractDecl({aPath: {pack: [], name: "Float"}}) if (!hasFeature(ctx, "Float.*")):
			case TAbstractDecl({aPath: {pack: [], name: "Class"}}) if (!hasFeature(ctx, "Class.*")):
			case TAbstractDecl({aPath: {pack: [], name: "Dynamic"}}) if (!hasFeature(ctx, "Dynamic.*")):
			case TAbstractDecl({aPath: {pack: [], name: "Bool"}}) if (!hasFeature(ctx, "Bool.*")):

			case TAbstractDecl(a) if (Meta.has(Meta.RuntimeValue, a.aMeta)):
				genAbstract(ctx, a);
			case _:
		}
	}

	/* Generator parts */

	static function genResources(ctx:GenpyContext):Void {
		if (ctx.com.resources.length() > 0) {
			var slashIndex = ctx.com.file.lastIndexOf("/") + 1;
			var len = ctx.com.file.length - slashIndex;
			var fileName = ctx.com.file.substr(slashIndex, len);
			newline(ctx);
			newline(ctx);
			newline(ctx);
			spr(ctx, "def _hx_resources__():");
			spr(ctx, "\n    import inspect");
			spr(ctx, "\n    import sys");
			spr(ctx, "\n    if not hasattr(sys.modules[__name__], '__file__'):");
			print(ctx, "\n        _file = '" + fileName + "'");
			spr(ctx, "\n    else:");
			spr(ctx, "\n        _file = __file__");

			spr(ctx, "\n    return {");
			var first = true;
			ctx.com.resources.iter(function(k, v) {
				var prefix = if (first) {
					first = false;
					"";
				} else ",";
				var kEnc = core.StringHelper.escapeResName(k, []);
				print(ctx, prefix + "\"" + core.StringHelper.sEscape(k) + "\": open('%s.%s'%(_file,'" + kEnc + "'),'rb').read()");

				sys.io.File.saveBytes(ctx.com.file + "." + kEnc, v);
			});
			spr(ctx, "}");
		}
	}

	static function genImports(ctx:GenpyContext):Void {
		function isIgnoreError(e:Expr, value:String):Bool return switch e.expr {
			case EBinop(OpAssign, {expr: EConst(Ident("ignoreError"))}, {expr: EConst(Ident(v))}) if (v == value): true;
			case _: false;
		};
		function import_(path:GlobalTypePath, meta:Metadata) {
			if (Meta.has(Meta.PythonImport, meta) && Gctx.isDirectlyUsed(ctx.com, meta)) {
				var m = Meta.get(Meta.PythonImport, meta);
				var args = m.exprs, mp = m.pos;

				var className = switch path.pack {
					case []: path.name;
					case pack: pack.join("_") + "_" + path.name;
				};

				var importType, ignoreError;
				switch args {
					case [{expr: EConst(String(moduleName, _))}]:
						importType = IModule(moduleName);
						ignoreError = false;
					case [{expr: EConst(String(moduleName, _))}, e] if (isIgnoreError(e, "false")):
						importType = IModule(moduleName);
						ignoreError = false;

					case [{expr: EConst(String(moduleName, _))}, e] if (isIgnoreError(e, "true")):
						importType = IModule(moduleName);
						ignoreError = true;

					case [{expr: EConst(String(moduleName, _))}, {expr: EConst(String(objectName, _))}]:
						importType = IObject(moduleName, objectName);
						ignoreError = false;
					case [{expr: EConst(String(moduleName, _))}, {expr: EConst(String(objectName, _))}, e] if (isIgnoreError(e, "false")):
						importType = IObject(moduleName, objectName);
						ignoreError = false;

					case [{expr: EConst(String(moduleName, _))}, {expr: EConst(String(objectName, _))}, e] if (isIgnoreError(e, "true")):
						importType = IObject(moduleName, objectName);
						ignoreError = true;
					case _:
						abort("Unsupported @:pythonImport format", mp);
						return;
				}

				var import_ = switch importType {
					case IModule(moduleName):
						/* importing whole module */
						if (moduleName == className) "import " + moduleName else "import " + moduleName + " as " + className;

					case IObject(moduleName, objectName):
						if (objectName.indexOf(".") >= 0)
							/* importing nested class */
							"import " + moduleName + " as _hx_temp_import; " + className + " = _hx_temp_import." + objectName + "; del _hx_temp_import"
						else
							/* importing a class from a module */
							if (objectName == className) "from " + moduleName + " import " + objectName else "from " + moduleName + " import "
								+ objectName + " as " + className;
				};
				newline(ctx);
				if (ignoreError) {
					spr(ctx, "try:\n    ");
					sprLine(ctx, import_);
					spr(ctx, "except:\n    pass");
				} else
					spr(ctx, import_);
			}
		}
		for (mt in ctx.com.types) {
			switch mt {
				case TClassDecl(c) if (hasClassFlag(c, CExtern)): import_(c.clPath, c.clMeta);
				case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)): import_(e.ePath, e.eMeta);
				case _:
			}
		}
	}

	static function genTypes(ctx:GenpyContext):Void {
		var usedPaths = new haxe.ds.StringMap<Bool>();
		function pathKey(path:GlobalTypePath) return path.pack.join(".") + ":" + path.name;
		function findType(path:GlobalTypePath) {
			usedPaths.set(pathKey(path), true);
			return Utils.findType(ctx.com, path);
		}
		var needAnonForTrace = hasFeature(ctx, "has_anon_trace") && hasFeature(ctx, "haxe.Log.trace");
		if (hasFeature(ctx, "has_anon") || hasFeature(ctx, "_hx_AnonObject") || hasFeature(ctx, "has_metadata") || needAnonForTrace) {
			var withBody = hasFeature(ctx, "has_anon") || hasFeature(ctx, "has_metadata") || needAnonForTrace;
			newline(ctx);
			newline(ctx);
			newline(ctx);
			spr(ctx, "class _hx_AnonObject:\n");
			if (withBody) {
				spr(ctx, "    _hx_disable_getattr = False\n");
				spr(ctx, "    def __init__(self, fields):\n");
				spr(ctx, "        self.__dict__ = fields\n");
				spr(ctx, "    def __repr__(self):\n");
				spr(ctx, "        return repr(self.__dict__)\n");
				spr(ctx, "    def __contains__(self, item):\n");
				spr(ctx, "        return item in self.__dict__\n");
				spr(ctx, "    def __getitem__(self, item):\n");
				spr(ctx, "        return self.__dict__[item]\n");
				spr(ctx, "    def __getattr__(self, name):\n");
				spr(ctx, "        if (self._hx_disable_getattr):\n");
				spr(ctx, "            raise AttributeError('field does not exist')\n");
				spr(ctx, "        else:\n");
				spr(ctx, "            return None\n");
				spr(ctx, "    def _hx_hasattr(self,field):\n");
				spr(ctx, "        self._hx_disable_getattr = True\n");
				spr(ctx, "        try:\n");
				spr(ctx, "            getattr(self, field)\n");
				spr(ctx, "            self._hx_disable_getattr = False\n");
				spr(ctx, "            return True\n");
				spr(ctx, "        except AttributeError:\n");
				spr(ctx, "            self._hx_disable_getattr = False\n");
				spr(ctx, "            return False\n");
			} else
				spr(ctx, "    pass");
			usedPaths.set(pathKey({pack: [], name: "_hx_AnonObject"}), true);
		}
		if (hasFeature(ctx, "python._hx_classes")) {
			newline(ctx);
			newline(ctx);
			newline(ctx);
			spr(ctx, "_hx_classes = {}");
		}
		if (hasFeature(ctx, "Boot.*")) genType(ctx, findType({pack: ["python"], name: "Boot"}));
		if (hasFeature(ctx, "has_enum") || hasFeature(ctx, "Enum.*")) genType(ctx, findType({pack: [], name: "Enum"}));
		if (hasFeature(ctx, "HxOverrides.*")) genType(ctx, findType({pack: [], name: "HxOverrides"}));
		for (mt in ctx.com.types) {
			if (!usedPaths.exists(pathKey(tInfos(mt).mtPath))) genType(ctx, mt);
		}
	}

	static function genStaticInits(ctx:GenpyContext):Void {
		newline(ctx);
		var l = ctx.staticInits.copy();
		l.reverse();
		for (f in l) f();
	}

	static function genBootStaticInits(ctx:GenpyContext):Void {
		newline(ctx);
		var l = ctx.bootStaticInits.copy();
		l.reverse();
		for (f in l) f();
	}

	static function genClassInits(ctx:GenpyContext):Void {
		newline(ctx);
		var l = ctx.classInits.copy();
		l.reverse();
		for (f in l) f();
	}

	static function genMain(ctx:GenpyContext):Void {
		var e = ctx.com.main.mainExpr;
		if (e == null) {} else {
			newline(ctx);
			newline(ctx);
			switch e.eexpr {
				case TBlock(el):
					for (e in el) {
						genExpr(ctx, e, "", "");
						newline(ctx);
					}
				case _:
					genExpr(ctx, e, "", "");
					newline(ctx);
			}
		}
	}

	/* Entry point */

	public static function run(com:Gctx):Void {
		Transformer.init(com);
		var ctx = mkContext(com);
		Gctx.mapSourceHeader(com.defines, function(s) print(ctx, "# " + s + "\n# coding: utf-8\n"));
		if (hasFeature(ctx, "closure_Array") || hasFeature(ctx, "closure_String")) spr(ctx, "from functools import partial as _hx_partial\n");
		spr(ctx, "import sys\n");
		if (Gctx.defined(com, Define.StdEncodingUtf8)) {
			spr(ctx, "try:\n");
			spr(ctx, "    if sys.stdout.encoding != 'utf-8':\n");
			spr(ctx, "        sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf8', buffering=1)\n");
			spr(ctx, "    if sys.stderr.encoding != 'utf-8':\n");
			spr(ctx, "        sys.stderr = open(sys.stderr.fileno(), mode='w', encoding='utf8', buffering=1)\n");
			spr(ctx, "except:\n");
			spr(ctx, "    pass\n");
		}
		genImports(ctx);
		genResources(ctx);
		genTypes(ctx);
		genBootStaticInits(ctx);
		genClassInits(ctx);
		genStaticInits(ctx);
		genMain(ctx);

		core.Path.mkdirFromPath(com.file);
		sys.io.File.saveBytes(com.file, haxe.io.Bytes.ofString(ctx.buf.toString()));
	}
}

class Genpy {
	public static function generate(com:Gctx):Void Generator.run(com);
}
