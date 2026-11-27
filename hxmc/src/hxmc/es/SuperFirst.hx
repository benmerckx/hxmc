package hxmc.es;

import core.TType;
import core.Ast;
import core.TFunctions.*;
import generators.Gctx;

// Before Genjs's constructor rewrite (filters.ES6Ctors: `this` before `super()` makes a class and its ancestors
// construct through `_hx_constructor`, which TypeScript cannot type): what a constructor does before `super(...)`
// from its first statement with `this` on (its field initializers, which Haxe puts first, and what follows them)
// moves after it, in its order, where that cannot be told apart:
//   - those statements use `this` only for the class's own variables (not an ancestor's, nor in a closure, nor
//     passing it on): nothing before `super()` sees the object
//   - `super`'s arguments have no effects and use none of the locals those statements declare or assign
//   - the ancestors' constructors (field initializers included) only assign their fields values without
//     effects or `this`, and call `super` with such arguments: they cannot see the moved fields, nor run code
//     the moved statements could; an extern's constructor (the root) is trusted to do as little, as JavaScript's
//     class fields have it (initialized after `super()`)
class SuperFirst {
	public static function run(com:Gctx) {
		for (t in com.types) switch t {
			case TClassDecl(c) if (c.clSuper != null && !hasClassFlag(c, CExtern)): hoist(c);
			case _:
		}
	}

	static function hoist(c:TClass) {
		var ctor = c.clConstructor;
		if (ctor == null) return;
		var tf = switch ctor.cfExpr {
			case {eexpr: TFunction(tf)}: tf;
			case _: return;
		}
		var el = switch tf.tfExpr.eexpr {
			case TBlock(el): el.toArray();
			case _: return;
		}
		var k = -1;
		for (i in 0...el.length) if (isSuperCall(el[i])) {
			k = i;
			break;
		}
		if (k <= 0) return;
		// (from the first statement with `this` on, in their order; none of them with `this` but for c's own
		// variables, the arguments without a local they declare or assign)
		var first = 0;
		while (first < k && !usesThis(el[first])) first++;
		if (first == k) return;
		var kept = el.slice(0, first), moved = el.slice(first, k);
		var written = new Map<Int, Bool>();
		for (e in moved) {
			if (!readsOwn(c, e)) return;
			for (v => _ in writes(e)) written.set(v, true);
		}
		switch el[k].eexpr {
			case TCall(_, args):
				for (a in args.toArray()) if (usesThis(a) || !pure(a) || Lambda.exists(reads(a), v -> written.exists(v))) return;
			case _:
				return;
		}
		if (!inert(c.clSuper.cls)) return;
		var body = kept.concat([el[k]]).concat(moved).concat(el.slice(k + 1));
		var e = mk(TBlock(haxe.ds.Vector.fromArrayCopy(body)), tf.tfExpr.etype, tf.tfExpr.epos);
		ctor.cfExpr = mk(TFunction({tfArgs: tf.tfArgs, tfType: tf.tfType, tfExpr: e}), ctor.cfExpr.etype, ctor.cfExpr.epos);
	}

	static function isSuperCall(e:TExpr):Bool return e.eexpr.match(TCall({eexpr: TConst(TSuper)}, _));

	// f a variable of c's own (an ancestor's could be one its constructor assigns; a property's accessors are
	// calls in the typed tree: this is its storage)
	static function own(c:TClass, f:TClassField):Bool {
		if (!f.cfKind.match(Var(_))) return false;
		for (x in c.clFields) if (x.cfName == f.cfName) return true;
		return false;
	}

	// whether a constructor (of an ancestor, and theirs) cannot see a subclass's fields nor have effects
	static final inertCache = new Map<TClass, Bool>();

	static function inert(c:TClass):Bool {
		if (hasClassFlag(c, CExtern)) return true;
		var cached = inertCache.get(c);
		if (cached != null) return cached;
		inertCache.set(c, false);
		var ok = switch c.clConstructor {
			case null: c.clSuper == null || inert(c.clSuper.cls);
			case {cfExpr: {eexpr: TFunction(tf)}}:
				var el = switch tf.tfExpr.eexpr {
					case TBlock(el): el.toArray();
					case _: [tf.tfExpr];
				}
				var calls = 0;
				Lambda.foreach(el, e -> switch e.eexpr {
					case TCall({eexpr: TConst(TSuper)}, args):
						calls++;
						Lambda.foreach(args.toArray(), a -> !usesThis(a) && pure(a));
					case TBinop(OpAssign, {eexpr: TField({eexpr: TConst(TThis)}, FInstance(_, _, f))}, v):
						f.cfKind.match(Var(_)) && !usesThis(v) && pure(v);
					case TReturn(null):
						true;
					case _:
						!usesThis(e) && pure(e);
				}) && (c.clSuper == null || inert(c.clSuper.cls));
			case _: false;
		}
		inertCache.set(c, ok);
		return ok;
	}

	// whether e uses `this` only to read c's own variables (not in a closure, which could run later)
	static function readsOwn(c:TClass, e:TExpr):Bool {
		var ok = true;
		function loop(e:TExpr, inFunction:Bool) {
			if (!ok) return;
			switch e.eexpr {
				case TField({eexpr: TConst(TThis)}, FInstance(_, _, f)) if (!inFunction && own(c, f)):
				case TConst(TThis | TSuper) | TIdent("`this"):
					ok = false;
				case TFunction(f):
					loop(f.tfExpr, true);
				case _:
					core.Texpr.iter(x -> loop(x, inFunction), e);
			}
		}
		loop(e, false);
		return ok;
	}

	// the locals e declares or assigns (ids), and those it reads
	static function writes(e:TExpr):Map<Int, Bool> {
		var out = new Map<Int, Bool>();
		function loop(e:TExpr) {
			switch e.eexpr {
				case TVar(v, _):
					out.set(v.vId, true);
				case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, _) | TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
					out.set(v.vId, true);
				case _:
			}
			core.Texpr.iter(loop, e);
		}
		loop(e);
		return out;
	}

	static function reads(e:TExpr):Array<Int> {
		var out = [];
		function loop(e:TExpr) {
			switch e.eexpr {
				case TLocal(v): out.push(v.vId);
				case _:
			}
			core.Texpr.iter(loop, e);
		}
		loop(e);
		return out;
	}

	static function usesThis(e:TExpr):Bool {
		var found = false;
		function loop(e:TExpr) {
			if (found) return;
			switch e.eexpr {
				case TConst(TThis | TSuper):
					found = true;
				case TIdent("`this"):
					found = true;
				case _:
					core.Texpr.iter(loop, e);
			}
		}
		loop(e);
		return found;
	}

	// no effects: values, locals (declared, assigned), closures (made, not called), plain field reads
	static function pure(e:TExpr):Bool {
		return switch e.eexpr {
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): true;
			case TVar(_, init): init == null || pure(init);
			case TBinop(OpAssign, {eexpr: TLocal(_)}, b): pure(b);
			case TBinop(OpAssign | OpAssignOp(_), _, _): false;
			case TBinop(_, a, b): pure(a) && pure(b);
			case TUnop(Increment | Decrement, _, _): false;
			case TUnop(_, _, a): pure(a);
			case TField(x, FInstance(_, _, f) | FStatic(_, f) | FAnon(f)) if (f.cfKind.match(Var(_))): pure(x);
			case TField(x, FDynamic(_) | FEnum(_, _)): pure(x);
			case TArrayDecl(el): Lambda.foreach(el.toArray(), pure);
			case TObjectDecl(fl): Lambda.foreach(fl.toArray(), f -> pure(f.expr));
			case TParenthesis(x) | TMeta(_, x) | TCast(x, null): pure(x);
			case TArray(a, b): pure(a) && pure(b);
			case TBlock(el): Lambda.foreach(el.toArray(), pure);
			case _: false;
		}
	}
}
