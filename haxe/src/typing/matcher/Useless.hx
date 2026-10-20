package typing.matcher;

import core.Message;
import core.Globals;
import core.Globals.Pos;
import typing.matcher.Pattern;
import typing.matcher.Constructor;
import typing.matcher.Case;
import context.Typecore;
import core.ds.MlList;

using core.ds.MlList.MlListTools;

/*
	Implements checks for useless patterns based on http://moscova.inria.fr/~maranget/papers/warn/index.html.
*/

enum UselessResult {
	False;
	Pos(pos:Pos);
	True;
}

// port: upstream's pattern lists and matrices (lists of rows), as OCaml lists
typedef PatternRow = MlList<PatternData>;
typedef PatternMatrix = MlList<PatternRow>;

@:structInit class LocatedUseless {
	public var result:UselessResult;
	public var pos:Pos;

	public inline function new(result:UselessResult, pos:Pos) {
		this.result = result;
		this.pos = pos;
	}

	public inline function clone():LocatedUseless return new LocatedUseless(result, pos);
}

class Useless {
	// U part

	public static function specialize(isTuple:Bool, con:ConstructorData, pM:PatternMatrix):PatternMatrix {
		var acc:PatternMatrix = Nil;
		while (true) switch pM {
			case Cons(patterns, rest):
				pM = rest;
				switch patterns {
					case Cons({kind: PatConstructor(con2, patterns1)}, patterns2) if (!isTuple && Constructor.equal(con, con2)):
						acc = Cons(patterns1.ofArray(patterns2), acc);
					case Cons({kind: PatTuple(patterns1)}, patterns2) if (isTuple):
						acc = Cons(patterns1.ofArray(patterns2), acc);
					case Cons({kind: PatAny, pos: p}, patterns2):
						acc = Cons(MlListTools.make(Constructor.arity(con), ({kind: PatAny, pos: p} : PatternData), patterns2), acc);
					case Cons({kind: PatBind(_, pat1)}, patterns2):
						pM = Cons(Cons(pat1, patterns2), pM);
					case _:
				}
			case Nil:
				return acc.rev();
		}
	}

	public static function defaultMatrix(pM:PatternMatrix):PatternMatrix {
		var acc:PatternMatrix = Nil;
		while (true) switch pM {
			case Cons(patterns, rest):
				pM = rest;
				switch patterns {
					case Cons({kind: PatBind(_, {kind: PatAny}) | PatAny}, patterns):
						acc = Cons(patterns, acc);
					case _:
				}
			case Nil:
				return acc.rev();
		}
	}

	public static function u(pM:PatternMatrix, q:PatternRow):Bool {
		return switch [q, pM] {
			case [Nil, Nil]: true;
			case [Nil, _]: false;
			case [Cons(q1, ql), _]:
				function loop(pat:PatternData):Bool return switch pat.kind {
					case PatConstructor(con, patterns): u(specialize(false, con, pM), patterns.ofArray(ql));
					case PatTuple(patterns): u(specialize(true, {kind: ConConst(TNull), pos: pat.pos}, pM), patterns.ofArray(ql));
					case PatAny: u(defaultMatrix(pM), ql);
					case PatOr(pat1, pat2): u(pM, Cons(pat1, ql)) || u(pM, Cons(pat2, ql));
					case PatBind(_, pat1): loop(pat1);
					case PatExtractor(_): true; // ?
				};
				loop(q1);
		};
	}

	// U' part

	public static function transferColumn(source:PatternMatrix, target:PatternMatrix):{source:PatternMatrix, target:PatternMatrix} {
		var from:PatternMatrix = Nil, into:PatternMatrix = Nil;
		while (true) switch [source, target] {
			case [Cons(patterns1, s), Cons(patterns2, t)]:
				switch patterns1 {
					case Cons(pat, patterns):
						from = Cons(patterns, from);
						into = Cons(Cons(pat, patterns2), into);
					case Nil:
				}
				source = s;
				target = t;
			case [Nil, Nil]:
				return {source: from.rev(), target: into.rev()};
			case _:
				throw "Invalid_argument: List.fold_left2";
		}
	}

	public static function copy(p:PatternMatrix):PatternMatrix {
		var acc:PatternMatrix = Nil;
		while (true) switch p {
			case Cons(_, rest):
				acc = Cons(Nil, acc);
				p = rest;
			case Nil:
				return acc;
		}
	}

	public static function specializePrime(isTuple:Bool, con:ConstructorData, pM:PatternMatrix, qM:PatternMatrix,
			rM:PatternMatrix):{p:PatternMatrix, q:PatternMatrix, r:PatternMatrix} {
		var arity = Constructor.arity(con);
		var pAcc:PatternMatrix = Nil,
			qAcc:PatternMatrix = Nil,
			rAcc:PatternMatrix = Nil;
		while (true) switch [pM, qM, rM] {
			case [Cons(p1, pRest), Cons(q1, qRest), Cons(r1, rRest)]:
				pM = pRest;
				qM = qRest;
				rM = rRest;
				inline function add(patterns:PatternRow):Void {
					pAcc = Cons(patterns, pAcc);
					qAcc = Cons(q1, qAcc);
					rAcc = Cons(r1, rAcc);
				}
				var row = p1;
				while (true) {
					switch row {
						case Cons({kind: PatConstructor(con2, patterns1)}, patterns2) if (!isTuple && Constructor.equal(con, con2)):
							add(patterns1.ofArray(patterns2));
						case Cons({kind: PatTuple(patterns1)}, patterns2) if (isTuple):
							add(patterns1.ofArray(patterns2));
						case Cons({kind: PatAny, pos: p}, patterns2):
							add(MlListTools.make(arity, ({kind: PatAny, pos: p} : PatternData), patterns2));
						case Cons({kind: PatOr(pat1, pat2)}, patterns2):
							pM = Cons(Cons(pat1, patterns2), Cons(Cons(pat2, patterns2), pM));
							qM = Cons(q1, Cons(q1, qM));
							rM = Cons(r1, Cons(r1, rM));
						case Cons({kind: PatBind(_, pat1)}, patterns2):
							row = Cons(pat1, patterns2);
							continue;
						case _:
					}
					break;
				}
			case [Nil, _, _]:
				return {p: pAcc.rev(), q: qAcc.rev(), r: rAcc.rev()};
			case _:
				throw "Invalid pattern matrices";
		}
	}

	public static function combine(et1:LocatedUseless, et2:LocatedUseless):UselessResult return switch [et1.result, et2.result] {
		case [True, True]: True;
		case [False, False]: False;
		case [True, False]: Pos(et2.pos);
		case [False, True]: Pos(et1.pos);
		case [True, Pos(_)]: et2.result;
		case [Pos(_), True]: et1.result;
		case [False, Pos(_)]: Pos(et1.pos);
		case [Pos(_), _]: et1.result;
	};

	public static function uPrime(pM:PatternMatrix, qM:PatternMatrix, rM:PatternMatrix, p:PatternRow, q:PatternRow, r:PatternRow):UselessResult {
		switch p {
			case Nil:
				switch r {
					case Nil:
						return u(qM, q) ? True : False;
					case _:
						var i = 0, et = True;
						for (pat in r) switch pat.kind {
							case PatOr(pat1, pat2):
								function processRow(i:Int, l:PatternRow, q:PatternRow):{pattern:PatternData, rest:PatternRow} {
									var acc = Nil, k = 0;
									while (true) switch l {
										case Cons(x, l1) if (i == k):
											return {pattern: x, rest: acc.rev().append(l1.append(q))};
										case Cons(x, l1):
											acc = Cons(x, acc);
											k++;
											l = l1;
										case Nil:
											throw "Invalid pattern column";
									}
								}
								var col:PatternMatrix = Nil, mat:PatternMatrix = Nil, rs = rM, qs = qM;
								while (true) switch [rs, qs] {
									case [Cons(r1, rRest), Cons(q1, qRest)]:
										var processed = processRow(i, r1, q1);
										col = Cons(Cons(processed.pattern, Nil), col);
										mat = Cons(processed.rest, mat);
										rs = rRest;
										qs = qRest;
									case [Nil, Nil]:
										break;
									case _:
										throw "Invalid_argument: List.fold_left2";
								}
								col = col.rev();
								mat = mat.rev();
								var rest = processRow(i, r, q).rest;
								var et1 = uPrime(col, mat, copy(mat), Cons(pat1, Nil), rest, Nil);
								var qM2 = mat.append(Cons(rest, Nil));
								var et2 = uPrime(col.append(Cons(Cons(pat1, Nil), Nil)), qM2, copy(qM2), Cons(pat2, Nil), rest, Nil);
								var et3 = combine({result: et1, pos: pat1.pos}, {result: et2, pos: pat2.pos});
								var pos = core.Ast.punion(pat1.pos, pat2.pos);
								et = combine({result: et, pos: pos}, {result: et3, pos: pos});
								i++;
							case _:
								throw "Expected or-pattern";
						}
						return et;
				}
			case Cons(pat, pl):
				function loop(pat:PatternData):UselessResult return switch pat.kind {
					case PatConstructor(con, patterns):
						var m = specializePrime(false, con, pM, qM, rM);
						uPrime(m.p, m.q, m.r, patterns.ofArray(pl), q, r);
					case PatTuple(patterns):
						var m = specializePrime(true, {kind: ConConst(TNull), pos: pat.pos}, pM, qM, rM);
						uPrime(m.p, m.q, m.r, patterns.ofArray(pl), q, r);
					case PatAny:
						var m = transferColumn(pM, qM);
						uPrime(m.source, m.target, rM, pl, Cons(pat, q), r);
					case PatOr(_, _):
						var m = transferColumn(pM, rM);
						uPrime(m.source, qM, m.target, pl, q, Cons(pat, r));
					case PatBind(_, pat1): loop(pat1);
					case PatExtractor(_): True;
				};
				return loop(pat);
		}
	}

	// Sane part

	public static function checkCase(ctx:context.Typecore.Typer, previous:Array<CaseRow>, row:CaseRow):Void {
		var matrix = MlListTools.ofArray(previous.map(function(row) return row.patterns));
		switch uPrime(matrix, copy(matrix), copy(matrix), row.patterns, Nil, Nil) {
			case False:
				Typecore.warning(ctx, WUnusedPattern, "This case is unused", row.caseData.casePos);
			case Pos(p):
				Typecore.warning(ctx, WUnusedPattern, "This pattern is unused", p);
			case True:
		}
	}

	public static function check(ctx:context.Typecore.Typer, cases:Array<CaseRow>):Void {
		var acc:Array<CaseRow> = [];
		for (row in cases) {
			checkCase(ctx, acc, row);
			if (row.caseData.caseGuard == null) acc.push(row);
		}
	}
}
