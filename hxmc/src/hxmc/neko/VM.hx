package hxmc.neko;

import haxe.ds.Vector;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import hxmc.neko.Module.Op;
import hxmc.neko.Frame.F;
import hxmc.neko.Value;

// one thread's interpreter (neko/vm/interp.c): the stack, `this`, the
// current function's environment. A call of the module's code is a call of
// interp (neko's loop calls without recursion; here each call is a Haxe call),
// a trap is six stack slots as in neko, so the compiler's stack offsets hold.
class VM {
	public static inline var INVALID = 0xFF;
	static inline var MAX_DEPTH = 6000;

	static final tls = new sys.thread.Tls<VM>();

	public var stack:Vector<NValue>;
	public var sp = 0;
	public var vthis:NValue = null;
	public var lastPrim:Null<NFun> = null;
	public var env:NValue = [];
	public var depth = 0;
	public var resolver:NValue = null;
	public var excStack:NArr = [];
	// each depth's module and the pc of its current call (neko's csp frames)
	final fmods = new Vector<Int>(MAX_DEPTH + 2, -1);
	final fpcs = new Vector<Int>(MAX_DEPTH + 2, 0);
	// what $print writes to
	public var print:Bytes->Void;
	public var custom:Map<String, NValue> = new Map();

	public function new() {
		stack = new Vector(1 << 12);
		print = defaultPrint;
		tls.value = this;
	}

	public static function current():VM {
		var v = tls.value;
		return v == null ? new VM() : v;
	}

	static function defaultPrint(b:Bytes) {
		var o = Sys.stdout();
		o.writeBytes(b, 0, b.length);
		o.flush();
	}

	// ---- errors

	// the boxes of the small Ints, made once
	static final smallInts:Vector<NValue> = {
		var v = new Vector<NValue>(2048);
		for (i in 0...2048)
			v[i] = (i - 1024 : NValue);
		v;
	};

	public static inline function box(i:Int):NValue
		return i >= -1024 && i < 1024 ? smallInts[i + 1024] : (i : NValue);

	public static inline function error(msg:String):NekoError
		return new NekoError(NStr.of(msg));

	// ---- the stack

	inline function push(v:NValue) {
		if (sp == stack.length) grow();
		stack[sp++] = v;
	}

	function growTo(n:Int) {
		while (stack.length < n)
			grow();
	}

	function grow() {
		if (stack.length >= 1 << 24) throw error("Stack Overflow");
		var n = new Vector<NValue>(stack.length * 2);
		Vector.blit(stack, 0, n, 0, sp);
		stack = n;
	}

	inline function pop(n:Int) {
		while (n-- > 0)
			stack[--sp] = null;
	}

	// ---- calls

	// val_callEx: f called on `thisv` (`keepThis`: the current `this`)
	public function callEx(thisv:NValue, f:NValue, args:NArr, keepThis = false):NValue {
		var oldThis = vthis, oldEnv = env, oldSp = sp, oldDepth = depth;
		try {
			for (a in args)
				push(a);
			var r = callOp(f, keepThis ? vthis : thisv, args.length);
			vthis = oldThis;
			env = oldEnv;
			return r;
		} catch (e:Dynamic) {
			var ne = wrap(e);
			capture(ne);
			vthis = oldThis;
			env = oldEnv;
			while (sp > oldSp)
				stack[--sp] = null;
			sp = oldSp;
			depth = oldDepth;
			throw ne;
		}
	}

	public inline function callN(f:NValue, args:NArr):NValue
		return callEx(null, f, args, true);

	// a call with nargs arguments on the stack, which it pops
	public function callOp(f:NValue, thisv:NValue, nargs:Int):NValue {
		if (!Tag.isFunction(f)) {
			pop(nargs);
			throw error("Invalid call");
		}
		var fn = f.asFun();
		if (fn.prim == null) {
			if (fn.nargs != nargs) {
				pop(nargs);
				throw error("Invalid call");
			}
			if (++depth > MAX_DEPTH) {
				depth = 0;
				throw error("Stack Overflow");
			}
			// (this and the environment are the frame's own: interp's arguments;
			// the frame's slots from the arguments, sp above them)
			var fp = sp - nargs;
			var m = fn.module;
			var top = fp + m.frameMax[fn.addr];
			if (top + 8 > stack.length) growTo(top + 8);
			sp = top;
			var r = interp(m, fn.addr, null, -1, thisv, fn.env, fp, top);
			depth--;
			// (the arguments popped; the frame's slots left as they are)
			sp = fp;
			return r;
		}
		if (fn.nargs != nargs && fn.nargs != -1) {
			pop(nargs);
			throw error("Invalid call");
		}
		var args = new Vector<NValue>(nargs);
		for (i in 0...nargs)
			args[i] = stack[sp - nargs + i];
		pop(nargs);
		// (a primitive reads them from the VM: val_this, the closure's env;
		// lastPrim names the primitive a Failure comes from, wrap: left as
		// it is when the primitive throws)
		var oldThis = vthis, oldEnv = env, oldPrim = lastPrim;
		vthis = thisv;
		env = fn.env;
		lastPrim = fn;
		var r = fn.prim(this, args);
		vthis = oldThis;
		env = oldEnv;
		lastPrim = oldPrim;
		return r;
	}

	// a module's code from its start (neko_vm_execute)
	public function execute(m:Module):NValue {
		var fp = sp;
		var top = fp + m.frameMax[0];
		if (top + 8 > stack.length) growTo(top + 8);
		sp = top;
		var r = interp(m, 0, null, -1, null, [], fp, top);
		sp = fp;
		return r;
	}

	// ---- the interpreter

	// a frame of a module's translated code (Frame), from pc: the frame's
	// slots from fp, the VM's sp at top above them (set to the arguments' top
	// for a call, back after it); trap >= 0: the part of the frame under the
	// trap whose six slots start there (protect), which ends at its EndTrap
	// (trapState ENDED, resumePc) or with the function (RETURNED)
	function interp(m:Module, pc:Int, acc:NValue, trap:Int, vthis:NValue, env:NValue, fp:Int, top:Int):NValue {
		final code = m.vcode;
		fmods[depth] = m.id;
		while (true) {
			switch code[pc] {
				case F.ANULL:
					acc = null;
					pc++;
				case F.ATRUE:
					acc = true;
					pc++;
				case F.AFALSE:
					acc = false;
					pc++;
				case F.ATHIS:
					acc = vthis;
					pc++;
				case F.ACONST:
					acc = m.consts[code[pc + 1]];
					pc += 2;
				case F.ASLOT:
					acc = stack[fp + code[pc + 1]];
					pc += 2;
				case F.AGLOBAL:
					acc = m.globals[code[pc + 1]];
					pc += 2;
				case F.AENV:
					var e = env.asArr();
					var i = code[pc + 1];
					if (i >= e.length) throw errorAt(m, pc, "Reading Outside Env");
					acc = e[i];
					pc += 2;
				case F.AFIELD:
					fpcs[depth] = pc;
					acc = field(m, pc, acc, code[pc + 1], vthis);
					pc += 2;
				case F.AARRAY:
					fpcs[depth] = pc;
					var a:NValue = stack[fp + code[pc + 1] - 1];
					if (Tag.isInt(acc) && Tag.isArray(a)) {
						var arr = a.asArr();
						var k = acc.asInt();
						acc = k < 0 || k >= arr.length ? null : arr[k];
					} else if (Tag.isObject(a))
						acc = objectOp(a.asObj(), acc, Fields.idGet, "Unsupported operation")
					else
						throw errorAt(m, pc, "Invalid array access");
					pc += 2;
				case F.AINDEX:
					fpcs[depth] = pc;
					acc = index(acc, code[pc + 1]);
					pc += 2;
				case F.SSLOT:
					stack[fp + code[pc + 1]] = acc;
					pc += 2;
				case F.SGLOBAL:
					m.globals[code[pc + 1]] = acc;
					pc += 2;
				case F.SENV:
					var e = env.asArr();
					var i = code[pc + 1];
					if (i >= e.length) throw errorAt(m, pc, "Writing Outside Env");
					e[i] = acc;
					pc += 2;
				case F.SFIELD:
					var o:NValue = stack[fp + code[pc + 2] - 1];
					if (Tag.isObject(o)) o.asObj().set(code[pc + 1], acc) else throw invalidFieldAt(m, pc, code[pc + 1]);
					pc += 3;
				case F.SARRAY:
					fpcs[depth] = pc;
					var d = fp + code[pc + 1];
					var a:NValue = stack[d - 1];
					var k:NValue = stack[d - 2];
					if (Tag.isArray(a) && Tag.isInt(k)) {
						var arr = a.asArr();
						var i = k.asInt();
						if (i >= 0 && i < arr.length) arr[i] = acc;
					} else if (Tag.isObject(a)) {
						var o = a.asObj();
						var f = o.get(Fields.idSet);
						if (f == null) throw errorAt(m, pc, "Unsupported operation");
						callEx(o, f, [k, acc]);
					} else
						throw errorAt(m, pc, "Invalid array access");
					pc += 2;
				case F.SINDEX:
					fpcs[depth] = pc;
					var a:NValue = stack[fp + code[pc + 2] - 1];
					var i = code[pc + 1];
					if (Tag.isArray(a)) {
						var arr = a.asArr();
						if (i >= 0 && i < arr.length) arr[i] = acc;
					} else if (Tag.isObject(a)) {
						var o = a.asObj();
						var f = o.get(Fields.idSet);
						if (f == null) throw errorAt(m, pc, "Unsupported operation");
						callEx(o, f, [i, acc]);
					} else
						throw errorAt(m, pc, "Invalid array access");
					pc += 3;
				case F.STHIS:
					vthis = acc;
					pc++;
				case F.PUSH:
					stack[fp + code[pc + 1]] = acc;
					pc += 2;
				case F.COPYPUSH:
					acc = stack[fp + code[pc + 1]];
					stack[fp + code[pc + 2]] = acc;
					pc += 3;
				case F.CONSTPUSH:
					acc = m.consts[code[pc + 1]];
					stack[fp + code[pc + 2]] = acc;
					pc += 3;
				case F.GLOBALPUSH:
					acc = m.globals[code[pc + 1]];
					stack[fp + code[pc + 2]] = acc;
					pc += 3;
				case F.CALL:
					fpcs[depth] = pc;
					acc = callAt(acc, vthis, code[pc + 1], fp + code[pc + 2]);
					sp = top;
					pc += 3;
				case F.OBJCALL:
					fpcs[depth] = pc;
					var d = fp + code[pc + 2];
					acc = callAt(acc, stack[d - 1], code[pc + 1], d - 1);
					sp = top;
					pc += 3;
				case F.CALLGF:
					// (a static's method: the class from a global, the method by the field's cache)
					fpcs[depth] = pc;
					var o:NValue = m.globals[code[pc + 1]];
					acc = callAt(field(m, pc, o, code[pc + 2], vthis), o, code[pc + 3], fp + code[pc + 4]);
					sp = top;
					pc += 5;
				case F.TAILCALL:
					// (Neko's tail call leaves this frame first: the callee
					// takes its place, the caller's call its position)
					sp = fp + code[pc + 2];
					depth--;
					var r = callOp(acc, vthis, code[pc + 1]);
					depth++;
					if (trap >= 0) trapState = RETURNED;
					return r;
				case F.APPLY:
					fpcs[depth] = pc;
					if (!Tag.isFunction(acc)) throw errorAt(m, pc, "$apply");
					var fn = acc.asFun();
					var n = code[pc + 1], d = fp + code[pc + 2];
					if (fn.nargs == n || fn.nargs == -1) {
						sp = d;
						acc = callOp(fn, vthis, n);
						sp = top;
					} else {
						if (n > fn.nargs) throw errorAt(m, pc, "$apply");
						var e:NArr = [for (_ in 0...fn.nargs + 1) null];
						e[0] = fn;
						for (i in 0...n)
							e[i + 1] = stack[d - n + i];
						acc = Builtins.applyClosure(fn.nargs - n, e);
					}
					pc += 3;
				case F.JUMP:
					pc = code[pc + 1];
				case F.JIF:
					if (Tag.isBool(acc) && acc.asBool()) pc = code[pc + 1] else pc += 2;
				case F.JIFNOT:
					if (Tag.isBool(acc) && acc.asBool()) pc += 2 else pc = code[pc + 1];
				case F.TRAP:
					var t = fp + code[pc + 2];
					stack[t] = code[pc + 1];
					stack[t + 1] = vthis;
					stack[t + 2] = env;
					stack[t + 3] = depth;
					stack[t + 4] = null;
					stack[t + 5] = null;
					acc = protect(m, pc + 3, acc, t, vthis, env, fp, top);
					sp = top;
					if (trapState == RETURNED) {
						if (trap < 0) trapState = 0;
						return acc;
					}
					pc = resumePc;
					vthis = resumeThis;
				case F.ENDTRAP:
					if (trap < 0 || trap != fp + code[pc + 1] - 6) throw errorAt(m, pc, "Invalid End Trap");
					trapState = ENDED;
					resumePc = pc + 2;
					resumeThis = vthis;
					return acc;
				case F.RET | F.LAST:
					if (trap >= 0) trapState = RETURNED;
					return acc;
				case F.MAKEENV:
					var n = code[pc + 1], d = fp + code[pc + 2];
					var e:NArr = [for (_ in 0...n) null];
					for (i in 0...n)
						e[i] = stack[d - n + i];
					if (!Tag.isFunction(acc) || acc.asFun().prim != null) throw errorAt(m, pc, "Invalid environment");
					var f = acc.asFun();
					acc = new NFun(f.nargs, e, f.module, f.addr, null, null);
					pc += 3;
				case F.MAKEARRAY:
					var n = code[pc + 1], d = fp + code[pc + 2];
					var a:NArr = [for (_ in 0...n + 1) null];
					a[0] = acc;
					for (i in 0...n)
						a[i + 1] = stack[d - n + i];
					acc = a;
					pc += 3;
				case F.MAKEARRAY2:
					var n = code[pc + 1], d = fp + code[pc + 2];
					var a:NArr = [for (_ in 0...n + 1) null];
					for (i in 0...n)
						a[i] = stack[d - n + i];
					a[n] = acc;
					acc = a;
					pc += 3;
				case F.BOOL:
					acc = !isFalse(acc);
					pc++;
				case F.NOT:
					acc = isFalse(acc);
					pc++;
				case F.ISNULL:
					acc = acc == null;
					pc++;
				case F.ISNOTNULL:
					acc = acc != null;
					pc++;
				case F.TYPEOF:
					acc = Tag.of(acc);
					pc++;
				case F.HASH:
					if (!Tag.isString(acc)) throw errorAt(m, pc, "$hash");
					acc = Fields.idBytes(acc.asStr().b);
					pc++;
				case F.NEW:
					acc = newObject(acc);
					pc++;
				case F.ADD:
					var a:NValue = stack[fp + code[pc + 1] - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) acc = box(a.asInt() + acc.asInt()) else {
						fpcs[depth] = pc;
						acc = add(a, acc);
					}
					pc += 2;
				case F.SUB:
					var a:NValue = stack[fp + code[pc + 1] - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) acc = box(a.asInt() - acc.asInt()) else {
						fpcs[depth] = pc;
						acc = numberOp(a, acc, Op.Sub);
					}
					pc += 2;
				case F.MULT:
					var a:NValue = stack[fp + code[pc + 1] - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) acc = box(a.asInt() * acc.asInt()) else {
						fpcs[depth] = pc;
						acc = numberOp(a, acc, Op.Mult);
					}
					pc += 2;
				case F.DIV:
					fpcs[depth] = pc;
					acc = div(stack[fp + code[pc + 1] - 1], acc);
					pc += 2;
				case F.MOD:
					fpcs[depth] = pc;
					var a:NValue = stack[fp + code[pc + 1] - 1];
					if (Tag.isInt(acc) && acc.asInt() == 0 && Tag.isInt(a)) throw errorAt(m, pc, "Invalid operation (%)");
					acc = numberOp(a, acc, Op.Mod);
					pc += 2;
				case F.BITOP:
					var op = code[pc + 1];
					var a:NValue = stack[fp + code[pc + 2] - 1];
					if (!Tag.isInt(acc) || !Tag.isInt(a)) throw errorAt(m, pc, "Invalid operation (" + opName(op) + ")");
					var x = a.asInt(), y = acc.asInt();
					acc = switch op {
						case Op.Shl: x << y;
						case Op.Shr: x >> y;
						case Op.UShr: x >>> y;
						case Op.Or: x | y;
						case Op.And: x & y;
						case _: x ^ y;
					}
					pc += 3;
				case F.CMP:
					var a:NValue = stack[fp + code[pc + 2] - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) acc = intCmp(code[pc + 1], a.asInt(), acc.asInt()) else {
						fpcs[depth] = pc;
						acc = anyCmp(code[pc + 1], a, acc);
					}
					pc += 3;
				case F.COMPARE:
					fpcs[depth] = pc;
					var c = compare(stack[fp + code[pc + 1] - 1], acc);
					acc = c == INVALID ? null : c;
					pc += 2;
				case F.PHYSCMP:
					acc = physCompare(stack[fp + code[pc + 1] - 1], acc);
					pc += 2;
				case F.JUMPTABLE:
					var n = code[pc + 1];
					if (Tag.isInt(acc) && acc.asInt() >= 0 && acc.asInt() < n) pc = code[pc + 3 + acc.asInt()] else pc = code[pc + 2];
				case F.OPIMM:
					var op = code[pc + 1], k = code[pc + 2];
					if (Tag.isInt(acc)) acc = intOp(op, acc.asInt(), k) else {
						fpcs[depth] = pc;
						acc = anyOp(op, acc, m.consts[code[pc + 3]]);
					}
					pc += 4;
				case F.CMPJUMP:
					var a:NValue = stack[fp + code[pc + 4] - 1];
					var b = false;
					if (Tag.isInt(a) && Tag.isInt(acc)) b = intCmp(code[pc + 1], a.asInt(), acc.asInt()) else {
						fpcs[depth] = pc;
						b = anyCmp(code[pc + 1], a, acc);
					}
					acc = b;
					if (b == (code[pc + 2] == 1)) pc = code[pc + 3] else pc += 5;
				case F.OPIMMJUMP:
					var b = false;
					if (Tag.isInt(acc)) b = intCmp(code[pc + 1], acc.asInt(), code[pc + 3]) else {
						fpcs[depth] = pc;
						b = anyCmp(code[pc + 1], acc, m.consts[code[pc + 4]]);
					}
					acc = b;
					if (b == (code[pc + 2] == 1)) pc = code[pc + 5] else pc += 6;
				case F.SLOTOPIMM:
					var a:NValue = stack[fp + code[pc + 1]];
					var op = code[pc + 2];
					if (Tag.isInt(a)) acc = intOp(op, a.asInt(), code[pc + 3]) else {
						fpcs[depth] = pc;
						acc = anyOp(op, a, m.consts[code[pc + 4]]);
					}
					pc += code[pc + 5];
				case F.SLOTOPIMMJUMP:
					var a:NValue = stack[fp + code[pc + 1]];
					var b = false;
					if (Tag.isInt(a)) b = intCmp(code[pc + 2], a.asInt(), code[pc + 4]) else {
						fpcs[depth] = pc;
						b = anyCmp(code[pc + 2], a, m.consts[code[pc + 5]]);
					}
					acc = b;
					if (b == (code[pc + 3] == 1)) pc = code[pc + 6] else pc += 8;
				case F.OPIMMPUSH:
					var op = code[pc + 1];
					if (Tag.isInt(acc)) acc = intOp(op, acc.asInt(), code[pc + 2]) else {
						fpcs[depth] = pc;
						acc = anyOp(op, acc, m.consts[code[pc + 3]]);
					}
					stack[fp + code[pc + 4]] = acc;
					pc += code[pc + 5];
				case F.SLOTOPIMMPUSH:
					var a:NValue = stack[fp + code[pc + 1]];
					var op = code[pc + 2];
					if (Tag.isInt(a)) acc = intOp(op, a.asInt(), code[pc + 3]) else {
						fpcs[depth] = pc;
						acc = anyOp(op, a, m.consts[code[pc + 4]]);
					}
					stack[fp + code[pc + 5]] = acc;
					pc += code[pc + 6];
				case F.SLOTRET:
					acc = stack[fp + code[pc + 1]];
					if (trap >= 0) trapState = RETURNED;
					return acc;
				case F.CALLGFPUSH:
					fpcs[depth] = pc;
					var o:NValue = m.globals[code[pc + 1]];
					acc = callAt(field(m, pc, o, code[pc + 2], vthis), o, code[pc + 3], fp + code[pc + 4]);
					sp = top;
					stack[fp + code[pc + 5]] = acc;
					pc += code[pc + 6];
				case F.CALLPUSH:
					fpcs[depth] = pc;
					acc = callAt(acc, vthis, code[pc + 1], fp + code[pc + 2]);
					sp = top;
					stack[fp + code[pc + 3]] = acc;
					pc += code[pc + 4];
				case F.BUILTIN:
					// (n + 8: a tail call, which leaves this frame first as TAILCALL)
					var n = code[pc + 2], d = fp + code[pc + 3];
					var tail = n >= 8;
					if (tail) {
						n -= 8;
						depth--;
					} else
						fpcs[depth] = pc;
					var r:NValue = builtin(code[pc + 1], d - n);
					if (r == NOT_RUN) r = callAt(m.consts[code[pc + 4]], vthis, n, d);
					if (tail) depth++;
					acc = r;
					sp = top;
					pc += 5;
				case op:
					throw errorAt(m, pc, "Invalid opcode " + op);
			}
		}
	}

	// a call of f with n arguments up to argTop: a function of the code
	// entered here (no callOp's frame between the two interps), any other by callOp
	inline function callAt(f:NValue, thisv:NValue, n:Int, argTop:Int):NValue {
		var fn:NFun = Std.isOfType(f, NFun) ? f.asFun() : null;
		return if (fn != null && fn.prim == null && fn.nargs == n && depth < MAX_DEPTH) {
			var fp = argTop - n;
			var cm = fn.module;
			var top = fp + cm.frameMax[fn.addr];
			if (top + 8 > stack.length) growTo(top + 8);
			sp = top;
			depth++;
			var r = interp(cm, fn.addr, null, -1, thisv, fn.env, fp, top);
			depth--;
			r;
		} else {
			sp = argTop;
			callOp(f, thisv, n);
		}
	}

	// a builtin's answer (Frame.BUILTINS) from its arguments on the stack
	// from base, or NOT_RUN where the call takes it (another type of
	// argument: its error; a comparison function given)
	static final NOT_RUN = new NVal(-1);

	function builtin(which:Int, base:Int):NValue {
		var a0:NValue = stack[base];
		switch which {
			case 0: // $sget
				var p:NValue = stack[base + 1];
				if (Tag.isString(a0) && Tag.isInt(p)) {
					var b = a0.asStr().b, i = p.asInt();
					return i < 0 || i >= b.length ? null : b.get(i);
				}
			case 1: // $sset
				var p:NValue = stack[base + 1], c:NValue = stack[base + 2];
				if (Tag.isString(a0) && Tag.isInt(p) && Tag.isInt(c)) {
					var b = a0.asStr().b, i = p.asInt();
					if (i < 0 || i >= b.length) return null;
					var v = c.asInt() & 0xFF;
					b.set(i, v);
					return v;
				}
			case 2: // $ssize
				if (Tag.isString(a0)) return a0.asStr().b.length;
			case 3: // $asize
				if (Tag.isArray(a0)) return a0.asArr().length;
			case 4: // $typeof
				return Tag.of(a0);
			case 5 | 6 | 7: // $hget, $hset, $hmem (no comparison function)
				var cmp:NValue = stack[base + (which == 6 ? 3 : 2)];
				if (cmp == null && Tag.isAbstract(a0) && a0.asAbs().kind == "hash") {
					var h:Builtins.NHash = a0.asAbs().data;
					var k:NValue = stack[base + 1];
					return switch which {
						case 5: h.get(this, k, null);
						case 6: h.set(this, k, stack[base + 2], null);
						case _: h.mem(this, k, null);
					}
				}
			case 8: // $objget
				var f:NValue = stack[base + 1];
				if (!Tag.isObject(a0)) return null;
				if (Tag.isInt(f)) return a0.asObj().get(f.asInt());
			case 9: // $objfield
				var f:NValue = stack[base + 1];
				if (Tag.isInt(f)) return Tag.isObject(a0) && a0.asObj().hasOwn(f.asInt());
			case 10: // $istrue
				return !isFalse(a0);
			case 11: // $not
				return isFalse(a0);
		}
		return NOT_RUN;
	}

	// o's field id (AccField): an inline cache by the code index of the
	// object and its field's slot, an own field's or its prototype's, checked
	// against the slot's id (the slots move)
	inline function field(m:Module, pc:Int, o:NValue, id:Int, vthis:NValue):NValue {
		if (!Tag.isObject(o)) throw invalidFieldAt(m, pc, id);
		var obj = o.asObj();
		var k = m.icIdx[pc];
		var c = m.icObj[pc];
		return if (c == obj && k < obj.n && obj.ids[k] == id) obj.vals[k] else if (c != null && c == obj.proto && k < c.n
			&& c.ids[k] == id && obj.find(id) < 0) c.vals[k] else fieldSlow(m, pc, obj, id, vthis);
	}

	function fieldSlow(m:Module, pc:Int, o:NObj, id:Int, vthis:NValue):NValue {
		var k = o.find(id);
		var p = o.proto;
		if (k >= 0) {
			m.icObj[pc] = o;
			m.icIdx[pc] = k;
			return o.vals[k];
		}
		if (p != null && (k = p.find(id)) >= 0) {
			m.icObj[pc] = p;
			m.icIdx[pc] = k;
			return p.vals[k];
		}
		if (resolver != null && !o.has(id)) return callEx(vthis, resolver, [o, id]);
		return o.get(id);
	}

	static inline var ENDED = 1;
	static inline var RETURNED = 2;

	var trapState = 0;
	var resumePc = 0;
	var resumeThis:NValue = null;

	// the code under a trap: an exception restores the trap's state and goes on
	// at its handler
	function protect(m:Module, pc:Int, acc:NValue, t:Int, vthis:NValue, env:NValue, fp:Int, top:Int):NValue {
		try {
			return interp(m, pc, acc, t, vthis, env, fp, top);
		} catch (e:Dynamic) {
			var ne = wrap(e);
			capture(ne);
			var d = stack[t + 3].asInt();
			resumePc = stack[t].asInt();
			resumeThis = stack[t + 1];
			// (Neko's calls since the trap, outermost first: the frames from the
			// trap's own, whose call or throw is among them, to the throw's;
			// after a $rethrow, the stack caught before follows)
			var st = ne.stack.slice(0, ne.depth - d + 1);
			st.reverse();
			excStack = ne.rethrown ? st.concat(excStack) : st;
			depth = d;
			trapState = ENDED;
			return ne.value;
		}
	}

	// the positions of the frames when it was thrown, innermost first
	public function capture(ne:NekoError) {
		if (ne.stack != null) return;
		var st:NArr = [];
		var k = depth;
		while (k >= 0) {
			var m = Module.byId(fmods[k]);
			st.push(m == null ? null : m.position(m.oldOf[fpcs[k]]));
			k--;
		}
		ne.stack = st;
		ne.depth = depth;
	}

	// $callstack: every frame's call, outermost first (the last: the call of
	// $callstack itself)
	public function callStack():NArr {
		var st:NArr = [];
		for (k in 0...depth + 1) {
			var m = Module.byId(fmods[k]);
			st.push(m == null ? null : m.position(m.oldOf[fpcs[k]]));
		}
		return st;
	}

	function errorAt(m:Module, pc:Int, msg:String):NekoError {
		fpcs[depth] = pc;
		return error(msg);
	}

	function invalidFieldAt(m:Module, pc:Int, id:Int):NekoError {
		fpcs[depth] = pc;
		return invalidField(id);
	}

	// a binary operation of an Int and a constant (OpImm)
	inline function intOp(op:Int, a:Int, k:Int):NValue {
		return switch op {
			case Op.Add: box(a + k);
			case Op.Sub: box(a - k);
			case Op.Mult: box(a * k);
			case _: intCmp(op, a, k);
		}
	}

	static inline function intCmp(op:Int, a:Int, b:Int):Bool {
		return switch op {
			case Op.Lt: a < b;
			case Op.Lte: a <= b;
			case Op.Gt: a > b;
			case Op.Gte: a >= b;
			case Op.Eq: a == b;
			case _: a != b;
		}
	}

	function anyOp(op:Int, a:NValue, b:NValue):NValue {
		return switch op {
			case Op.Add: add(a, b);
			case Op.Sub | Op.Mult: numberOp(a, b, op);
			case _: anyCmp(op, a, b);
		}
	}

	function anyCmp(op:Int, a:NValue, b:NValue):Bool {
		var c = compare(a, b);
		return switch op {
			case Op.Eq: c == 0;
			case Op.Neq: c != 0;
			case Op.Lt: c != INVALID && c < 0;
			case Op.Lte: c != INVALID && c <= 0;
			case Op.Gt: c != INVALID && c > 0;
			case _: c != INVALID && c >= 0;
		}
	}

	// a Haxe error of the host (an unexpected one) as a Neko exception
	public function wrap(e:Dynamic):NekoError {
		if (Std.isOfType(e, NekoError)) return e;
		if (Std.isOfType(e, Builtins.Failure)) return new NekoError(NStr.of(lastPrim == null ? "?" : lastPrim.name));
		if (Std.isOfType(e, haxe.Exception)) return new NekoError(NStr.of((e : haxe.Exception).message));
		return new NekoError(NStr.of(Std.string(e)));
	}

	static function opName(op:Int):String {
		return switch op {
			case Op.Shl: "<<";
			case Op.Shr: ">>";
			case Op.UShr: ">>>";
			case Op.Or: "|";
			case Op.And: "&";
			case Op.Xor: "^";
			case Op.Sub: "-";
			case Op.Mult: "*";
			case Op.Mod: "%";
			case _: "?";
		}
	}

	function invalidField(id:Int):NekoError {
		var n = Fields.nameBytes(id);
		if (n == null) return error("Invalid field access");
		return error("Invalid field access : " + n.toString());
	}

	inline function index(acc:NValue, i:Int):NValue {
		return if (Tag.isArray(acc)) {
			var arr = acc.asArr();
			i < 0 || i >= arr.length ? null : arr[i];
		} else if (Tag.isObject(acc)) objectOp(acc.asObj(), i, Fields.idGet, "Unsupported operation") else throw error("Invalid array access");
	}

	public static inline function isFalse(v:NValue):Bool {
		return v == null || (Tag.isBool(v) && !v.asBool()) || (Tag.isInt(v) && v.asInt() == 0);
	}

	public static function newObject(p:NValue):NObj {
		if (p == null) return new NObj();
		if (!Tag.isObject(p)) throw error("$new");
		return p.asObj().copy();
	}

	function objectOp(o:NObj, arg:NValue, id:Int, err:String):NValue {
		var f = o.get(id);
		if (f == null) throw error(err);
		return callEx(o, f, [arg]);
	}

	// a field function of o if any (ObjectOpGen's test)
	inline function opField(o:NValue, id:Int):NValue
		return Tag.isObject(o) ? o.asObj().get(id) : null;

	function add(a:NValue, b:NValue):NValue {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if (ka == 1 && kb == 1) return a.asInt() + b.asInt();
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) return a.asFloat() + b.asFloat();
		if (ka == 1 && Tag.isString(b)) return concat(Bytes.ofString(Std.string(a.asInt())), b.asStr().b);
		if (kb == 1 && Tag.isString(a)) return concat(a.asStr().b, Bytes.ofString(Std.string(b.asInt())));
		var f = opField(a, Fields.idAdd);
		if (f != null) return callEx(a, f, [b]);
		f = opField(b, Fields.idRadd);
		if (f != null) return callEx(b, f, [a]);
		if (Tag.isString(a) || Tag.isString(b)) return concat(toBytes(a), toBytes(b));
		throw error("Invalid operation (+)");
	}

	static function concat(a:Bytes, b:Bytes):NStr {
		var r = Bytes.alloc(a.length + b.length);
		r.blit(0, a, 0, a.length);
		r.blit(a.length, b, 0, b.length);
		return new NStr(r);
	}

	function numberOp(a:NValue, b:NValue, op:Int):NValue {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if (ka == 1 && kb == 1) {
			var x = a.asInt(), y = b.asInt();
			return switch op {
				case Op.Sub: x - y;
				case Op.Mult: x * y;
				case _: x % y;
			}
		}
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) {
			var x = a.asFloat(), y = b.asFloat();
			return switch op {
				case Op.Sub: x - y;
				case Op.Mult: x * y;
				case _: x % y;
			}
		}
		var id = 0, rid = 0;
		switch op {
			case Op.Sub:
				id = Fields.idSub;
				rid = Fields.idRsub;
			case Op.Mult:
				id = Fields.idMult;
				rid = Fields.idRmult;
			case _:
				id = Fields.idMod;
				rid = Fields.idRmod;
		}
		var f = opField(a, id);
		if (f != null) return callEx(a, f, [b]);
		f = opField(b, rid);
		if (f != null) return callEx(b, f, [a]);
		throw error("Invalid operation (" + opName(op) + ")");
	}

	function div(a:NValue, b:NValue):NValue {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) return a.asFloat() / b.asFloat();
		var f = opField(a, Fields.idDiv);
		if (f != null) return callEx(a, f, [b]);
		f = opField(b, Fields.idRdiv);
		if (f != null) return callEx(b, f, [a]);
		throw error("Invalid operation (/)");
	}

	static inline function icmp(a:Int, b:Int):Int
		return a == b ? 0 : (a < b ? -1 : 1);

	static inline function fcmp(a:Float, b:Float):Int {
		if (Math.isNaN(a) || Math.isNaN(b)) return INVALID;
		return a == b ? 0 : (a < b ? -1 : 1);
	}

	public static function scmp(a:Bytes, b:Bytes):Int {
		var r = a.compare(b);
		return r == 0 ? 0 : (r < 0 ? -1 : 1);
	}

	static final TRUE = Bytes.ofString("true");
	static final FALSE = Bytes.ofString("false");

	// val_compare
	public function compare(a:NValue, b:NValue):Int {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if (ka == 1) {
			if (kb == 1) return icmp(a.asInt(), b.asInt());
			if (kb == 2) return fcmp(a.asInt(), b.asFloat());
			if (Tag.isString(b)) return scmp(Bytes.ofString(Std.string(a.asInt())), b.asStr().b);
		} else if (ka == 2) {
			if (kb == 1) return fcmp(a.asFloat(), b.asInt());
			if (kb == 2) return fcmp(a.asFloat(), b.asFloat());
			if (Tag.isString(b)) return scmp(Bytes.ofString(formatFloat(a.asFloat())), b.asStr().b);
		} else if (Tag.isString(a)) {
			var sa = a.asStr().b;
			if (kb == 1) return scmp(sa, Bytes.ofString(Std.string(b.asInt())));
			if (kb == 2) return scmp(sa, Bytes.ofString(formatFloat(b.asFloat())));
			if (kb == 3) return scmp(sa, b.asBool() ? TRUE : FALSE);
			if (Tag.isString(b)) return scmp(sa, b.asStr().b);
		} else if (ka == 3) {
			if (kb == 3) return a.asBool() == b.asBool() ? 0 : (a.asBool() ? 1 : -1);
			if (Tag.isString(b)) return scmp(a.asBool() ? TRUE : FALSE, b.asStr().b);
		} else if (Tag.isObject(a) && Tag.isObject(b)) {
			if (a == b) return 0;
			var f = a.asObj().get(Fields.idCompare);
			if (f == null) return INVALID;
			var r = callEx(a, f, [b]);
			return Tag.isInt(r) ? r.asInt() : INVALID;
		}
		if (ka == 0 && kb == 0) return 0;
		if (ka == 0 || kb == 0) return INVALID;
		return same(a, b) ? 0 : INVALID;
	}

	// physical equality
	public static function same(a:NValue, b:NValue):Bool {
		var ka = hxmc.Native.typeKind(a);
		if (ka != hxmc.Native.typeKind(b)) return false;
		return switch ka {
			case 0: true;
			case 1: a.asInt() == b.asInt();
			case 3: a.asBool() == b.asBool();
			case 2: false;
			case _: a == b;
		}
	}

	static function physCompare(a:NValue, b:NValue):Int {
		if (Tag.isInt(a) && Tag.isInt(b)) return icmp(a.asInt(), b.asInt());
		return same(a, b) ? 0 : 1;
	}

	// ---- printing (val_buffer)

	public function toBytes(v:NValue):Bytes {
		if (Tag.isString(v)) return v.asStr().b;
		var b = new BytesBuffer();
		buffer(b, v, []);
		return b.getBytes();
	}

	public function buffer(b:BytesBuffer, v:NValue, stack:NArr) {
		for (s in stack)
			if (s == v) {
				b.addString("...");
				return;
			}
		switch Tag.of(v) {
			case Tag.TINT:
				b.addString(Std.string(v.asInt()));
			case Tag.TSTRING:
				b.add(v.asStr().b);
			case Tag.TFLOAT:
				b.addString(formatFloat(v.asFloat()));
			case Tag.TNULL:
				b.addString("null");
			case Tag.TBOOL:
				b.addString(v.asBool() ? "true" : "false");
			case Tag.TFUNCTION:
				b.addString("#function:" + v.asFun().nargs);
			case Tag.TOBJECT:
				var o = v.asObj();
				var f = o.get(Fields.idString);
				var s:NValue = f == null ? null : callEx(o, f, []);
				if (Tag.isString(s)) b.add(s.asStr().b) else {
					stack.push(v);
					b.addString("{");
					var first = true;
					for (i in 0...o.n) {
						b.addString(first ? " " : ", ");
						first = false;
						var n = Fields.nameBytes(o.ids[i]);
						if (n == null) b.addString("null") else b.add(n);
						b.addString(" => ");
						buffer(b, o.vals[i], stack);
					}
					b.addString(first ? "}" : " }");
					stack.pop();
				}
			case Tag.TARRAY:
				var a = v.asArr();
				b.addString("[");
				stack.push(v);
				for (i in 0...a.length) {
					buffer(b, a[i], stack);
					if (i != a.length - 1) b.addString(",");
				}
				stack.pop();
				b.addString("]");
			case Tag.TABSTRACT:
				b.addString("#abstract");
			case _:
				b.addString("#unknown");
		}
	}

	// printf's %.15g
	public static function formatFloat(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (!Math.isFinite(f)) return f > 0 ? "inf" : "-inf";
		if (f == 0) return 1 / f < 0 ? "-0" : "0";
		var neg = f < 0;
		var s = Std.string(neg ? -f : f);
		// the shortest digits and the exponent of the first one
		var mant = s, exp = 0;
		var e = s.indexOf("e");
		if (e >= 0) {
			mant = s.substr(0, e);
			exp = Std.parseInt(s.substr(e + 1).split("+").join(""));
		}
		var dot = mant.indexOf(".");
		var intPart = dot < 0 ? mant : mant.substr(0, dot);
		var frac = dot < 0 ? "" : mant.substr(dot + 1);
		var digits = intPart + frac;
		var point = intPart.length + exp; // the decimal point after this many digits
		var lead = 0;
		while (lead < digits.length - 1 && digits.charCodeAt(lead) == "0".code)
			lead++;
		digits = digits.substr(lead);
		point -= lead;
		// round to 15 significant digits
		if (digits.length > 15) {
			var d = [for (i in 0...15) digits.charCodeAt(i) - "0".code];
			var next = digits.charCodeAt(15) - "0".code;
			var rest = false;
			for (i in 16...digits.length)
				if (digits.charCodeAt(i) != "0".code) rest = true;
			if (next > 5 || (next == 5 && (rest || d[14] & 1 == 1))) {
				var i = 14;
				while (i >= 0) {
					d[i]++;
					if (d[i] < 10) break;
					d[i] = 0;
					i--;
				}
				if (i < 0) {
					d.unshift(1);
					d.pop();
					point++;
				}
			}
			digits = [for (x in d) String.fromCharCode("0".code + x)].join("");
		}
		// trailing zeros dropped
		var end = digits.length;
		while (end > 1 && digits.charCodeAt(end - 1) == "0".code)
			end--;
		digits = digits.substr(0, end);
		var x = point - 1; // the exponent
		var out = if (x < -4 || x >= 15) {
			var m = digits.substr(0, 1) + (digits.length > 1 ? "." + digits.substr(1) : "");
			var ax = x < 0 ? -x : x;
			m + "e" + (x < 0 ? "-" : "+") + (ax < 10 ? "0" : "") + ax;
		} else if (point <= 0) {
			"0." + StringTools.rpad("", "0", -point) + digits;
		} else if (point >= digits.length) {
			digits + StringTools.rpad("", "0", point - digits.length);
		} else {
			digits.substr(0, point) + "." + digits.substr(point);
		}
		return neg ? "-" + out : out;
	}
}
