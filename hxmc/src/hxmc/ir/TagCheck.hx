package hxmc.ir;

import hxmc.ir.Ir;
import haxe.ds.Vector;

// A type parameter's value is a tagged word (RTag; hxmc.rt.Tagged, docs/hxmc.md,
// "Values of type parameters"): a reference, or an Int or a Float encoded. It
// shares Dynamic's 64 bits, not its meaning: where code reads it as Dynamic
// (the runtime's arguments, a Dynamic's, a Null<T>'s or a structure's slot,
// a box to unbox, a type test) a scalar's word is boxed first, and where it
// reads a number it is decoded (FnLower.coerce: EUntag). A conversion the
// lowering misses would be a crash at run time, or a wrong value; this check
// of every function's final IR (Lower.bindHosts: the runtime's functions
// bound) makes it a build error instead, naming the function and the place.
// Words flow as they are into a word's slot and into a class's, an enum's,
// an array's or a function's (no scalar is one of those: the reference
// itself), and any reference flows into a word's slot.
class TagCheck {
	var fi:FuncInfo;
	var globals:Array<{ty:Ty, init:Null<CtorInfo>, name:String, ?tls:String, ?bss:Int, ?sym:String, ?exp:String}>;

	function new(fi, globals) {
		this.fi = fi;
		this.globals = globals;
	}

	public static function func(fi:FuncInfo, prog:Program) {
		var c = new TagCheck(fi, prog.globals);
		c.stmts(fi.body);
	}

	static inline function isTag(t:Ty):Bool
		return Ir.isWord(t);

	// a slot of type `to` that must not take a word as it is
	static function readsDynamic(to:Ty):Bool
		return switch to {
			case TI32 | TBool | TF64 | TI64 | TU8: true;
			case TRef(RAny | RNull(TBool | TI64) | RAnon | RNative(_)): true;
			case _: false;
		}

	function fail(what:String):Dynamic
		throw 'hxmc: internal error: a type parameter\'s tagged word $what without conversion in ${fi.display != null ? fi.display : fi.name} (hxmc.ir.TagCheck)';

	function flow(x:Ex, to:Ty, what:String) {
		var from = Ir.typeOf(x);
		if (isTag(from) && readsDynamic(to)) fail('flows into $what (${Ir.repr(to)}: ${show(x, 3)})');
		if (isTag(to) && Ir.isScalar(from)) fail('is made from a number for $what (${show(x, 3)})');
	}

	function notTag(x:Ex, what:String)
		if (isTag(Ir.typeOf(x))) fail('is $what (${show(x, 3)})');

	// (the expression, for the error: its constructors, locals and callees, to depth d)
	static function show(e:Ex, d:Int):String {
		var name = switch e {
			case ELocal(l): return "local " + l.name;
			case EInt(v): return Std.string(v);
			case ECall(f, _): "ECall " + (f.display != null ? f.display : f.name);
			case ECallHost(n, _, _): "ECallHost " + n;
			case EField(c, idx, _): "EField " + c.name + "." + c.fields[idx].name;
			case _: e.getName();
		};
		if (d == 0) return name;
		var subs = [];
		Facts.iterEx(x -> subs.push(show(x, d - 1)), e);
		return subs.length == 0 ? name : name + "(" + subs.join(", ") + ")";
	}

	function exs(xs:Vector<Ex>, tys:Int->Null<Ty>, what:String) {
		for (i in 0...xs.length) {
			var t = tys(i);
			if (t != null) flow(xs[i], t, what + " (argument " + i + ")");
			ex(xs[i]);
		}
	}

	function ex(e:Ex) {
		switch e {
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | ELocal(_) | EGlobal(_, _) | EType(_) | ENewObj(_):
			case EBin(op, a, b):
				if (op != RefEq && op != RefNe) {
					notTag(a, "an operand of " + op.getName());
					notTag(b, "an operand of " + op.getName());
				}
				ex(a);
				ex(b);
			case ENot(a) | EConv(_, a):
				notTag(a, "an operand of " + e.getName());
				ex(a);
			case EBox(t, a):
				flow(a, t, "a box");
				ex(a);
			case EUnbox(_, a):
				notTag(a, "unboxed");
				ex(a);
			case EInstOf(_, a):
				notTag(a, "type-tested");
				ex(a);
			case EEnumTag(a, _):
				notTag(a, "read as an enum value");
				ex(a);
			// (a word's bits as an Int64, deliberately: hx_tag_is reads them)
			case ECast(TI64, a) if (isTag(Ir.typeOf(a))):
				ex(a);
			case ECast(t, a):
				flow(a, t, "a cast");
				ex(a);
			case ETag(_, a) | EUntag(_, a) | EField(_, _, a) | EFieldAddr(_, _, a) | EAnonGet(_, _, a, _) | EEnumParam(_, _, a) | EArrLen(a) | EBoxGet(_, a) | ECapture(_, _, a):
				ex(a);
			case EArrGet(_, a, i) | EArrGetU(_, a, i):
				ex(a);
				ex(i);
			case ECall(f, args):
				exs(args, i -> i < f.args.length ? f.args[i].ty : null, "a call of " + (f.display != null ? f.display : f.name));
			case ECallDispatch(_, s, args):
				exs(args, i -> i < s.args.length ? s.args[i] : null, "a virtual call");
			case ECallClos(s, c, args):
				ex(c);
				exs(args, i -> i < s.args.length ? s.args[i] : null, "a closure call");
			case ECallAnon(_, s, o, args):
				ex(o);
				exs(args, i -> i < s.args.length ? s.args[i] : null, "a structural call");
			case ECallHost(n, args, _):
				// (the runtime's arguments are Dynamic's: only hx_tag_eq takes words)
				exs(args, i -> n == "hx_tag_eq" ? null : TRef(RAny), "the runtime's " + n);
			case ENewEnum(c, args):
				exs(args, i -> c.params[i], "an enum argument");
			case ENewArr(elem, args):
				exs(args, i -> elem, "an array element");
			case ENewClos(l, args):
				exs(args, i -> l.captures[i].ty, "a capture");
			case ENewBox(t, a):
				flow(a, t, "a captured variable");
				ex(a);
			case ENewAnon(_, args):
				// (Dynamic slots, whatever the shape's first object had there: FnLower)
				exs(args, i -> TRef(RAny), "a structure's field");
		}
	}

	function stmts(ss:Vector<Stmt>)
		for (s in ss)
			stmt(s);

	function stmt(s:Stmt) {
		switch s {
			case SSet(l, e):
				flow(e, l.ty, "a local (" + l.name + ")");
				ex(e);
			case SExpr(e):
				ex(e);
			case SSetField(c, idx, o, v):
				ex(o);
				flow(v, c.fields[idx].ty, "the field " + c.name + "." + c.fields[idx].name);
				ex(v);
			case SAnonSet(name, t, o, v):
				if (isTag(t)) fail("is stored through a structure (" + name + ")");
				ex(o);
				flow(v, t, "the structural field " + name);
				ex(v);
			case SArrSet(elem, _, i, v):
				ex(i);
				flow(v, elem, "an array element");
				ex(v);
			case SArrPush(elem, _, v):
				flow(v, elem, "an array element");
				ex(v);
			case SBoxSet(t, b, v):
				ex(b);
				flow(v, t, "a captured variable");
				ex(v);
			case SSetGlobal(g, v):
				flow(v, globals[g].ty, "the static " + globals[g].name);
				ex(v);
			case SIf(c, a, b):
				notTag(c, "a condition");
				ex(c);
				stmts(a);
				stmts(b);
			case SLoop(body):
				stmts(body);
			case SBreak | SContinue | SPos(_, _):
			case SSwitch(e, cases, def):
				notTag(e, "switched on");
				ex(e);
				for (c in cases)
					stmts(c.body);
				stmts(def);
			case SReturn(e):
				if (e != null) {
					flow(e, fi.ret, "the result");
					ex(e);
				}
			case SThrow(e):
				notTag(e, "thrown");
				ex(e);
			case STry(body, catches):
				stmts(body);
				for (c in catches)
					stmts(c.body);
			case SCold(_, s):
				stmt(s);
		}
	}
}
