package typing.matcher;

import core.TType;
import core.Globals.Pos;
import core.Texpr;
import core.TPrinting;
import typing.matcher.Bind;
import typing.matcher.Case;
import typing.matcher.Constructor;

enum TypeFiniteness {
	Infinite; // type has inifite constructors (e.g. Int, String)
	CompileTimeFinite; // type is considered finite only at compile-time but has inifite possible run-time values (enum abstracts)
	RunTimeFinite; // type is truly finite (Bool, enums)
}

// How a switch tests its scrutinee.
enum MatchKind {
	SKValue; // against constants, statics and types
	SKEnum; // by the index of its enum constructor
	SKLength(aa:typing.ArrayAccess.ArrayAccessData); // by its length, read the way this says (#8012)
}

// What a switch examines: a subject's expression and what the switch makes of it, see Subject.make_scrutinee.
@:structInit class Scrutinee {
	public var scrExpr:TExpr;
	public var scrKind:MatchKind;
	public var scrFiniteness:TypeFiniteness;
	public var scrConstructors:Array<ConstructorData>; // the constructors of its type
	public var scrNullable:Bool;

	public inline function new(scrExpr:TExpr, scrKind:MatchKind, scrFiniteness:TypeFiniteness, scrConstructors:Array<ConstructorData>,
			scrNullable:Bool) {
		this.scrExpr = scrExpr;
		this.scrKind = scrKind;
		this.scrFiniteness = scrFiniteness;
		this.scrConstructors = scrConstructors;
		this.scrNullable = scrNullable;
	}
}

enum DecisionTreeKind {
	Leaf(caseData:CaseData);
	Switch(scrutinee:Scrutinee, cases:Array<DecisionSwitchCase>, defaultTree:DecisionTreeData);
	Bind(bindings:Array<Bind>, tree:DecisionTreeData);
	Guard(expr:TExpr, thenTree:DecisionTreeData, elseTree:DecisionTreeData);
	GuardNull(expr:TExpr, thenTree:DecisionTreeData, elseTree:DecisionTreeData);
	Fail;
}

@:structInit class DecisionTreeData {
	public var dtT:DecisionTreeKind;
	public var dtI:Int;
	public var dtPos:Pos;
	public var dtGotoTarget:Bool;
	public var dtTexpr:Null<TExpr>;

	public inline function new(dtT:DecisionTreeKind, dtI:Int, dtPos:Pos, dtGotoTarget:Bool, dtTexpr:Null<TExpr>) {
		this.dtT = dtT;
		this.dtI = dtI;
		this.dtPos = dtPos;
		this.dtGotoTarget = dtGotoTarget;
		this.dtTexpr = dtTexpr;
	}

	public inline function clone():DecisionTreeData return new DecisionTreeData(dtT, dtI, dtPos, dtGotoTarget, dtTexpr);
}

@:structInit class DecisionSwitchCase {
	public var scCon:ConstructorData;
	public var scUnguarded:Bool;
	public var scDt:DecisionTreeData;

	public inline function new(scCon:ConstructorData, scUnguarded:Bool, scDt:DecisionTreeData) {
		this.scCon = scCon;
		this.scUnguarded = scUnguarded;
		this.scDt = scDt;
	}

	public inline function clone():DecisionSwitchCase return new DecisionSwitchCase(scCon, scUnguarded, scDt);
}

class DecisionTree {
	public static function makeBindGen(v:TVar, p:Pos, e:TExpr, s:BindStatus):Bind return {
		bVar: v,
		bPos: p,
		bExpr: e,
		bStatus: s
	};

	public static function makeBind(v:TVar, p:Pos, e:TExpr):Bind return makeBindGen(v, p, e, BindUsed);

	public static function sMatchKind(k:MatchKind):String return switch k {
		case SKValue: "value";
		case SKEnum: "enum";
		case SKLength(_): "length";
	};

	public static final tabString = "    ";

	public static function toString(dt:DecisionTreeData):String {
		var buf = new StringBuf(), indices:Array<Int> = [];
		inline function addLine(tabs:String, s:String):Void {
			if (buf.length > 0) buf.add("\n");
			if (indices.length > 0) {
				buf.add(StringTools.lpad(Std.string(indices.pop()), " ", 2));
				buf.add(tabs.substr(0, tabs.length - 2));
			} else buf.add(tabs);
			buf.add(s);
		}
		inline function sExpr(tabs:String, e:TExpr):String return TPrinting.sExprPretty(true, tabs, false, MatcherGlobals.sType, e);
		inline function printExprNoblock(tabs:String, e:TExpr):Void switch e.eexpr {
			case TBlock(el):
				for (e in el) addLine(tabs, sExpr(tabs, e));
			case _:
				addLine(tabs, sExpr(tabs, e));
		};
		var loop:String->DecisionTreeData->Void = null;
		inline function printGuard(tabs:String, e:TExpr, dt1:DecisionTreeData, dt2:DecisionTreeData, isNullGuard:Bool):Void {
			addLine(tabs, "if (");
			buf.add(sExpr(tabs, e));
			if (isNullGuard) buf.add(" == null");
			buf.add(")");
			loop(tabs + tabString, dt1);
			addLine(tabs, "else");
			loop(tabs + tabString, dt2);
		}
		loop = function(tabs, dt) {
			indices.push(dt.dtI);
			switch dt.dtT {
				case Leaf(caseData):
					if (caseData.caseExpr != null) printExprNoblock(tabs, caseData.caseExpr);
				case Switch(scrutinee, cases, defaultTree):
					addLine(tabs, "switch " + sMatchKind(scrutinee.scrKind) + " (" + sExpr(tabs, scrutinee.scrExpr) + ")");
					for (sc in cases) {
						addLine(tabs + tabString, "case ");
						buf.add(Constructor.toString(sc.scCon));
						buf.add(sc.scUnguarded ? "(unguarded)" : "guarded");
						buf.add(":");
						loop(tabs + tabString + tabString, sc.scDt);
					}
					addLine(tabs + tabString, "default");
					loop(tabs + tabString + tabString, defaultTree);
				case Bind(bl, tree):
					for (bind in bl) {
						addLine(tabs, "var ");
						buf.add(bind.bVar.vName + "<" + bind.bVar.vId + "> = ");
						buf.add(sExpr(tabs, bind.bExpr));
						switch bind.bStatus {
							case BindUnused: buf.add(" // unused");
							case BindDeferred: buf.add(" // deferred");
							case BindUsed:
						}
					}
					loop(tabs, tree);
				case Guard(e, dt1, dt2):
					printGuard(tabs, e, dt1, dt2, false);
				case GuardNull(e, dt1, dt2):
					printGuard(tabs, e, dt1, dt2, true);
				case Fail:
					addLine(tabs, "<fail>");
			}
		};
		loop(tabString, dt);
		return buf.toString();
	}

	public static function equalDt(dt1:DecisionTreeData, dt2:DecisionTreeData):Bool return dt1.dtI == dt2.dtI;

	public static function equalBindExpr(e1:TExpr, e2:TExpr):Bool return Texpr.equal(e1, e2);

	// port: Ast.safe_for_all2, inlined
	static inline function all2<A>(f:A->A->Bool, a:Array<A>, b:Array<A>):Bool {
		var r = a.length == b.length;
		if (r) for (i in 0...a.length) if (!f(a[i], b[i])) {
			r = false;
			break;
		}
		return r;
	}

	public static function equal(dt1:DecisionTreeKind, dt2:DecisionTreeKind):Bool return switch [dt1, dt2] {
		case [Leaf(c1), Leaf(c2)]: c1 == c2;
		case [Switch(s1, c1, d1), Switch(s2, c2, d2)]:
			// What the switch makes of its scrutinee follows from the expression and the cases.
			Texpr.equal(s1.scrExpr, s2.scrExpr) && all2(function(a:DecisionSwitchCase,
					b:DecisionSwitchCase) return Constructor.equal(a.scCon, b.scCon) && a.scUnguarded == b.scUnguarded
					&& equalDt(a.scDt, b.scDt),
				c1, c2) && equalDt(d1, d2);
		case [Bind(l1, d1), Bind(l2, d2)]: all2(function(a:typing.matcher.Bind.Bind,
					b:typing.matcher.Bind.Bind) return a.bVar == b.bVar && equalBindExpr(a.bExpr, b.bExpr),
				l1, l2) && equalDt(d1, d2);
		case [Fail, Fail]: true;
		case [Guard(e1, d11, d12), Guard(e2, d21, d22)] | [GuardNull(e1, d11, d12), GuardNull(e2, d21, d22)]: e1 == e2 && equalDt(d11,
				d21) && equalDt(d12, d22);
		case _: false;
	};

	// port: the tuple (scr_expr, cases, dt) is hashed as an array.
	public static function hash(dt:DecisionTreeKind):Int return switch dt {
		case Switch(scrutinee, cases, d):
			core.ds.Hashtbl.hash(([scrutinee.scrExpr, cases, d] : Array<Dynamic>));
		case _:
			core.ds.Hashtbl.hash(dt);
	};
}
