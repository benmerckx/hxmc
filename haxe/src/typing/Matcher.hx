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
import core.MetaList.StrictMeta as MetaTag;
import core.TType;
import core.Ast;
import core.Ast.Expr;
import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TOther.ExtType;
import core.Meta;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import typing.matcher.Case;
import typing.matcher.Pattern;
import typing.matcher.Compile;
import typing.matcher.DecisionTree;
import typing.matcher.ExprToPattern;
import typing.matcher.TexprConverter;
import typing.matcher.MatcherGlobals;
import core.ds.MlList;

@:structInit class MatchCase {
	public var patterns:Array<Expr>;
	public var guard:Null<Expr>;
	public var expr:Null<Expr>;
	public var pos:Pos;

	public inline function new(patterns:Array<Expr>, guard:Null<Expr>, expr:Null<Expr>, pos:Pos) {
		this.patterns = patterns;
		this.guard = guard;
		this.expr = expr;
		this.pos = pos;
	}

	public inline function clone():MatchCase return new MatchCase(patterns, guard, expr, pos);
}

typedef MatchDefault = core.Ast.SwitchDefault;

class Matcher {
	static function matchExprImpl(ctx:context.Typecore.Typer, e:Expr, cases:Array<MatchCase>, def:Null<MatchDefault>,
			withType:WithTypeValue, postfixMatch:Bool, p:Pos):TExpr {
		var matchDebug = Meta.has(MetaTag.Custom(":debug.match"), ctx.f.curfield.cfMeta);
		function loop(e:Expr):{type:T, subjects:Array<TExpr>} {
			return switch e.expr {
				case EArrayDecl(el) if (!(el.length == 1 && switch el[0].expr {
					case EFor(_, _) | EWhile(_, _, _): true;
					case _: false;
				})):
					var typed = el.map(function(e) return typeExpr(ctx, e, WithTypeTools.value));
					{type: ExprToPattern.tupleType(typed.map(function(e) return e.etype)), subjects: typed};
				case EParenthesis(e): loop(e);
				case _:
					var e = typeExpr(ctx, e, WithTypeTools.value);
					{type: e.etype, subjects: [e]};
			};
		}
		var subject = loop(e);
		if (def != null) cases = cases.concat([
			{
				patterns: [{expr: EConst(Ident("_")), pos: def.pos}],
				guard: null,
				expr: def.expr,
				pos: def.pos
			}
		]);
		var tmono:Null<T> = null, allowMinVoid = false;
		switch withType {
			case WithType(t, source):
				switch [follow(t), source] {
					case [TMono(_), ImplicitReturn]:
						tmono = t;
						withType = Value(source);
						allowMinVoid = true;
					case [TAbstract(a, _), ImplicitReturn] if (a.aPath.pack.length == 0 && a.aPath.name == "Void"):
						tmono = t;
						withType = Value(source);
						allowMinVoid = true;
					case [TMono(_), _]:
						tmono = t;
						withType = WithTypeTools.value;
					case _:
				}
			case _:
		}
		// var freeMonos = Case.collectFreeMonos(subject.type);
		var rows:Array<CaseRow> = cases.map(function(c):CaseRow {
			var cp = c.pos;
			if (c.expr != null
				&& cp.pfile == Globals.nullPos.pfile
				&& cp.pmin == Globals.nullPos.pmin
				&& cp.pmax == Globals.nullPos.pmax)
				cp = c.expr.pos;
			var row = Case.make(ctx, subject.type, [], c.patterns, c.guard, c.expr, withType, postfixMatch, cp);
			return {caseData: row.caseData, bindings: MlListTools.ofArray(row.bindings), patterns: Cons(row.pattern, Nil)};
		});
		inline function inferSwitchType():T return switch withType {
			case NoValue: ctx.t.tvoid;
			case Value(_):
				if (rows.length == 0)
					// If there are no cases we assume Void. This then causes a "Cannot use Void as value" error.
					// Note that we cannot rely on an exhaustiveness error because the switch could be over an empty enum.
					ctx.t.tvoid
				else {
					var el = rows.map(function(row) {
						var e = row.caseData.caseExpr;
						return e == null
							// If we have no block we have to use the `case pattern` position because that's all we have.
							? mk(TBlock([]), ctx.t.tvoid, row.caseData.casePos)
							// If we have a block, use the position of the last element.
							: switch e.eexpr {
							case TBlock(values) if (values.length > 0): values[values.length - 1];
							case _: e;
						};
					});
					allowMinVoid ? unifyMinForTypeSource(ctx, el, ImplicitReturn) : unifyMin(ctx, el);
				}
			case WithType(t, _): t;
		};
		if (matchDebug) {
			Sys.println("CASES BEGIN");
			for (row in rows) Sys.println(MlListTools.toArray(row.patterns).map(Pattern.toString).join(""));
			Sys.println("CASES END");
		}
		var dt = Compile.compile(ctx, matchDebug, subject.subjects, rows, p);
		if (matchDebug) {
			Sys.println("DECISION TREE BEGIN");
			Sys.println(DecisionTree.toString(dt));
			Sys.println("DECISION TREE END");
		}
		var tSwitch = inferSwitchType();
		if (tmono != null && !(allowMinVoid && ExtType.isVoid(follow(tmono)))) unify(ctx, tSwitch, tmono, p);
		var result = TexprConverter.toTexpr(ctx, tSwitch, withType, dt);
		if (matchDebug) {
			Sys.println("TEXPR BEGIN");
			Sys.println(MatcherGlobals.sExprPretty(result));
			Sys.println("TEXPR END");
		}
		return {eexpr: result.eexpr, etype: result.etype, epos: p};
	}

	public static function matchExpr(ctx:context.Typecore.Typer, e:Expr, cases:Array<MatchCase>, def:Null<MatchDefault>,
			withType:WithTypeValue, postfixMatch:Bool, p:Pos):TExpr {
		if (cases.length == 0 && def == null && withType == NoValue) return typeExpr(ctx, e, WithTypeTools.value);
		return matchExprImpl(ctx, e, cases, def, withType, postfixMatch, p);
	}
}
