package hxmc;

import hxmc.ir.Ir;

// What a function's machine code depends on, hashed (per module by Driver,
// to key the object cache): its IR, and of everything else in the program
// only what MirBuild reads: field locations and types, the signatures and
// no-GC flags of callees, layouts of the objects it creates, the names of
// what it refers to, and the digest of a callee that may be inlined (its own
// IR, Inlined). Program-wide numbers (type indices, field ids, signatures,
// global indices) are not in it: native code refers to them by name
// (absolute symbols resolved when linking), so adding a type, a field or a
// global elsewhere leaves this module's code and key unchanged.
//
// The IR goes into the hash as words, without text: each node a tag of its
// own and its fields, numbers whole, strings with their length, lists with
// theirs (no two IRs give the same words). Two lanes of 32-bit arithmetic,
// the same on every host.
@:access(hxmc.ir.Facts)
class Fingerprint {
	var prep:Prep;
	var inlined:Null<Inlined>;
	var depth = 0;
	// the literals without a symbol yet, with the one they get (literal,
	// symbol, ...), each once in the order met: Driver registers them once
	// the threads are done
	public var newStrings:Array<String> = [];
	var seen = new Map<String, Bool>();

	public function new(prep:Prep, inlined:Null<Inlined>) {
		this.prep = prep;
		this.inlined = inlined;
	}

	// a 64-bit hash of a string (two 32-bit lanes), as 16 hex digits
	public static function hash(s:String):String {
		var h1 = 0x811c9dc5, h2 = 0x2545f491;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			h1 = (h1 ^ c) * 0x01000193;
			h2 = (h2 ^ c) * 0x5bd1e995;
			h2 ^= h2 >>> 15;
		}
		h1 ^= s.length;
		h1 = (h1 ^ (h1 >>> 16)) * 0x85ebca6b;
		h2 = (h2 ^ (h2 >>> 13)) * 0xc2b2ae35;
		return StringTools.hex(h1 ^ (h2 >>> 7), 8) + StringTools.hex(h2 ^ (h1 >>> 11), 8);
	}

	// ---- the hash: murmur3's mixing in one lane, xxhash32's round in the other

	var h1 = 0x2545f491;
	var h2 = 0x165667b1;
	var words = 0;

	inline function word(k:Int) {
		var a = k * 0xcc9e2d51;
		a = (a << 15) | (a >>> 17);
		a *= 0x1b873593;
		var x = h1 ^ a;
		x = (x << 13) | (x >>> 19);
		h1 = x * 5 + 0xe6546b64;
		var y = h2 + k * 0x85ebca77;
		y = (y << 13) | (y >>> 19);
		h2 = y * 0x9e3779b1;
		words++;
	}

	function str(s:String) {
		var n = s.length;
		word(n);
		var i = 0;
		while (i + 1 < n) {
			word(StringTools.fastCodeAt(s, i) | (StringTools.fastCodeAt(s, i + 1) << 16));
			i += 2;
		}
		if (i < n) word(StringTools.fastCodeAt(s, i));
	}

	// the hash's two words: murmur3's finalizer, xxhash32's
	function digest1():Int {
		var a = h1 ^ words;
		a = (a ^ (a >>> 16)) * 0x85ebca6b;
		a = (a ^ (a >>> 13)) * 0xc2b2ae35;
		return a ^ (a >>> 16);
	}

	function digest2():Int {
		var b = h2 ^ words;
		b = (b ^ (b >>> 15)) * 0x85ebca77;
		b = (b ^ (b >>> 13)) * 0xc2b2ae3d;
		return b ^ (b >>> 16);
	}

	// the key of what was hashed (16 hex digits)
	public function key():String
		return StringTools.hex(digest1(), 8) + StringTools.hex(digest2(), 8);

	// what every key starts with (the tool and the target, Driver.toolKey)
	public function text(s:String)
		str(s);

	// a literal's symbol, collected when it has none yet
	function literal(s:String, name:Null<String>) {
		if (seen.exists(s) || prep.strSymIfKnown(s) != null) return;
		seen.set(s, true);
		newStrings.push(s);
		newStrings.push(name != null ? name : Prep.strName(s));
	}

	// ---- the IR

	static inline var FUNC = 1;
	static inline var LIST = 2;
	static inline var INLINE = 3;
	static inline var S_SET = 10;
	static inline var S_EXPR = 11;
	static inline var S_SETFIELD = 12;
	static inline var S_ANONSET = 13;
	static inline var S_ARRSET = 14;
	static inline var S_ARRPUSH = 15;
	static inline var S_BOXSET = 16;
	static inline var S_SETGLOBAL = 17;
	static inline var S_IF = 18;
	static inline var S_LOOP = 19;
	static inline var S_BREAK = 20;
	static inline var S_CONTINUE = 21;
	static inline var S_SWITCH = 22;
	static inline var S_RETURN = 23;
	static inline var S_THROW = 24;
	static inline var S_TRY = 25;
	static inline var S_COLD = 26;
	static inline var S_POS = 27;
	static inline var E_INT = 40;
	static inline var E_F64 = 41;
	static inline var E_STR = 42;
	static inline var E_NULL = 43;
	static inline var E_LOCAL = 44;
	static inline var E_GLOBAL = 45;
	static inline var E_BIN = 46;
	static inline var E_NOT = 47;
	static inline var E_CONV = 48;
	static inline var E_BOX = 49;
	static inline var E_UNBOX = 50;
	static inline var E_FIELDADDR = 51;
	static inline var E_FIELD = 52;
	static inline var E_ANONGET = 53;
	static inline var E_INSTOF = 54;
	static inline var E_ENUMTAG = 55;
	static inline var E_ENUMPARAM = 56;
	static inline var E_ARRLEN = 57;
	static inline var E_ARRGET = 58;
	static inline var E_BOXGET = 59;
	static inline var E_CAPTURE = 60;
	static inline var E_TYPE = 61;
	static inline var E_CALL = 62;
	static inline var E_CALLDISPATCH = 63;
	static inline var E_CALLCLOS = 64;
	static inline var E_CALLANON = 65;
	static inline var E_CALLHOST = 66;
	static inline var E_NEWOBJ = 67;
	static inline var E_NEWENUM = 68;
	static inline var E_NEWARR = 69;
	static inline var E_NEWCLOS = 70;
	static inline var E_NEWBOX = 71;
	static inline var E_NEWANON = 72;
	static inline var E_ARRGETU = 73;

	public function func(f:FuncInfo) {
		word(FUNC);
		str(prep.funcSym(f));
		word(f.args.length);
		for (a in f.args)
			local(a);
		ty(f.ret);
		word(f.hasTry ? 1 : 0);
		word(f.locals.length);
		for (l in f.locals)
			local(l);
		stmts(f.body);
	}

	inline function local(l:Local) {
		word(l.id);
		ty(l.ty);
	}

	// (its representation: Ir.repr)
	inline function ty(t:Ty)
		word(switch t {
			case TI32: 1;
			case TBool: 2;
			case TF64: 3;
			case TI64: 4;
			case TVoid: 5;
			case TRef(_): 6;
			case TStruct(_): 7;
		});

	function tyName(tindex:Int) {
		var s = prep.tySym(tindex);
		if (s == null) {
			word(0);
			word(tindex);
		} else {
			word(1);
			str(s);
		}
	}

	function stmts(ss:haxe.ds.Vector<Stmt>) {
		word(LIST);
		word(ss.length);
		for (s in ss)
			stmt(s);
	}

	function stmt(s:Stmt) {
		switch s {
			case SSet(l, e):
				word(S_SET);
				word(l.id);
				ex(e);
			case SExpr(e):
				word(S_EXPR);
				ex(e);
			case SSetField(c, idx, o, v):
				word(S_SETFIELD);
				word(c.locs[idx]);
				ty(c.fields[idx].ty);
				ex(o);
				ex(v);
			case SAnonSet(n, t, o, v):
				word(S_ANONSET);
				str(n);
				ty(t);
				ex(o);
				ex(v);
			case SArrSet(elem, a, i, v):
				word(S_ARRSET);
				ty(elem);
				word(a.id);
				ex(i);
				ex(v);
			case SArrPush(elem, a, v):
				word(S_ARRPUSH);
				ty(elem);
				word(a.id);
				ex(v);
			case SBoxSet(t, x, v):
				word(S_BOXSET);
				ty(t);
				ex(x);
				ex(v);
			case SSetGlobal(g, v):
				word(S_SETGLOBAL);
				str(prep.p.globals[g].name);
				ty(prep.p.globals[g].ty);
				ex(v);
			case SIf(c, x, y):
				word(S_IF);
				ex(c);
				stmts(x);
				stmts(y);
			case SLoop(body):
				word(S_LOOP);
				stmts(body);
			case SBreak:
				word(S_BREAK);
			case SContinue:
				word(S_CONTINUE);
			case SSwitch(e, cases, def):
				word(S_SWITCH);
				ex(e);
				word(cases.length);
				for (c in cases) {
					word(c.values.length);
					for (v in c.values)
						word(v);
					stmts(c.body);
				}
				stmts(def);
			case SReturn(e):
				word(S_RETURN);
				if (e == null) word(0) else {
					word(1);
					ex(e);
				}
			case SThrow(e):
				word(S_THROW);
				ex(e);
			case STry(body, catches):
				word(S_TRY);
				stmts(body);
				word(catches.length);
				for (c in catches) {
					word(c.l.id);
					if (c.test == null) word(0) else {
						word(1);
						ex(c.test(ELocal(c.l)));
					}
					stmts(c.body);
				}
			case SCold(_, x):
				word(S_COLD);
				stmt(x);
			case SPos(file, line):
				word(S_POS);
				str(file);
				word(line);
		}
	}

	function args(xs:haxe.ds.Vector<Ex>) {
		word(xs.length);
		for (x in xs)
			ex(x);
	}

	function ex(e:Ex) {
		switch e {
			case EInt(v):
				word(E_INT);
				word(v);
			case EF64(v):
				word(E_F64);
				word(haxe.io.FPHelper.doubleLow(v));
				word(haxe.io.FPHelper.doubleHigh(v));
			case EStr(s):
				// (collects the literal: DataGen defines every one, cached modules included)
				literal(s, null);
				word(E_STR);
				str(s);
			case ENull(_):
				word(E_NULL);
			case ELocal(l):
				word(E_LOCAL);
				word(l.id);
			case EGlobal(g, t):
				word(E_GLOBAL);
				str(prep.p.globals[g].name);
				ty(t);
			case EBin(op, x, y):
				word(E_BIN);
				word(op.getIndex());
				ex(x);
				ex(y);
			case ENot(x):
				word(E_NOT);
				ex(x);
			case EConv(op, x):
				word(E_CONV);
				word(op.getIndex());
				ex(x);
			case EBox(t, x):
				word(E_BOX);
				ty(t);
				ex(x);
			case EUnbox(t, x):
				word(E_UNBOX);
				ty(t);
				ex(x);
			case EFieldAddr(c, idx, o):
				word(E_FIELDADDR);
				word(c.locs[idx]);
				ex(o);
			case EField(c, idx, o):
				word(E_FIELD);
				word(c.locs[idx]);
				ty(c.fields[idx].ty);
				ex(o);
			case EAnonGet(n, t, o, hint):
				word(E_ANONGET);
				str(n);
				ty(t);
				if (hint != null && hint.tindex >= 0) {
					word(1);
					tyName(hint.tindex);
					word(hint.locs[hint.slot(n) - 1]);
				} else word(0);
				ex(o);
			case ECast(_, x):
				ex(x);
			case EInstOf(c, x):
				word(E_INSTOF);
				tyName(c.tindex);
				ex(x);
			case EEnumTag(x, en):
				word(E_ENUMTAG);
				if (en != null && en.ctors.length > 0) {
					word(1);
					tyName(en.ctors[0].tindex);
					word(en.ctors[0].tag);
				} else word(0);
				ex(x);
			case EEnumParam(c, idx, x):
				word(E_ENUMPARAM);
				word(idx);
				word(c.params.length);
				for (t in c.params)
					ty(t);
				ex(x);
			case EArrLen(a):
				word(E_ARRLEN);
				ex(a);
			case EArrGet(elem, a, i):
				word(E_ARRGET);
				ty(elem);
				ex(a);
				ex(i);
			case EArrGetU(elem, a, i):
				word(E_ARRGETU);
				ty(elem);
				ex(a);
				ex(i);
			case EBoxGet(t, x):
				word(E_BOXGET);
				ty(t);
				ex(x);
			case ECapture(l, idx, c):
				word(E_CAPTURE);
				word(idx);
				word(l.captures.length);
				for (x in l.captures)
					ty(x.ty);
				ex(c);
			case EType(t):
				word(E_TYPE);
				str(switch t {
					case TRClass(c): prep.typeObjSym(c.tindex);
					case TREnum(e): prep.typeObjSym(e.tindex);
					case TRBuiltin(n): n;
				});
			case ECall(f, xs):
				word(E_CALL);
				str(prep.funcSym(f));
				word(f.noGc ? (f.blocks ? 2 : 1) : 0);
				word(f.args.length);
				for (a in f.args)
					ty(a.ty);
				ty(f.ret);
				args(xs);
				// a callee that may be inlined: its body too (Inline), as its digest
				if (depth < Inline.DEPTH && inlined != null) {
					var k = inlined.index.get(f);
					if (k != null) {
						var d = depth + 1;
						word(INLINE);
						word(inlined.digests[d][2 * k]);
						word(inlined.digests[d][2 * k + 1]);
						var l = inlined.literals[d][k];
						var i = 0;
						while (i < l.length) {
							literal(l[i], l[i + 1]);
							i += 2;
						}
					}
				}
			case ECallDispatch(sel, sig, xs):
				word(E_CALLDISPATCH);
				str(prep.selectorSym(sel));
				str(sig.key);
				args(xs);
			case ECallClos(s, c, xs):
				word(E_CALLCLOS);
				str(s.key);
				ex(c);
				args(xs);
			case ECallAnon(n, s, o, xs):
				word(E_CALLANON);
				str(n);
				str(s.key);
				ex(o);
				args(xs);
			case ECallHost(n, xs, r):
				word(E_CALLHOST);
				str(n);
				ty(r);
				// (a C function: how MirBuild.cCall converts and whether it blocks)
				var cs = hxmc.ir.CInterop.SIGS.get(n);
				if (cs == null) word(0) else {
					word(hxmc.ir.CInterop.BLOCKING.exists(n) ? 2 : 1);
					word(cs.args.length);
					for (a in cs.args)
						str(hxmc.ir.CInterop.shape(a));
					str(hxmc.ir.CInterop.shape(cs.ret));
				}
				// (the names the intrinsics take are not string objects of the program)
				switch [n, xs] {
					case ["hxmc_unsafe_Mem_sym" | "hxmc_unsafe_Mem_cstr" | "hxmc_unsafe_Mem_tlsGet" | "hxmc_unsafe_Mem_tlsSet" | "hxmc_unsafe_Mem_abi", [EStr(s)]]
						| ["hxmc_unsafe_Mem_tlsSet" | "hxmc_unsafe_Mem_words", [EStr(s), _]]:
						word(1);
						str(s);
						if (xs.length > 1) {
							word(1);
							ex(xs[1]);
						} else word(0);
					case _:
						word(0);
						args(xs);
				}
			case ENewObj(c):
				word(E_NEWOBJ);
				tyName(c.tindex);
				word(c.nslots);
			case ENewEnum(c, xs):
				word(E_NEWENUM);
				tyName(c.tindex);
				word(c.tag); // (Escape folds the tag of a known constructor)
				word(c.params.length);
				for (t in c.params)
					ty(t);
				args(xs);
			case ENewArr(elem, xs):
				word(E_NEWARR);
				ty(elem);
				args(xs);
			case ENewClos(l, xs):
				word(E_NEWCLOS);
				tyName(l.tindex);
				str(prep.funcSym(l.fn));
				word(l.captures.length);
				for (c in l.captures)
					ty(c.ty);
				args(xs);
			case ENewBox(t, x):
				word(E_NEWBOX);
				ty(t);
				ex(x);
			case ENewAnon(sh, xs):
				word(E_NEWANON);
				tyName(sh.tindex);
				word(sh.nslots);
				word(sh.fields.length);
				for (i in 0...sh.fields.length) {
					word(sh.locs[i]);
					ty(sh.fields[i].ty);
				}
				args(xs);
		}
	}
}

// The functions that may be inlined (MirBuild.inlineCands), each hashed as
// a caller's key takes it at each depth of inlining (1 to Inline.DEPTH: the
// calls it makes of others at the depth below, by their digests), with the
// literals that walk collects. Driver computes them before the keys, depth
// by depth from the deepest, in parallel.
class Inlined {
	public var funcs:haxe.ds.Vector<FuncInfo>;
	public var index = new Map<FuncInfo, Int>();
	// per depth, per function k: its digest's words (2k, 2k + 1) and literals (literal, symbol, ...)
	public var digests = new haxe.ds.Vector<haxe.ds.Vector<Int>>(Inline.DEPTH + 1);
	public var literals = new haxe.ds.Vector<haxe.ds.Vector<Array<String>>>(Inline.DEPTH + 1);

	var prep:Prep;

	public function new(prep:Prep, funcs:haxe.ds.Vector<FuncInfo>) {
		this.prep = prep;
		this.funcs = funcs;
		for (k in 0...funcs.length)
			index.set(funcs[k], k);
		for (d in 0...Inline.DEPTH + 1) {
			digests[d] = new haxe.ds.Vector(d == 0 ? 0 : 2 * funcs.length);
			literals[d] = new haxe.ds.Vector(d == 0 ? 0 : funcs.length);
		}
	}

	// function k at depth d (the deeper ones done)
	public function compute(d:Int, k:Int) {
		var fp = new Fingerprint(prep, this);
		@:privateAccess {
			fp.depth = d;
			fp.func(funcs[k]);
			digests[d][2 * k] = fp.digest1();
			digests[d][2 * k + 1] = fp.digest2();
		}
		literals[d][k] = fp.newStrings;
	}
}
