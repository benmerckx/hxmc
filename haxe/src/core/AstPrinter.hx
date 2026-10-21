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

package core;

import core.Ast;
import core.Globals;
import core.Ast as AstTools;
import core.Meta as MetadataTools;

// port: from haxe/src/core/ast.ml, module Printer.
class AstPrinter {
	public static function sExprInner(tabs:String, e:Expr):String {
		function expr(e:Expr):String return sExprInner(tabs, e);
		return switch e.expr {
			case EConst(c): AstTools.sConstant(c);
			case EArray(a, b): expr(a) + "[" + expr(b) + "]";
			case EBinop(op, a, b): expr(a) + " " + AstTools.sBinop(op) + " " + expr(b);
			case EField(e, f, k): expr(e) + (k == EFNormal ? "." : "?.") + f;
			case EParenthesis(e): "(" + expr(e) + ")";
			case EObjectDecl(fl): "{ " + [for (f in fl) AstTools.sObjectKeyName(f.key.name, f.key.quote) + " : " + expr(f.expr)].join(", ") + " }";
			case EArrayDecl(el): "[" + sExprList(tabs, el, ", ") + "]";
			case ECall(e, el): expr(e) + "(" + sExprList(tabs, el, ", ") + ")";
			case ENew(t, el): "new " + sComplexTypePath(tabs, t) + "(" + sExprList(tabs, el, ", ") + ")";
			case EUnop(op, Postfix, e): expr(e) + AstTools.sUnop(op);
			case EUnop(op, Prefix, e): AstTools.sUnop(op) + expr(e);
			case EFunction(FKNamed(n, inl), f): (inl ? "inline " : "") + "function " + n.name + sFunc(tabs, f);
			case EFunction(FKAnonymous, f): "function" + sFunc(tabs, f);
			case EFunction(FKArrow, f): "function" + sFunc(tabs, f, true);
			case EVars(vl): "var " + [for (v in vl) sVar(tabs, v)].join(", ");
			case EBlock([]): "{ }";
			case EBlock(el): sBlock(tabs, el, "{", "\n", "}");
			case EFor(a, b): "for (" + expr(a) + ") " + expr(b);
			case EIf(e, a, b): "if (" + expr(e) + ") " + expr(a) + (b == null ? "" : " else " + expr(b));
			case EWhile(c, e, NormalWhile): "while (" + expr(c) + ") " + expr(e);
			case EWhile(c, e, DoWhile): "do " + expr(e) + " while (" + expr(c) + ")";
			case ESwitch(e, cases, def): "switch "
				+ expr(e)
				+ " {\n\t"
				+ tabs
				+ [for (c in cases) sCase(tabs, c)].join("\n\t" + tabs)
					+ (def == null ? "" : "\n\t" + tabs + "default:" + (def.expr == null ? "" : sExprOmitBlock(tabs, def.expr)))
					+ "\n"
					+ tabs
					+ "}";
			case ETry(e, catches): "try " + expr(e) + [for (c in catches) sCatch(tabs, c)].join("");
			case EReturn(e): "return" + sOptExpr(tabs, e, " ");
			case EBreak: "break";
			case EContinue: "continue";
			case EUntyped(e): "untyped " + expr(e);
			case EThrow(e): "throw " + expr(e);
			case ECast(e, t): t == null ? "cast " + expr(e) : "cast (" + expr(e) + ", " + sComplexType(tabs, t.type) + ")";
			case EIs(e, t): expr(e) + " is " + sComplexType(tabs, t.type);
			case ETernary(a, b, c): expr(a) + " ? " + expr(b) + " : " + expr(c);
			case ECheckType(e, t): "(" + expr(e) + " : " + sComplexType(tabs, t.type) + ")";
			case EMeta(m, e): sMetadata(tabs, m) + " " + expr(e);
			case EDisplay(e, k): "#DISPLAY(" + expr(e) + ", " + AstTools.sDisplayKind(k) + ")";
		};
	}

	public static function sExprList(tabs:String, el:haxe.ds.Vector<Expr>, sep:String):String return [for (e in el) sExprInner(tabs, e)].join(sep);

	public static function sComplexTypePath(tabs:String,
			t:PlacedTypePath):String return Globals.sTypePath({pack: t.path.tpackage, name: t.path.tname})
			+ (t.path.tsub == null ? "" : "." + t.path.tsub)
			+ sTypeParamOrConsts(tabs, t.path.tparams);

	public static function sTypeParamOrConsts(tabs:String,
			pl:haxe.ds.Vector<TypeParamOrConst>):String return pl.length == 0 ? "" : "<" + [for (p in pl) sTypeParamOrConst(tabs, p)].join(",") +
			">";

	public static function sTypeParamOrConst(tabs:String, p:TypeParamOrConst):String return switch p {
		case TPType(t): sComplexType(tabs, t.type);
		case TPExpr(e): sExprInner(tabs, e);
	};

	public static function sComplexType(tabs:String, t:ComplexType):String return switch t {
		case CTPath(p): sComplexTypePath(tabs, p);
		// port: preserve upstream's conditional grouping, including the nonempty argument branch.
		case CTFunction(args, ret): args.length > 0 ? [for (a in args) sComplexType(tabs, a.type)].join(" -> ") : "Void -> "
				+ sComplexType(tabs, ret.type);
		case CTAnonymous(fl): "{ " + [for (f in fl) sClassField(tabs, f)].join("; ") + "}";
		case CTParent(t): "(" + sComplexType(tabs, t.type) + ")";
		case CTOptional(t): "?" + sComplexType(tabs, t.type);
		case CTNamed(n, t): n.name + ":" + sComplexType(tabs, t.type);
		case CTExtend(tl, fl): "{> "
			+ [for (t in tl) sComplexTypePath(tabs, t)].join(" >, ") + ", " + [for (f in fl) sClassField(tabs, f)].join(", ") + " }";
		case CTIntersection(tl): [for (t in tl) sComplexType(tabs, t.type)].join("&");
	};

	static function separated<T>(f:T->String, sep:String, l:Array<T>):String return l.length == 0 ? "" : l.map(f).join(sep) + sep;

	public static function sClassField(tabs:String, f:ClassField):String {
		var doc = f.cffDoc == null ? "" : "/**\n\t" + tabs + AstTools.genDocText(f.cffDoc) + "\n**/\n";
		inline function metas(ml:Metadata):String return separated(m -> sMetadata(tabs, m), "\n" + tabs, ml);
		function access(al:Array<PlacedAccess>):String return separated((a:PlacedAccess) -> AstTools.sAccess(a.access), " ", al);
		return switch f.cffKind {
			case FVar(t, e):
				var keyword = "var ", question = "";
				var al = f.cffAccess.filter(function(a) {
					if (a.access == AFinal) {
						keyword = "final ";
						return false;
					}
					return true;
				});
				var ml = f.cffMeta.filter(function(m) {
					if (m.meta == MetadataTools.Optional) {
						question = "?";
						return false;
					}
					return true;
				});
				doc
				+ metas(ml)
				+ access(al)
				+ keyword
				+ question
				+ f.cffName.name
				+ sOptTypeHint(tabs, t, " : ")
				+ sOptExpr(tabs, e, " = ");
			case FProp(get, set, t, e): doc + metas(f.cffMeta) + access(f.cffAccess) + "var " + f.cffName.name + "(" + get.name + ","
				+ set.name + ")" + sOptTypeHint(tabs, t, " : ") + sOptExpr(tabs, e, " = ");
			case FFun(func): doc + metas(f.cffMeta) + access(f.cffAccess) + "function " + f.cffName.name + sFunc(tabs, func);
		};
	}

	public static function sMetadata(tabs:String,
			m:MetadataEntry):String return "@"
			+ MetadataTools.toString(m.meta)
			+ (m.exprs.length > 0 ? "(" + sExprList(tabs, m.exprs, ", ") + ")" : "");

	public static function sOptExpr(tabs:String, e:Null<Expr>, pre:String):String return e == null ? "" : pre + sExprInner(tabs, e);

	public static function sOptTypeHint(tabs:String, t:Null<TypeHint>,
			pre:String):String return t == null ? "" : pre + sComplexType(tabs, t.type);

	public static function sFunc(tabs:String, f:Func,
			isArrow = false):String return sTypeParamList(tabs, f.fParams)
			+ "("
			+ [for (a in f.fArgs) sFuncArg(tabs, a)].join(", ")
				+ ")"
				+ sOptTypeHint(tabs, f.fType, ":")
				+ (isArrow ? " -> " : "")
				+ sOptExpr(tabs, f.fExpr, " ");

	public static function sTypeParam(tabs:String,
			t:TypeParam):String return t.tpName.name
			+ sTypeParamList(tabs, t.tpParams)
			+ (t.tpConstraints == null ? "" : ":(" + sComplexType(tabs, t.tpConstraints.type) + ")");

	public static function sTypeParamList(tabs:String,
			tl:haxe.ds.Vector<TypeParam>):String return tl.length == 0 ? "" : "<" + [for (t in tl) sTypeParam(tabs, t)].join(", ") + ">";

	public static function sFuncArg(tabs:String,
			a:FuncArg):String return a.optional ? "?" : "" + a.name.name + sOptTypeHint(tabs, a.type, ":") + sOptExpr(tabs, a.expr, " = ");

	public static function sVar(tabs:String, v:EVar):String {
		var s = v.evName.name + sOptTypeHint(tabs, v.evType, ":") + sOptExpr(tabs, v.evExpr, " = ");
		return v.evMeta.length == 0 ? s : [for (m in v.evMeta) sMetadata(tabs, m)].join(" ") + " " + s;
	}

	public static function sCase(tabs:String,
			c:SwitchCase):String return "case "
			+ sExprList(tabs, c.values, ", ")
			+ (c.guard == null ? ":" : " if (" + sExprInner(tabs, c.guard) + "):")
			+ (c.expr == null ? "" : sExprOmitBlock(tabs, c.expr));

	public static function sCatch(tabs:String,
			c:Catch):String return " catch(" + c.name.name + sOptTypeHint(tabs, c.type, ":") + ") " + sExprInner(tabs, c.expr);

	public static function sBlock(tabs:String, el:haxe.ds.Vector<Expr>, open:String, nl:String,
			close:String):String return open + "\n\t" + tabs + sExprList(tabs + "\t", el, ";\n\t" + tabs) + ";" + nl + tabs + close;

	public static function sExprOmitBlock(tabs:String, e:Expr):String return switch e.expr {
		case EBlock([]): "";
		case EBlock(el): sBlock(tabs + "\t", el, "", "", "");
		case _: sExprInner(tabs + "\t", e) + ";";
	};

	public static function sExpr(e:Expr):String return sExprInner("", e);
}
