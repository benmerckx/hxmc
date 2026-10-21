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

package syntax;

import core.Ast;
import core.Ast.Expr;
import core.MetaList.StrictMeta;
import core.Ast.Ast.*;
import core.Globals.*;
import core.Globals.Pos;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

class Reification {
	public static function reify(inMacro:Bool):{toExpr:Expr->Expr, toCtype:TypeHint->Pos->Expr, toTypeDef:TypeDecl->Expr} {
		var currentPos:Null<Expr> = null;
		inline function en(ename:String, name:String, values:Vector<Expr>, p:Pos):Expr {
			// We don't want the position of the call expression to span the entire call (#6396).
			var min:core.Globals.Pos = {pfile: p.pfile, pmin: p.pmin, pmax: p.pmin};
			var constructor:Expr = {expr: EConst(Ident(name)), pos: min};
			return values.length == 0 ? constructor : {expr: ECall(constructor, values), pos: min};
		}
		function rawString(s:String, p:Pos):Expr return {expr: EConst(String(s, SDoubleQuotes)), pos: p};
		function toString(s:String,
				p:Pos):Expr return s.length > 1 && s.charAt(0) == "$" ? {expr: EConst(Ident(s.substr(1))), pos: p} : rawString(s, p);
		inline function placed(n:PlacedName):Expr return toString(n.name, n.pos);
		inline function nil(p:Pos):Expr return {expr: EConst(Ident("null")), pos: p};
		function arr<A>(f:A->Pos->Expr, values:Array<A>,
				p:Pos):Expr return {expr: EArrayDecl(values.mapToVector(function(v) return f(v, p))), pos: p};
		// port: arr of an AST list kept as a Vector
		function vec<A>(f:A->Pos->Expr, values:Vector<A>,
				p:Pos):Expr return {expr: EArrayDecl(values.map(function(v) return f(v, p))), pos: p};
		function opt<A>(f:A->Pos->Expr, v:Null<A>, p:Pos):Expr return v == null ? nil(p) : f(v, p);
		inline function bool(v:Bool, p:Pos):Expr return {expr: EConst(Ident(v ? "true" : "false")), pos: p};
		inline function obj(fields:Array<{name:String, e:Expr}>, p:Pos):Expr return {
			expr: EObjectDecl(fields.mapToVector(function(f) return ({
				key: {name: f.name, pos: nullPos, quote: NoQuotes},
				expr: f.e
			} : core.Ast.ObjectField))),
			pos: p
		};
		inline function fld(name:String, e:Expr):{name:String, e:Expr}
			return {name: name, e: e};
		function field(e:Expr, name:String, p:Pos):Expr return {expr: EField(e, name, EFNormal), pos: p};
		inline function macroField(cls:String, name:String,
				p:Pos):Expr return field(field(field({expr: EConst(Ident("haxe")), pos: p}, "macro", p), cls, p), name, p);
		inline function toConst(c:Constant, p:Pos):Expr return switch c {
			case Int(i, suffix): en("Constant", "CInt", vector(rawString(i, p), opt(rawString, suffix, p)), p);
			case String(s, kind): en("Constant", "CString", vector(
					rawString(s, p),
					en("StringLiteralKind", kind == SDoubleQuotes ? "DoubleQuotes" : "SingleQuotes", vector(), p)
				), p);
			case Float(f, suffix): en("Constant", "CFloat", vector(rawString(f, p), opt(rawString, suffix, p)), p);
			case Ident(s): en("Constant", "CIdent", vector(rawString(s, p)), p);
			case Regexp(r, o): en("Constant", "CRegexp", vector(rawString(r, p), rawString(o, p)), p);
		};
		function toBinop(op:Binop, p:Pos):Expr return switch op {
			case OpAssignOp(op): en("Binop", "OpAssignOp", vector(toBinop(op, p)), p);
			case _: en("Binop", switch op {
					case OpAdd: "OpAdd";
					case OpMult: "OpMult";
					case OpDiv: "OpDiv";
					case OpSub: "OpSub";
					case OpAssign: "OpAssign";
					case OpEq: "OpEq";
					case OpNotEq: "OpNotEq";
					case OpGt: "OpGt";
					case OpGte: "OpGte";
					case OpLt: "OpLt";
					case OpLte: "OpLte";
					case OpAnd: "OpAnd";
					case OpOr: "OpOr";
					case OpXor: "OpXor";
					case OpBoolAnd: "OpBoolAnd";
					case OpBoolOr: "OpBoolOr";
					case OpShl: "OpShl";
					case OpShr: "OpShr";
					case OpUShr: "OpUShr";
					case OpMod: "OpMod";
					case OpInterval: "OpInterval";
					case OpArrow: "OpArrow";
					case OpIn: "OpIn";
					case OpNullCoal: "OpNullCoal";
					case OpAssignOp(_): throw "assert";
				}, vector(), p);
		};
		var toExpr:Expr->Pos->Expr = null;
		var toCtype:TypeHint->Pos->Expr = null;
		var toCfield:ClassField->Pos->Expr = null;
		var toMeta:Metadata->Pos->Expr = null;
		var toExprArray:Vector<Expr>->Pos->Expr = null;
		inline function toPos(p:Pos):Expr {
			if (currentPos != null) return currentPos;
			if (inMacro) return {expr: EUntyped({expr: EConst(Ident("$__mk_pos__")), pos: p}), pos: p};
			return obj([
				fld("file", rawString(p.pfile, p)),
				fld("min", {expr: EConst(Int(Std.string(p.pmin), null)), pos: p}),
				fld("max", {expr: EConst(Int(Std.string(p.pmax), null)), pos: p})
			], p);
		}
		inline function toEncPos(p:Pos):Expr {
			if (currentPos != null) return currentPos;
			if (inMacro) return toPos(p);
			return {expr: ECall(macroField("Context", "makePosition", p), vector(toPos(p))), pos: p};
		}
		function toTparam(t:TypeParamOrConst, p:Pos):Expr return switch t {
			case TPType(t): en("TypeParam", "TPType", vector(toCtype(t, p)), p);
			case TPExpr(e): en("TypeParam", "TPExpr", vector(toExpr(e, p)), p);
		};
		inline function toTpath(ptp:PlacedTypePath):Expr {
			var t = ptp.path;
			var p:Pos = ptp.posFull;
			if (t.tpackage.length == 0 && t.tname.length > 1 && t.tname.charAt(0) == "$") {
				var ei:Expr = {expr: EConst(Ident(t.tname.substr(1))), pos: p};
				if (t.tparams.length == 0) return ei;
				// `macro : $TP<Int>` conveys the intent to use TP and overwrite the
				// type parameters.
				return obj([
					fld("pack", field(ei, "pack", p)),
					fld("name", field(ei, "name", p)),
					fld("sub", field(ei, "sub", p)),
					fld("params", vec(toTparam, t.tparams, p)),
					fld("pos", toPos(p)),
					fld("posPath", toPos(ptp.posPath))
				], p);
			}
			var fields = [
				fld("pack", arr(toString, t.tpackage, p)),
				fld("name", toString(t.tname, p)),
				fld("params", vec(toTparam, t.tparams, p)),
				fld("pos", toPos(p)),
				fld("posPath", toPos(ptp.posPath))
			];
			if (t.tsub != null) fields.push(fld("sub", toString(t.tsub, p)));
			return obj(fields, p);
		}
		function toTypeHint(t:TypeHint, _:Pos):Expr
			// to_obj ["type",to_ctype t p;"pos",to_pos p] p
			return toCtype(t, t.pos);
		toCtype = function(t, p) return switch t.type {
			case CTPath({
				path: {
					tpackage: [],
					tparams: [],
					tsub: null,
					tname: n
				}
			}) if (n.charAt(0) == "$"): toString(n, p);
			case CTPath(t): en("ComplexType", "TPath", vector(toTpath(t)), p);
			case CTFunction(args, ret): en("ComplexType", "TFunction", vector(vec(toTypeHint, args, p), toTypeHint(ret, p)), p);
			case CTAnonymous(fields): en("ComplexType", "TAnonymous", vector(vec(toCfield, fields, p)), p);
			case CTParent(t): en("ComplexType", "TParent", vector(toTypeHint(t, p)), p);
			case CTExtend(tl,
				fields): en("ComplexType", "TExtend", vector(vec(function(t, _) return toTpath(t), tl, p), vec(toCfield, fields, p)), p);
			case CTOptional(t): en("ComplexType", "TOptional", vector(toTypeHint(t, p)), p);
			case CTNamed(n, t): en("ComplexType", "TNamed", vector(placed(n), toTypeHint(t, p)), p);
			case CTIntersection(tl): en("ComplexType", "TIntersection", vector(vec(toCtype, tl, p)), p);
		};
		inline function toFun(f:Func, p:Pos):Expr {
			p = {pfile: p.pfile, pmin: p.pmin, pmax: p.pmin};
			function arg(a:FuncArg, p:Pos):Expr {
				var fields = [
					fld("name", toString(a.name.name, p)),
					fld("opt", bool(a.optional, p)),
					fld("type", opt(toTypeHint, a.type, p))
				];
				if (a.expr != null) fields.push(fld("value", toExpr(a.expr, p)));
				return obj(fields, p);
			}
			function param(t:TypeParam, p:Pos):Expr return obj([
				fld("name", placed(t.tpName)),
				fld("constraints", t.tpConstraints == null ? nil(p) : arr(toCtype, [t.tpConstraints], p)),
				fld("params", vec(param, t.tpParams, p))
			], p);
			return obj([
				fld("args", vec(arg, f.fArgs, p)),
				fld("ret", opt(toTypeHint, f.fType, p)),
				fld("expr", opt(toExpr, f.fExpr, p)),
				fld("params", vec(param, f.fParams, p))
			], p);
		}
		toCfield = function(f, p) {
			p = f.cffPos;
			function access(a:PlacedAccess, p:Pos):Expr return en("Access", switch a.access {
				case APublic: "APublic";
				case APrivate: "APrivate";
				case AStatic: "AStatic";
				case AOverride: "AOverride";
				case ADynamic: "ADynamic";
				case AInline: "AInline";
				case AMacro: "AMacro";
				case AFinal: "AFinal";
				case AExtern: "AExtern";
				case AAbstract: "AAbstract";
				case AOverload: "AOverload";
				case AEnum: "AEnum";
			}, vector(), p);
			var kind = switch f.cffKind {
				case FVar(ct, e): en("FieldType", "FVar", vector(opt(toTypeHint, ct, p), opt(toExpr, e, p)), p);
				case FFun(fun): en("FieldType", "FFun", vector(toFun(fun, p)), p);
				case FProp(get, set, t,
					e): en("FieldType", "FProp", vector(placed(get), placed(set), opt(toTypeHint, t, p), opt(toExpr, e, p)), p);
			};
			var fields = [fld("name", placed(f.cffName))];
			if (f.cffDoc != null) fields.push(fld("doc", toString(genDocText(f.cffDoc), p)));
			if (f.cffAccess.length > 0) fields.push(fld("access", arr(access, f.cffAccess, p)));
			fields.push(fld("kind", kind));
			fields.push(fld("pos", toPos(f.cffPos)));
			if (f.cffMeta.length > 0) fields.push(fld("meta", toMeta(f.cffMeta, p)));
			return obj(fields, p);
		};
		toMeta = function(meta, p) return arr(function(m:MetadataEntry, _) {
			var p = m.pos;
			return obj([
				fld("name", toString(core.Meta.toString(m.meta), p)),
				fld("params", toExprArray(m.exprs, p)),
				fld("pos", toPos(p))
			], p);
		}, meta, p);
		toExprArray = function(values, p) {
			if (values.length == 1) switch values[0].expr {
				case EMeta(m, e1) if (m.exprs.length == 0 && Type.enumEq(m.meta, StrictMeta.Dollar("a"))):
					switch e1.expr {
						case EArrayDecl(el) if (!(el.length == 1 && (switch el[0].expr {
							case EFor(_, _): true;
							case _: false;
						}))): return toExprArray(el, p);
						case _: return e1;
					}
				case _:
			}
			return vec(toExpr, values, p);
		};
		toExpr = function(e, _) {
			var p = e.pos;
			function expr(name:String,
					args:Vector<Expr>):Expr return obj([fld("expr", en("ExprDef", name, args, p)), fld("pos", toPos(p))], p);
			inline function loop(e:Expr):Expr return toExpr(e, e.pos);
			return switch e.expr {
				case EConst(Ident(n)) if (n.charAt(0) == "$" && n.length > 1 && n != "$__mk_pos__"): toString(n, p);
				case EConst(c): expr("EConst", vector(toConst(c, p)));
				case EArray(e1, e2): expr("EArray", vector(loop(e1), loop(e2)));
				case EBinop(op, e1, e2): expr("EBinop", vector(toBinop(op, p), loop(e1), loop(e2)));
				case EField(e1, s, kind):
					var patched = patchStringPos(p, s);
					expr("EField", vector(
						loop(e1),
						toString(s, patched),
						en("EFieldKind", kind == EFNormal ? "Normal" : "Safe", vector(), patched)
					));
				case EParenthesis(e1): expr("EParenthesis", vector(loop(e1)));
				case EObjectDecl(fl): expr("EObjectDecl", vector(
						vec(function(f:ObjectField, p) return obj([
							fld("field", toString(f.key.name, e.pos)),
							fld("expr", loop(f.expr)),
							fld("quotes", en("QuoteStatus", f.key.quote == NoQuotes ? "Unquoted" : "Quoted", vector(), f.key.pos))
						], p), fl, p)
					));
				case EArrayDecl(el): expr("EArrayDecl", vector(toExprArray(el, p)));
				case ECall(e1, el): expr("ECall", vector(loop(e1), toExprArray(el, p)));
				case ENew(ptp, el): expr("ENew", vector(toTpath(ptp), toExprArray(el, p)));
				case EUnop(op, flag, e1): expr("EUnop", vector(
						en("Unop", switch op {
							case Increment: "OpIncrement";
							case Decrement: "OpDecrement";
							case Not: "OpNot";
							case Neg: "OpNeg";
							case NegBits: "OpNegBits";
							case Spread: "OpSpread";
						}, vector(), p),
						bool(flag == Postfix, p),
						loop(e1)
					));
				case EVars(vl): expr("EVars", vector(
						vec(function(v:EVar, p) return obj([
							fld("name", toString(v.evName.name, v.evName.pos)),
							fld("namePos", toPos(v.evName.pos)),
							fld("type", opt(toTypeHint, v.evType, p)),
							fld("expr", opt(toExpr, v.evExpr, p)),
							fld("isFinal", bool(v.evFinal, p)),
							fld("isStatic", bool(v.evStatic, p)),
							fld("meta", toMeta(v.evMeta, p))
						], p), vl, p)
					));
				case EFunction(kind, f):
					var k = switch kind {
						case FKAnonymous: en("FunctionKind", "FAnonymous", vector(), p);
						case FKArrow: en("FunctionKind", "FArrow", vector(), p);
						case FKNamed(n, inlineFlag): en("FunctionKind", "FNamed", vector(toString(n.name, n.pos), bool(inlineFlag, n.pos)), p);
					};
					expr("EFunction", vector(k, toFun(f, p)));
				case EBlock(el): expr("EBlock", vector(toExprArray(el, p)));
				case EFor(e1, e2): expr("EFor", vector(loop(e1), loop(e2)));
				case EIf(e1, e2, eelse): expr("EIf", vector(loop(e1), loop(e2), opt(toExpr, eelse, p)));
				case EWhile(e1, e2, flag): expr("EWhile", vector(loop(e1), loop(e2), bool(flag == NormalWhile, p)));
				case ESwitch(e1, cases, def): expr("ESwitch", vector(
						loop(e1),
						vec(function(c:SwitchCase, p) return obj([
							fld("values", toExprArray(c.values, p)),
							fld("guard", opt(toExpr, c.guard, p)),
							fld("expr", opt(toExpr, c.expr, p))
						], p), cases, p),
						opt(function(d:SwitchDefault, p) return opt(toExpr, d.expr, p), def, p)
					));
				case ETry(e1, catches): expr("ETry", vector(
						loop(e1),
						vec(function(c:Catch, p) return obj([
							fld("name", toString(c.name.name, p)),
							fld("type", opt(toCtype, c.type, p)),
							fld("expr", loop(c.expr))
						], p), catches, p)
					));
				case EReturn(eo): expr("EReturn", vector(opt(toExpr, eo, p)));
				case EBreak: expr("EBreak", vector());
				case EContinue: expr("EContinue", vector());
				case EUntyped(e1): expr("EUntyped", vector(loop(e1)));
				case EThrow(e1): expr("EThrow", vector(loop(e1)));
				case ECast(e1, ct): expr("ECast", vector(loop(e1), opt(toTypeHint, ct, p)));
				case EIs(e1, ct): expr("EIs", vector(loop(e1), toTypeHint(ct, p)));
				case EDisplay(e1, dk): expr("EDisplay", vector(
						loop(e1),
						en("DisplayKind", (switch dk {
							case DKCall: "DKCall";
							case DKDot: "DKDot";
							case DKStructure: "DKStructure";
							case DKMarked: "DKMarked";
							case DKPattern(_): "DKPattern";
						}), vector(), p)
					));
				case ETernary(e1, e2, e3): expr("ETernary", vector(loop(e1), loop(e2), loop(e3)));
				case ECheckType(e1, ct): expr("ECheckType", vector(loop(e1), toTypeHint(ct, p)));
				case EMeta(meta, e1):
					var mp = meta.pos;
					switch [(cast meta.meta : StrictMeta), meta.exprs] {
						case [StrictMeta.Dollar("" | "e"), _]: e1;
						case [StrictMeta.Dollar("a"), _]: expr("EArrayDecl", vector(
								switch e1.expr {
									case EArrayDecl(el):
										toExprArray(el, mp);
									case _:
										e1;
								}
							));
						case [StrictMeta.Dollar("b"), _]: expr("EBlock", vector(e1));
						// TODO: can $v and $i be implemented better?
						case [StrictMeta.Dollar("v"), _]: switch e1.expr {
								case EParenthesis({
									expr: ECheckType(e2, {type: CTPath({path: {tname: "String", tpackage: []}})})
								}): expr("EConst", vector(en("Constant", "CString", vector(e2), e2.pos)));
								case EParenthesis({
									expr: ECheckType(e2, {type: CTPath({path: {tname: "Int", tpackage: []}})})
								}): expr("EConst", vector(en("Constant", "CInt", vector(e2), e2.pos)));
								case EParenthesis({
									expr: ECheckType(e2, {type: CTPath({path: {tname: "Float", tpackage: []}})})
								}): expr("EConst", vector(en("Constant", "CFloat", vector(e2), e2.pos)));
								case EConst(Int(s,
									"i64")): expr("EConst",
										vector(en("Constant", "CInt", vector(rawString(s, e1.pos), rawString("i64", e1.pos)), e1.pos)));
								case _: {expr: ECall(macroField("Context", "makeExpr", mp), vector(e1, toEncPos(e1.pos))), pos: mp};
							}
						case [StrictMeta.Dollar("i"), _]: expr("EConst", vector(en("Constant", "CIdent", vector(e1), e1.pos)));
						case [StrictMeta.Dollar("p"), _]: {expr: ECall(macroField("MacroStringTools", "toFieldExpr", mp), vector(e1)), pos: mp};
						case [StrictMeta.Pos, [pexpr]]:
							var old = currentPos;
							currentPos = pexpr;
							var result = loop(e1);
							currentPos = old;
							result;
						case _: expr("EMeta", vector(
								obj([
									fld("name", toString(core.Meta.toString(meta.meta), mp)),
									fld("params", toExprArray(meta.exprs, mp)),
									fld("pos", toPos(mp))
								], mp),
								loop(e1)
							));
					}
			};
		};
		function toTparamDecl(p:Pos, t:TypeParam):Expr return obj([
			fld("name", placed(t.tpName)),
			fld("params", {expr: EArrayDecl(t.tpParams.map(function(t) return toTparamDecl(p, t))), pos: p}),
			fld("meta", toMeta(t.tpMeta, p)),
			fld("constraints", {expr: EArrayDecl(t.tpConstraints == null ? vector() : vector(toCtype(t.tpConstraints, p))), pos: p}),
			fld("defaultType", opt(toCtype, t.tpDefault, p))
		], p);
		function toTypeDef(t:TypeDecl):Expr {
			var p = t.pos;
			return switch t.definition {
				case EClass(d):
					var ext:Null<Expr> = null;
					var impl = [];
					var interf = false,
						finalFlag = false,
						abstractFlag = false,
						externFlag = false;
					for (flag in d.flags) switch flag {
						case HExtern: externFlag = true;
						case HPrivate:
						case HInterface: interf = true;
						case HExtends(ptp): if (ext == null) ext = toTpath(ptp); else impl.push(toTpath(ptp));
						case HImplements(ptp): impl.push(toTpath(ptp));
						case HFinal: finalFlag = true;
						case HAbstract: abstractFlag = true;
					}
					obj([
						fld("pack", {expr: EArrayDecl(vector()), pos: p}),
						fld("name", toString(d.name.name, d.name.pos)),
						fld("pos", toPos(p)),
						fld("meta", toMeta(d.meta, p)),
						fld("params", {
							expr: EArrayDecl(d.params.map(function(t) return toTparamDecl(p, t))),
							pos: p
						}),
						fld("isExtern", bool(externFlag, p)),
						fld("kind", en("TypeDefKind", "TDClass", vector(
							ext == null ? nil(p) : ext,
							{expr: EArrayDecl(Vector.fromArrayCopy(impl)), pos: p},
							bool(interf, p),
							bool(finalFlag, p),
							bool(abstractFlag, p)
						), p)),
						fld("fields", {expr: EArrayDecl(d.data.map(function(f) return toCfield(f, p))), pos: p})
					], p);
				case _: throw "assert";
			};
		}
		return {toExpr: function(e) return toExpr(e, e.pos), toCtype: toCtype, toTypeDef: toTypeDef};
	}

	public static function reifyExpr(e:Expr, inMacro:Bool):Expr {
		var e = reify(inMacro).toExpr(e);
		return {expr: ECheckType(e, {type: makePtpCt(mkTypePath(["haxe", "macro"], "Expr"), nullPos), pos: nullPos}), pos: e.pos};
	}
}
