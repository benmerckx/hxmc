package hxmc.neko;

import haxe.ds.Vector;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import hxmc.neko.Module.Op;
import hxmc.neko.Value;

// one thread's interpreter (neko/vm/interp.c): the stack, `this`, the
// current function's environment. A call of the module's code is a call of
// interp (neko's loop calls without recursion; here each call is a Haxe call),
// a trap is six stack slots as in neko, so the compiler's stack offsets hold.
class VM {
	public static inline var INVALID = 0xFF;
	static inline var MAX_DEPTH = 6000;

	static final tls = new sys.thread.Tls<VM>();

	public var stack:Vector<Dynamic>;
	public var sp = 0;
	public var vthis:Dynamic = null;
	public var env:Dynamic = [];
	public var depth = 0;
	public var resolver:Dynamic = null;
	public var excStack:Array<Dynamic> = [];
	// each depth's module and the pc of its current call (neko's csp frames)
	final fmods = new Vector<Module>(MAX_DEPTH + 2);
	final fpcs = new Vector<Int>(MAX_DEPTH + 2, 0);
	// what $print writes to
	public var print:Bytes->Void;
	public var custom:Map<String, Dynamic> = new Map();

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
	static final smallInts:Vector<Dynamic> = {
		var v = new Vector<Dynamic>(2048);
		for (i in 0...2048)
			v[i] = (i - 1024 : Dynamic);
		v;
	};

	public static inline function box(i:Int):Dynamic
		return i >= -1024 && i < 1024 ? smallInts[i + 1024] : (i : Dynamic);

	public static inline function error(msg:String):NekoError
		return new NekoError(NStr.of(msg));

	// ---- the stack

	inline function push(v:Dynamic) {
		if (sp == stack.length) grow();
		stack[sp++] = v;
	}

	function grow() {
		if (stack.length >= 1 << 24) throw error("Stack Overflow");
		var n = new Vector<Dynamic>(stack.length * 2);
		Vector.blit(stack, 0, n, 0, sp);
		stack = n;
	}

	inline function pop(n:Int) {
		while (n-- > 0)
			stack[--sp] = null;
	}

	// ---- calls

	// val_callEx: f called on `thisv` (`keepThis`: the current `this`)
	public function callEx(thisv:Dynamic, f:Dynamic, args:Array<Dynamic>, keepThis = false):Dynamic {
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

	public inline function callN(f:Dynamic, args:Array<Dynamic>):Dynamic
		return callEx(null, f, args, true);

	// a call with nargs arguments on the stack, which it pops
	public function callOp(f:Dynamic, thisv:Dynamic, nargs:Int):Dynamic {
		if (!Tag.isFunction(f)) {
			pop(nargs);
			throw error("Invalid call");
		}
		var fn:NFun = f;
		var oldThis = vthis, oldEnv = env;
		if (fn.prim == null) {
			if (fn.nargs != nargs) {
				pop(nargs);
				throw error("Invalid call");
			}
			if (++depth > MAX_DEPTH) {
				depth = 0;
				throw error("Stack Overflow");
			}
			vthis = thisv;
			env = fn.env;
			var r = interp(fn.module, fn.addr, null);
			depth--;
			vthis = oldThis;
			env = oldEnv;
			return r;
		}
		if (fn.nargs != nargs && fn.nargs != -1) {
			pop(nargs);
			throw error("Invalid call");
		}
		var args:Array<Dynamic> = [for (i in 0...nargs) stack[sp - nargs + i]];
		pop(nargs);
		vthis = thisv;
		env = fn.env;
		var r = fn.prim(this, args);
		vthis = oldThis;
		env = oldEnv;
		return r;
	}

	// a module's code from its start (neko_vm_execute)
	public function execute(m:Module):Dynamic {
		var oldThis = vthis, oldEnv = env;
		vthis = null;
		env = [];
		var r = interp(m, 0, null);
		vthis = oldThis;
		env = oldEnv;
		return r;
	}

	// ---- the interpreter

	// a frame of the module's code, from pc; trap >= 0: the part of the frame
	// under the trap whose six slots start there (protect), which ends at its
	// EndTrap (trapState ENDED, resumePc) or with the function (RETURNED)
	function interp(m:Module, pc:Int, acc:Dynamic, trap:Int = -1):Dynamic {
		final code = m.code;
		fmods[depth] = m;
		while (true) {
			switch code[pc++] {
				case Op.AccNull:
					acc = null;
				case Op.AccTrue:
					acc = true;
				case Op.AccFalse:
					acc = false;
				case Op.AccThis:
					acc = vthis;
				case Op.AccInt:
					acc = m.consts[code[pc++]];
				case Op.AccStack0:
					acc = stack[sp - 1];
				case Op.AccStack1:
					acc = stack[sp - 2];
				case Op.AccStack:
					acc = stack[sp - 1 - code[pc++]];
				case Op.AccGlobal:
					acc = m.globals[code[pc++]];
				case Op.AccEnv:
					var e:Array<Dynamic> = env;
					var i = code[pc];
					if (i >= e.length) throw errorAt(m, pc, "Reading Outside Env");
					pc++;
					acc = e[i];
				case Op.AccField:
					fpcs[depth] = pc;
					var id = code[pc];
					if (Tag.isObject(acc)) {
						var o:NObj = acc;
						if (resolver != null && !o.has(id)) acc = callEx(null, resolver, [o, id], true) else acc = o.get(id);
					} else
						throw invalidFieldAt(m, pc, id);
					pc++;
				case Op.AccArray:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(acc) && Tag.isArray(a)) {
						var arr:Array<Dynamic> = a;
						var k:Int = acc;
						acc = k < 0 || k >= arr.length ? null : arr[k];
					} else if (Tag.isObject(a))
						acc = objectOp(a, acc, Fields.idGet, "Unsupported operation")
					else
						throw errorAt(m, pc, "Invalid array access");
					stack[--sp] = null;
				case Op.AccIndex0:
					fpcs[depth] = pc;
					acc = index(acc, 0);
				case Op.AccIndex1:
					fpcs[depth] = pc;
					acc = index(acc, 1);
				case Op.AccIndex:
					fpcs[depth] = pc;
					acc = index(acc, code[pc]);
					pc++;
				case Op.AccBuiltin:
					acc = m.consts[code[pc++]];
				case Op.SetStack:
					stack[sp - 1 - code[pc++]] = acc;
				case Op.SetGlobal:
					m.globals[code[pc++]] = acc;
				case Op.SetEnv:
					var e:Array<Dynamic> = env;
					var i = code[pc];
					if (i >= e.length) throw errorAt(m, pc, "Writing Outside Env");
					pc++;
					e[i] = acc;
				case Op.SetField:
					fpcs[depth] = pc;
					var o:Dynamic = stack[sp - 1];
					if (Tag.isObject(o)) (o : NObj).set(code[pc], acc) else throw invalidFieldAt(m, pc, code[pc]);
					stack[--sp] = null;
					pc++;
				case Op.SetArray:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					var k:Dynamic = stack[sp - 2];
					if (Tag.isArray(a) && Tag.isInt(k)) {
						var arr:Array<Dynamic> = a;
						var i:Int = k;
						if (i >= 0 && i < arr.length) arr[i] = acc;
					} else if (Tag.isObject(a)) {
						var o:NObj = a;
						var f = o.get(Fields.idSet);
						if (f == null) throw errorAt(m, pc, "Unsupported operation");
						callEx(o, f, [k, acc]);
					} else
						throw errorAt(m, pc, "Invalid array access");
					stack[--sp] = null;
					stack[--sp] = null;
				case Op.SetIndex:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					var i = code[pc];
					if (Tag.isArray(a)) {
						var arr:Array<Dynamic> = a;
						if (i >= 0 && i < arr.length) arr[i] = acc;
					} else if (Tag.isObject(a)) {
						var o:NObj = a;
						var f = o.get(Fields.idSet);
						if (f == null) throw errorAt(m, pc, "Unsupported operation");
						callEx(o, f, [i, acc]);
					} else
						throw errorAt(m, pc, "Invalid array access");
					pc++;
					stack[--sp] = null;
				case Op.SetThis:
					vthis = acc;
				case Op.Push:
					if (sp == stack.length) grow();
					stack[sp++] = acc;
				case Op.Pop:
					pop(code[pc++]);
				case Op.Apply:
					fpcs[depth] = pc + 1;
					if (!Tag.isFunction(acc)) throw errorAt(m, pc, "$apply");
					var fn:NFun = acc;
					var n = code[pc++];
					if (fn.nargs == n || fn.nargs == -1) acc = callOp(fn, vthis, n) else {
						if (n > fn.nargs) throw errorAt(m, pc, "$apply");
						var e:Array<Dynamic> = [for (_ in 0...fn.nargs + 1) null];
						e[0] = fn;
						var i = n;
						while (i > 0) {
							e[i--] = stack[sp - 1];
							stack[--sp] = null;
						}
						acc = Builtins.applyClosure(fn.nargs - n, e);
					}
				case Op.TailCall:
					var p = code[pc++];
					var st = p >> 3;
					var nargs = p & 7;
					// the arguments over the frame, the frame popped
					st -= nargs;
					for (i in 0...nargs)
						stack[sp - nargs - st + i] = stack[sp - nargs + i];
					pop(st);
					fpcs[depth] = pc;
					var r = callOp(acc, vthis, nargs);
					if (trap >= 0) trapState = RETURNED;
					return r;
				case Op.Call:
					fpcs[depth] = pc + 1;
					acc = callOp(acc, vthis, code[pc++]);
				case Op.ObjCall:
					fpcs[depth] = pc + 1;
					var o:Dynamic = stack[sp - 1];
					stack[--sp] = null;
					acc = callOp(acc, o, code[pc++]);
				case Op.Jump:
					pc = code[pc];
				case Op.JumpIf:
					if (Tag.isBool(acc) && (acc : Bool)) pc = code[pc] else pc++;
				case Op.JumpIfNot:
					if (Tag.isBool(acc) && (acc : Bool)) pc++ else pc = code[pc];
				case Op.Trap:
					if (sp + 6 > stack.length) grow();
					var t = sp;
					stack[t] = code[pc];
					stack[t + 1] = vthis;
					stack[t + 2] = env;
					stack[t + 3] = depth;
					stack[t + 4] = null;
					stack[t + 5] = null;
					sp += 6;
					acc = protect(m, pc + 1, acc, t);
					if (trapState == RETURNED) {
						if (trap < 0) trapState = 0;
						return acc;
					}
					pc = resumePc;
				case Op.EndTrap:
					if (trap < 0 || trap != sp - 6) throw errorAt(m, pc, "Invalid End Trap");
					pop(6);
					trapState = ENDED;
					resumePc = pc;
					return acc;
				case Op.Ret:
					pop(code[pc++]);
					if (trap >= 0) trapState = RETURNED;
					return acc;
				case Op.MakeEnv:
					fpcs[depth] = pc;
					var n = code[pc++];
					var e:Array<Dynamic> = [for (_ in 0...n) null];
					while (n-- > 0) {
						e[n] = stack[sp - 1];
						stack[--sp] = null;
					}
					if (!Tag.isFunction(acc) || (acc : NFun).prim != null) throw errorAt(m, pc, "Invalid environment");
					var f:NFun = acc;
					acc = new NFun(f.nargs, e, f.module, f.addr, null, null);
				case Op.MakeArray:
					var n = code[pc++];
					var a:Array<Dynamic> = [for (_ in 0...n + 1) null];
					while (n > 0) {
						a[n--] = stack[sp - 1];
						stack[--sp] = null;
					}
					a[0] = acc;
					acc = a;
				case Op.MakeArray2:
					var n = code[pc++];
					var a:Array<Dynamic> = [for (_ in 0...n + 1) null];
					a[n] = acc;
					while (n > 0) {
						a[--n] = stack[sp - 1];
						stack[--sp] = null;
					}
					acc = a;
				case Op.Bool:
					acc = !isFalse(acc);
				case Op.Not:
					acc = isFalse(acc);
				case Op.IsNull:
					acc = acc == null;
				case Op.IsNotNull:
					acc = acc != null;
				case Op.Add:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					acc = Tag.isInt(a) && Tag.isInt(acc) ? box((a : Int) + (acc : Int)) : add(a, acc);
					stack[--sp] = null;
				case Op.Sub:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					acc = Tag.isInt(a) && Tag.isInt(acc) ? box((a : Int) - (acc : Int)) : numberOp(a, acc, Op.Sub);
					stack[--sp] = null;
				case Op.Mult:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					acc = Tag.isInt(a) && Tag.isInt(acc) ? box((a : Int) * (acc : Int)) : numberOp(a, acc, Op.Mult);
					stack[--sp] = null;
				case Op.Div:
					fpcs[depth] = pc;
					acc = div(stack[sp - 1], acc);
					stack[--sp] = null;
				case Op.Mod:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(acc) && (acc : Int) == 0 && Tag.isInt(a)) throw errorAt(m, pc, "Invalid operation (%)");
					acc = numberOp(a, acc, Op.Mod);
					stack[--sp] = null;
				case Op.Shl | Op.Shr | Op.UShr | Op.Or | Op.And | Op.Xor:
					var a:Dynamic = stack[sp - 1];
					var op = code[pc - 1];
					if (!Tag.isInt(acc) || !Tag.isInt(a)) throw errorAt(m, pc, "Invalid operation (" + opName(op) + ")");
					var x:Int = a, y:Int = acc;
					acc = switch op {
						case Op.Shl: x << y;
						case Op.Shr: x >> y;
						case Op.UShr: x >>> y;
						case Op.Or: x | y;
						case Op.And: x & y;
						case _: x ^ y;
					}
					stack[--sp] = null;
				case Op.Eq:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) {
						acc = (a : Int) == (acc : Int);
						stack[--sp] = null;
						continue;
					}
					var c = compare(a, acc);
					acc = c == 0;
					stack[--sp] = null;
				case Op.Neq:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) {
						acc = (a : Int) != (acc : Int);
						stack[--sp] = null;
						continue;
					}
					var c = compare(a, acc);
					acc = c != 0;
					stack[--sp] = null;
				case Op.Lt:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) {
						acc = (a : Int) < (acc : Int);
						stack[--sp] = null;
						continue;
					}
					var c = compare(a, acc);
					acc = c != INVALID && c < 0;
					stack[--sp] = null;
				case Op.Lte:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) {
						acc = (a : Int) <= (acc : Int);
						stack[--sp] = null;
						continue;
					}
					var c = compare(a, acc);
					acc = c != INVALID && c <= 0;
					stack[--sp] = null;
				case Op.Gt:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) {
						acc = (a : Int) > (acc : Int);
						stack[--sp] = null;
						continue;
					}
					var c = compare(a, acc);
					acc = c != INVALID && c > 0;
					stack[--sp] = null;
				case Op.Gte:
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					if (Tag.isInt(a) && Tag.isInt(acc)) {
						acc = (a : Int) >= (acc : Int);
						stack[--sp] = null;
						continue;
					}
					var c = compare(a, acc);
					acc = c != INVALID && c >= 0;
					stack[--sp] = null;
				case Op.TypeOf:
					acc = Tag.of(acc);
				case Op.Compare:
					fpcs[depth] = pc;
					var c = compare(stack[sp - 1], acc);
					acc = c == INVALID ? null : c;
					stack[--sp] = null;
				case Op.PhysCompare:
					acc = physCompare(stack[sp - 1], acc);
					stack[--sp] = null;
				case Op.Hash:
					if (!Tag.isString(acc)) throw errorAt(m, pc, "$hash");
					acc = Fields.idBytes((acc : NStr).b);
				case Op.New:
					acc = newObject(acc);
				case Op.JumpTable:
					var n = code[pc];
					if (Tag.isInt(acc) && (acc : Int) >= 0 && (acc : Int) < n) pc += 1 + 2 * (acc : Int) else pc += 1 + 2 * n;
				case Op.Loop:
				// ---- superinstructions (Module.fuse)
				case Op.PushStack0:
					acc = stack[sp - 1];
					if (sp == stack.length) grow();
					stack[sp++] = acc;
					pc++;
				case Op.PushStack1:
					acc = stack[sp - 2];
					if (sp == stack.length) grow();
					stack[sp++] = acc;
					pc++;
				case Op.PushStack:
					acc = stack[sp - 1 - code[pc]];
					if (sp == stack.length) grow();
					stack[sp++] = acc;
					pc += 2;
				case Op.PushConst:
					acc = m.consts[code[pc]];
					if (sp == stack.length) grow();
					stack[sp++] = acc;
					pc += 2;
				case Op.PushGlobal:
					acc = m.globals[code[pc]];
					if (sp == stack.length) grow();
					stack[sp++] = acc;
					pc += 2;
				case Op.OpImm:
					var k = code[pc], op = code[pc + 2];
					fpcs[depth] = pc + 3;
					if (Tag.isInt(acc)) acc = intOp(op, acc, k) else acc = anyOp(op, acc, m.consts[code[pc + 1]]);
					pc += 3;
				case Op.CmpJump:
					var p = code[pc];
					fpcs[depth] = pc;
					var a:Dynamic = stack[sp - 1];
					stack[--sp] = null;
					var b = Tag.isInt(a) && Tag.isInt(acc) ? intCmp(p & 255, a, acc) : anyCmp(p & 255, a, acc);
					acc = b;
					if (b == (p >= 256)) pc = code[pc + 1] else pc += 2;
				case Op.OpImmJump:
					var k = code[pc], p = code[pc + 2];
					fpcs[depth] = pc + 3;
					var b = Tag.isInt(acc) ? intCmp(p & 255, acc, k) : anyCmp(p & 255, acc, m.consts[code[pc + 1]]);
					acc = b;
					if (b == (p >= 256)) pc = code[pc + 4] else pc += 5;
				case Op.Last:
					if (trap >= 0) trapState = RETURNED;
					return acc;
				case op:
					throw errorAt(m, pc, "Invalid opcode " + op);
			}
		}
	}

	static inline var ENDED = 1;
	static inline var RETURNED = 2;

	var trapState = 0;
	var resumePc = 0;

	// the code under a trap: an exception restores the trap's state and goes on
	// at its handler
	function protect(m:Module, pc:Int, acc:Dynamic, t:Int):Dynamic {
		try {
			return interp(m, pc, acc, t);
		} catch (e:Dynamic) {
			var ne = wrap(e);
			capture(ne);
			var d:Int = stack[t + 3];
			resumePc = stack[t];
			vthis = stack[t + 1];
			env = stack[t + 2];
			// (the frames between the throw and the trap, not the trap's own)
			excStack = ne.stack.slice(0, ne.depth - d);
			depth = d;
			while (sp > t)
				stack[--sp] = null;
			trapState = ENDED;
			return ne.value;
		}
	}

	// the positions of the frames when it was thrown, innermost first
	public function capture(ne:NekoError) {
		if (ne.stack != null) return;
		var st:Array<Dynamic> = [];
		var k = depth;
		while (k >= 0) {
			var m = fmods[k];
			st.push(m == null ? null : m.position(fpcs[k] - 1));
			k--;
		}
		ne.stack = st;
		ne.depth = depth;
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
	inline function intOp(op:Int, a:Int, k:Int):Dynamic {
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

	function anyOp(op:Int, a:Dynamic, b:Dynamic):Dynamic {
		return switch op {
			case Op.Add: add(a, b);
			case Op.Sub | Op.Mult: numberOp(a, b, op);
			case _: anyCmp(op, a, b);
		}
	}

	function anyCmp(op:Int, a:Dynamic, b:Dynamic):Bool {
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
	public static function wrap(e:Dynamic):NekoError {
		if (Std.isOfType(e, NekoError)) return e;
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

	inline function index(acc:Dynamic, i:Int):Dynamic {
		return if (Tag.isArray(acc)) {
			var arr:Array<Dynamic> = acc;
			i < 0 || i >= arr.length ? null : arr[i];
		} else if (Tag.isObject(acc)) objectOp(acc, i, Fields.idGet, "Unsupported operation") else throw error("Invalid array access");
	}

	public static inline function isFalse(v:Dynamic):Bool {
		return v == null || (Tag.isBool(v) && !(v : Bool)) || (Tag.isInt(v) && (v : Int) == 0);
	}

	public static function newObject(p:Dynamic):NObj {
		if (p == null) return new NObj();
		if (!Tag.isObject(p)) throw error("$new");
		return (p : NObj).copy();
	}

	function objectOp(o:NObj, arg:Dynamic, id:Int, err:String):Dynamic {
		var f = o.get(id);
		if (f == null) throw error(err);
		return callEx(o, f, [arg]);
	}

	// a field function of o if any (ObjectOpGen's test)
	inline function opField(o:Dynamic, id:Int):Dynamic
		return Tag.isObject(o) ? (o : NObj).get(id) : null;

	function add(a:Dynamic, b:Dynamic):Dynamic {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if (ka == 1 && kb == 1) return (a : Int) + (b : Int);
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) return (a : Float) + (b : Float);
		if (ka == 1 && Tag.isString(b)) return concat(Bytes.ofString(Std.string((a : Int))), (b : NStr).b);
		if (kb == 1 && Tag.isString(a)) return concat((a : NStr).b, Bytes.ofString(Std.string((b : Int))));
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

	function numberOp(a:Dynamic, b:Dynamic, op:Int):Dynamic {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if (ka == 1 && kb == 1) {
			var x:Int = a, y:Int = b;
			return switch op {
				case Op.Sub: x - y;
				case Op.Mult: x * y;
				case _: x % y;
			}
		}
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) {
			var x:Float = a, y:Float = b;
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

	function div(a:Dynamic, b:Dynamic):Dynamic {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) return (a : Float) / (b : Float);
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
	public function compare(a:Dynamic, b:Dynamic):Int {
		var ka = Tag.kind(a), kb = Tag.kind(b);
		if (ka == 1) {
			if (kb == 1) return icmp(a, b);
			if (kb == 2) return fcmp((a : Int), (b : Float));
			if (Tag.isString(b)) return scmp(Bytes.ofString(Std.string((a : Int))), (b : NStr).b);
		} else if (ka == 2) {
			if (kb == 1) return fcmp((a : Float), (b : Int));
			if (kb == 2) return fcmp(a, b);
			if (Tag.isString(b)) return scmp(Bytes.ofString(formatFloat(a)), (b : NStr).b);
		} else if (Tag.isString(a)) {
			var sa = (a : NStr).b;
			if (kb == 1) return scmp(sa, Bytes.ofString(Std.string((b : Int))));
			if (kb == 2) return scmp(sa, Bytes.ofString(formatFloat(b)));
			if (kb == 3) return scmp(sa, (b : Bool) ? TRUE : FALSE);
			if (Tag.isString(b)) return scmp(sa, (b : NStr).b);
		} else if (ka == 3) {
			if (kb == 3) return (a : Bool) == (b : Bool) ? 0 : ((a : Bool) ? 1 : -1);
			if (Tag.isString(b)) return scmp((a : Bool) ? TRUE : FALSE, (b : NStr).b);
		} else if (Tag.isObject(a) && Tag.isObject(b)) {
			if (a == b) return 0;
			var f = (a : NObj).get(Fields.idCompare);
			if (f == null) return INVALID;
			var r = callEx(a, f, [b]);
			return Tag.isInt(r) ? (r : Int) : INVALID;
		}
		if (ka == 0 && kb == 0) return 0;
		if (ka == 0 || kb == 0) return INVALID;
		return same(a, b) ? 0 : INVALID;
	}

	// physical equality
	public static function same(a:Dynamic, b:Dynamic):Bool {
		var ka = hxmc.Native.typeKind(a);
		if (ka != hxmc.Native.typeKind(b)) return false;
		return switch ka {
			case 0: true;
			case 1: (a : Int) == (b : Int);
			case 3: (a : Bool) == (b : Bool);
			case 2: false;
			case _: a == b;
		}
	}

	static function physCompare(a:Dynamic, b:Dynamic):Int {
		if (Tag.isInt(a) && Tag.isInt(b)) return icmp(a, b);
		return same(a, b) ? 0 : 1;
	}

	// ---- printing (val_buffer)

	public function toBytes(v:Dynamic):Bytes {
		if (Tag.isString(v)) return (v : NStr).b;
		var b = new BytesBuffer();
		buffer(b, v, []);
		return b.getBytes();
	}

	public function buffer(b:BytesBuffer, v:Dynamic, stack:Array<Dynamic>) {
		for (s in stack)
			if (s == v) {
				b.addString("...");
				return;
			}
		switch Tag.of(v) {
			case Tag.TINT:
				b.addString(Std.string((v : Int)));
			case Tag.TSTRING:
				b.add((v : NStr).b);
			case Tag.TFLOAT:
				b.addString(formatFloat(v));
			case Tag.TNULL:
				b.addString("null");
			case Tag.TBOOL:
				b.addString((v : Bool) ? "true" : "false");
			case Tag.TFUNCTION:
				b.addString("#function:" + (v : NFun).nargs);
			case Tag.TOBJECT:
				var o:NObj = v;
				var f = o.get(Fields.idString);
				var s:Dynamic = f == null ? null : callEx(o, f, []);
				if (Tag.isString(s)) b.add((s : NStr).b) else {
					stack.push(v);
					b.addString("{");
					var first = true;
					for (i in 0...o.ids.length) {
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
				var a:Array<Dynamic> = v;
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
