package hxmc.wasmgc;

import hxmc.Buf;
import hxmc.ir.Ir;
import hxmc.wasm.Enc;

private enum Frame {
	FBreak; // a loop's exit
	FLoop; // a loop's head
	FPlain; // if, switch blocks, try
}

// One function of the IR as a WasmGC function body (GcModule). The IR's
// statements are structured, so they map onto wasm's blocks: a loop is a
// block (its exit) around a loop (its head), a switch nested blocks and a
// br_table. Locals are the function's (references as eqref unless their IR
// type proves one: keyOf), plus temporaries taken and given back around the
// code that needs them. A local or parameter of no such type that the code
// only ever casts to one type (Dynamic and closure parameters read as a
// class, a runtime function's Dynamic as Bytes) gets that type: the function
// is emitted again with the local of that type, cast where it is set (a
// parameter: once, on entry) instead of where it is read (refine).
class FuncGen {
	final m:GcModule;
	final f:FuncInfo;
	final b = new Buf();
	final local = new Map<Int, Int>();
	final extra:Array<String> = []; // the locals after the parameters: a representation, or "t<type>" (ref null type)
	final localKey = new Map<Int, String>(); // a local's (by id) type, as extra's
	final free = new Map<String, Array<Int>>();
	final frames:Array<Frame> = [];
	var nparams = 0;
	// the locals given a type (a second emission), by id
	final refined:Map<Int, Int>;
	// the types each untyped local is cast to where read, and those read otherwise
	final castUses = new Map<Int, Map<Int, Bool>>();
	final otherUses = new Map<Int, Bool>();
	var castUse = false;
	// the frame areas (Mem.stack, struct slots) in the linear memory: their
	// size, the frame's base and the stack pointer on entry (restored on return)
	// the locals set from a Dynamic cast to their type (Haxe's unchecked
	// casts, `t = any` for a String t): of no wasm type (a value of another
	// type may be held, as in linear memory, cast only where used as one)
	final loose = new Map<Int, Bool>();
	var hasFrame = false;
	var frameSize = 0;
	var fp = -1;
	var spEntry = -1;

	public function new(m:GcModule, f:FuncInfo, ?refined:Map<Int, Int>) {
		this.m = m;
		this.f = f;
		this.refined = refined != null ? refined : new Map();
	}

	// the locals the code only casts to one type (for a second emission), or null
	public function refine():Null<Map<Int, Int>> {
		var r = null;
		for (id => ts in castUses) {
			if (otherUses.exists(id) || loose.exists(id)) continue;
			var t = -1, n = 0;
			for (k in ts.keys()) {
				t = k;
				n++;
			}
			if (n != 1) continue;
			if (r == null) r = new Map();
			r.set(id, t);
		}
		return r;
	}

	static function repr(t:Ty):String
		return GcModule.repr(t);

	// a reference type the IR's type proves (a class's: locals of it keep its
	// type, so that their fields are read without a cast), else the representation
	function keyOf(t:Ty):String
		return m.keyOf(t);

	public function emit():Buf {
		var shadows = [];
		for (i in 0...f.args.length) {
			var a = f.args[i];
			local.set(a.id, nparams++);
			localKey.set(a.id, m.paramKey(f, i));
			// (a parameter of a class type, or this, or refined: cast once into a local of its type)
			var k = refined.exists(a.id) ? "t" + refined.get(a.id) : m.precise(f) ? "" : i == 0 && f.selfClass != null ? "t" + m.classType(f.selfClass) : keyOf(a.ty);
			if (k.charAt(0) == "t") shadows.push({param: nparams - 1, id: a.id, key: k});
		}
		for (s in shadows) {
			var i = nparams + extra.length;
			extra.push(s.key);
			localGet(s.param);
			castTo(Std.parseInt(s.key.substr(1)));
			localSet(i);
			local.set(s.id, i);
			localKey.set(s.id, s.key);
		}
		var code = m.uses.bodies.get(f);
		function setSt(s:Stmt) {
			switch s {
				case SSet(l, ECast(TRef(_), x) | x) if (!l.ty.match(TRef(RAny)) && dynamicTyped(x)): loose.set(l.id, true);
				case _:
			}
			hxmc.ir.Facts.iterStmt(setSt, _ -> {}, s);
		}
		for (s in code.body)
			setSt(s);
		function frameEx(e:Ex) {
			switch e {
				case ECallHost("hxmc_unsafe_Mem_stack" | "hxmc_unsafe_Mem_structSlot", _, _): hasFrame = true;
				case _:
			}
			hxmc.ir.Facts.iterEx(frameEx, e);
		}
		function frameSt(s:Stmt)
			hxmc.ir.Facts.iterStmt(frameSt, frameEx, s);
		for (s in code.body)
			frameSt(s);
		if (hasFrame) {
			fp = nparams + extra.length;
			extra.push("i");
			spEntry = nparams + extra.length;
			extra.push("i");
		}
		for (l in code.locals)
			if (!local.exists(l.id) && repr(l.ty) != "v") {
				local.set(l.id, nparams + extra.length);
				var k = refined.exists(l.id) ? "t" + refined.get(l.id) : loose.exists(l.id) ? repr(l.ty) : keyOf(l.ty);
				extra.push(k);
				localKey.set(l.id, k);
			}
		for (s in code.body)
			stmt(s);
		if (repr(f.ret) != "v") b.u8(0x00) else leave(); // (a value-returning function ends with a return)
		b.u8(0x0B);
		// the locals' declarations in front
		var out = new Buf();
		Enc.uleb(out, extra.length);
		for (r in extra) {
			out.u8(1);
			switch r {
				case "i": out.u8(Enc.I32);
				case "f": out.u8(Enc.F64);
				case "l": out.u8(Enc.I64);
				case "p": out.u8(0x6D);
				case _:
					out.u8(0x63);
					Enc.sleb(out, Std.parseInt(r.substr(1)));
			}
		}
		if (hasFrame) {
			// (the frame: below the caller's)
			out.u8(0x23);
			Enc.uleb(out, m.spGlobal);
			out.u8(0x22);
			Enc.uleb(out, spEntry);
			out.u8(0x41);
			Enc.sleb(out, (frameSize + 15) & ~15);
			out.u8(0x6B);
			out.u8(0x22);
			Enc.uleb(out, fp);
			out.u8(0x24);
			Enc.uleb(out, m.spGlobal);
		}
		out.buf(b);
		return out;
	}

	// (before a return: the frame given back)
	function leave() {
		if (!hasFrame) return;
		localGet(spEntry);
		op(0x24);
		Enc.uleb(b, m.spGlobal);
	}

	// an expression of the IR's Dynamic (Any, type parameters)
	static function dynamicTyped(e:Ex):Bool
		return switch e {
			case ELocal(l): l.ty.match(TRef(RAny));
			case ECall(fn, _): fn.ret.match(TRef(RAny));
			case ECallHost(_, _, t) | EAnonGet(_, t, _, _) | EArrGet(t, _, _) | EArrGetU(t, _, _) | EBoxGet(t, _): t.match(TRef(RAny));
			case ECallClos(s, _, _) | ECallDispatch(_, s, _) | ECallAnon(_, s, _, _): s.ret.match(TRef(RAny));
			case EField(c, idx, _): c.fields[idx].ty.match(TRef(RAny));
			case _: false;
		}

	function unsupported(what:String):Dynamic
		throw 'hxmc: -D hxmc.wasm-gc: ${f.display != null ? f.display : f.name}: $what is not supported yet';

	// ---- temporaries

	function temp(r:String):Int {
		var l = free.get(r);
		if (l != null && l.length > 0) return l.pop();
		var i = nparams + extra.length;
		extra.push(r);
		return i;
	}

	function release(r:String, i:Int) {
		var l = free.get(r);
		if (l == null) free.set(r, l = []);
		l.push(i);
	}

	inline function op(x:Int)
		b.u8(x);

	function localGet(i:Int) {
		op(0x20);
		Enc.uleb(b, i);
	}

	function localSet(i:Int) {
		op(0x21);
		Enc.uleb(b, i);
	}

	function localTee(i:Int) {
		op(0x22);
		Enc.uleb(b, i);
	}

	function i32(v:Int) {
		op(0x41);
		Enc.sleb(b, v);
	}

	function call(i:Int) {
		op(0x10);
		Enc.uleb(b, i);
	}

	function castTo(t:Int)
		m.castTo(b, t);

	// an expression's static wasm type, as extra's keys ("n": null, a subtype of all)
	function wtype(e:Ex):String
		return switch e {
			case ELocal(l): localKey.exists(l.id) ? localKey.get(l.id) : repr(l.ty);
			case ENewObj(c): "t" + m.classType(c);
			case ECall(fn, _): m.retKey(fn);
			case EField(c, idx, _): m.fieldKey(c, idx);
			case EStr(_): "t" + m.stringType;
			case ECast(_, x): wtype(x);
			case ENull(_): "n";
			case EGlobal(g, _): m.globalKey(g);
			case EEnumParam(c, idx, _): m.ctorParamKey(c, idx);
			case ECapture(l, idx, _): m.captureKey(l, idx);
			case ENewEnum(c, _): "t" + (c.params.length == 0 ? m.enumTypeOf(c.en) : m.ctorType(c));
			case ENewArr(t, _): "t" + m.arrType(GcModule.elemKind(t));
			case ENewClos(l, _): "t" + m.lambdaTypeOf(l);
			case ENewBox(t, _): "t" + m.boxType(t);
			case ENewAnon(s, _): "t" + m.shapeType(s);
			case ECallHost("hxmc_narray_new", [EInt(k), _], _): "t" + m.naType(GcModule.NA_KINDS[k]);
			case _: rOf(e);
		}

	// the kind of the NativeArray storage e's static type is (GcModule.NA_KINDS), or null
	function dataKind(e:Ex):Null<String> {
		var k = wtype(e);
		return k.charAt(0) == "t" ? m.naKindOf(Std.parseInt(k.substr(1))) : null;
	}

	// the value of e on the stack as a value of key k (keyOf: cast when a type)
	function exprKey(e:Ex, k:String)
		if (k.charAt(0) == "t") exprAs(e, Std.parseInt(k.substr(1))) else expr(e);

	// the value of e on the stack as a (ref null t): cast unless its type already is one
	function exprAs(e:Ex, t:Int) {
		// (an untyped local cast: noted for refine)
		var l = castBase(e);
		if (l != null) {
			var ts = castUses.get(l.id);
			if (ts == null) castUses.set(l.id, ts = new Map());
			ts.set(t, true);
			castUse = true;
		}
		expr(e);
		castUse = false;
		var k = wtype(e);
		if (k == "n") return;
		if (k.charAt(0) == "t" && m.isSubtype(Std.parseInt(k.substr(1)), t)) return;
		castTo(t);
	}

	function gc(o:Int, ?a:Int, ?c:Int)
		m.gc(b, o, a, c);

	// ---- null access (docs/hxmc.md, "Null access")

	// e's value on the stack as a (ref t), about to be dereferenced: with the
	// explicit tests of -D hxmc.null-checks (Lower.nullChecks, WebAssembly's
	// default), null calls rt_null_access, which throws "Null Access" (the
	// engine would trap, and no handler catches a trap)
	function derefAs(e:Ex, t:Int) {
		var id = localOf(e);
		if (!hxmc.ir.Lower.nullChecks || f.declNoGc || nonNull(e) || id != null && checked.exists(id)) {
			exprAs(e, t);
			return;
		}
		exprAs(e, t);
		call(m.nonNullOf(t));
		if (id != null) checked.set(id, true);
	}

	// The locals tested since their last assignment on every path here (a
	// test dominating this point): their tests are not repeated. A nested
	// statement list (a branch, a loop's or a try's body, a handler) starts
	// with what was known before it and gives back nothing but the locals it
	// assigns forgotten (they may differ after it); a loop forgets them before
	// its body too (the next iteration).
	var checked = new Map<Int, Bool>();

	function localOf(e:Ex):Null<Int>
		return switch e {
			case ELocal(l): l.id;
			case ECast(_, x): localOf(x);
			case _: null;
		}

	function scoped(ss:Array<Stmt>) {
		var saved = checked;
		checked = saved.copy();
		stmts(ss);
		checked = saved;
		forgetAssigned(ss);
	}

	function forgetAssigned(ss:Array<Stmt>) {
		if (!checked.keys().hasNext()) return;
		function st(s:Stmt) {
			switch s {
				case SSet(l, _): checked.remove(l.id);
				case _:
			}
			hxmc.ir.Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in ss)
			st(s);
	}

	// a value never null: made here, a literal, a constructor's object
	// (new), a closure's own (its call tests it: ECallClos); not a method's
	// receiver (as MirBuild.nonNull)
	function nonNull(e:Ex):Bool
		return switch e {
			case ELocal(l): f.args.length > 0 && l.id == f.args[0].id && (f.lambda != null || MirBuild.isCtor(f));
			case EStr(_) | EType(_) | ENewObj(_) | ENewEnum(_) | ENewArr(_) | ENewClos(_) | ENewBox(_) | ENewAnon(_): true;
			case ECast(_, x): nonNull(x);
			case _: false;
		}

	function castBase(e:Ex):Null<Local>
		return switch e {
			case ELocal(l) if (localKey.get(l.id) == "p"): l;
			case ECast(_, x): castBase(x);
			case _: null;
		}

	// ---- statements

	function block(kind:Frame, opcode:Int) {
		op(opcode);
		op(0x40);
		frames.push(kind);
	}

	function end() {
		op(0x0B);
		frames.pop();
	}

	function depthOf(kind:Frame):Int {
		var i = frames.length - 1;
		while (i >= 0) {
			if (frames[i] == kind) return frames.length - 1 - i;
			i--;
		}
		throw "no enclosing loop";
	}

	function stmts(ss:Array<Stmt>)
		for (s in ss)
			stmt(s);

	function stmt(s:Stmt) {
		switch s {
			case SSet(l, e):
				var k = localKey.get(l.id);
				if (k != null && k.charAt(0) == "t") exprAs(e, Std.parseInt(k.substr(1))) else expr(e);
				if (local.exists(l.id)) localSet(local.get(l.id)) else if (rOf(e) != "v") op(0x1A);
				checked.remove(l.id);
			case SExpr(e):
				expr(e);
				if (rOf(e) != "v") op(0x1A);
			case SSetField(c, idx, o, v):
				derefAs(o, m.classType(c));
				var fk = m.fieldKey(c, idx);
				if (fk.charAt(0) == "t") exprAs(v, Std.parseInt(fk.substr(1))) else expr(v);
				gc(0x05, m.classType(c), idx + 1);
			case SAnonSet(name, t, o, v):
				// (directly into a layout made here that has the field, else through
				// the runtime: the field may be one added dynamically)
				var tmp = temp("p");
				var vx = inLocal(v);
				expr(o);
				localSet(tmp);
				var cands = anonCands(name, t, null);
				block(FPlain, 0x02);
				for (s in cands) {
					op(0x02);
					op(0x6D);
					localGet(tmp);
					castShape(s);
					localGet(vx.l);
					gc(0x05, m.shapeType(s), s.slot(name) + 1);
					op(0x0C);
					Enc.uleb(b, 1);
					op(0x0B);
					op(0x1A);
				}
				localGet(tmp);
				expr(EStr(name));
				localGet(vx.l);
				boxTop(t);
				call(m.exportOf("gc_anon_set"));
				end();
				vx.done();
				release("p", tmp);
			case SArrSet(elem, a, i, v):
				arrSet(GcModule.elemKind(elem), local.get(a.id), i, v);
			case SArrPush(elem, a, v):
				arrPush(GcModule.elemKind(elem), local.get(a.id), v);
			case SBoxSet(t, bx, v):
				exprAs(bx, m.boxType(t));
				expr(v);
				gc(0x05, m.boxType(t), 0);
			case SSetGlobal(g, v):
				exprKey(v, m.globalKey(g));
				op(0x24);
				Enc.uleb(b, m.globalOf(g));
			case SIf(c, a, e):
				expr(c);
				block(FPlain, 0x04);
				scoped(a);
				if (e.length > 0) {
					op(0x05);
					scoped(e);
				}
				end();
			case SLoop(body):
				block(FBreak, 0x02);
				block(FLoop, 0x03);
				forgetAssigned(body);
				scoped(body);
				op(0x0C);
				Enc.uleb(b, 0);
				end();
				end();
			case SBreak:
				op(0x0C);
				Enc.uleb(b, depthOf(FBreak));
			case SContinue:
				op(0x0C);
				Enc.uleb(b, depthOf(FLoop));
			case SSwitch(e, cases, def):
				switchStmt(e, cases, def);
			case SReturn(e):
				if (e != null) {
					var rk = m.retKey(f);
					if (rk.charAt(0) == "t") exprAs(e, Std.parseInt(rk.substr(1))) else expr(e);
				}
				leave();
				op(0x0F);
			case SThrow(e):
				expr(e);
				op(0x08);
				op(0);
			case STry(body, catches):
				tryStmt(body, catches);
			case SCold(_, x):
				stmt(x);
			case SPos(_, _):
		}
	}

	function switchStmt(e:Ex, cases:Array<{values:Array<Int>, body:Array<Stmt>}>, def:Array<Stmt>) {
		var t = temp("i");
		expr(e);
		localSet(t);
		var lo = 0x7fffffff, hi = -0x7fffffff, count = 0;
		for (c in cases)
			for (v in c.values) {
				if (v < lo) lo = v;
				if (v > hi) hi = v;
				count++;
			}
		// (the span in Float: string switches are on 32-bit hashes, whose difference overflows)
		if (count == 0 || (hi : Float) - lo > 4.0 * count + 16) {
			// sparse: tests one after the other
			var opened = 0;
			for (c in cases) {
				for (k in 0...c.values.length) {
					localGet(t);
					i32(c.values[k]);
					op(0x46);
					if (k > 0) op(0x72);
				}
				block(FPlain, 0x04);
				scoped(c.body);
				op(0x05);
				opened++;
			}
			scoped(def);
			for (_ in 0...opened)
				end();
			release("i", t);
			return;
		}
		// dense: blocks, the innermost holding the br_table; case k's body follows block k
		var n = cases.length;
		block(FPlain, 0x02); // the end
		block(FPlain, 0x02); // the default
		for (_ in 0...n)
			block(FPlain, 0x02);
		var targets = [for (_ in lo...hi + 1) n];
		for (k in 0...n)
			for (v in cases[k].values)
				targets[v - lo] = k;
		localGet(t);
		if (lo != 0) {
			i32(lo);
			op(0x6B);
		}
		op(0x0E);
		Enc.uleb(b, targets.length);
		for (x in targets)
			Enc.uleb(b, x);
		Enc.uleb(b, n);
		for (k in 0...n) {
			end();
			scoped(cases[k].body);
			// (to the end: past the remaining case blocks and the default)
			op(0x0C);
			Enc.uleb(b, n - k);
		}
		end();
		scoped(def);
		end();
		release("i", t);
	}

	// ---- arrays: the fast path inline (an array of the kind expected, in range),
	// else the helper's (another kind, growing, out of range: Helpers)

	// br_on_cast_fail to the enclosing block (its result an eqref): the eqref on
	// the stack not an array of kind k; else the array, then in tmp
	function castArr(k:String):Int {
		brOnCastFail(m.arrType(k));
		var t = temp("t" + m.arrType(k));
		localSet(t);
		return t;
	}

	// the value of e in a local (a temporary unless e is one), and its release
	function inLocal(e:Ex):{l:Int, done:Void->Void} {
		switch e {
			case ELocal(l) if (local.exists(l.id)):
				return {l: local.get(l.id), done: () -> {}};
			case _:
				var k = rOf(e);
				var t = temp(k);
				expr(e);
				localSet(t);
				return {l: t, done: () -> release(k, t)};
		}
	}

	function arrGet(k:String, a:Ex, i:Ex) {
		var r = k == "b" ? "i" : k;
		var ix = inLocal(i);
		op(0x02); // the result
		blockType(r);
		frames.push(FPlain);
		op(0x02); // the slow path: the eqref
		op(0x6D);
		frames.push(FPlain);
		expr(a);
		var t = castArr(k);
		localGet(ix.l);
		localGet(t);
		gc(0x02, m.arrType(k), 0);
		op(0x49); // i32.lt_u
		op(0x04);
		blockType(r);
		localGet(t);
		gc(0x02, m.arrType(k), 1);
		localGet(ix.l);
		gc(0x0B, m.dataType(k));
		op(0x05);
		m.constZero(b, r);
		op(0x0B);
		op(0x0C);
		Enc.uleb(b, 1);
		end();
		localGet(ix.l);
		call(Helpers.arrGet(m, k));
		end();
		release("t" + m.arrType(k), t);
		ix.done();
	}

	function arrSet(k:String, a:Int, i:Ex, v:Ex) {
		var ix = inLocal(i), vx = inLocal(v);
		block(FPlain, 0x02); // the end
		op(0x02); // the slow path: the eqref
		op(0x6D);
		frames.push(FPlain);
		localGet(a);
		var t = castArr(k);
		localGet(ix.l);
		localGet(t);
		gc(0x02, m.arrType(k), 0);
		op(0x49);
		op(0x04);
		op(0x40);
		localGet(t);
		gc(0x02, m.arrType(k), 1);
		localGet(ix.l);
		localGet(vx.l);
		gc(0x0E, m.dataType(k));
		op(0x0C);
		Enc.uleb(b, 2);
		op(0x0B);
		localGet(t);
		end();
		localGet(ix.l);
		localGet(vx.l);
		call(Helpers.arrSet(m, k));
		end();
		release("t" + m.arrType(k), t);
		vx.done();
		ix.done();
	}

	function arrPush(k:String, a:Int, v:Ex) {
		var vx = inLocal(v);
		var n = temp("i");
		block(FPlain, 0x02); // the end
		op(0x02); // the slow path: the eqref
		op(0x6D);
		frames.push(FPlain);
		localGet(a);
		var t = castArr(k);
		// (room in the storage: stored at the length, which grows by one)
		localGet(t);
		gc(0x02, m.arrType(k), 0);
		localTee(n);
		localGet(t);
		gc(0x02, m.arrType(k), 1);
		gc(0x0F);
		op(0x49);
		op(0x04);
		op(0x40);
		localGet(t);
		gc(0x02, m.arrType(k), 1);
		localGet(n);
		localGet(vx.l);
		gc(0x0E, m.dataType(k));
		localGet(t);
		localGet(n);
		i32(1);
		op(0x6A);
		gc(0x05, m.arrType(k), 0);
		op(0x0C);
		Enc.uleb(b, 2);
		op(0x0B);
		localGet(t);
		end();
		localGet(vx.l);
		call(Helpers.arrPush(m, k));
		end();
		release("i", n);
		release("t" + m.arrType(k), t);
		vx.done();
	}

	// ---- anonymous structures

	// the layouts (of the anonymous structures made) that may hold the field, of
	// t's representation: the type's own first; none when more than ANON_CANDS
	static inline var ANON_CANDS = 6;

	function anonCands(name:String, t:Ty, hint:Null<ShapeInfo>):Array<ShapeInfo> {
		var r = repr(t);
		function has(s:ShapeInfo):Bool {
			var k = s.slot(name);
			return k > 0 && repr(s.fields[k - 1].ty) == r;
		}
		var out = hint != null && has(hint) ? [hint] : [];
		for (s in m.uses.shapes.keys())
			if (s != hint && has(s)) out.push(s);
		if (out.length > ANON_CANDS) out = hint != null && has(hint) ? [hint] : [];
		return out;
	}

	// br_on_cast_fail to the enclosing block (its result an eqref) unless the eqref on the stack has the layout
	function castShape(s:ShapeInfo)
		brOnCastFail(m.shapeType(s));

	var excCount = 0;

	function tryStmt(body:Array<Stmt>, catches:Array<{test:Null<Ex->Ex>, l:Local, body:Array<Stmt>}>) {
		// (with a linear memory: the stack pointer as here again where an
		// exception is caught, the frames it left without returning given back)
		var sp = -1;
		if (m.memory) {
			sp = temp("i");
			op(0x23);
			Enc.uleb(b, m.spGlobal);
			localSet(sp);
		}
		block(FPlain, 0x06);
		scoped(body);
		op(0x07);
		op(0);
		var t = temp("p");
		localSet(t);
		if (sp >= 0) {
			localGet(sp);
			op(0x24);
			Enc.uleb(b, m.spGlobal);
			release("i", sp);
		}
		var exc = new Local(-1000 - excCount++, "exc", TRef(RAny));
		local.set(exc.id, t);
		var opened = 0, all = false;
		for (c in catches) {
			if (c.test != null) {
				expr(c.test(ELocal(exc)));
				block(FPlain, 0x04);
				opened++;
			}
			localGet(t);
			// (set from the exception, any value: never refined)
			otherUses.set(c.l.id, true);
			if (local.exists(c.l.id)) localSet(local.get(c.l.id)) else op(0x1A);
			checked.remove(c.l.id);
			scoped(c.body);
			if (c.test == null) {
				all = true;
				break;
			}
			op(0x05);
		}
		if (!all) {
			op(0x09);
			Enc.uleb(b, opened);
		}
		for (_ in 0...opened)
			end();
		end();
		release("p", t);
	}

	// ---- expressions

	public static function binR(o:BinOp):String
		return switch o {
			case Add | Sub | Mul | Mod | And | Or | Xor | Shl | Shr | UShr: "i";
			case Eq | Ne | Lt | Le | Gt | Ge | RefEq | RefNe: "i";
			case FAdd | FSub | FMul | FDiv | FMod: "f";
			case FEq | FNe | FLt | FLe | FGt | FGe: "i";
			case LAdd | LSub | LMul | LDiv | LMod | LAnd | LOr | LXor | LShl | LShr | LUShr: "l";
			case LEq | LNe | LLt | LLe | LGt | LGe: "i";
		}

	public static function rOf(e:Ex):String
		return switch e {
			case EInt(_): "i";
			case EF64(_): "f";
			case EStr(_): "p";
			case ENull(t): repr(t);
			case ELocal(l): repr(l.ty);
			case EGlobal(_, t): repr(t);
			case EBin(o, _, _): binR(o);
			case ENot(_): "i";
			case EConv(o, _):
				switch o {
					case I2F | FNeg | L2F: "f";
					case F2I | L2I: "i";
					case I2L | F2L | LNeg: "l";
				}
			case EBox(_, _): "p";
			case EUnbox(t, _): repr(t);
			case EField(c, idx, _): repr(c.fields[idx].ty);
			case EFieldAddr(_): "l";
			case EAnonGet(_, t, _, _): repr(t);
			case ECast(t, _): repr(t);
			case EInstOf(_, _) | EEnumTag(_, _) | EArrLen(_): "i";
			case EEnumParam(c, idx, _): repr(c.params[idx]);
			case EArrGet(t, _, _) | EArrGetU(t, _, _): repr(t);
			case EBoxGet(t, _): repr(t);
			case ECapture(l, idx, _): repr(l.captures[idx].ty);
			case EType(_): "p";
			case ECall(f, _): repr(f.ret);
			case ECallDispatch(_, s, _) | ECallClos(s, _, _) | ECallAnon(_, s, _, _): repr(s.ret);
			case ECallHost(_, _, t): repr(t);
			case ENewObj(_) | ENewEnum(_, _) | ENewArr(_, _) | ENewClos(_, _) | ENewBox(_, _) | ENewAnon(_, _): "p";
		}

	function expr(e:Ex) {
		switch e {
			case EInt(v):
				i32(v);
			case EF64(v):
				op(0x44);
				var bs = haxe.io.Bytes.alloc(8);
				bs.setDouble(0, v);
				b.bytes(bs);
			case EStr(s):
				op(0x23);
				Enc.uleb(b, m.strLit(s));
			case ENull(t):
				m.constZero(b, repr(t));
			case ELocal(l):
				var i = local.get(l.id);
				if (i == null) unsupported("the local " + l.name + " (not declared)");
				if (!castUse) otherUses.set(l.id, true);
				localGet(i);
			case EGlobal(g, _):
				op(0x23);
				Enc.uleb(b, m.globalOf(g));
			case EBin(o, x, y):
				expr(x);
				expr(y);
				binop(o);
			case ENot(x):
				expr(x);
				op(0x45);
			case EConv(o, x):
				expr(x);
				switch o {
					case I2F: op(0xB7);
					case F2I: f2i();
					case FNeg: op(0x9A);
					case I2L: op(0xAC);
					case L2I: op(0xA7);
					case L2F: op(0xB9);
					case F2L:
						op(0xFC);
						op(6);
					case LNeg:
						var t = temp("l");
						localSet(t);
						op(0x42);
						op(0);
						localGet(t);
						op(0x7D);
						release("l", t);
				}
			case EBox(t, x):
				expr(x);
				m.box(b, t);
			case EUnbox(t, x):
				expr(x);
				call(Helpers.unbox(m, t == TBool ? "b" : repr(t)));
			case EField(c, idx, o):
				derefAs(o, m.classType(c));
				gc(0x02, m.classType(c), idx + 1);
			case EFieldAddr(_, _, _):
				unsupported("the address of a struct field");
			case EAnonGet(name, t, o, hint):
				// (directly when the object has a layout made here with the field, the
				// type's first, else through the runtime)
				var tmp = temp("p");
				expr(o);
				localSet(tmp);
				var cands = anonCands(name, t, hint);
				op(0x02);
				blockType(repr(t));
				frames.push(FPlain);
				for (s in cands) {
					op(0x02);
					op(0x6D);
					localGet(tmp);
					castShape(s);
					gc(0x02, m.shapeType(s), s.slot(name) + 1);
					op(0x0C);
					Enc.uleb(b, 1);
					op(0x0B);
					op(0x1A);
				}
				localGet(tmp);
				expr(EStr(name));
				call(m.exportOf("gc_anon_get"));
				unboxTop(t);
				end();
				release("p", tmp);
			case ECast(t, x):
				if (repr(t) != rOf(x)) unsupported("a cast from " + rOf(x) + " to " + repr(t));
				expr(x);
			case EInstOf(c, x):
				expr(x);
				if (c.isInterface) call(Helpers.implementsOf(m, c)) else {
					op(0xFB);
					op(0x14);
					Enc.sleb(b, m.classType(c));
				}
			case EEnumTag(x, _):
				derefAs(x, m.enumType);
				gc(0x02, m.enumType, 0);
			case EEnumParam(c, idx, x):
				derefAs(x, m.ctorType(c));
				gc(0x02, m.ctorType(c), idx + 2);
			case EArrLen(a):
				derefAs(a, m.arrBaseType);
				gc(0x02, m.arrBaseType, 0);
			case EArrGet(t, a, i):
				arrGet(GcModule.elemKind(t), a, i);
			case EArrGetU(t, a, i):
				// (unchecked: upstream's Vector over an Array, which hxmc's std replaces; of
				// references as an array's, for generic code, Vector<T>'s, reads one of any kind)
				var k = GcModule.elemKind(t);
				if (k == "p") arrGet(k, a, i) else {
					derefAs(a, m.arrType(k));
					gc(0x02, m.arrType(k), 1);
					expr(i);
					gc(0x0B, m.dataType(k));
				}
			case EBoxGet(t, x):
				exprAs(x, m.boxType(t));
				gc(0x02, m.boxType(t), 0);
			case ECapture(l, idx, x):
				exprAs(x, m.lambdaTypeOf(l));
				gc(0x02, m.lambdaTypeOf(l), idx + 1);
			case EType(tr):
				op(0x23);
				Enc.uleb(b, m.typeValue(tr));
			case ECall(fn, args):
				for (k in 0...args.length) {
					var pk = m.paramKey(fn, k);
					if (pk.charAt(0) == "t") exprAs(args[k], Std.parseInt(pk.substr(1))) else expr(args[k]);
				}
				call(m.funcOf(fn));
			case ECallDispatch(sel, s, args):
				var tk = "t" + m.objType;
				var t = temp(tk);
				derefAs(args[0], m.objType);
				localTee(t);
				for (k in 1...args.length)
					expr(args[k]);
				localGet(t);
				m.indexOf(b);
				i32(m.selCount);
				op(0x6C);
				i32(m.selOf(sel));
				op(0x6A);
				op(0x11);
				Enc.uleb(b, m.typeOfSig(s));
				Enc.uleb(b, 0);
				release(tk, t);
			case ECallClos(s, c, args):
				var ct = m.closTypeOf(s);
				var t = temp("t" + ct);
				derefAs(c, ct);
				localTee(t);
				for (a in args)
					expr(a);
				localGet(t);
				gc(0x02, ct, 0);
				op(0x14);
				Enc.uleb(b, m.fnTypeOf(s));
				release("t" + ct, t);
			case ECallAnon(name, s, o, args):
				// a class instance's method of that name (Helpers.anonCall: by its
				// class), else the runtime's (gc_anon_call), the arguments boxed
				var tmp = temp("p");
				var vals = [for (k in 0...args.length) temp(repr(s.args[k]))];
				expr(o);
				localSet(tmp);
				for (k in 0...args.length) {
					expr(args[k]);
					localSet(vals[k]);
				}
				localGet(tmp);
				op(0xFB);
				op(0x14);
				Enc.sleb(b, m.objType);
				op(0x04);
				blockType(repr(s.ret));
				localGet(tmp);
				for (k in 0...args.length)
					localGet(vals[k]);
				call(Helpers.anonCall(m, name, s));
				op(0x05);
				localGet(tmp);
				expr(EStr(name));
				i32(args.length);
				for (k in 0...args.length) {
					localGet(vals[k]);
					boxTop(s.args[k]);
				}
				gc(0x08, m.dataType("p"), args.length);
				gc(0x00, m.arrType("p"));
				call(m.exportOf("gc_anon_call"));
				if (repr(s.ret) == "v") op(0x1A) else unboxTop(s.ret);
				op(0x0B);
				for (k in 0...args.length)
					release(repr(s.args[k]), vals[k]);
				release("p", tmp);
			case ECallHost(name, args, ret):
				host(name, args, ret);
			case ENewObj(c):
				var t = m.classType(c);
				i32(m.clsOf(c));
				for (fl in c.fields)
					m.constZero(b, repr(fl.ty));
				gc(0x00, t);
			case ENewEnum(c, args):
				i32(c.tag);
				i32(m.enumId(c.en));
				if (c.params.length == 0) gc(0x00, m.enumTypeOf(c.en)) else {
					for (k in 0...args.length)
						exprKey(args[k], m.ctorParamKey(c, k));
					gc(0x00, m.ctorType(c));
				}
			case ENewArr(t, values):
				var k = GcModule.elemKind(t);
				i32(values.length);
				for (v in values)
					expr(v);
				gc(0x08, m.dataType(k), values.length);
				gc(0x00, m.arrType(k));
			case ENewClos(l, captures):
				var fi = m.funcOf(l.fn);
				m.declare(fi);
				op(0xD2);
				Enc.uleb(b, fi);
				for (k in 0...captures.length)
					exprKey(captures[k], m.captureKey(l, k));
				gc(0x00, m.lambdaTypeOf(l));
			case ENewBox(t, v):
				expr(v);
				gc(0x00, m.boxType(t));
			case ENewAnon(s, values):
				m.constZero(b, "p");
				i32(m.shapeId(s));
				for (v in values)
					expr(v);
				gc(0x00, m.shapeType(s));
		}
	}

	// the Float on the stack to an Int: truncated, out of range modulo 2^32 and NaN 0,
	// as the native targets (hx_f2i_slow): inline when within the range
	function f2i() {
		var t = temp("f");
		localTee(t);
		op(0x99);
		op(0x44);
		var bs = haxe.io.Bytes.alloc(8);
		bs.setDouble(0, 2147483648.0);
		b.bytes(bs);
		op(0x63);
		op(0x04);
		op(Enc.I32);
		localGet(t);
		op(0xFC);
		op(2);
		op(0x05);
		localGet(t);
		call(Helpers.f2iSlow(m));
		op(0x0B);
		release("f", t);
	}

	function blockType(r:String)
		switch r {
			case "i": op(Enc.I32);
			case "f": op(Enc.F64);
			case "l": op(Enc.I64);
			case "p": op(0x6D);
			case _: op(0x40);
		}

	// ---- hxmc.NativeArray (FnLower.nativeRead, nativeWrite; rt/gc/GcNArray):
	// a NativeArray of a known element type is the bare data array of its kind,
	// accessed directly; one of a Dynamic element may be storage of any kind or a
	// wrapper (made for an erased type parameter), reference storage accessed
	// inline, the rest through Helpers.naGet and GcNArray.set

	// the most elements of each kind (MirBuild's: the same programs fail)
	static final NA_LIMITS = [0x0FFFFFFD, 0x1FFFFFFA, 0x0FFFFFFD, 0x0FFFFFFD, 0x7FFFFFE8];

	function narray(name:String, args:Array<Ex>) {
		var p = m.dataType("p");
		switch name {
			case "hxmc_narray_new":
				var kn = switch args[0] {
					case EInt(k): k;
					case _: unsupported("a NativeArray of a kind not constant");
				};
				var d = m.naType(GcModule.NA_KINDS[kn]);
				// (1 to the most elements by one unsigned test; none: the empty array
				// of the kind; else the error)
				var n = temp("i");
				expr(args[1]);
				localTee(n);
				i32(1);
				op(0x6B);
				i32(NA_LIMITS[kn]);
				op(0x49);
				op(0x04);
				op(0x63);
				Enc.sleb(b, d);
				localGet(n);
				gc(0x07, d);
				op(0x05);
				localGet(n);
				op(0x45);
				op(0x04);
				op(0x63);
				Enc.sleb(b, d);
				op(0x23);
				Enc.uleb(b, m.emptyArray(GcModule.NA_KINDS[kn]));
				op(0x05);
				call(m.exportOf("hx_narray_bad_length"));
				op(0x00);
				op(0x0B);
				op(0x0B);
				release("i", n);
			case "hxmc_narray_length":
				var k = dataKind(args[0]);
				if (k != null) {
					derefAs(args[0], m.naType(k));
					gc(0x0F);
				} else {
					expr(args[0]);
					call(Helpers.naLen(m));
				}
			case "hxmc_narray_dget":
				// (reference storage inline: the eqref left for the slow path when not)
				var ix = inLocal(args[1]);
				op(0x02);
				op(0x6D);
				frames.push(FPlain);
				op(0x02);
				op(0x6D);
				frames.push(FPlain);
				expr(args[0]);
				brOnCastFail(p);
				localGet(ix.l);
				gc(0x0B, p);
				op(0x0C);
				Enc.uleb(b, 1);
				end();
				localGet(ix.l);
				call(Helpers.naGet(m));
				end();
				ix.done();
			case "hxmc_narray_dset":
				var ix = inLocal(args[1]), vx = inLocal(args[2]);
				block(FPlain, 0x02);
				op(0x02);
				op(0x6D);
				frames.push(FPlain);
				expr(args[0]);
				brOnCastFail(p);
				localGet(ix.l);
				localGet(vx.l);
				gc(0x0E, p);
				op(0x0C);
				Enc.uleb(b, 1);
				end();
				localGet(ix.l);
				localGet(vx.l);
				call(m.exportOf("hx_narray_set_slow"));
				end();
				vx.done();
				ix.done();
			case _ if (StringTools.startsWith(name, "hxmc_narray_get_")):
				var k = name.substr(name.length - 1), d = m.naType(k);
				derefAs(args[0], d);
				expr(args[1]);
				// (Bools: unsigned bytes)
				gc(k == "b" ? 0x0D : 0x0B, d);
			case _ if (StringTools.startsWith(name, "hxmc_narray_set_")):
				var d = m.naType(name.substr(name.length - 1));
				derefAs(args[0], d);
				expr(args[1]);
				expr(args[2]);
				gc(0x0E, d);
			case _:
				unsupported("the intrinsic " + name);
		}
	}

	// br_on_cast_fail to the enclosing block (its result an eqref) unless the
	// eqref on the stack is a (non-null) t; else that, as a t
	function brOnCastFail(t:Int) {
		op(0xFB);
		op(0x19);
		op(1);
		Enc.uleb(b, 0);
		op(0x6D);
		Enc.sleb(b, t);
	}

	// the value on the stack (of type t) boxed, as Dynamic
	function boxTop(t:Ty)
		m.box(b, t);

	// the Dynamic on the stack as a t
	function unboxTop(t:Ty)
		if (repr(t) != "p") call(Helpers.unbox(m, t == TBool ? "b" : repr(t)));

	function binop(o:BinOp)
		switch o {
			case Add: op(0x6A);
			case Sub: op(0x6B);
			case Mul: op(0x6C);
			case Mod: op(0x6F);
			case And: op(0x71);
			case Or: op(0x72);
			case Xor: op(0x73);
			case Shl: op(0x74);
			case Shr: op(0x75);
			case UShr: op(0x76);
			case Eq: op(0x46);
			case Ne: op(0x47);
			case Lt: op(0x48);
			case Le: op(0x4C);
			case Gt: op(0x4A);
			case Ge: op(0x4E);
			case RefEq: op(0xD3);
			case RefNe:
				op(0xD3);
				op(0x45);
			case FAdd: op(0xA0);
			case FSub: op(0xA1);
			case FMul: op(0xA2);
			case FDiv: op(0xA3);
			case FMod: call(Helpers.fmod(m));
			case FEq: op(0x61);
			case FNe: op(0x62);
			case FLt: op(0x63);
			case FLe: op(0x65);
			case FGt: op(0x64);
			case FGe: op(0x66);
			case LAdd: op(0x7C);
			case LSub: op(0x7D);
			case LMul: op(0x7E);
			case LDiv: op(0x7F);
			case LMod: op(0x81);
			case LAnd: op(0x83);
			case LOr: op(0x84);
			case LXor: op(0x85);
			case LShl:
				op(0xAC);
				op(0x86);
			case LShr:
				op(0xAC);
				op(0x87);
			case LUShr:
				op(0xAC);
				op(0x88);
			case LEq: op(0x51);
			case LNe: op(0x52);
			case LLt: op(0x53);
			case LLe: op(0x57);
			case LGt: op(0x55);
			case LGe: op(0x59);
		}

	// whether the value on the stack is of the type (Std.isOfType with a type literal, catch)
	function typeTest(tr:TypeRef) {
		inline function test(t:Int) {
			op(0xFB);
			op(0x14);
			Enc.sleb(b, t);
		}
		switch tr {
			case TRClass(c):
				if (c.isInterface) call(Helpers.implementsOf(m, c)) else test(m.classType(c));
			case TREnum(_):
				test(m.enumType);
			case TRBuiltin(n):
				switch n {
					case "String": test(m.stringType);
					case "Array": test(m.arrBaseType);
					case "hxmc_NativeArray":
						call(Helpers.naKind(m));
						i32(0);
						op(0x4E);
					case "Bool": test(m.dynType(TBool));
					case "Int":
						// (an Int, or a Float of an Int's value, as hxmc.rt.Dyn.is: GcNative.isInt)
						call(m.exportOf("gc_is_int"));
					case "Float" | "Dynamic":
						call(Helpers.kind(m));
						var t = temp("i");
						localSet(t);
						switch n {
							case "Float":
								localGet(t);
								i32(1);
								op(0x46);
								localGet(t);
								i32(2);
								op(0x46);
								op(0x72);
							case _:
								localGet(t);
								i32(0);
								op(0x47);
						}
						release("i", t);
					case _:
						unsupported("a type test against " + n);
				}
		}
	}

	// the runtime's intrinsics (hxmc.rt.gc.W) and the calls left to the runtime
	function host(name:String, args:Array<Ex>, ret:Ty) {
		inline function all()
			for (a in args)
				expr(a);
		if (StringTools.startsWith(name, "hxmc_unsafe_Mem_")) {
			mem(name.substr(16), args);
			return;
		}
		if (StringTools.startsWith(name, "hxmc_narray_")) {
			narray(name, args);
			return;
		}
		var w = "hxmc_rt_gc_W_";
		if (StringTools.startsWith(name, w)) {
			switch name.substr(w.length) {
				case "strLen":
					exprAs(args[0], m.stringType);
					gc(0x0F);
				case "strGet":
					exprAs(args[0], m.stringType);
					expr(args[1]);
					gc(0x0D, m.stringType);
				case "strNew":
					all();
					gc(0x07, m.stringType);
				case "strSet":
					exprAs(args[0], m.stringType);
					expr(args[1]);
					expr(args[2]);
					gc(0x0E, m.stringType);
				case "strCopy":
					exprAs(args[0], m.stringType);
					expr(args[1]);
					exprAs(args[2], m.stringType);
					expr(args[3]);
					expr(args[4]);
					gc(0x11, m.stringType, m.stringType);
				case "write":
					all();
					call(m.importOf("hxmc.write"));
				case "now":
					call(m.importOf("hxmc.now"));
				case "kind":
					all();
					call(Helpers.kind(m));
				case "objHash":
					all();
					call(Helpers.objHash(m));
				case "isNull":
					all();
					op(0xD1);
				case "same":
					all();
					op(0xD3);
				case "unboxInt":
					all();
					call(Helpers.unbox(m, "i"));
				case "unboxFloat":
					all();
					call(Helpers.unbox(m, "f"));
				case "unboxBool":
					all();
					call(Helpers.unbox(m, "b"));
				case "unboxI64":
					all();
					call(Helpers.unbox(m, "l"));
				case "f64Bits":
					all();
					op(0xBD);
				case "bitsF64":
					all();
					op(0xBF);
				case "trap":
					op(0x00);
				case "fmt":
					all();
					call(m.importOf("hxmc.fmt"));
				case "classOf":
					all();
					call(m.meta.classOf());
				case "fieldNames":
					all();
					call(m.meta.fieldNames());
				case "objGet":
					all();
					call(m.meta.objGet());
				case "objCopy":
					all();
					call(m.meta.objCopy());
				case "objSet":
					all();
					call(m.meta.objSet());
				case "createEmpty":
					all();
					call(m.meta.createEmpty());
				case "enumOf":
					all();
					call(m.meta.enumOf());
				case "enumIndex":
					exprAs(args[0], m.enumType);
					gc(0x02, m.enumType, 0);
				case "enumNames":
					all();
					call(m.meta.enumNamesOf());
				case "enumParams":
					all();
					call(m.meta.enumParams());
				case "enumEq":
					all();
					call(m.meta.enumEq());
				case "enumCreate":
					all();
					call(m.meta.enumCreate());
				case "typeAt":
					all();
					call(m.meta.typeAt());
				case "typeKind" | "typeId" | "typeName":
					all();
					m.meta.typeField(b, name.substr(w.length) == "typeKind" ? 0 : name.substr(w.length) == "typeId" ? 1 : 2);
				case "staticNames":
					all();
					call(m.meta.staticNames());
				case "staticGet":
					all();
					call(m.meta.staticGet());
				case "staticSet":
					all();
					call(m.meta.staticSet());
				case "instOf":
					all();
					call(m.meta.instOf());
				case "isType":
					all();
					op(0xFB);
					op(0x14);
					Enc.sleb(b, m.typeType());
				case "anonOverflow":
					exprAs(args[0], m.anonBaseType);
					gc(0x02, m.anonBaseType, 0);
				case "setAnonOverflow":
					exprAs(args[0], m.anonBaseType);
					expr(args[1]);
					gc(0x05, m.anonBaseType, 0);
				case "dynCall":
					all();
					call(m.dynCall());
				case "sysStr" | "sysNum" | "readFile" | "writeFile" | "dateNum" | "fileIo":
					all();
					call(m.importOf("hxmc." + name.substr(w.length)));
				case "arrLen":
					exprAs(args[0], m.arrBaseType);
					gc(0x02, m.arrBaseType, 0);
				case "arrKind":
					all();
					call(Helpers.arrKind(m));
				case "arrGet":
					all();
					call(Helpers.arrGetDyn(m));
				case "arrSet":
					all();
					call(Helpers.arrSetDyn(m));
				case "arrGetI" | "arrGetB" | "arrGetF" | "arrGetL" | "arrGetP":
					all();
					call(Helpers.arrGet(m, name.substr(w.length + 6).toLowerCase()));
				case "arrNew":
					all();
					call(Helpers.arrNew(m));
				case "arrSetLen":
					all();
					call(Helpers.arrSetLen(m));
				case "arrBlit":
					all();
					call(Helpers.arrBlit(m));
				case "naKind":
					all();
					call(Helpers.naKind(m));
				case "naNew":
					all();
					call(Helpers.naNew(m));
				case "naLen":
					all();
					call(Helpers.naLen(m));
				case "naGet":
					all();
					call(Helpers.naGet(m));
				case "naSet":
					all();
					call(Helpers.naSet(m));
				case "naCopy":
					// (storage of one kind known here: array.copy inline)
					var k = dataKind(args[0]);
					if (k != null && dataKind(args[2]) == k) {
						all();
						gc(0x11, m.naType(k), m.naType(k));
						i32(1);
					} else {
						all();
						call(Helpers.naCopy(m));
					}
				case "naStorage":
					all();
					call(Helpers.naStorage(m));
				case "naWrap":
					all();
					i32(0);
					gc(0x00, m.nwrapType);
				case "naSetStorage":
					exprAs(args[0], m.nwrapType);
					expr(args[1]);
					gc(0x05, m.nwrapType, 0);
				case "naFix":
					exprAs(args[0], m.nwrapType);
					i32(1);
					gc(0x05, m.nwrapType, 1);
				case "bytesNew":
					all();
					gc(0x07, m.bytesType);
				case "bytesLen":
					exprAs(args[0], m.bytesType);
					gc(0x0F);
				case "bytesGet":
					exprAs(args[0], m.bytesType);
					expr(args[1]);
					gc(0x0D, m.bytesType);
				case "bytesSet":
					exprAs(args[0], m.bytesType);
					expr(args[1]);
					expr(args[2]);
					gc(0x0E, m.bytesType);
				case "bytesCopy":
					exprAs(args[0], m.bytesType);
					expr(args[1]);
					exprAs(args[2], m.bytesType);
					expr(args[3]);
					expr(args[4]);
					gc(0x11, m.bytesType, m.bytesType);
				case "bytesFill":
					exprAs(args[0], m.bytesType);
					expr(args[1]);
					expr(args[2]);
					expr(args[3]);
					gc(0x10, m.bytesType);
				case "bytesGetI32":
					all();
					call(Helpers.bytesGet(m, false));
				case "bytesSetI32":
					all();
					call(Helpers.bytesSet(m, false));
				case "memToBytes":
					all();
					call(Helpers.memToBytes(m));
				case "bytesToMem":
					all();
					call(Helpers.bytesToMem(m));
				case "bytesGetI64":
					all();
					call(Helpers.bytesGet(m, true));
				case "bytesSetI64":
					all();
					call(Helpers.bytesSet(m, true));
				case "f32Bits":
					all();
					op(0xB6);
					op(0xBC);
				case "bitsF32":
					all();
					op(0xBE);
					op(0xBB);
				case "parseFloat":
					all();
					call(m.importOf("hxmc.parseFloat"));
				case "math":
					all();
					call(m.importOf("hxmc.math"));
				case "random":
					call(m.importOf("hxmc.random"));
				case x:
					unsupported("the intrinsic " + x);
			}
			return;
		}
		inline function f64(v:Float) {
			op(0x44);
			var bs = haxe.io.Bytes.alloc(8);
			bs.setDouble(0, v);
			b.bytes(bs);
		}
		inline function hostMath(code:Int) {
			i32(code);
			expr(args[0]);
			if (args.length > 1) expr(args[1]) else f64(0);
			call(m.importOf("hxmc.math"));
		}
		switch name {
			case "Std_isOfType" | "Std_is" | "hx_is" if (args[1].match(EType(_))):
				expr(args[0]);
				switch args[1] {
					case EType(tr): typeTest(tr);
					case _:
				}
			case "Std_isOfType" | "Std_is" | "hx_is":
				// (a type known at run time only: GcNative.isOfType)
				all();
				call(m.exportOf("gc_is"));
			case "hx_is_typeobj" if (args[1].match(EInt(_))):
				// Std.isOfType(v, Class), (v, Enum): a type object (GcModule.typeValue:
				// its kind 0 a class, 1 an enum, 2 a builtin), of an enum for Enum
				var wantEnum = args[1].match(EInt(1));
				var tt = m.typeType();
				var t = temp("p");
				expr(args[0]);
				localTee(t);
				op(0xFB);
				op(0x14);
				Enc.sleb(b, tt);
				op(0x04);
				op(0x7F);
				localGet(t);
				castTo(tt);
				gc(0x02, tt, 0);
				i32(1);
				op(wantEnum ? 0x46 : 0x47);
				op(0x05);
				i32(0);
				op(0x0B);
				release("p", t);
			case "hx_clos_of_sig" if (args[1].match(EStr(_))):
				// (the closure when it has this signature, else null)
				var key = switch args[1] {
					case EStr(k): k;
					case _: null;
				};
				var sig = m.sigOfKey(key);
				var t = temp("p");
				expr(args[0]);
				localTee(t);
				op(0xFB);
				op(0x14);
				Enc.sleb(b, m.closTypeOf(sig));
				op(0x04);
				op(0x6D);
				localGet(t);
				op(0x05);
				op(0xD0);
				op(0x6D);
				op(0x0B);
				release("p", t);
			case "hx_dyn_call":
				all();
				call(m.dynCall());
			case "haxe_io_Bytes_alloc":
				all();
				gc(0x07, m.bytesType);
			case "haxe_io_Bytes_get_length":
				exprAs(args[0], m.bytesType);
				gc(0x0F);
			case "haxe_io_Bytes_get":
				exprAs(args[0], m.bytesType);
				expr(args[1]);
				gc(0x0D, m.bytesType);
			case "haxe_io_Bytes_set":
				exprAs(args[0], m.bytesType);
				expr(args[1]);
				expr(args[2]);
				gc(0x0E, m.bytesType);
			case "haxe_io_Bytes_getInt32":
				all();
				call(Helpers.bytesGet(m, false));
			case "haxe_io_Bytes_setInt32":
				all();
				call(Helpers.bytesSet(m, false));
			case "haxe_io_Bytes_getDouble":
				all();
				call(Helpers.bytesGet(m, true));
				op(0xBF);
			case "haxe_io_Bytes_setDouble":
				expr(args[0]);
				expr(args[1]);
				expr(args[2]);
				op(0xBD);
				call(Helpers.bytesSet(m, true));
			case "haxe_io_Bytes_getFloat":
				all();
				call(Helpers.bytesGet(m, false));
				op(0xBE);
				op(0xBB);
			case "haxe_io_Bytes_setFloat":
				expr(args[0]);
				expr(args[1]);
				expr(args[2]);
				op(0xB6);
				op(0xBC);
				call(Helpers.bytesSet(m, false));
			case "Type_createEmptyInstance" if (args[0].match(EType(TRClass(_)))):
				switch args[0] {
					case EType(TRClass(c)): expr(ENewObj(c));
					case _:
				}
			case "Std_downcast" if (args[1].match(EType(_))):
				// (the value when of the type, else null)
				var t = temp("p");
				expr(args[0]);
				localTee(t);
				switch args[1] {
					case EType(tr): typeTest(tr);
					case _:
				}
				op(0x04);
				op(0x6D);
				localGet(t);
				op(0x05);
				m.constZero(b, "p");
				op(0x0B);
				release("p", t);
			case "Std_downcast" | "hx_cast" if (!args[1].match(EType(_))):
				// (the value when of the type, else null; a cast: else an error unless null)
				var t = temp("p");
				expr(args[0]);
				localTee(t);
				expr(args[1]);
				call(m.exportOf("gc_is"));
				if (name == "hx_cast") {
					localGet(t);
					op(0xD1);
					op(0x72);
				}
				op(0x04);
				op(0x6D);
				localGet(t);
				op(0x05);
				if (name == "hx_cast") {
					expr(EStr("Class cast error"));
					op(0x08);
					op(0);
				} else
					m.constZero(b, "p");
				op(0x0B);
				release("p", t);
			case "hx_cast" if (args[1].match(EType(_))):
				// (null, or a value of the type: else an error)
				var t = temp("p");
				expr(args[0]);
				localTee(t);
				op(0xD1);
				localGet(t);
				switch args[1] {
					case EType(tr): typeTest(tr);
					case _:
				}
				op(0x72);
				op(0x04);
				op(0x6D);
				localGet(t);
				op(0x05);
				expr(EStr("Class cast error"));
				op(0x08);
				op(0);
				op(0x0B);
				release("p", t);
			case "String_charCodeAt_i":
				// (0 past the end, as fastCodeAt)
				var sk = "t" + m.stringType;
				var t = temp("i"), s = temp(sk);
				derefAs(args[0], m.stringType);
				localSet(s);
				expr(args[1]);
				localTee(t);
				localGet(s);
				gc(0x0F);
				op(0x49);
				op(0x04);
				op(Enc.I32);
				localGet(s);
				localGet(t);
				gc(0x0D, m.stringType);
				op(0x05);
				i32(0);
				op(0x0B);
				release("i", t);
				release(sk, s);
			case "String_length":
				derefAs(args[0], m.stringType);
				gc(0x0F);
			case "Math_NaN": f64(Math.NaN);
			case "Math_POSITIVE_INFINITY": f64(Math.POSITIVE_INFINITY);
			case "Math_NEGATIVE_INFINITY": f64(Math.NEGATIVE_INFINITY);
			case "Math_PI": f64(3.141592653589793);
			case "Math_abs":
				all();
				op(0x99);
			case "Math_sqrt":
				all();
				op(0x9F);
			case "Math_ffloor":
				all();
				op(0x9C);
			case "Math_fceil":
				all();
				op(0x9B);
			case "Math_fround":
				all();
				f64(0.5);
				op(0xA0);
				op(0x9C);
			case "Math_floor" | "Math_ceil" | "Math_round":
				all();
				if (name == "Math_round") {
					f64(0.5);
					op(0xA0);
				}
				op(name == "Math_ceil" ? 0x9B : 0x9C);
				f2i();
			case "Math_max":
				all();
				op(0xA5);
			case "Math_min":
				all();
				op(0xA4);
			case "Math_isNaN":
				var t = temp("f");
				all();
				localTee(t);
				localGet(t);
				op(0x62);
				release("f", t);
			case "Math_isFinite":
				var t = temp("f");
				all();
				localTee(t);
				localGet(t);
				op(0xA1);
				f64(0);
				op(0x61);
				release("f", t);
			case "Math_sin": hostMath(0);
			case "Math_cos": hostMath(1);
			case "Math_tan": hostMath(2);
			case "Math_asin": hostMath(3);
			case "Math_acos": hostMath(4);
			case "Math_atan": hostMath(5);
			case "Math_atan2": hostMath(6);
			case "Math_exp": hostMath(7);
			case "Math_log": hostMath(8);
			case "Math_pow": hostMath(9);
			case "Math_random":
				call(m.importOf("hxmc.random"));
			case "rt_throw":
				// (the value thrown, as hxmc.rt.Start's)
				all();
				op(0x08);
				op(0);
			case "rt_blocking_enter" | "rt_blocking_leave":
			// (the linker's builtins of linear memory: hxmc.rt.wasm.Wasm)
			case "memcpy" | "memmove" | "memset" if (m.memory):
				var t = temp("l");
				expr(args[0]);
				localTee(t);
				op(0xA7);
				expr(args[1]);
				if (name != "memset") op(0xA7);
				expr(args[2]);
				op(0xA7);
				op(0xFC);
				if (name == "memset") {
					op(11);
					op(0);
				} else {
					op(10);
					op(0);
					op(0);
				}
				localGet(t);
				release("l", t);
			case "wasm_memory_size" if (m.memory):
				op(0x3F);
				op(0);
			case "wasm_memory_grow" if (m.memory):
				expr(args[0]);
				op(0x40);
				op(0);
			case _ if (m.foreignOf(name) != null):
				// (wasm32's C ABI: pointers as i32, floats as f32)
				var sig = hxmc.CAbi.wasmSig(hxmc.ir.CInterop.SIGS.get(name));
				for (k in 0...args.length) {
					expr(args[k]);
					switch sig.args[k] {
						case CPtr: op(0xA7);
						case CF32: op(0xB6);
						case _:
					}
				}
				call(m.foreignOf(name));
				switch sig.ret {
					case CPtr: op(0xAD);
					case CF32: op(0xBB);
					case _:
				}
			case _:
				unsupported("the runtime function " + name);
		}
	}

	// ---- the linear memory (hxmc.unsafe.Mem: as MirBuild expands it for linear memory)

	// p + off (+ i * scale) as an i32 on the stack; the constant part left for the instruction (its offset)
	function address(p:Ex, off:Ex, ?i:Ex, scale = 1):Int {
		expr(p);
		op(0xA7);
		var disp = 0;
		switch off {
			case EInt(v) if (v >= 0): disp = v;
			case _:
				expr(off);
				op(0x6A);
		}
		if (i != null) {
			expr(i);
			if (scale > 1) {
				i32(scale == 2 ? 1 : scale == 4 ? 2 : 3);
				op(0x74);
			}
			op(0x6A);
		}
		return disp;
	}

	inline function memarg(disp:Int) {
		op(0);
		Enc.uleb(b, disp);
	}

	function mem(name:String, args:Array<Ex>) {
		inline function load(opcode:Int) {
			var d = address(args[0], args[1]);
			op(opcode);
			memarg(d);
		}
		inline function store(opcode:Int, ?demote = false) {
			var d = address(args[0], args[1]);
			expr(args[2]);
			if (demote) op(0xB6);
			op(opcode);
			memarg(d);
		}
		inline function loadAt(opcode:Int, scale:Int) {
			var d = address(args[0], args[1], args[2], scale);
			op(opcode);
			memarg(d);
		}
		inline function storeAt(opcode:Int, scale:Int) {
			var d = address(args[0], args[1], args[2], scale);
			expr(args[3]);
			op(opcode);
			memarg(d);
		}
		inline function slot(size:Int, align:Int) {
			frameSize = (frameSize + align - 1) & ~(align - 1);
			localGet(fp);
			i32(frameSize);
			op(0x6A);
			op(0xAD);
			frameSize += size;
		}
		inline function literal(e:Ex):String
			return switch e {
				case EStr(s): s;
				case _: unsupported("Mem." + name + " of a value that is not a literal");
			}
		inline function intLit(e:Ex):Int
			return switch e {
				case EInt(v): v;
				case _: unsupported("Mem." + name + " of a size that is not a constant");
			}
		switch name {
			case "getI8": load(0x2C);
			case "getU8": load(0x2D);
			case "getI16": load(0x2E);
			case "getU16": load(0x2F);
			case "getI32": load(0x28);
			case "getI64" | "getPtr": load(0x29);
			case "getF32":
				load(0x2A);
				op(0xBB);
			case "getF64": load(0x2B);
			case "setI8": store(0x3A);
			case "setI16": store(0x3B);
			case "setI32": store(0x36);
			case "setI64" | "setPtr": store(0x37);
			case "setF32": store(0x38, true);
			case "setF64": store(0x39);
			case "getU8At": loadAt(0x2D, 1);
			case "getU16At": loadAt(0x2F, 2);
			case "getI32At": loadAt(0x28, 4);
			case "getI64At": loadAt(0x29, 8);
			case "getF64At": loadAt(0x2B, 8);
			case "setU8At": storeAt(0x3A, 1);
			case "setU16At": storeAt(0x3B, 2);
			case "setI32At": storeAt(0x36, 4);
			case "setI64At": storeAt(0x37, 8);
			case "setF64At": storeAt(0x39, 8);
			case "stack": slot(intLit(args[0]), 16);
			case "structSlot": slot((intLit(args[0]) + 7) & ~7, intLit(args[1]));
			case "cstr":
				op(0x42);
				Enc.sleb(b, m.cstr(literal(args[0])));
			case "sym":
				var s = literal(args[0]);
				if (s == "__heap_base") {
					op(0x23);
					Enc.uleb(b, m.heapGlobal);
					op(0xAD);
				} else {
					var cb = m.symbolFunc(s);
					if (cb == null) unsupported("the symbol " + s);
					op(0x42);
					Enc.sleb(b, m.callbackOf(cb));
				}
			case "ult":
				expr(args[0]);
				expr(args[1]);
				// (Ints: NativeArray's bounds tests, FnLower.inBounds)
				op(rOf(args[0]) == "i" ? 0x49 : 0x54);
			case "f64Bits":
				expr(args[0]);
				op(0xBD);
			case "bitsF64":
				expr(args[0]);
				op(0xBF);
			case "zero":
				expr(args[0]);
				op(0xA7);
				i32(0);
				expr(args[1]);
				op(0xA7);
				op(0xFC);
				op(11);
				op(0);
			case "call0":
				expr(args[0]);
				op(0xA7);
				op(0x11);
				Enc.uleb(b, m.callbackType("_v"));
				op(1);
			case "os":
				i32(3);
			case "arm":
				i32(0);
			case "frame":
				op(0x42);
				op(0);
			case "target":
				i32(6);
			case "platform":
				i32(0);
			case x:
				unsupported("Mem." + x + " (a reference in the linear memory)");
		}
	}
}
