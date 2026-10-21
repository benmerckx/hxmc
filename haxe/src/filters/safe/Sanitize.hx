package filters.safe;

import core.Globals.Platform;
import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.TOther.ExtType;
import core.Meta;
import core.Abstract;
import core.Error;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// ----------------------------------------------------------------------
// SANITIZE

/*
	makes sure that when an AST get generated to source code, it will not
	generate expressions that evaluate differently. It is then necessary to
	add parenthesises around some binary expressions when the AST does not
	correspond to the natural operand priority order for the platform
*/
class Sanitize {
	/*
		this is the standard C++ operator precedence, which is also used by both JS and PHP
	*/
	public static function standardPrecedence(op:Binop):{priority:Int, left:Bool} {
		return switch op {
			case OpIn: {priority: 4, left: false};
			case OpMult | OpDiv | OpMod: {priority: 5, left: true};
			case OpAdd | OpSub: {priority: 6, left: true};
			case OpShl | OpShr | OpUShr: {priority: 7, left: true};
			case OpLt | OpLte | OpGt | OpGte: {priority: 8, left: true};
			case OpEq | OpNotEq: {priority: 9, left: true};
			case OpAnd: {priority: 10, left: true};
			case OpXor: {priority: 11, left: true};
			case OpOr: {priority: 12, left: true};
			case OpInterval: {priority: 13, left: false}; // haxe specific
			case OpBoolAnd: {priority: 14, left: true};
			case OpBoolOr: {priority: 15, left: true};
			case OpArrow: {priority: 16, left: true};
			case OpNullCoal: {priority: 17, left: false};
			case OpAssignOp(OpAssign): {priority: 18, left: false}; // mimics ?:
			case OpAssign | OpAssignOp(_): {priority: 19, left: false};
		};
	}

	public static function needParent(e:TExpr):Bool {
		return switch e.eexpr {
			case TConst(_) | TLocal(_) | TArray(_, _) | TField(_, _) | TEnumParameter(_, _, _) | TEnumIndex(_) | TParenthesis(_) |
				TCall(_, _) | TNew(_, _, _) | TTypeExpr(_) | TObjectDecl(_) | TArrayDecl(_) | TIdent(_): false;
			case TCast(e, null) | TMeta(_, e): needParent(e);
			case _: true;
		};
	}

	// port: sanitize_expr's local helpers; static so each call does not allocate closures.
	static function parent(e:TExpr):TExpr return switch e.eexpr {
		case TParenthesis(_): e;
		case _: TypeOps.mk(TParenthesis(e), e.etype, e.epos);
	};

	static function block(e:TExpr):TExpr return switch e.eexpr {
		case TBlock(_): e;
		case _: TypeOps.mk(TBlock(vector(e)), e.etype, e.epos);
	};

	// complex expressions are the one that once generated to source consists in several expressions
	static function complex(e:TExpr):TExpr return switch e.eexpr {
		case TVar(_, _) // needs to be put into blocks
			| TCall({eexpr: TIdent("__js__")}, _): // we never know
			block(e);
		case _: e;
	};

	// tells if the printed expresssion ends with an if without else
	static function hasIf(e:TExpr):Bool return switch e.eexpr {
		case TIf(_, _, null): true;
		case TWhile(_, body, NormalWhile): hasIf(body);
		case _: false;
	};

	public static function sanitizeExpr(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		var def:TExprDef = switch e.eexpr {
			case TConst(TNull):
				if (scom.platformConfig.pfStatic && !TypeOps.isNullable(e.etype)) {
					function loop(t:T):TExpr {
						return switch TypeOps.follow(t) {
							case TMono(_) // in these cases the null will cast to default value
							| TFun(_): // this is a bit a particular case, maybe flash-specific actually
								e;
							case TAbstract(a, tl) if (Meta.has(FromNull, a.aMeta)): TypeOps.mk(TCast(e, null), e.etype, e.epos);
							// TODO: this should use get_underlying_type, but we do not have access to Codegen here.
							case TAbstract(a, tl) if (!Meta.has(CoreType, a.aMeta)): loop(TypeOps.applyParams(a.aParams, tl, a.aThis));
							case _ if (scom.platform == Cross): e;
							case _: Error.raiseTypingError("On static platforms, null can't be used as basic type "
									+ core.TPrinting.sType(core.TPrinting.printContext(), e.etype),
									e.epos);
						};
					}
					return loop(e.etype);
				} else return e;
			case TBinop(op, e1, e2):
				inline function swap(op1:Binop, op2:Binop):Bool {
					var p1 = standardPrecedence(op1);
					var p2 = standardPrecedence(op2);
					return p1.left && p1.priority <= p2.priority;
				}
				function loop(ee:TExpr, left:Bool):Bool return switch ee.eexpr {
					case TBinop(op2, _, _): left ? !swap(op2, op) : swap(op, op2);
					case TIf(_, _, _): left ? !swap(OpAssignOp(OpAssign), op) : swap(op, OpAssignOp(OpAssign));
					case TCast(inner, null) | TMeta(_, inner): loop(inner, left);
					case TConst(TInt(i)) if (!left): (op == OpAdd || op == OpSub) && i < 0;
					case TConst(TFloat(flt)) if (!left): (op == OpAdd || op == OpSub) && flt.charAt(0) == "-";
					case _: false;
				};
				TBinop(op, loop(e1, true) ? parent(e1) : e1, loop(e2, false) ? parent(e2) : e2);
			case TUnop(Not, Prefix, {eexpr: TUnop(Not, Prefix, e1) | TParenthesis({eexpr: TUnop(Not, Prefix, e1)})})
				if (ExtType.isBool(Abstract.followWithAbstractsWithoutNull(e1.etype))): return e1;
			case TUnop(op, mode, e1):
				function loop(ee:TExpr):TExpr return switch ee.eexpr {
					case TConst(TInt(i)) if (op == Neg && i < 0): parent(e1);
					case TConst(TFloat(flt)) if (op == Neg && flt.charAt(0) == "-"): parent(e1);
					case TBinop(_, _, _) | TIf(_, _, _) | TUnop(_, _, _): parent(e1);
					case TCast(inner, null) | TMeta(_, inner): loop(inner);
					case _: e1;
				};
				TUnop(op, mode, loop(e1));
			case TIf(e1, e2, eelse):
				var isIf = switch e2.eexpr {
					case TIf(_, _, _): true;
					case _: false;
				};
				TIf(parent(e1), (eelse != null && hasIf(e2)) || isIf ? block(e2) : complex(e2), eelse == null ? null : complex(eelse));
			case TWhile(e1, e2, flag): TWhile(parent(e1), complex(e2), flag);
			case TFunction(f):
				var body = switch f.tfExpr.eexpr {
					case TBlock(exprs):
						if (ExtType.isVoid(TypeOps.follow(f.tfType)) && exprs.length > 0) switch exprs[exprs.length - 1].eexpr {
							case TReturn(null): TypeOps.mk(TBlock(exprs.slice(0, exprs.length - 1)), f.tfExpr.etype, f.tfExpr.epos);
							case _: f.tfExpr;
						} else f.tfExpr;
					case _: block(f.tfExpr);
				};
				TFunction({tfArgs: f.tfArgs, tfType: f.tfType, tfExpr: body});
			case TCall(e2, args): if (needParent(e2)) TCall(parent(e2), args); else return e;
			case TEnumParameter(e2, ef, i): if (needParent(e2)) TEnumParameter(parent(e2), ef, i); else return e;
			case TEnumIndex(e2): if (needParent(e2)) TEnumIndex(parent(e2)); else return e;
			case TField(e2, f): if (needParent(e2)) TField(parent(e2), f); else return e;
			case TArray(e1, e2): if (needParent(e1)) TArray(parent(e1), e2); else return e;
			case TTry(e1, catches): TTry(block(e1), catches.map(c -> {variable: c.variable, expr: block(c.expr)}));
			case TSwitch(sw):
				TSwitch({
					switchSubject: parent(sw.switchSubject),
					switchCases: sw.switchCases.map(c -> ({
						casePatterns: c.casePatterns,
						caseExpr: complex(c.caseExpr)
					} : core.TType.TSwitchCase)),
					switchDefault: sw.switchDefault == null ? null : complex(sw.switchDefault),
					switchExhaustive: sw.switchExhaustive
				});
			case _: return e;
		};
		return {eexpr: def, etype: e.etype, epos: e.epos};
	}

	// port: `com` is polymorphic and unused upstream.
	public static function reduceExpr<C>(com:C, e:TExpr):TExpr {
		return switch e.eexpr {
			case TBlock(l) if (l.length == 0): e;
			case TBlock(l):
				var ec = l[l.length - 1];
				// remove all no-ops : not-final constants in blocks
				var rest = [];
				for (i in 0...l.length - 1) switch l[i].eexpr {
					case TConst(_) | TBlock([]) | TObjectDecl([]):
					case _: rest.push(l[i]);
				}
				if (rest.length == 0) ec; else {
					rest.push(ec);
					TypeOps.mk(TBlock(haxe.ds.Vector.fromArrayCopy(rest)), e.etype, e.epos);
				}
			case TParenthesis(ec): {eexpr: ec.eexpr, etype: ec.etype, epos: e.epos};
			case TTry(body, []): body;
			case _: e;
		};
	}

	public static function sanitize(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		return sanitizeExpr(scom, reduceExpr(scom.platformConfig, core.Texpr.mapExprWithScom(sanitize, scom, e)));
	}
}
