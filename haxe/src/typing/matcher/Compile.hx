package typing.matcher;

import core.Globals.Pos;
import core.TType;
import core.Ast;
import core.Ast.*;
import core.Error;
import core.Texpr;
import core.TUnification;
import core.ds.NotFound;
import core.ds.Exit;
import context.Common;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import context.Typecore.*;
import context.Typecore;
import typing.matcher.Pattern;
import typing.matcher.Constructor;
import typing.matcher.DecisionTree;
import typing.matcher.DecisionTree.*;
import typing.matcher.Case;
import typing.matcher.Bind;
import typing.matcher.MatcherGlobals.*;
import typing.matcher.MatcherGlobals;
import core.TUnification.typeIseq;
import core.ds.MlList;

using core.ds.MlList.MlListTools;

private class ExtractorFound extends haxe.Exception {
	public function new() super("Extractor");
}

typedef MatcherContext = {var ctx:Typer; var dtTable:haxe.ds.IntMap<Array<DecisionTreeData>>; var matchPos:Pos; var matchDebug:Bool; var dtCount:Int;}

class Compile {
	// port: DtTable (Hashtbl.Make(DecisionTree)) as buckets under a key built only from
	// what DecisionTree.equal compares, so equal trees share a bucket.
	static function hashconsKey(dt:DecisionTreeKind):Int return switch dt {
		case Leaf(c): 1 + c.casePos.pmin * 8;
		case Switch(_, cases, def): 2 + (cases.length * 31 + def.dtI + (cases.length > 0 ? cases[0].scDt.dtI * 131 : 0)) * 8;
		case Bind(l, d): 3 + (l.length * 31 + d.dtI) * 8;
		case Fail: 4;
		case Guard(_, a, b): 5 + (a.dtI * 31 + b.dtI) * 8;
		case GuardNull(_, a, b): 6 + (a.dtI * 31 + b.dtI) * 8;
	};

	public static function hashcons(m:MatcherContext, dt:DecisionTreeKind, p:Pos):DecisionTreeData {
		var key = hashconsKey(dt);
		var bucket = m.dtTable.get(key);
		if (bucket == null) {
			bucket = [];
			m.dtTable.set(key, bucket);
		}
		for (existing in bucket) if (DecisionTree.equal(existing.dtT, dt)) return existing;
		var d = ({
			dtT: dt,
			dtI: m.dtCount++,
			dtPos: p,
			dtGotoTarget: false,
			dtTexpr: null
		} : typing.matcher.DecisionTree.DecisionTreeData);
		bucket.push(d);
		return d;
	}

	static function leaf(m:MatcherContext, c:CaseData):DecisionTreeData return hashcons(m, Leaf(c), c.casePos);

	static function fail(m:MatcherContext, p:Pos):DecisionTreeData return hashcons(m, Fail, p);

	static function switchTree(m:MatcherContext, e:TExpr, cases:Array<DecisionSwitchCase>,
			def:DecisionTreeData):DecisionTreeData return hashcons(m, Switch(e, cases, def), e.epos);

	static function bind(m:MatcherContext, bl:Array<Bind>, dt:DecisionTreeData):DecisionTreeData return hashcons(m, Bind(bl, dt), dt.dtPos);

	static function guard(m:MatcherContext, e:TExpr, a:DecisionTreeData,
			b:DecisionTreeData):DecisionTreeData return hashcons(m, Guard(e, a, b), punion(a.dtPos, b.dtPos));

	static function guardNull(m:MatcherContext, e:TExpr, a:DecisionTreeData,
			b:DecisionTreeData):DecisionTreeData return hashcons(m, GuardNull(e, a, b), punion(a.dtPos, b.dtPos));

	static function getSubSubjects(m:MatcherContext, e:TExpr, con:ConstructorData,
			positions:Array<Pos>):Array<{name:String, e:TExpr}> return switch con.kind {
			case ConEnum(en, ef):
				var tl = Monomorph.spawnConstrainedMonos(function(t) return t, en.eParams);
				var ten = TEnum(en, tl);
				if (!typeIseq(ten, e.etype)) e = mk(TCast(e, null), ten, e.epos);
				switch follow(ef.efType) {
					case TFun(s): [
							for (i in 0...s.args.length) {
								var a = s.args[i];
								var p = i < positions.length ? positions[i] : e.epos;
								{
									name: a.name,
									e: mk(TEnumParameter(core.ds.Record.withFields(e, {epos: p}), ef, i),
										applyParams(en.eParams, tl, monomorphs(ef.efParams, a.type)), p)
								};
							}
						];
					case _: [];
				}
			case ConFields(sl): sl.map(function(s) return {name: s, e: ExprToPattern.typeFieldAccess(m.ctx, e, s)});
			case ConArray(0): [];
			case ConArray(i):
				var aa = ExprToPattern.getArrayAccess(m.ctx, e.etype, e.epos);
				function get(ei:TExpr):TExpr return aa != null ? aa.aaGet(e, ei, aa.aaType,
					e.epos) : Calls.accGet(m.ctx, Calls.arrayAccess(m.ctx, e, ei, MGet, e.epos));
				[
					for (i in 0...i) {
						var ei = Texpr.Builder.makeInt(m.ctx.com.basic, i, e.epos);
						{name: 'a$i', e: get(ei)};
					}
				];
			case ConConst(_) | ConTypeExpr(_) | ConStatic(_, _): [];
		};

	static function specialize(subject:TExpr, con:ConstructorData, cases:Array<CaseRow>):Array<CaseRow> {
		var arity = Constructor.arity(con);
		function row(c:CaseRow):Null<CaseRow> {
			return switch c.patterns {
				case Nil: null;
				case Cons(p, tail): switch p.kind {
						case PatConstructor(other,
							ps) if (Constructor.equal(con, other)): {caseData: c.caseData, bindings: c.bindings, patterns: ps.ofArray(tail)};
						case PatAny: {caseData: c.caseData, bindings: c.bindings, patterns: MlListTools.make(arity, p, tail)};
						case PatBind(v, p1): row({
								caseData: c.caseData,
								bindings: Cons(makeBind(v, p.pos, subject), c.bindings),
								patterns: Cons(p1, tail)
							});
						case _: null;
					};
			}
		}
		var result = [];
		for (c in cases) {
			var r = row(c);
			if (r != null) result.push(r);
		}
		return result;
	}

	static function defaultRows(subject:TExpr, cases:Array<CaseRow>):Array<CaseRow> {
		function row(c:CaseRow):Null<CaseRow> {
			return switch c.patterns {
				case Nil: null;
				case Cons(p, tail): switch p.kind {
						case PatAny: {caseData: c.caseData, bindings: c.bindings, patterns: tail};
						case PatBind(v, p1): row({
								caseData: c.caseData,
								bindings: Cons(makeBind(v, p.pos, subject), c.bindings),
								patterns: Cons(p1, tail)
							});
						case _: null;
					};
			}
		}
		var result = [];
		for (c in cases) {
			var r = row(c);
			if (r != null) result.push(r);
		}
		return result;
	}

	static function isWildcardPattern(p:PatternData):Bool return switch p.kind {
		case PatAny: true;
		case PatBind(_, p): isWildcardPattern(p);
		case _: false;
	};

	static function expand(cases:Array<CaseRow>):Array<CaseRow> {
		// port: the rows are pushed onto `result` in the order of upstream's `@`
		var result:Array<CaseRow> = [];
		function expandRow(f:PatternData->PatternData, c:CaseRow):Void {
			inline function row(ps:MlList<PatternData>):CaseRow return {caseData: c.caseData, bindings: c.bindings, patterns: ps};
			switch c.patterns {
				case Nil:
					result.push(c);
				case Cons(p, tail):
					switch p.kind {
						case PatOr(a, b):
							expandRow(f, row(Cons(a, tail)));
							expandRow(f, row(Cons(b, tail)));
						case PatBind(v, p1): expandRow(function(p2) return f({kind: PatBind(v, p2), pos: p.pos}), row(Cons(p1, tail)));
						case PatTuple(ps): expandRow(f, row(ps.ofArray(tail)));
						case _: result.push(row(Cons(f(p), tail)));
					}
			}
		}
		for (c in cases) expandRow(function(p) return p, c);
		return result;
	}

	static function sSubjects(s:MlList<Subject>):String return s.toArray().map(function(s) return s.toString()).join(" ");

	static function sCase(c:CaseRow):String {
		var bindings = c.bindings.toArray().map(function(b) return '${b.bVar.vName}<${b.bVar.vId}> = ${sExprPretty(b.bExpr)}').join(", ");
		var patterns = c.patterns.toArray().map(Pattern.toString).join(" ");
		var expr = c.caseData.caseExpr == null ? "" : core.TPrinting.sExprPretty(false, "\t\t", false, sType, c.caseData.caseExpr);
		var guard = c.caseData.caseGuard == null ? "" : core.TPrinting.sExprPretty(false, "\t\t", false, sType, c.caseData.caseGuard);
		return '\n\t\tbindings: $bindings\n\t\tpatterns: $patterns\n\t\tguard: $guard\n\t\texpr: $expr';
	}

	static function sCases(c:Array<CaseRow>):String return c.map(sCase).join("\n");

	static function selectColumn(subjects:MlList<Subject>, cases:Array<CaseRow>):{subjects:MlList<Subject>, cases:Array<CaseRow>} {
		function loop(i:Int, patterns:MlList<PatternData>):Int return switch patterns {
			case Cons({kind: PatAny | PatExtractor(_)}, patterns): loop(i + 1, patterns);
			case Cons({kind: PatBind(_, pat1)}, patterns): loop(i, Cons(pat1, patterns));
			case Nil: 0;
			case _: i;
		};
		var i = loop(0, cases[0].patterns);
		function sort<A>(l:MlList<A>):MlList<A> {
			if (i == 0) return l;
			var cur = 0, acc = Nil;
			while (true) switch l {
				case Cons(x, rest):
					if (i == cur) return Cons(x, acc.append(rest));
					cur++;
					acc = Cons(x, acc);
					l = rest;
				case Nil:
					return acc;
			}
		}
		return {
			subjects: sort(subjects),
			cases: cases.map(function(c) return ({
				caseData: c.caseData,
				bindings: c.bindings,
				patterns: sort(c.patterns)
			} : typing.matcher.Case.CaseRow))
		};
	}

	static function compileRows(m:MatcherContext, subjects:MlList<Subject>, cases:Array<CaseRow>):DecisionTreeData {
		if (cases.length == 0) return fail(m, switch subjects {
			case Cons(subject, _): subject.getPos();
			case Nil: m.matchPos;
		});
		var patterns = cases[0].patterns, allWildcards = true;
		while (allWildcards) switch patterns {
			case Cons(p, rest):
				allWildcards = isWildcardPattern(p);
				patterns = rest;
			case Nil:
				break;
		}
		if (allWildcards) return compileLeaf(m, subjects, cases[0], cases.slice(1));
		cases = expand(cases);
		var column = selectColumn(subjects, cases);
		subjects = column.subjects;
		cases = expand(column.cases); // TODO: is this really necessary?
		return try compileSwitch(m, subjects, cases) catch (e:ExtractorFound) compileExtractors(m, subjects, cases);
	}

	static function compileLeaf(m:MatcherContext, subjects:MlList<Subject>, row:CaseRow, cases:Array<CaseRow>):DecisionTreeData {
		if (m.matchDebug)
			Sys.println('compile_leaf:\n\tsubjects: ${sSubjects(subjects)}\n\tcase: ${sCase(row)}\n\tcases: ${sCases(cases)}');
		var dt = leaf(m, row.caseData);
		if (row.caseData.caseGuard != null) dt = guard(m, row.caseData.caseGuard, dt, compileRows(m, subjects, cases));
		var ps = row.patterns,
			ss = subjects,
			bs = row.bindings;
		while (true) switch [ps, ss] {
			case [Cons({kind: PatAny}, Nil), _]:
				break;
			case [Cons({kind: PatBind(v, p1), pos: p}, patterns), Cons(subject, _)]:
				bs = Cons(makeBind(v, p, subject.getAssignedExpr()), bs);
				ps = Cons(p1, patterns);
			case [Cons(_, patterns), Cons(_, rest)]:
				ps = patterns;
				ss = rest;
			case [Nil, Nil]:
				break;
			case [Nil, Cons(subject, _)]:
				Error.raiseTypingError("Invalid match: Not enough patterns", subject.getPos());
			case [Cons(p, _), Nil]:
				Error.raiseTypingError("Invalid match: Too many patterns", p.pos);
		}
		if (bs.match(Nil)) return dt;
		var bl = bs.toArray();
		bl.reverse();
		return bind(m, bl, dt);
	}

	static function compileSwitch(m:MatcherContext, subjects:MlList<Subject>, cases:Array<CaseRow>):DecisionTreeData {
		var first = switch subjects {
			case Nil: throw new InternalMatchFailure();
			case Cons(subject, rest):
				subjects = rest;
				subject;
		};
		var scoped = first.getScopedExpr();
		var subject = first.getExpr();
		var sigma:Array<{con:ConstructorData, unguarded:Bool, positions:Array<Pos>}> = [];
		var nullRows:Array<CaseRow> = [];
		for (row in cases) {
			var patterns = row.patterns;
			function loop(bs:MlList<Bind>, p:PatternData):Void switch p.kind {
				case PatConstructor({kind: ConConst(TNull)}, _):
					nullRows.push({caseData: row.caseData, bindings: bs, patterns: patterns.tl()});
				case PatConstructor(con, ps):
					var found = null;
					for (s in sigma) if (Constructor.equal(s.con, con)) {
						found = s;
						break;
					}
					if (found == null) sigma.push({
						con: con,
						unguarded: row.caseData.caseGuard == null,
						positions: ps.map(function(p) return p.pos)
					});
					else {
						found.con = con;
						found.positions = ps.map(function(p) return p.pos);
						if (row.caseData.caseGuard == null) found.unguarded = true;
					}
				case PatBind(_, {kind: PatAny}):
				case PatBind(v, p1):
					loop(Cons(makeBind(v, p.pos, subject), bs), p1);
				case PatAny:
				case PatExtractor(_):
					throw core.ds.FastThrow.of(new ExtractorFound());
				case _:
					Error.raiseTypingError("Unexpected pattern: " + Pattern.toString(p), row.caseData.casePos);
			};
			loop(row.bindings, patterns.hd());
		}
		sigma.sort(function(a, b) return a.con.pos.pmin - b.con.pos.pmin);
		if (m.matchDebug)
			Sys.println('compile_switch:\n\tsubject: ${sExprPretty(subject)}\n\ttsubjects: ${sSubjects(subjects)}\n\tcases: ${sCases(cases)}');
		var switchCases = sigma.map(function(s) {
			var sub = getSubSubjects(m, subject, s.con, s.positions);
			var bs = [], ss = [];
			for (sub in sub) {
				var v = addLocal(m.ctx, VGenerated, genLocalPrefix + sub.name, sub.e.etype, sub.e.epos);
				var ev = mk(TLocal(v), v.vType, v.vPos);
				var b = makeBindGen(v, v.vPos, sub.e, BindUnused);
				bs.push(b);
				ss.push(new Subject(ev, b));
			}
			var dt = compileRows(m, ss.ofArray(subjects), specialize(subject, s.con, cases));
			return ({scCon: s.con, scUnguarded: s.unguarded, scDt: bind(m, bs, dt)} : typing.matcher.DecisionTree.DecisionSwitchCase);
		});
		// This is very awkward: We need to know the first occurrence of the subject expression in the
		// decision tree before recursing. Ideally, this would be handled automatically during the recursion,
		// but for this to work we would have to replace some texpr occurrences with subject.
		var subjectNull = subject,
			subjectSwitch = subject,
			subjectDefault = subject;
		if (nullRows.length > 0 || isExplicitNullOrAbstractOverThat(subject.etype)) subjectNull = scoped.expr;
		else if (switchCases.length == 0) subjectDefault = scoped.expr;
		else subjectSwitch = scoped.expr;
		var defaults = defaultRows(subjectDefault, cases);
		var switchDefault = compileRows(m, subjects, defaults);
		var dt = switchCases.length == 0 ? switchDefault : switchTree(m, subjectSwitch, switchCases, switchDefault);
		if (nullRows.length == 0) {
			if (isExplicitNullOrAbstractOverThat(subject.etype)) dt = guardNull(m, subjectNull, switchDefault, dt);
		} else dt = guardNull(m, subjectNull, compileRows(m, subjects, nullRows.concat(defaults)), dt);
		scoped.reset();
		return dt;
	}

	static function compileExtractors(m:MatcherContext, subjects:MlList<Subject>, cases:Array<CaseRow>):DecisionTreeData {
		var subject = switch subjects {
			case Nil: throw new InternalMatchFailure();
			case Cons(subject, rest):
				subjects = rest;
				subject.getExpr();
		};
		if (m.matchDebug)
			Sys.println('compile_extractor:\n\tsubject: ${sExprPretty(subject)}\n\ttsubjects: ${sSubjects(subjects)}\n\tcases: ${sCases(cases)}');
		// Find all extractors of the current column and associate them with bindings, if exist
		var count = 0;
		var extracted:Array<{row:CaseRow, ex:Null<{extractor:Extractor, i:Int, bindings:MlList<Bind>}>}> = [];
		for (row in cases) {
			var ex:Null<{extractor:Extractor, i:Int, bindings:MlList<Bind>}> = null;
			function loop(bs:MlList<Bind>, p:PatternData):Void switch p.kind {
				case PatExtractor(e):
					ex = {extractor: e, i: ++count, bindings: bs};
				case PatBind(v, p1):
					loop(Cons(makeBind(v, p.pos, subject), bs), p1);
				case _:
			};
			loop(Nil, row.patterns.hd());
			extracted.push({row: row, ex: ex});
		}
		var any:PatternData = {kind: PatAny, pos: nullPos};
		var result:Array<CaseRow> = [],
			ss:Array<Subject> = [],
			bs:Array<Bind> = [],
			lut:Array<{e:TExpr, subject:Subject, i:Int}> = [];
		for (item in extracted) {
			var row:CaseRow = item.row;
			var p, tail;
			switch row.patterns {
				case Nil:
					throw "assert";
				case Cons(p1, rest):
					p = p1;
					tail = rest;
			}
			if (item.ex == null) {
				// If there's no extractor, generate `[pattern1, _, ..., _ ]`
				result.push({caseData: row.caseData, bindings: row.bindings, patterns: makeOffsetList(0, count, p, any).ofArray(tail)});
				continue;
			}
			var ex:Extractor = item.ex.extractor;
			// Replace the _ local with our subject
			function replace(e:TExpr):TExpr return switch e.eexpr {
				case TLocal(v) if (v == ex.exVar): subject;
				case _: core.Texpr.mapExpr(replace, e);
			};
			var e = replace(ex.exExpr);
			var bindings = item.ex.bindings.append(row.bindings);
			// See if we already had an equal extractor expression. In that case we can reuse its _hx_tmp
			var found:Null<{e:TExpr, subject:Subject, i:Int}> = null;
			for (entry in lut) if (Texpr.equal(e, entry.e)) {
				found = entry;
				break;
			}
			var i:Int = item.ex.i;
			var sub:Subject;
			if (found == null) {
				// Generate a local and add it to the subjects so that they become `[subject1, ..., localI, ...]`
				var v = allocVar(VExtractorVariable, "_hx_tmp", e.etype, e.epos);
				var ev = mk(TLocal(v), v.vType, e.epos);
				var binding = makeBindGen(v, v.vPos, e, BindDeferred);
				sub = new Subject(ev, binding);
				bs.push(binding);
				lut.unshift({e: e, subject: sub, i: i});
			} else {
				i = found.i;
				sub = found.subject;
			}
			ss.push(sub);
			result.push({
				caseData: row.caseData,
				bindings: bindings,
				// For the patterns, generate `[_, ..., extractorPatternI, ..., _]
				patterns: makeOffsetList(i, count - i, ex.exPattern, any).ofArray(tail)
			});
		}
		/* At the end of all this we have something like this:
			var _hx_tmp1 = extractorLhs1(subject);
			var _hx_tmpN = extractorLhsN(subject);
			switch [subject, _hx_tmp1, _hx_tmpN] {
				case [normalSubjectMatch, _, _]:
				case [_, extractorRhs1, _]:
				case [_, _, extractorRhsN]:
			}
		*/
		var dt = compileRows(m, Cons(new Subject(subject, null), ss.ofArray(subjects)), result);
		return bind(m, bs, dt);
	}

	public static function compile(ctx:Typer, debug:Bool, expressions:Array<TExpr>, cases:Array<CaseRow>, p:Pos):DecisionTreeData {
		var m:MatcherContext = {
			ctx: ctx,
			matchDebug: debug,
			dtTable: new haxe.ds.IntMap(),
			matchPos: p,
			dtCount: 0
		};
		var subjects = [], vars = [];
		for (e in expressions) switch e.eexpr {
			case TConst(_) | TLocal(_):
				subjects.push(new Subject(e, null));
			case _:
				var v = genLocal(ctx, e.etype, e.epos);
				var ev = mk(TLocal(v), e.etype, e.epos);
				var b = makeBind(v, e.epos, e);
				subjects.push(new Subject(ev, b));
				vars.push(b);
		}
		if (cases.length == 0 && subjects.length > 0) {
			var dt = fail(m, subjects[0].getPos());
			return switchTree(m, subjects[0].getExpr(), [], dt);
		}
		var dt = compileRows(m, subjects.ofArray(), cases);
		Useless.check(ctx, cases);
		return vars.length == 0 ? dt : bind(m, vars, dt);
	}
}
