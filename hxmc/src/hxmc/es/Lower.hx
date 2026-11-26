package hxmc.es;

import haxe.ds.Vector;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TOther.ExtType;
import core.Meta;
import core.Error;
import core.Texpr;
import generators.Gctx;
import generators.Genjs;
import hxmc.es.Es;
import hxmc.es.Es.EsTools.*;

using core.ds.VectorTools;

// What a lowering needs from the program, which it may not change (lowerings run in parallel): its answers are
// references (Ref) Chunk resolves as it prints, and what the lowering used, recorded (Chunk.Unit, which Chunk replays
// in the program's order once all are lowered: the files' imports, the runtime's parts, the names in use).
interface Resolve {
	// a type as a value (its binding, an extern's native path)
	function type(t:ModuleType, p:Pos):Ex;
	// a type found by its path (js.Boot, haxe.Log), as a value
	function typeByPath(pack:Array<String>, name:String, p:Pos):Ex;
	function moduleField(m:ModuleDef, f:TClassField, p:Pos):Ex;
	// `$hx.<name>`, the runtime's
	function rt(name:String):Ex;
	// an enum value's index's key: `$hx.index`, TypeScript's binding of it
	function index():Ex;
	// an untyped name (TIdent, js.Syntax.construct's): a global, or one of Genjs's runtime names
	function ident(name:String):Ex;
	// untyped code's text: Genjs's runtime names in it replaced by the runtime's
	function rawText(code:String):String;
	function feature(f:String):Bool;
	// a static field the code uses, by its dot path (what reflection the program needs: Rtti)
	function refer(path:String):Void;
	// whether c is an extern of the std's (TypeScript: not declared by _externs.d.ts)
	function stdExtern(c:TClass):Bool;
	// the split (js.Bundle.split) e calls, if it calls one
	function split(e:TExpr):Null<Splits.SplitPoint>;
	// a split's key in the runtime's table of their files (its name, its number when minified)
	function splitKey(name:String):Ex;
	// (modules) the file of a split's code, which is lowered where it is called, its bindings that file's: f's value
	function inSplit<R>(s:Splits.SplitPoint, f:Int->R):R;
	// whether a split's code is where it is called (modules), not in a file the runtime loads
	function splitsInline():Bool;
	// a field's code (e) begins (its locals are named apart from other fields', minified; FieldNames reads it), a local of it
	function enterScope(e:TExpr):Void;
	function declare(s:Sym):Void;
	// whether the output is TypeScript (casts where Haxe accepted what TypeScript would not)
	function ts():Bool;
	// (Properties) a call of a method of an accessor's name (args: its arguments; discarded: its value used for nothing), one
	// taken as a value; a field's name read dynamically; a string constant
	function accessorCall(a:TClassField, args:Int, discarded:Bool):Void;
	function accessorTaken(a:TClassField):Void;
	function dynamicName(n:String):Void;
	function stringConst(s:String):Void;
	// (Properties) a property's storage read or written by the code of class `by` (null: code outside any class's body)
	function storage(p:TClassField, by:Null<TClass>):Void;
	// (Properties) a value reflection reads the fields of (Reflect.fields, JSON.stringify: FieldNames.READS), of its type
	function reflected(t:T):Void;
}

// A typed expression (post-filter) as JavaScript. Decides what depends on the code alone: arrows (a function
// without its own `this`, `super`, `arguments`), `this` for `_gthis` where only arrows use it, `const` for
// locals never assigned again, statements where a value is expected (in place where assigned, declared or
// returned, else an arrow called in place), enums (`new E.C(...)`, `x[$hx.index]`, parameters by name).
class Lower {
	final com:Gctx;
	final r:Resolve;
	final locals = new Map<Int, Sym>();
	// locals assigned after their declaration (`let`)
	var assigned = new Map<Int, Bool>();
	// (TypeScript) locals of opaque abstracts computed with (`x++`, `x |= y`): `any`
	final computed = new Map<Int, Bool>();
	// locals that are `this` (`_gthis` where only arrows use it)
	final thisAliases = new Map<Int, Bool>();
	var catchVars:Array<Ex> = [];
	// (TypeScript) whether to cast, the class whose code it is (what it may read of others' protected fields), the
	// return type of the function lowered
	final ts:Bool;
	// (es-modules: an abstract's constructor `A.new`, its implementation the abstract's object: staticName)
	final modules:Bool;
	public var cls:Null<TClass> = null;
	// (TypeScript) the class whose constructor is lowered (`readonly` fields written there as they are), the functions' depth
	public var ctorOf:Null<TClass> = null;
	var depth = 0;
	var retType:Null<T> = null;

	public function new(com:Gctx, r:Resolve) {
		this.com = com;
		this.r = r;
		this.ts = r.ts();
		this.modules = Gctx.definedValueSafe(com, "hxmc.js") == "es-modules";
	}

	// a static's name in the output: an abstract's constructor's `new` (es-modules: `A.new(...)`, as Haxe writes `new A(...)`;
	// the typer's `_hx_new` elsewhere)
	public static function staticName(modules:Bool, c:TClass, f:TClassField):String
		return modules && c.clKind.match(KAbstractImpl(_)) && hasClassFieldFlag(f, CfAbstractConstructor) ? "new" : f.cfName;

	// ------------------------------------------------------------------ entry points

	// a field's code (method, initializer, `__init__`, the main expression): what it assigns first
	public function prepare(e:TExpr) {
		r.enterScope(e);
		function walk(e:TExpr) {
			switch e.eexpr {
				case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, _) | TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
					assigned.set(v.vId, true);
					// (TypeScript: computed with, an opaque abstract's local is `any`: `(x as any)` is no target)
					if (ts && !e.eexpr.match(TBinop(OpAssign, _, _)) && Casts.opaque(v.vType)) computed.set(v.vId, true);
				case _:
			}
			Texpr.iter(walk, e);
		}
		walk(e);
	}

	// t: the function's type (its optional arguments), tparams: a method's type parameters
	public function func(f:TFunc, canArrow:Bool, p:Pos, ?t:T, ?tparams:TypeParams):Fn {
		depth++;
		var r = funcIn(f, canArrow, p, t, tparams);
		depth--;
		return r;
	}

	function funcIn(f:TFunc, canArrow:Bool, p:Pos, ?t:T, ?tparams:TypeParams):Fn {
		var arrow = canArrow && !hasOwnThis(f);
		var params = [for (a in f.tfArgs) local(a.variable)];
		var n = f.tfArgs.length;
		var last = n > 0 ? f.tfArgs[n - 1] : null;
		var rest = last != null && last.defaultValue == null && ExtType.isRest(follow(last.variable.vType));
		// (TypeScript: optional from the first one with a default or optional in its type, nothing required after it)
		var optFrom:Null<Int> = null;
		var sig = t == null ? null : switch follow(t) {
			case TFun(s): s;
			case _: null;
		}
		for (i in 0...n) if (optFrom == null && !(rest && i == n - 1)
			&& (f.tfArgs[i].defaultValue != null || (sig != null && i < sig.args.length && sig.args[i].optional)))
			optFrom = i;
		var oldRet = retType;
		retType = f.tfType;
		var body:Array<St> = [];
		// (a default: `a ??= v`, Haxe's (a null argument takes it too))
		for (a in f.tfArgs) switch a.defaultValue {
			case null | {eexpr: TConst(TNull)}:
			case d: body.push(st(SExpr(ex(EAssign("??=", ex(EId(local(a.variable))), expr(d))))));
		}
		var oldCatch = catchVars;
		catchVars = [];
		aliasThis(f.tfExpr);
		stmt(f.tfExpr, body);
		catchVars = oldCatch;
		retType = oldRet;
		return {
			params: params,
			rest: rest,
			body: body,
			arrow: arrow,
			ret: f.tfType,
			tparams: tparams,
			optFrom: optFrom,
			thisAny: canArrow && !arrow,
			pos: p
		};
	}

	public function statements(e:TExpr):Array<St> {
		var out = [];
		aliasThis(e);
		stmt(e, out);
		return out;
	}

	// ------------------------------------------------------------------ (TypeScript) narrowing

	// what the tests on a local enum value's index established, as TypeScript narrows by them: the indexes it may
	// have; `dead`: TypeScript has it as `never` (a test Haxe's matcher repeats where an enclosing one decided it), its
	// index and arguments read as `any`
	var possible = new Map<Int, Array<Int>>();
	var dead = new Map<Int, Bool>();

	static function enumLocal(x:TExpr):Null<TVar> return switch Texpr.skip(x).eexpr {
		case TLocal(v) if (narrowable(x)): v;
		case _: null;
	}

	function isKnown(x:TExpr, k:Int):Bool {
		var v = enumLocal(x);
		if (v == null || dead.exists(v.vId)) return false;
		var p = possibleOf(v);
		return p.length == 1 && p[0] == k;
	}

	function isDead(x:TExpr):Bool {
		var v = enumLocal(x);
		return v != null && dead.exists(v.vId);
	}

	static function refined(v:TVar, t:T):Bool return switch [follow(v.vType), follow(t)] {
		case [TEnum(a, pa), TEnum(b, pb)]: a == b && pa.length > 0 && !core.TUnification.fastEq(v.vType, t);
		case _: false;
	}

	function possibleOf(v:TVar):Array<Int> {
		var p = possible.get(v.vId);
		if (p != null) return p;
		return switch follow(v.vType) {
			case TEnum(en, _): [for (n in en.eConstrs.names()) en.eConstrs.find(n).efIndex];
			case _: [];
		}
	}

	// `v[index] == k`
	function indexTest(c:TExpr):Null<{v:TVar, k:Int}> {
		if (!ts) return null;
		return switch Texpr.skip(c).eexpr {
			case TBinop(OpEq, a, b):
				switch [Texpr.skip(a).eexpr, Texpr.skip(b).eexpr] {
					case [TEnumIndex(x), TConst(TInt(k))] if (enumLocal(x) != null): {v: enumLocal(x), k: k};
					case _: null;
				}
			case _: null;
		}
	}

	// f with v known to have one of `set` (none: dead), as it was after
	function knowing<R>(v:TVar, set:Null<Array<Int>>, f:Void->R):R {
		var id = v.vId;
		var oldP = possible.get(id), oldD = dead.exists(id);
		if (set == null || set.length == 0) dead.set(id, true) else possible.set(id, set);
		var r = f();
		if (oldP == null) possible.remove(id) else possible.set(id, oldP);
		if (oldD) dead.set(id, true) else dead.remove(id);
		return r;
	}

	// a condition, what follows where it holds (`yes`) and where not (`no`), each knowing what it established
	function narrowing<R>(c:TExpr, yes:Void->R, no:Null<Void->R>):{c:Ex, yes:R, no:Null<R>} {
		var t = indexTest(c);
		if (t == null || dead.exists(t.v.vId)) return {c: expr(c), yes: yes(), no: no == null ? null : no()};
		var set = possibleOf(t.v);
		// (decided already: the test as `any`, TypeScript would find it has no overlap)
		if (!set.contains(t.k)) return {c: knowing(t.v, null, () -> expr(c)), yes: knowing(t.v, null, yes), no: no == null ? null : no()};
		return {
			c: expr(c),
			yes: knowing(t.v, [t.k], yes),
			no: no == null ? null : knowing(t.v, [for (i in set) if (i != t.k) i], no)
		};
	}

	// ------------------------------------------------------------------ locals

	public function local(v:TVar):Sym {
		var s = locals.get(v.vId);
		if (s == null) {
			s = new Sym(SLocal, RESERVED.exists(v.vName) || GLOBALS.exists(v.vName) || (ts && v.vName == "index") ? "$" + v.vName : v.vName);
			s.type = computed.exists(v.vId) ? TDynamic(null) : v.vType;
			locals.set(v.vId, s);
		}
		// (each time: a local may be used by the code of two fields, filters.ES6Ctors' constructors)
		r.declare(s);
		return s;
	}

	// globals a local would hide from untyped code (Genjs's kwds2): escaped where declared
	static final GLOBALS = [
		for (s in [
			"Infinity", "NaN", "decodeURI", "decodeURIComponent", "encodeURI", "encodeURIComponent", "escape", "eval", "isFinite", "isNaN",
			"parseFloat", "parseInt", "undefined", "unescape", "JSON", "Number", "Object", "console", "window", "require", "globalThis"
		])
			s => true
	];

	public function localNames():Array<String> return [for (s in locals) s.name];

	// `var _gthis = this` in e's top-level statements whose every use is in arrows (or none): `this`
	function aliasThis(e:TExpr) {
		var candidates = new Map<Int, Bool>();
		function find(e:TExpr) switch e.eexpr {
			case TBlock(el): for (x in el) find(x);
			case TVar(v, {eexpr: TConst(TThis)}) if (!assigned.exists(v.vId)): candidates.set(v.vId, true);
			case _:
		}
		find(e);
		if (!candidates.iterator().hasNext()) return;
		var bad = new Map<Int, Bool>();
		function walk(e:TExpr, ownThis:Bool) {
			// (a split's initializer: in a file of its own, `this` a capture)
			if (r.split(e) != null) {
				Texpr.iter(x -> walk(x, true), e);
				return;
			}
			switch e.eexpr {
				case TLocal(v) if (ownThis && candidates.exists(v.vId)):
					bad.set(v.vId, true);
				case TFunction(f):
					walk(f.tfExpr, ownThis || hasOwnThis(f));
					return;
				case _:
			}
			Texpr.iter(x -> walk(x, ownThis), e);
		}
		walk(e, false);
		for (k in candidates.keys()) if (!bad.exists(k)) thisAliases.set(k, true);
	}

	// ------------------------------------------------------------------ statements

	function block(e:TExpr):Array<St> {
		var out = [];
		stmt(e, out);
		return out;
	}

	public function stmt(e:TExpr, out:Array<St>):Void {
		var p = e.epos;
		inline function push(d:StDef) out.push(st(d, p));
		switch e.eexpr {
			case TBlock(el):
				var i = 0;
				while (i < el.length) {
					var n = loop(el, i, out);
					if (n == 0) {
						stmt(el[i], out);
						i++;
					} else i += n;
				}
			case TMeta(m = {exprs: [{expr: EConst(Int(i, _))}]}, e1) if ((m.meta : core.MetaList.StrictMeta) == LoopLabel):
				switch e1.eexpr {
					case TWhile(_):
						var inner = block(e1);
						push(SLabel("loop" + i, inner.length == 1 ? inner[0] : st(SBlock(inner), p)));
					case TBreak: push(SBreak("loop" + i));
					case TContinue: push(SContinue("loop" + i));
					case _: stmt(e1, out);
				}
			case TMeta(_, e1) | TParenthesis(e1) | TCast(e1, null):
				stmt(e1, out);
			case TVar(v, _) if (thisAliases.exists(v.vId)):
			case TVar(v, init) if (init != null && statementLike(init)):
				push(SVar(VLet, [{name: local(v), init: null}]));
				var target = mk(TLocal(v), v.vType, p);
				stmt(distribute(init, x -> mk(TBinop(OpAssign, target, x), v.vType, x.epos)), out);
			case TVar(v, init):
				var kind = init != null && !assigned.exists(v.vId) ? VConst : VLet;
				// (TypeScript: a copy of a local enum value knows what it does)
				var from = ts && init != null && narrowable(mk(TLocal(v), v.vType, p)) ? enumLocal(init) : null;
				if (from != null) {
					if (dead.exists(from.vId)) dead.set(v.vId, true);
					if (possible.exists(from.vId)) possible.set(v.vId, possible.get(from.vId));
				}
				push(SVar(kind, [{name: local(v), init: init == null ? null : as(expr(init), init.etype, v.vType)}]));
			case TBinop(OpAssign, target, value) if (statementLike(value) && pureTarget(target)):
				stmt(distribute(value, x -> mk(TBinop(OpAssign, target, x), target.etype, x.epos)), out);
			case TReturn(v) if (v != null && statementLike(v)):
				stmt(distribute(v, x -> mk(TReturn(x), e.etype, x.epos)), out);
			case TReturn(v):
				push(SReturn(v == null ? null : retType == null ? expr(v) : as(expr(v), v.etype, retType)));
			case TThrow(v):
				push(SThrow(expr(v)));
			case TBreak:
				push(SBreak(null));
			case TContinue:
				push(SContinue(null));
			case TIf(c, a, b):
				var n = narrowing(c, () -> block(a), b == null ? null : () -> block(b));
				push(SIf(n.c, n.yes, n.no));
			case TWhile(c, body, NormalWhile):
				push(SWhile(expr(c), block(body)));
			case TWhile(c, body, DoWhile):
				push(SDoWhile(block(body), expr(c)));
			case TSwitch(sw):
				push(switchStatement(sw));
			case TTry(body, catches):
				if (catches.length != 1) Error.abort("Unhandled try/catch, please report", p);
				var c = catches[0];
				var b = block(body);
				var v = local(c.variable);
				catchVars.unshift(ex(EId(v)));
				var h = block(c.expr);
				catchVars.shift();
				push(STry(b, v, h));
			case TFunction(_):
				push(SExpr(expr(e)));
			// (a value alone does nothing)
			case TConst(_) | TLocal(_) | TTypeExpr(_):
			case TObjectDecl(fields):
				for (f in fields) stmt(f.expr, out);
			case TCall({eexpr: TIdent("__feature__")}, el) if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_)))):
				var f = switch el[0].eexpr {
					case TConst(TString(f)): f;
					case _: throw "assert";
				}
				if (r.feature(f)) stmt(el[1], out) else if (el.length > 2) stmt(el[2], out);
			case TCall({eexpr: TField(_, FStatic({clPath: {pack: ["js"], name: "Lib"}}, {cfName: "rethrow"}))}, []) if (catchVars.length > 0):
				push(SThrow(catchVars[0]));
			// (an accessor's call whose value nothing uses: a property's write may be `o.x = v`, Properties)
			case TCall(callee, args) if (accessorOf(callee) != null && r.split(e) == null):
				push(SExpr(call(e, callee, args, true)));
			case _:
				push(SExpr(expr(e)));
		}
	}

	// how often e names v
	static function uses(v:TVar, e:TExpr):Int {
		var n = 0;
		function walk(e:TExpr) {
			switch e.eexpr {
				case TLocal(x) if (x.vId == v.vId): n++;
				case TVar(x, _) if (x.vId == v.vId): n++;
				case _:
			}
			Texpr.iter(walk, e);
		}
		walk(e);
		return n;
	}

	static function usesIn(v:TVar, el:haxe.ds.Vector<TExpr>, from:Int):Int {
		var n = 0;
		for (i in from...el.length) n += uses(v, el[i]);
		return n;
	}

	// whether e names a local other than x by x's name
	static function namesLike(e:TExpr, x:TVar):Bool {
		var found = false;
		function walk(e:TExpr) {
			switch e.eexpr {
				case TLocal(v) if (v.vId != x.vId && v.vName == x.vName): found = true;
				case _:
			}
			if (!found) Texpr.iter(walk, e);
		}
		walk(e);
		return found;
	}

	static function generated(v:TVar):Bool return v.vKind.match(VGenerated) || StringTools.startsWith(v.vName, "_g");

	// the filters' loops (for `for (x in array)`, `for (i in a...b)`) at el[i], as they were: `for (const x of a)`,
	// `for (let i = a; i < b; i++)`, where the counters are used for nothing else; the statements used (0: none)
	function loop(el:haxe.ds.Vector<TExpr>, i:Int, out:Array<St>):Int {
		var g = switch el[i].eexpr {
			case TVar(v, {eexpr: TConst(_) | TLocal(_)}) if (generated(v)): v;
			case TVar(v, _) if (generated(v)): v;
			case _: return 0;
		}
		// (an end, or the array: a local of its own, `_g1`)
		var g1:Null<TVar> = null, g1Init:Null<TExpr> = null, j = i + 1;
		if (j < el.length) switch el[j].eexpr {
			case TVar(v, init) if (generated(v) && init != null):
				g1 = v;
				g1Init = init;
				j++;
			case _:
		}
		if (j >= el.length) return 0;
		var gInit = switch el[i].eexpr {
			case TVar(_, init): init;
			case _: null;
		}
		var rest = function(body:haxe.ds.Vector<TExpr>, from:Int):Array<St> {
			var b = [];
			for (k in from...body.length) stmt(body[k], b);
			return b;
		}
		inline function unusedAfter(v:TVar) return usesIn(v, el, j + 1) == 0;
		// (the condition: in parentheses)
		var loopExpr = switch el[j].eexpr {
			case TWhile(cond, body, flag): mk(TWhile(Texpr.skip(cond), body, flag), el[j].etype, el[j].epos);
			case _: return 0;
		}
		switch loopExpr.eexpr {
			// for (x in array)
			case TWhile({eexpr: TBinop(OpLt, {eexpr: TLocal(c)}, {eexpr: TField({eexpr: TLocal(a)}, FInstance({clPath: {pack: [], name: "Array"}}, _, {cfName: "length"}))})},
				{eexpr: TBlock(body)}, NormalWhile)
				if (c.vId == g.vId && gInit != null && gInit.eexpr.match(TConst(TInt(0))) && body.length >= 2):
				var x = switch body[0].eexpr {
					case TVar(x, {eexpr: TArray({eexpr: TLocal(a2)}, {eexpr: TLocal(c2)})}) if (a2.vId == a.vId && c2.vId == g.vId): x;
					case _: return 0;
				}
				if (!body[1].eexpr.match(TUnop(Increment, _, {eexpr: TLocal({vId: _ == g.vId => true})}))) return 0;
				var ownArray = g1 != null && g1.vId == a.vId;
				if (!ownArray && (g1 != null || assigned.exists(a.vId))) return 0;
				if (usesIn(g, body, 2) != 0 || usesIn(a, body, 2) != 0 && ownArray || !unusedAfter(g) || (ownArray && !unusedAfter(a))) return 0;
				// (not where what it iterates names a local by the loop variable's name: in its scope, not yet initialized)
				if (namesLike(ownArray ? g1Init : mk(TLocal(a), a.vType, el[j].epos), x)) return 0;
				var of = ownArray ? expr(g1Init) : ex(EId(local(a)));
				out.push(st(SForOf(assigned.exists(x.vId) ? VLet : VConst, local(x), of, rest(body, 2)), el[j].epos));
				return j - i + 1;
			// for (i in a...b)
			case TWhile({eexpr: TBinop(OpLt, {eexpr: TLocal(c)}, end)}, {eexpr: TBlock(body)}, NormalWhile) if (c.vId == g.vId && body.length >= 1 && gInit != null):
				var x = switch body[0].eexpr {
					case TVar(x, {eexpr: TUnop(Increment, Postfix, {eexpr: TLocal(c2)})}) if (c2.vId == g.vId): x;
					case _: return 0;
				}
				if (assigned.exists(x.vId) || usesIn(g, body, 1) != 0 || !unusedAfter(g)) return 0;
				if (namesLike(gInit, x) || namesLike(end, x) || (g1Init != null && namesLike(g1Init, x))) return 0;
				var decls:Array<Decl> = [{name: local(x), init: expr(gInit)}];
				var test = switch end.eexpr {
					case TLocal(e) if (g1 != null && e.vId == g1.vId):
						if (usesIn(g1, body, 0) != 0 || !unusedAfter(g1)) return 0;
						// (an end that cannot change: itself; else evaluated once, as Haxe does)
						switch g1Init.eexpr {
							case TConst(_): expr(g1Init);
							case TLocal(l) if (!assigned.exists(l.vId)): expr(g1Init);
							case _:
								decls.push({name: local(g1), init: expr(g1Init)});
								ex(EId(local(g1)));
						}
					case TConst(_) if (g1 == null): expr(end);
					case _: return 0;
				}
				out.push(st(SFor(st(SVar(VLet, decls)), ex(EBinary("<", ex(EId(local(x))), test)), ex(EUpdate("++", false, ex(EId(local(x))))), rest(body, 1)), el[j].epos));
				return j - i + 1;
			case _:
				return 0;
		}
	}

	// (TypeScript) the fields of locals a switch is on, in its cases: a test of one against a constant there is one TypeScript
	// finds decided (the matcher's `switch (a.length) { case 0: if (a.length == 3)`)
	final decided = new Map<String, Bool>();

	static function fieldKey(e:TExpr):Null<String> return switch Texpr.skip(e).eexpr {
		case TField(x, f): switch Texpr.skip(x).eexpr {
				case TLocal(v): v.vId + "." + fieldName(f);
				case _: null;
			}
		case _: null;
	}

	function decidedTest(a:TExpr, b:TExpr):Bool {
		function on(x:TExpr, c:TExpr) {
			var k = fieldKey(x);
			return k != null && decided.exists(k) && Texpr.skip(c).eexpr.match(TConst(_));
		}
		return on(a, b) || on(b, a);
	}

	function switchStatement(sw:TSwitch):StDef {
		// (TypeScript: on a local enum value's index, each case knowing it; a case decided already (an enclosing test's):
		// all as `any`, TypeScript would find it can't be)
		var v = switch Texpr.skip(sw.switchSubject).eexpr {
			case TEnumIndex(x) if (ts): enumLocal(x);
			case _: null;
		}
		var set = v == null || dead.exists(v.vId) ? null : possibleOf(v);
		function value(p:TExpr):Null<Int> return switch p.eexpr {
			case TConst(TInt(i)): i;
			case _: null;
		}
		for (c in sw.switchCases) for (p in c.casePatterns) if (set != null && !set.contains(value(p))) set = null;
		if (v != null && set == null && !dead.exists(v.vId)) return knowing(v, null, () -> switchStatement(sw));
		inline function knowingCase<R>(vals:Array<Int>, f:Void->R):R return v == null || dead.exists(v.vId) ? f() : knowing(v, vals, f);
		var on = expr(sw.switchSubject);
		// (TypeScript: on a branded abstract's value, whose cases are its literals: as `any`, which they compare with)
		if (ts && Casts.literalCast(sw.switchSubject.etype) && !on.def.match(EAs(_))) on = ex(EAs(on));
		// (on an enum's index: the constructors' names beside their indexes)
		var names:Null<Array<String>> = switch Texpr.skip(sw.switchSubject).eexpr {
			case TEnumIndex(x):
				switch follow(x.etype) {
					case TEnum(en, _):
						var a = [];
						for (n in en.eConstrs.names()) {
							var f = en.eConstrs.find(n);
							a[f.efIndex] = f.efName;
						}
						a;
					case _: null;
				}
			case _: null;
		}
		var key = ts ? fieldKey(sw.switchSubject) : null;
		var wasDecided = key != null && decided.exists(key);
		var cases:Array<Case> = [];
		for (c in sw.switchCases) {
			if (key != null) decided.set(key, true);
			var body = knowingCase([for (p in c.casePatterns) value(p)], () -> block(c.caseExpr));
			if (key != null && !wasDecided) decided.remove(key);
			if (!terminates(body)) body.push(st(SBreak(null)));
			var comments = names == null ? null : [
				for (p in c.casePatterns) switch p.eexpr {
					case TConst(TInt(i)) if (names[i] != null): names[i];
					case _: "?";
				}
			];
			cases.push({tests: [for (p in c.casePatterns) p.eexpr.match(TConst(TNull)) ? ex(ENull) : expr(p)], body: scoped(body), comments: comments});
		}
		if (sw.switchDefault != null) {
			var rest = set == null ? null : [for (i in set) if (!Lambda.exists(sw.switchCases.toArray(), c -> Lambda.exists(c.casePatterns.toArray(), p -> value(p) == i))) i];
			cases.push({tests: null, body: scoped(knowingCase(rest, () -> block(sw.switchDefault)))});
		}
		return SSwitch(on, cases);
	}

	// whether control cannot reach the end of the statements
	static function terminates(body:Array<St>):Bool {
		if (body.length == 0) return false;
		return switch body[body.length - 1].def {
			case SReturn(_) | SThrow(_) | SBreak(_) | SContinue(_): true;
			case SBlock(b): terminates(b);
			case SIf(_, a, b): b != null && terminates(a) && terminates(b);
			case _: false;
		}
	}

	// a case's statements, in a block of their own where they declare
	static function scoped(body:Array<St>):Array<St> {
		for (s in body) if (s.def.match(SVar(_) | SClass(_) | SFunction(_))) return [st(SBlock(body))];
		return body;
	}

	// ------------------------------------------------------------------ values

	public static function statementLike(e:TExpr):Bool return switch e.eexpr {
		case TVar(_) | TWhile(_) | TThrow(_) | TSwitch(_) | TTry(_): true;
		case TBlock([e1]): statementLike(e1);
		case TBlock(el): el.length > 0;
		case TIf(_, a, b): b != null && (statementLike(a) || statementLike(b));
		case TMeta(_, e1) | TParenthesis(e1): statementLike(e1);
		case _: false;
	}

	// e, its value given to sink where it is left
	static function distribute(e:TExpr, sink:TExpr->TExpr):TExpr {
		inline function with(d:TExprDef) return mk(d, e.etype, e.epos);
		return switch e.eexpr {
			case TBlock(el) if (el.length > 0):
				var a = el.toArray();
				a[a.length - 1] = distribute(a[a.length - 1], sink);
				with(TBlock(Vector.fromArrayCopy(a)));
			case TIf(c, a, b) if (b != null): with(TIf(c, distribute(a, sink), distribute(b, sink)));
			case TSwitch(sw):
				with(TSwitch({
					switchSubject: sw.switchSubject,
					switchCases: sw.switchCases.map(c -> ({casePatterns: c.casePatterns, caseExpr: distribute(c.caseExpr, sink)} : TSwitchCase)),
					switchDefault: sw.switchDefault == null ? null : distribute(sw.switchDefault, sink),
					switchExhaustive: sw.switchExhaustive
				}));
			case TTry(b, catches): with(TTry(distribute(b, sink), catches.map(c -> {variable: c.variable, expr: distribute(c.expr, sink)})));
			case TMeta(m, e1): with(TMeta(m, distribute(e1, sink)));
			case TParenthesis(e1): distribute(e1, sink);
			case TVar(_) | TWhile(_) | TThrow(_) | TReturn(_) | TBreak | TContinue: e;
			case _: sink(e);
		}
	}

	// an assignment's target that can be written in each branch
	static function pureTarget(e:TExpr):Bool return switch e.eexpr {
		case TLocal(_) | TConst(TThis) | TTypeExpr(_): true;
		case TField(x, FInstance(_, _, _) | FStatic(_, _) | FAnon(_) | FDynamic(_)): pureTarget(x);
		case _: false;
	}

	// a statement where a value is expected: an arrow called in place, returning it
	function statementValue(e:TExpr):Ex {
		var body = [];
		var oldRet = retType;
		retType = e.etype;
		stmt(distribute(e, x -> mk(TReturn(x), x.etype, x.epos)), body);
		retType = oldRet;
		return ex(ECall(ex(EFn({params: [], rest: false, body: body, arrow: true, ret: e.etype}), e.epos), []), e.epos);
	}

	static function binop(op:Binop):String return switch op {
		case OpAdd: "+";
		case OpMult: "*";
		case OpDiv: "/";
		case OpSub: "-";
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
		case OpBoolAnd: "&&";
		case OpBoolOr: "||";
		case OpShl: "<<";
		case OpShr: ">>";
		case OpUShr: ">>>";
		case OpMod: "%";
		case OpNullCoal: "??";
		case OpIn: "in";
		case OpAssignOp(op): binop(op) + "=";
		case OpInterval | OpArrow: throw "assert";
	}

	// o.name, or o["name"] where it is no identifier
	public static function member(o:Ex, name:String, ?p:Pos):Ex return validIdent(name) ? ex(EMember(o, name), p) : ex(EIndex(o, ex(EStr(name))), p);

	// a field access's namespace (FieldNames: its class's family's, its class's statics'; NGlobal: the global one)
	static function nsOf(f:TFieldAccess):Ns return switch f {
		case FInstance(c, _, _): NInstance(c);
		case FStatic(c, _): NStatic(c);
		case FClosure(c, _) if (c != null): NInstance(c.cls);
		case _: NGlobal;
	}

	// a Haxe field of o (its name minified: FieldNames)
	public static function field(o:Ex, name:String, ns:Ns, ?p:Pos):Ex return validIdent(name) ? ex(EField(o, name, ns), p) : ex(EIndex(o, ex(EStr(name))), p);


	// (Properties) a property's storage (@:isVar), read or written: noted, with the class whose code this is
	function stored(f:TClassField, e:Ex):Ex {
		if (!f.cfKind.match(Var(_)) || !Properties.isProperty(f) || !isPhysicalField(f)) return e;
		r.storage(f, cls);
		return ex(EBacked(f, e), e.pos);
	}

	// (Properties) the method a call calls, of an accessor's name, the program's (not an extern's)
	static function accessorOf(callee:TExpr):Null<TClassField> return switch callee.eexpr {
		case TField(_, FInstance(c, _, cf) | FStatic(c, cf)) if (!hasClassFlag(c, CExtern) && !hasClassFieldFlag(cf, CfExtern) && Properties.accessorNamed(cf)): cf;
		case _: null;
	}

	// a signature's first optional argument
	static function firstOptional(s:TSignature):Null<Int> {
		for (i in 0...s.args.length) if (s.args[i].optional) return i;
		return null;
	}

	// (TypeScript) a local of an enum's type, which TypeScript narrows by a test on its index
	static function narrowable(x:TExpr):Bool return switch Texpr.skip(x).eexpr {
		case TLocal(v): switch follow(v.vType) {
				case TEnum(en, _): !hasEnumFlag(en, EnExtern);
				case _: false;
			}
		case _: false;
	}

	// an enum constructor's parameter's name, the value's field
	static function paramName(ef:TEnumField, i:Int):String return switch follow(ef.efType) {
		case TFun(s): s.args[i].name;
		case _: throw "assert";
	}

	// Genjs.isDynamicIterator: `.iterator()` on what may be an Array
	static function dynamicIterator(x:TExpr):Bool {
		function loop(t:T):Bool {
			return switch follow(t) {
				case TInst({clPath: {pack: [], name: "Array"}}, _) | TInst({clKind: KTypeParameter(_)}, _) | TAnon(_) | TDynamic(_) | TMono(_):
					true;
				case TAbstract(a, tl) if (!Meta.has(Meta.CoreType, a.aMeta)):
					loop(core.Abstract.getUnderlyingType(a, tl));
				case _: false;
			}
		}
		return loop(x.etype);
	}

	public function expr(e:TExpr):Ex {
		var p = e.epos;
		inline function mkx(d:ExDef) return ex(d, p);
		var s = r.split(e);
		if (s != null) return splitCall(s, p);
		if (statementLike(e)) return statementValue(e);
		return switch e.eexpr {
			// (TypeScript: a literal Haxe types as a branded abstract, in its code: as `any`, it has not the brand)
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_)) | TObjectDecl(_) | TArrayDecl(_)
				| TBinop(OpAdd | OpSub | OpMult | OpDiv | OpMod | OpShl | OpShr | OpUShr | OpAnd | OpOr | OpXor, _, _) | TUnop(Neg | NegBits, _, _)
				if (ts && Casts.literalCast(e.etype)):
				any(expr({eexpr: e.eexpr, etype: tDynamic, epos: e.epos}));
			case TConst(TInt(i)): mkx(ENum(Std.string(i)));
			case TConst(TFloat(s)): mkx(ENum(s));
			case TConst(TString(s)):
				r.stringConst(s);
				mkx(EStr(s));
			case TConst(TBool(b)): mkx(EBool(b));
			case TConst(TNull): mkx(ENull);
			case TConst(TThis): mkx(EThis);
			case TConst(TSuper): mkx(ESuper);
			case TLocal(v) if (thisAliases.exists(v.vId)): mkx(EThis);
			// (TypeScript: a GADT's value where a match refined its type, which TypeScript doesn't)
			case TLocal(v) if (ts && refined(v, e.etype)): any(mkx(EId(local(v))));
			// (TypeScript: as its declaration has it, where Haxe has it as another, an abstract's `this` as the abstract)
			case TLocal(v) if (ts && Casts.need(v.vType, e.etype)): any(mkx(EId(local(v))));
			case TLocal(v): mkx(EId(local(v)));
			case TArray(a, i): mkx(EIndex(arrayObject(a, i), expr(i)));
			case TBinop(OpAssign | OpAssignOp(_), a, b):
				mkx(EAssign(switch e.eexpr {
					case TBinop(op, _, _): binop(op);
					case _: throw "assert";
				}, target(a), assignedValue(a, b)));
			// (TypeScript: what follows a test of an enum value's index knowing it)
			case TBinop(OpBoolAnd, a, b) if (indexTest(a) != null):
				var n = narrowing(a, () -> expr(b), null);
				mkx(EBinary("&&", n.c, n.yes));
			// (TypeScript: an enum value compared as `any` (TypeScript may have narrowed it); an operand of arithmetic
			// not a number, untyped code's)
			case TBinop(op = OpEq | OpNotEq, a, b) if (ts && (Casts.enumLike(a.etype) || Casts.enumLike(b.etype))):
				mkx(EBinary(binop(op), any(expr(a)), expr(b)));
			// (TypeScript: operands it would call of no overlap, or one a literal array, object, function or NaN, compared as
			// `any`, both: Haxe compares them)
			case TBinop(op = OpEq | OpNotEq, a, b) if (ts):
				var x = expr(a), y = expr(b);
				Casts.disjoint(a.etype, b.etype) || fresh(x) || fresh(y) || decidedTest(a, b) ? mkx(EBinary(binop(op), any(x), any(y))) : mkx(EBinary(binop(op), x, y));
			case TBinop(op = OpSub | OpMult | OpDiv | OpMod | OpShl | OpShr | OpUShr | OpAnd | OpOr | OpXor, a, b) if (ts):
				mkx(EBinary(binop(op), num(a), num(b)));
			case TBinop(op, a, b): mkx(EBinary(binop(op), native(a), native(b)));
			case TField(x, f) if (fieldName(f) == "iterator" && dynamicIterator(x) && !f.match(FStatic(_) | FEnum(_))):
				mkx(ECall(r.rt("iterator"), [expr(x)]));
			case TField(x, f) if (fieldName(f) == "keyValueIterator" && dynamicIterator(x) && !f.match(FStatic(_) | FEnum(_))):
				mkx(ECall(r.rt("keyValueIterator"), [expr(x)]));
			case TField(x, FInstance(_, _, f) | FStatic(_, f) | FAnon(f)) if (Meta.has(Meta.SelfCall, f.cfMeta)):
				expr(x);
			case TField(x, fa = FClosure(c, f)):
				if (c == null) r.dynamicName(f.cfName) else if (Properties.accessorNamed(f)) r.accessorTaken(f);
				if (Meta.has(Meta.SelfCall, f.cfMeta)) expr(x) else mkx(ECall(r.rt("bind"), [expr(x), mkx(EFieldName(f.cfName, nsOf(fa)))]));
			// (a class without a name: its statics at the top level, Genjs's)
			case TField(_, FStatic(c = {clPath: {pack: [], name: ""}}, f)):
				hasClassFlag(c, CExtern) ? r.ident(f.cfName) : r.moduleField(c.clModule, f, p);
			case TField(_, FStatic({clKind: KModuleFields(m)}, f)):
				r.moduleField(m, f, p);
			// (the runtime, js.Hx: its part)
			case TField(_, FStatic({clPath: {pack: [], name: "$hx"}}, f)):
				r.rt(f.cfName);
			case TField({eexpr: TTypeExpr(TClassDecl({clPath: {pack: [], name: "$hx"}}))}, FDynamic(name)):
				r.rt(name);
			case TField(_, FStatic(c, f)):
				r.refer(Genjs.dotPath(c.clPath) + "." + f.cfName);
				var o = r.type(TClassDecl(c), p);
				// (TypeScript: std's extern of a global by another name (`@:native("Error") V8Error`) has what its type does not)
				if (ts && r.stdExtern(c) && renamed(c)) o = any(o);
				var n = staticName(modules, c, f);
				stored(f, ts && !hasClassFieldFlag(f, CfPublic) && !visible(c, f, null) && !o.def.match(EAs(_)) ? ex(EFriend(o, n), p) : field(o, n, NStatic(c), p));
			case TField(_, FEnum(en, ef)):
				enumValue(en, ef, e.etype, p);
			// (Genjs's field of an enum value's index, which the std reads untyped: haxe.Serializer)
			case TField(x, FDynamic("_hx_index")):
				mkx(EIndex(expr(x), r.index()));
			case TField(x, f):
				switch f {
					case FAnon(cf): r.dynamicName(cf.cfName);
					case FDynamic(n): r.dynamicName(n);
					case _:
				}
				var o = fieldObject(x, f);
				switch f {
					// (TypeScript: a `protected` field where Haxe let the code read it, `@:privateAccess`'s)
					case FInstance(c, _, cf) if (ts && !o.def.match(EAs(_)) && !x.eexpr.match(TConst(TSuper)) && !hasClassFlag(c, CExtern)
						&& !hasClassFieldFlag(cf, CfPublic) && !visible(c, cf, switch follow(x.etype) {
							case TInst(r, _): r;
							case _: null;
						})):
						stored(cf, ex(EFriend(o, cf.cfName), p));
					case FInstance(_, _, cf): stored(cf, field(o, fieldName(f), nsOf(f), p));
					case _: field(o, fieldName(f), nsOf(f), p);
				}
			case TTypeExpr(t): r.type(t, p);
			// (TypeScript: and a Dynamic local, which it may have narrowed (`x instanceof String`: a `String` object), as `any`)
			case TCast(x, null) if (ts):
				(Casts.isDynamic(e.etype) && !Casts.isDynamic(x.etype)) || (Casts.isDynamic(x.etype) && !Casts.isDynamic(e.etype) && Texpr.skip(x).eexpr.match(TLocal(_))) ? any(expr(x)) : as(expr(x), x.etype, e.etype);
			case TParenthesis(x) | TMeta(_, x) | TCast(x, null): expr(x);
			case TObjectDecl(fields):
				mkx(EObject([
					for (f in fields)
						({key: validIdent(f.key.name) ? KField(f.key.name, NGlobal) : KString(f.key.name), value: expr(f.expr)} : Prop)
				]));
			// (TypeScript: each of the array's type: Haxe's abstracts let one be another without a cast, in the abstract's code)
			case TArrayDecl(el):
				var t = switch follow(e.etype) {
					case TInst({clPath: {pack: [], name: "Array"}}, [t]) if (ts): t;
					case _: null;
				}
				mkx(EArray([for (x in el) t == null ? expr(x) : as(expr(x), x.etype, t)]));
			// (TypeScript: std's extern's array of `Any` or `Dynamic`, which its lib may have as `unknown[]`: `Object.values`)
			case TCall(callee = {eexpr: TField(_, FStatic(c, _))}, args) if (ts && r.stdExtern(c) && mentionsAny(e.etype)): any(call(e, callee, args));
			case TCall(callee, args): call(e, callee, args);
			case TNew({clPath: {pack: [], name: "Array"}}, _, args) if (args.length == 0): mkx(EArray([]));
			// (a Haxe String is a primitive: `new String(s)` would be an object, not `===` to s, its type not `string`)
			case TNew(c = {clPath: {pack: [], name: "String"}}, _, [a]): as(mkx(ECall(r.type(TClassDecl(c), p), [expr(a)])), TInst(c, haxe.ds.Vector.fromArrayCopy([])), e.etype);
			case TNew(c, _, args):
				var ctor = r.type(TClassDecl(c), p);
				// (TypeScript: a generic class's type arguments, which it may not infer from the arguments)
				if (ts && !hasClassFlag(c, CExtern) && c.clParams.length > 0 && ctor.def.match(EId(_) | ERef(_))) switch e.eexpr {
					case TNew(_, params, _) if (params.length == c.clParams.length): ctor = ex(ETypeArgs(ctor, params.toArray()), p);
					case _:
				}
				// (a Haxe constructor: its trailing `null`s to optional arguments, as callArgs)
				// (TypeScript: as the constructor takes them)
				var sig = !ts || c.clConstructor == null ? null : switch follow(applyParams(c.clParams, switch e.eexpr {
					case TNew(_, params, _): params;
					case _: throw "assert";
				}, c.clConstructor.cfType)) {
					case TFun(s): s;
					case _: null;
				}
				var a = trimDefaults([for (i in 0...args.length) {
					var v = expr(args[i]);
					sig != null && i < sig.args.length && !ExtType.isRest(follow(sig.args[i].type)) ? as(v, args[i].etype, sig.args[i].type) : v;
				}], args, hasClassFlag(c, CExtern) ? null : c.clConstructor);
				var made = if (c.clConstructor != null && Meta.has(Meta.SelfCall, c.clConstructor.cfMeta)) mkx(ECall(ctor, a)) else mkx(ENew(ctor, a));
				// (TypeScript: of its class, its type arguments', where Haxe has it as another type: a structure of an abstract,
				// an abstract @:forward.new makes of it)
				switch e.eexpr {
					case TNew(_, params, _) if (ts && (ctor.def.match(ETypeArgs(_)) || follow(e.etype).match(TAbstract(_)))): as(made, TInst(c, params), e.etype);
					case _: made;
				}
			case TUnop(Spread, _, x): mkx(ESpread(native(x)));
			case TUnop(op = Increment | Decrement, flag, x): mkx(EUpdate(op == Increment ? "++" : "--", flag == Prefix, target(x)));
			case TUnop(Not, _, x): mkx(EUnary("!", native(x)));
			case TUnop(Neg, _, x): mkx(EUnary("-", native(x)));
			case TUnop(NegBits, _, x): mkx(EUnary("~", native(x)));
			case TFunction(f): mkx(EFn(func(f, true, p, e.etype)));
			case TIf(c, a, b):
				var n = narrowing(c, () -> as(expr(a), a.etype, e.etype), b == null ? null : () -> as(expr(b), b.etype, e.etype));
				mkx(ECond(n.c, n.yes, n.no == null ? mkx(ENull) : n.no));
			case TCast(x, t):
				r.refer("js.Boot.__cast");
				mkx(ECall(ts ? ex(EFriend(r.typeByPath(["js"], "Boot", p), "__cast"), p) : field(r.typeByPath(["js"], "Boot", p), "__cast", NStaticPath("js.Boot"), p), [expr(x), r.type(t, p)]));
			case TEnumIndex(x): mkx(EIndex(ts && isDead(x) ? any(expr(x)) : expr(x), r.index()));
			// (TypeScript: a local a test on its index narrowed to the constructor, as it is)
			case TEnumParameter(x, ef, i) if (!ts || isKnown(x, ef.efIndex)): field(expr(x), paramName(ef, i), NCtorParam(ef), p);
			case TEnumParameter(x, ef, i): field(any(expr(x)), paramName(ef, i), NCtorParam(ef), p);
			case TIdent(s): r.ident(s);
			case TReturn(_) | TBreak | TContinue: Error.abort("This expression cannot be compiled to Javascript", p);
			case TVar(_) | TBlock(_) | TWhile(_) | TSwitch(_) | TTry(_) | TThrow(_): statementValue(e);
		}
	}

	// what an assignment or `++` writes: a field by its name (not `iterator`'s helper)
	function target(e:TExpr):Ex {
		return switch e.eexpr {
			case TField(x, f = FInstance(_) | FAnon(_) | FDynamic(_)) if (Genjs.isIteratorFieldAccess(f)): field(expr(x), fieldName(f), nsOf(f), e.epos);
			// (TypeScript: a `readonly` field, but in its class's constructor, `this`'s: of the object as `any`)
			case TField(x, fa = FInstance(_, _, cf) | FStatic(_, cf)) if (ts && Properties.readonlyVar(cf)
				&& !(fa.match(FInstance(_)) && depth == 1 && ctorOf != null && Lambda.has(ctorOf.clFields, cf) && Texpr.skip(x).eexpr.match(TConst(TThis)))):
				var o = switch fa {
					case FStatic(c, _): r.type(TClassDecl(c), e.epos);
					case _: expr(x);
				}
				field(ex(EAs(o), o.pos), cf.cfName, nsOf(fa), e.epos);
			case TParenthesis(x) | TMeta(_, x): target(x);
			case _: expr(e);
		}
	}

	// a split's call: its file loaded ($hx.load), its initializer called with the captures (bundled)
	function splitCall(s:Splits.SplitPoint, p:Pos):Ex {
		// (modules: the modules it needs imported, its code here, closing over the captures)
		if (r.splitsInline()) return r.inSplit(s, file -> ex(ESplit(file, func(s.fn, true, p)), p));
		var name = "split";
		for (v in s.captures) if (v.vName == name) name += "$";
		var param = new Sym(SLocal, name);
		param.type = TDynamic(null);
		var init = ex(ECall(ex(EIndex(ex(EId(param)), ex(ENum(Std.string(s.index))))), [for (v in s.captures) expr(mk(TLocal(v), v.vType, p))]), p);
		var load = ex(ECall(r.rt("load"), [r.splitKey(s.name)]), p);
		return ex(ECall(ex(EMember(load, "then")), [ex(EFn({params: [param], rest: false, arrow: true, body: [st(SReturn(init))]}))]), p);
	}

	// a constructor of arguments as a value: a function of them which constructs (`new`, as the constructor is)
	function enumValue(en:TEnum, ef:TEnumField, t:T, p:Pos):Ex {
		var c = field(r.type(TEnumDecl(en), p), ef.efName, NEnumCtor(en), p);
		return switch [follow(ef.efType), follow(t)] {
			case [TFun(_), TFun(s)]:
				var ps = [for (a in s.args) {
					var v = new Sym(SLocal, RESERVED.exists(a.name) || a.name == "" ? "$" + a.name : a.name);
					if (ts) v.type = a.type;
					r.declare(v);
					v;
				}];
				ex(EFn({params: ps, rest: false, arrow: true, body: [st(SReturn(ex(ENew(c, [for (v in ps) ex(EId(v))]), p)))], optFrom: ts ? firstOptional(s) : null}), p);
			case _: c;
		}
	}

	function call(e:TExpr, callee:TExpr, args:Vector<TExpr>, discarded = false):Ex {
		var p = e.epos;
		inline function mkx(d:ExDef) return ex(d, p);
		inline function values() return [for (a in args) expr(a)];
		return switch [callee.eexpr, args] {
			case [TField(_, FStatic({clPath: {pack: ["js"], name: "Syntax"}}, {cfName: meth})), _]:
				syntax(e, meth, args, callee.epos);
			case [TField(_, FStatic({clPath: {pack: ["js"], name: "Lib"}}, {cfName: "rethrow"})), []]:
				if (catchVars.length == 0) Error.abort("js.Lib.rethrow can only be called inside a catch block", callee.epos);
				mkx(ECall(ex(EFn({params: [], rest: false, arrow: true, body: [st(SThrow(catchVars[0]))]})), []));
			case [TField(_, FStatic({clPath: {pack: ["js"], name: "Lib"}}, {cfName: "getOriginalException"})), []]:
				if (catchVars.length == 0) Error.abort("js.Lib.getOriginalException can only be called inside a catch block", callee.epos);
				catchVars[0];
			case [TIdent("__define_feature__"), [_, x]]:
				expr(x);
			case [TIdent("__feature__"), el] if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_)))):
				var f = switch el[0].eexpr {
					case TConst(TString(f)): f;
					case _: throw "assert";
				}
				if (r.feature(f)) expr(el[1]) else if (el.length > 2) expr(el[2]) else mkx(EUndefined);
			case [TIdent("__resources__"), []]:
				var out = [];
				com.resources.iter((name, data) -> out.push(ex(EObject([
					{key: KName("name"), value: ex(EStr(name))},
					{key: KName("data"), value: ex(EStr(codegen.Codegen.bytesSerialize(data)))}
				]))));
				// (TypeScript: `str` is the cache Resource fills in)
				any(mkx(EArray(out)));
			case [TIdent("`trace"), [v, infos]]:
				if (r.feature("haxe.Log.trace")) mkx(ECall(field(r.typeByPath(["haxe"], "Log", p), "trace", NStaticPath("haxe.Log")), [expr(v), expr(infos)])) else {
					var at = switch infos.eexpr {
						case TObjectDecl(fields) if (fields.length >= 2 && fields[0].key.name == "fileName" && fields[1].key.name == "lineNumber"):
							switch [fields[0].expr.eexpr, fields[1].expr.eexpr] {
								case [TConst(TString(f)), TConst(TInt(l))]: f + ":" + l + ":";
								case _: null;
							}
						case _: null;
					}
					var log = member(ex(EId(new Sym(SGlobal, "console"))), "log");
					mkx(ECall(log, at == null ? [expr(v)] : [ex(EStr(at)), expr(v)]));
				}
			case [TField(x, f), []] if (fieldName(f) == "iterator" && dynamicIterator(x) && !f.match(FStatic(_) | FEnum(_))):
				mkx(ECall(r.rt("getIterator"), [expr(x)]));
			case [TField(x, f), []] if (fieldName(f) == "keyValueIterator" && dynamicIterator(x) && !f.match(FStatic(_) | FEnum(_))):
				mkx(ECall(r.rt("getKeyValueIterator"), [expr(x)]));
			case [TField(_, FEnum(en, ef)), _]:
				mkx(ENew(field(r.type(TEnumDecl(en), p), ef.efName, NEnumCtor(en), p), values()));
			case _:
				var f = native(callee);
				if (ts) f = typeArgs(f, callee);
				// (TypeScript: a spread argument where a function of fixed arguments is called)
				if (ts && Lambda.exists(args.toArray(), a -> a.eexpr.match(TUnop(Spread, _, _))) && !f.def.match(ESuper)) f = any(f);
				switch callee.eexpr {
					case TField(_, FStatic(cl, cf) | FInstance(cl, _, cf)):
						var k = Genjs.dotPath(cl.clPath) + "." + cf.cfName;
						var l = Properties.reflects(k);
						if (l != null) for (i in l) if (i < args.length) r.reflected(Texpr.skip(args[i]).etype);
					case _:
				}
				var c = mkx(ECall(f, callArgs(callee, args)));
				var a = accessorOf(callee);
				if (a == null) c else {
					r.accessorCall(a, args.length, discarded);
					mkx(EAccessor(a, c, discarded));
				}
		}
	}

	// a call's arguments, but the trailing `null`s passed to optional arguments of a Haxe method known at the call
	// (Haxe has no `undefined`: none and `null` are alike)
	function callArgs(callee:TExpr, args:Vector<TExpr>):Array<Ex> {
		var sig = switch follow(callee.etype) {
			case TFun(s): s;
			case _: null;
		}
		// (TypeScript: as the function takes them; a generic enum's constructor as a function, of which TypeScript infers
		// none of the type arguments from the other's)
		// (an abstract's method: its `this` the abstract, as Chunk.abstractThis declares it)
		var self = switch callee.eexpr {
			case TField(_, FStatic({clKind: KAbstractImpl(a)}, cf)) if (ts && hasClassFieldFlag(cf, CfImpl) && !hasClassFieldFlag(cf, CfAbstractConstructor)
				&& Casts.branded(a)):
				TAbstract(a, Vector.fromArrayCopy([for (_ in a.aParams) tDynamic]));
			case _: null;
		}
		var out = [for (i in 0...args.length) {
			var v = expr(args[i]);
			if (!ts) v else if (i == 0 && self != null) as(v, args[i].etype, self) else if (genericCtor(args[i])) any(v) else if (sig != null && i < sig.args.length && !ExtType.isRest(follow(sig.args[i].type)))
				as(v, args[i].etype, sig.args[i].type) else v;
		}];
		var target = switch callee.eexpr {
			case TField(_, FStatic(c, cf)) if (!hasClassFlag(c, CExtern) && !hasClassFieldFlag(cf, CfExtern)): cf;
			case TField(_, FInstance(c, _, cf)) if (!hasClassFlag(c, CExtern) && !hasClassFlag(c, CInterface) && !hasClassFieldFlag(cf, CfExtern)): cf;
			case _: null;
		}
		return trimDefaults(out, args, target);
	}

	public static function trimDefaults(out:Array<Ex>, args:Vector<TExpr>, target:Null<TClassField>):Array<Ex> {
		// (a method, not a `dynamic` one, which may be any function)
		var params = switch target == null ? null : target.cfKind {
			case Method(MethNormal | MethInline): switch follow(target.cfType) {
					case TFun(s): s.args;
					case _: return out;
				}
			case _: return out;
		}
		var n = out.length;
		while (n > 0 && n <= params.length && params[n - 1].optional && Texpr.skip(args[n - 1]).eexpr.match(TConst(TNull)))
			n--;
		return n == out.length ? out : out.slice(0, n);
	}

	function syntax(e:TExpr, meth:String, args:Vector<TExpr>, pos:Pos):Ex {
		var p = e.epos;
		inline function mkx(d:ExDef) return ex(d, p);
		return switch [meth, args] {
			case ["construct", _] if (args.length >= 1):
				var a = [for (i in 1...args.length) expr(args[i])];
				switch args[0].eexpr {
					case TConst(TString(s)): mkx(ENew(r.ident(s), a));
					case _: mkx(ENew(expr(args[0]), a));
				}
			case ["instanceof", [o, t]]: mkx(EBinary("instanceof", o.eexpr.match(TConst(_)) ? any(expr(o)) : expr(o), expr(t)));
			case ["typeof", [o]]: mkx(EUnary("typeof", expr(o)));
			case ["strictEq", [a, b]]: mkx(EBinary("===", expr(a), expr(b)));
			case ["strictNeq", [a, b]]: mkx(EBinary("!==", expr(a), expr(b)));
			case ["delete", [o, f]]: mkx(EUnary("delete", ex(EIndex(expr(o), expr(f)), p)));
			case ["code", _] if (args.length >= 1):
				var codeStr = switch args[0].eexpr {
					case TConst(TString(s)): s;
					case _: Error.abort("The `code` argument for js.Syntax.code must be a string constant", args[0].epos);
				}
				var rest = args.slice(1);
				if (rest.length == 0 && codeStr == "this") return mkx(EThis);
				var parts:Array<RawPart> = [];
				function reveal(x:TExpr):TExpr return switch x.eexpr {
					case TCast(y, _) | TMeta(_, y): reveal(y);
					case _: x;
				}
				var vals:Array<TExpr> = [
					for (a in rest) switch reveal(a).eexpr {
						case TIf(_) | TBinop(_) | TUnop(_): ({eexpr: TParenthesis(a), etype: a.etype, epos: a.epos} : TExpr);
						case _: a;
					}
				];
				codegen.Codegen.interpolateCode(com.error, codeStr, vals, s -> parts.push(RText(r.rawText(s))), a -> {
					var v = expr(a);
					// (parenthesized: raw code's operators around it are unknown)
					parts.push(RValue(switch a.eexpr {
						case TParenthesis(_): ex(ERaw([RText("("), RValue(v), RText(")")]));
						case _: v;
					}));
				}, args[0].epos);
				mkx(ERaw(parts));
			case ["plainCode", [code]]:
				switch code.eexpr {
					case TConst(TString(s)): mkx(ERaw([RText(r.rawText(s.split("\r\n").join("\n")))]));
					case _: Error.abort("The `code` argument for js.Syntax.plainCode must be a string constant", code.epos);
				}
			case ["field", [o, f]]:
				switch Texpr.skip(f) {
					// (TypeScript: of an object as `any`, a field it may not have)
					case {eexpr: TConst(TString(s))}:
						r.dynamicName(s);
						member(any(expr(o)), s, p);
					case _: mkx(EIndex(any(expr(o)), expr(f)));
				}
			case _:
				Error.abort('Unknown js.Syntax method `$meth` with ${args.length} arguments', pos);
		}
	}

	// ------------------------------------------------------------------ TypeScript's casts (Casts)

	// (TypeScript) what JavaScript does something with (indexes, calls, computes with, iterates, reads a field of): an opaque
	// abstract's value as `any` (Casts.opaque)
	function native(e:TExpr):Ex return ts && Casts.opaque(e.etype) ? any(expr(e)) : expr(e);

	// x, where Haxe has it as a `from` and a `to` is expected
	function as(x:Ex, from:T, to:T):Ex return ts && (Casts.need(from, to) || extraLiteral(x, to) || (literal(x) && Casts.literalCast(to))) ? any(x) : x;

	// (TypeScript) a value whose type is TypeScript's own, whatever Haxe's: an object, an array, a number computed
	static function literal(x:Ex):Bool return switch x.def {
		case EObject(_) | EArray(_) | ENum(_) | EStr(_): true;
		case EBinary("-" | "*" | "/" | "%" | "<<" | ">>" | ">>>" | "&" | "|" | "^", _, _) | EUnary("-" | "~", _): true;
		case _: false;
	}

	// (an array of `Any` or `Dynamic`, which TypeScript infers as `unknown[]` from what its lib declares generic)
	static function mentionsAny(t:T):Bool return switch follow(t) {
		case TInst({clPath: {pack: [], name: "Array"}}, [p]): follow(p).match(TDynamic(_) | TAbstract({aPath: {pack: [], name: "Any"}}, _));
		case _: false;
	}

	// (an extern whose @:native name is not its own: its path rewritten, the real one kept by @:realPath)
	static function renamed(c:TClass):Bool {
		for (m in c.clMeta) switch m {
			case {meta: core.MetaList.StrictMeta.RealPath, exprs: [{expr: EConst(String(path, _))}]}: return path.split(".").pop() != c.clPath.name;
			case _:
		}
		return false;
	}

	// (TypeScript) a value no other is `==` to as TypeScript sees it: a new array, object, function or instance, NaN
	static function fresh(x:Ex):Bool return switch x.def {
		case EArray(_) | EObject(_) | EFn(_) | ENew(_, _): true;
		case EId(s): s.name == "NaN";
		case ERef(RIdent("NaN")): true;
		case ERaw([RText("NaN")]): true;
		case EMember(_, "NaN"): true;
		case _: false;
	}

	// (not a part of the runtime by Genjs's name, `$hxClasses`: `any` to TypeScript already)
	function any(x:Ex):Ex return ts && !x.def.match(EAs(_) | ERaw([RText(StringTools.startsWith(_, "$hx.") => true)])) ? ex(EAs(x), x.pos) : x;

	// (an object literal with a field the structure it goes to has not)
	static function extraLiteral(x:Ex, to:T):Bool return switch [x.def, follow(to)] {
		case [_, TAbstract({aPath: {pack: [], name: "Null"}}, [p])]: extraLiteral(x, p);
		// (or to a type parameter's type, which TypeScript does not know it to be)
		case [EObject(_), TInst({clKind: KTypeParameter(_)}, _)]: true;
		case [EObject(props), TAnon(a)] if (!a.aFields.isEmpty() && !a.aFields.exists("")):
			Lambda.exists(props, p -> switch p.key {
				case KName(n) | KString(n) | KField(n, _): !a.aFields.exists(n);
				case _: false;
			});
		case _: false;
	}

	// an assignment's value (to a class itself, untyped code replacing it: TypeScript has it as its constructor)
	function assignedValue(target:TExpr, value:TExpr):Ex {
		var v = expr(value);
		if (!ts) return v;
		return Texpr.skip(target).eexpr.match(TTypeExpr(_)) ? any(v) : as(v, value.etype, target.etype);
	}

	// an operand of arithmetic
	function num(e:TExpr):Ex return Casts.numeric(e.etype) ? expr(e) : any(expr(e));

	// the array of `a[i]`: by a key not a number (untyped code's), the object as TypeScript has it may not have it
	function arrayObject(a:TExpr, i:TExpr):Ex {
		var o = native(a);
		if (!ts) return o;
		var key = i;
		while (key.eexpr.match(TCast(_, null))) key = switch key.eexpr {
			case TCast(k, _): k;
			case _: key;
		}
		// (casts in a row, an inlined abstract's or function's argument: TypeScript has what the innermost one has)
		var inner = a;
		while (inner.eexpr.match(TCast(_, null) | TMeta(_, _) | TParenthesis(_))) inner = switch inner.eexpr {
			case TCast(y, _) | TMeta(_, y) | TParenthesis(y): y;
			case _: inner;
		}
		return !Casts.numeric(key.etype) && (!Casts.tsAny(inner.etype) || inner.eexpr.match(TIdent(_) | TTypeExpr(_))) ? any(o) : o;
	}

	// `moz`, `webkit`, `ms` or `o` before a capital (`webkitHidden`)
	static function vendorPrefixed(name:String):Bool {
		for (v in ["moz", "webkit", "ms", "o"]) if (StringTools.startsWith(name, v) && name.length > v.length) {
			var c = StringTools.fastCodeAt(name, v.length);
			if (c >= "A".code && c <= "Z".code) return true;
		}
		return false;
	}


	// the object of a field access: `any` where TypeScript would not have the field Haxe reads
	function fieldObject(x:TExpr, f:TFieldAccess):Ex {
		var o = native(x);
		if (!ts) return o;
		// (casts in a row, an inlined abstract's `this`: TypeScript has what the innermost one has)
		var inner = x;
		while (inner.eexpr.match(TCast(_, null) | TMeta(_, _) | TParenthesis(_))) inner = switch inner.eexpr {
			case TCast(y, _) | TMeta(_, y) | TParenthesis(y): y;
			case _: inner;
		}
		if (inner != x && ((Casts.isDynamic(x.etype) && !Casts.isDynamic(inner.etype)) || Casts.need(inner.etype, x.etype))) return any(o);
		// (of an untyped global name: TypeScript has its own type for it, or none)
		if (inner.eexpr.match(TIdent(_))) return any(o);
		// (of untyped code's value, Dynamic to Haxe: TypeScript has its own type for it, `window`'s)
		if (o.def.match(ERaw(_)) && f.match(FDynamic(_) | FAnon(_))) return any(o);
		// (of enum values: TypeScript has its type as the union of those it lists)
		switch [x.eexpr, follow(x.etype)] {
			case [TArrayDecl(_), TInst({clPath: {pack: [], name: "Array"}}, [t])] if (Casts.enumLike(t)): return any(o);
			case _:
		}
		return switch f {
			// (of a type parameter's value: TypeScript has its constraint)
			case FInstance(_, _, _) | FAnon(_) if (follow(x.etype).match(TInst({clKind: KTypeParameter(_)}, _))): any(o);
			// (an extern's vendor-prefixed member, which TypeScript's library has not)
			case FInstance(c, _, cf) if (hasClassFlag(c, CExtern) && vendorPrefixed(cf.cfName)): any(o);
			case FDynamic(_) if (!Casts.tsAny(x.etype) && !x.eexpr.match(TConst(TSuper))): any(o);
			case _: o;
		}
	}

	// whether TypeScript lets the code of `cls` read cf, `protected`, a field of c's (or a super class's), of a value of
	// class recv (null: a static)
	function visible(c:TClass, cf:TClassField, recv:Null<TClass>):Bool {
		if (cls == null || hasClassFlag(c, CInterface)) return cls != null;
		var d = c;
		while (d != null && !Lambda.has(d.clFields, cf) && !Lambda.has(d.clStatics, cf)) d = d.clSuper == null ? null : d.clSuper.cls;
		if (d == null) d = c;
		inline function sub(a:TClass, b:TClass):Bool {
			var x = a;
			while (x != null && x != b) x = x.clSuper == null ? null : x.clSuper.cls;
			return x != null;
		}
		return sub(cls, d) && (recv == null || sub(recv, cls));
	}

	// (TypeScript) a generic method's call with its type arguments, as the call has them, where TypeScript has the
	// receiver's type (on `any`, it takes none)
	function typeArgs(f:Ex, callee:TExpr):Ex {
		// (a receiver TypeScript has as `any`, a cast's on the way)
		function anyOn(e:Ex):Bool return switch e.def {
			case EAs(_): true;
			case EAsType(o, _): anyOn(o);
			case EMember(o, _) | EField(o, _, _) | EIndex(o, _) | ECall(o, _) | ETypeArgs(o, _) | EFriend(o, _): anyOn(o);
			case EAccessor(_, c, _): anyOn(c);
			case EBacked(_, x): anyOn(x);
			case _: false;
		}
		if (anyOn(f)) return f;
		return switch callee.eexpr {
			case TField(o, FStatic(c, cf) | FInstance(c, _, cf)) if (paramsOf(c, cf).length > 0 && !hasClassFlag(c, CExtern)
				&& f.def.match(EMember(_) | EField(_) | EIndex(_) | EId(_) | ERef(_) | EFriend(_)) && (o.eexpr.match(TTypeExpr(_)) || follow(o.etype).match(TInst(_, _))) && typed(o)):
				var args = instantiation(paramsOf(c, cf), cf.cfType, callee.etype);
				args == null ? f : ex(ETypeArgs(f, args), f.pos);
			case _: f;
		}
	}

	static function typed(e:TExpr):Bool return switch e.eexpr {
		case TTypeExpr(_) | TConst(TThis | TSuper): true;
		// (and as declared: a method returning an abstract, which TypeScript has as `any`)
		case TCall(f, _): typed(f) && !Casts.tsAny(e.etype) && !declaredAny(f);
		case TField(_, FInstance(c, _, _) | FStatic(c, _)) if (hasClassFlag(c, CExtern)): false;
		case TField(x, _) | TParenthesis(x) | TMeta(_, x): !Casts.tsAny(e.etype) && typed(x);
		case _: !Casts.tsAny(e.etype);
	}

	static function declaredAny(f:TExpr):Bool return switch Texpr.skip(f).eexpr {
		// (a static's of a type parameter not its own, an abstract's: out of scope, `any`)
		case TField(_, FStatic(c, cf)): switch follow(cf.cfType) {
				case TFun(s): Casts.tsAny(s.ret) || switch follow(s.ret) {
						case TInst({clKind: KTypeParameter(p)}, _): !Lambda.exists(paramsOf(c, cf), x -> x.ttpName == p.ttpName);
						case _: false;
					}
				case _: false;
			}
		case TField(_, FInstance(_, _, cf)): switch follow(cf.cfType) {
				case TFun(s): Casts.tsAny(s.ret);
				case _: false;
			}
		case _: false;
	}

	// (TypeScript) a function's type parameters: its own; an abstract's implementation's, the abstract's first (abstractThis)
	static function paramsOf(c:TClass, cf:TClassField):Array<TypedTypeParam> {
		var own = cf.cfParams.toArray();
		return switch c.clKind {
			case KAbstractImpl(a) if (a.aParams.length > 0):
				[for (p in a.aParams) if (!Lambda.exists(own, x -> x.ttpName == p.ttpName)) p].concat(own);
			case _: own;
		}
	}

	// the type arguments of type parameters (params) of a field's type (ft) in t, its type where it is used (null: one not
	// found)
	static function instantiation(params:Array<TypedTypeParam>, ft:T, t:T):Null<Array<T>> {
		var found = new Map<String, T>();
		function walk(d:T, a:T, depth:Int) {
			if (depth > 20) return;
			switch [d, a] {
				case [TInst({clKind: KTypeParameter(p)}, _), _] if (Lambda.exists(params, x -> x.ttpName == p.ttpName) && !found.exists(p.ttpName)):
					found.set(p.ttpName, a);
				case [TMono(m), _] if (m.tmType != null): walk(m.tmType, a, depth + 1);
				case [_, TMono(m)] if (m.tmType != null): walk(d, m.tmType, depth + 1);
				case [TLazy(l), _]: walk(lazyType(l), a, depth + 1);
				case [_, TLazy(l)]: walk(d, lazyType(l), depth + 1);
				case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
					for (i in 0...s1.args.length) walk(s1.args[i].type, s2.args[i].type, depth + 1);
					walk(s1.ret, s2.ret, depth + 1);
				case [TInst(c1, p1), TInst(c2, p2)] if (c1 == c2 && p1.length == p2.length):
					for (i in 0...p1.length) walk(p1[i], p2[i], depth + 1);
				case [TEnum(e1, p1), TEnum(e2, p2)] if (e1 == e2 && p1.length == p2.length):
					for (i in 0...p1.length) walk(p1[i], p2[i], depth + 1);
				case [TAbstract(a1, p1), TAbstract(a2, p2)] if (a1 == a2 && p1.length == p2.length):
					for (i in 0...p1.length) walk(p1[i], p2[i], depth + 1);
				case [TType(t1, p1), TType(t2, p2)] if (t1 == t2 && p1.length == p2.length):
					for (i in 0...p1.length) walk(p1[i], p2[i], depth + 1);
				case _:
			}
		}
		walk(ft, t, 0);
		var out = [];
		for (p in params) {
			var a = found.get(p.ttpName);
			if (a == null) return null;
			out.push(a);
		}
		return out;
	}

	static function genericCtor(e:TExpr):Bool return switch e.eexpr {
		case TParenthesis(x) | TMeta(_, x): genericCtor(x);
		case TField(_, FEnum(en, ef)): en.eParams.length > 0 && follow(ef.efType).match(TFun(_));
		case _: false;
	}

	// whether f uses its own `this`, `super` or `arguments` (untyped code naming them too): no arrow then
	static function hasOwnThis(f:TFunc):Bool {
		function names(s:String):Bool {
			var i = 0, n = s.length;
			inline function word(c:Int) return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code || c == "$".code;
			while (i < n) {
				if (word(StringTools.fastCodeAt(s, i))) {
					var s0 = i;
					while (i < n && word(StringTools.fastCodeAt(s, i))) i++;
					switch s.substring(s0, i) {
						case "this" | "super" | "arguments" | "eval": return true;
						case _:
					}
				} else i++;
			}
			return false;
		}
		function loop(e:TExpr):Bool {
			return switch e.eexpr {
				case TConst(TThis | TSuper): true;
				case TIdent(s): names(s);
				case TFunction(_): false;
				case TCall(c, args) if (Genjs.isCodeInjectionFunction(c)):
					switch args.length > 0 ? args[0].eexpr : null {
						case TConst(TString(s)):
							if (names(s)) return true;
							for (i in 1...args.length) if (loop(args[i])) return true;
							false;
						case _: true;
					}
				case _: Texpr.checkExpr(loop, e);
			}
		}
		for (a in f.tfArgs) if (a.defaultValue != null && loop(a.defaultValue)) return true;
		return loop(f.tfExpr);
	}
}
