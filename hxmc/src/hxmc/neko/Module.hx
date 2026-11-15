package hxmc.neko;

import haxe.ds.Vector;
import haxe.io.Bytes;
import hxmc.neko.Value;

// the opcodes (neko/vm/opcodes.h)
class Op {
	public static inline var AccNull = 0;
	public static inline var AccTrue = 1;
	public static inline var AccFalse = 2;
	public static inline var AccThis = 3;
	public static inline var AccInt = 4;
	public static inline var AccStack = 5;
	public static inline var AccGlobal = 6;
	public static inline var AccEnv = 7;
	public static inline var AccField = 8;
	public static inline var AccArray = 9;
	public static inline var AccIndex = 10;
	public static inline var AccBuiltin = 11;
	public static inline var SetStack = 12;
	public static inline var SetGlobal = 13;
	public static inline var SetEnv = 14;
	public static inline var SetField = 15;
	public static inline var SetArray = 16;
	public static inline var SetIndex = 17;
	public static inline var SetThis = 18;
	public static inline var Push = 19;
	public static inline var Pop = 20;
	public static inline var Call = 21;
	public static inline var ObjCall = 22;
	public static inline var Jump = 23;
	public static inline var JumpIf = 24;
	public static inline var JumpIfNot = 25;
	public static inline var Trap = 26;
	public static inline var EndTrap = 27;
	public static inline var Ret = 28;
	public static inline var MakeEnv = 29;
	public static inline var MakeArray = 30;
	public static inline var Bool = 31;
	public static inline var IsNull = 32;
	public static inline var IsNotNull = 33;
	public static inline var Add = 34;
	public static inline var Sub = 35;
	public static inline var Mult = 36;
	public static inline var Div = 37;
	public static inline var Mod = 38;
	public static inline var Shl = 39;
	public static inline var Shr = 40;
	public static inline var UShr = 41;
	public static inline var Or = 42;
	public static inline var And = 43;
	public static inline var Xor = 44;
	public static inline var Eq = 45;
	public static inline var Neq = 46;
	public static inline var Gt = 47;
	public static inline var Gte = 48;
	public static inline var Lt = 49;
	public static inline var Lte = 50;
	public static inline var Not = 51;
	public static inline var TypeOf = 52;
	public static inline var Compare = 53;
	public static inline var Hash = 54;
	public static inline var New = 55;
	public static inline var JumpTable = 56;
	public static inline var Apply = 57;
	public static inline var AccStack0 = 58;
	public static inline var AccStack1 = 59;
	public static inline var AccIndex0 = 60;
	public static inline var AccIndex1 = 61;
	public static inline var PhysCompare = 62;
	public static inline var TailCall = 63;
	public static inline var Loop = 64;
	public static inline var MakeArray2 = 65;
	public static inline var AccInt32 = 66;
	public static inline var Last = 67;
	// superinstructions (Module.fuse), in the slots of what they replace
	public static inline var PushStack0 = 68; // AccStack0 Push
	public static inline var PushStack1 = 69; // AccStack1 Push
	public static inline var PushStack = 70; // AccStack n Push: n
	public static inline var PushConst = 71; // AccInt Push: the constant's index
	public static inline var PushGlobal = 72; // AccGlobal g Push: g
	public static inline var OpImm = 73; // Push AccInt k <op>: k, the constant's index, op
	public static inline var CmpJump = 74; // <cmp> JumpIf(Not) t: cmp | 256 for JumpIf, t
	public static inline var OpImmJump = 75; // Push AccInt k <cmp> JumpIf(Not) t: k, index, cmp | 256 for JumpIf, (slot), t

	public static final hasParam:Array<Bool> = [
		false, false, false, false, true, true, true, true, true, false, true, true, // AccNull..AccBuiltin
		true, true, true, true, false, true, false, false, true, true, true, // SetStack..ObjCall
		true, true, true, true, false, true, true, true, // Jump..MakeArray
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, // Bool..Xor
		false, false, false, false, false, false, false, false, false, false, false, // Eq..New
		true, true, false, false, false, false, false, true, false, true, true, false // JumpTable..Last
	];
}

class Module {
	public var name:NStr;
	public var globals:Array<Dynamic>;
	public var code:Vector<Int>;
	// AccBuiltin's values, by the index in the code
	public var consts:Array<Dynamic> = [];
	public var exports:NObj;
	public var loader:NObj;
	public var fields:Array<String> = [];
	// the debug position of each code index: an index of dbgTbl, -1: none
	public var dbgIdx:Null<Vector<Int>>;
	public var dbgTbl:Array<Dynamic> = [];

	function new() {}

	public function position(pc:Int):Dynamic {
		if (dbgIdx == null || pc < 0 || pc >= dbgIdx.length) return name;
		var i = dbgIdx[pc];
		return i < 0 ? name : dbgTbl[i];
	}

	static function invalid():Dynamic
		throw new ReadError();

	// neko_read_module
	public static function read(b:Bytes, loader:NObj):Module {
		var p = 0;
		inline function byte():Int {
			if (p >= b.length) invalid();
			return b.get(p++);
		}
		inline function long():Int {
			if (p + 4 > b.length) invalid();
			var v = b.getInt32(p);
			p += 4;
			return v;
		}
		function str():String {
			var start = p;
			while (true) {
				if (p >= b.length || p - start > 0x100) invalid();
				if (b.get(p++) == 0) break;
			}
			return b.getString(start, p - 1 - start);
		}
		var m = new Module();
		if (long() != 0x4F4B454E) invalid();
		var nglobals = long(), nfields = long(), codesize = long();
		if (nglobals < 0 || nglobals > 0xFFFF || nfields < 0 || nfields > 0xFFFF || codesize < 0 || codesize > 0xFFFFFF) invalid();
		m.loader = loader;
		m.exports = new NObj();
		m.exports.set(Fields.id("__module"), new NAbs("module", m));
		m.globals = [for (_ in 0...nglobals) null];
		var version = 1;
		var funcs = [];
		for (i in 0...nglobals) {
			switch byte() {
				case 1:
					str();
				case 2:
					var v = long();
					if ((v & 0xFFFFFF) >= codesize) invalid();
					var f = new NFun(v >>> 24, [], m, v & 0xFFFFFF, null, null);
					m.globals[i] = f;
					funcs.push(f);
				case 3:
					if (p + 2 > b.length) invalid();
					var len = b.getUInt16(p);
					p += 2;
					if (p + len > b.length) invalid();
					m.globals[i] = new NStr(b.sub(p, len));
					p += len;
				case 4:
					m.globals[i] = parseFloat(str());
				case 5:
					p = readDebug(m, b, p, codesize);
				case 6:
					version = byte();
				case _:
					invalid();
			}
		}
		for (i in 0...nfields) {
			var f = str();
			m.fields.push(f);
			Fields.id(f);
		}
		var code = new Vector<Int>(codesize + 1, 0);
		// isOp[i]: code[i] is an opcode, not a parameter
		var isOp = new Vector<Bool>(codesize + 1, false);
		var i = 0;
		while (i < codesize) {
			var t = byte();
			isOp[i] = true;
			switch t & 3 {
				case 0:
					code[i++] = t >> 2;
				case 1:
					code[i++] = t >> 3;
					code[i++] = (t >> 2) & 1;
				case 2:
					code[i++] = t >> 2;
					if (t == 2) code[i - 1] = byte() else code[i++] = byte();
				case _:
					code[i++] = t >> 2;
					code[i++] = long();
			}
		}
		if (i != codesize) invalid();
		isOp[codesize] = true;
		code[codesize] = Op.Last;
		i = 0;
		while (i < codesize) {
			var c = code[i];
			if (c >= Op.Last || (i + 1 <= codesize && isOp[i + 1] == Op.hasParam[c])) invalid();
			var param = code[i + 1];
			switch c {
				case Op.AccGlobal | Op.SetGlobal:
					if (param < 0 || param >= nglobals) invalid();
				case Op.Jump | Op.JumpIf | Op.JumpIfNot | Op.Trap:
					var t = param + i;
					if (t < 0 || t > codesize || !isOp[t]) invalid();
					code[i + 1] = t;
				case Op.AccInt:
					// (boxed once: the interpreter reads the value from consts)
					code[i + 1] = m.consts.length;
					m.consts.push((param : Dynamic));
				case Op.AccIndex | Op.AccStack:
					code[i + 1] = param + 2;
				case Op.AccBuiltin:
					var v:Dynamic = if (param == Fields.idLoader) loader else if (param == Fields.idExports) m.exports else {
						var o = Builtins.get();
						if (!o.has(param)) throw new NekoError(NStr.of("Builtin not found : " + Fields.name(param)));
						o.get(param);
					}
					code[i + 1] = m.consts.length;
					m.consts.push(v);
				case Op.MakeArray:
					if (version >= 2) code[i] = Op.MakeArray2;
				case Op.JumpTable:
					if (param > 512 || i + 1 + param * 2 >= codesize) invalid();
				case _:
			}
			i += Op.hasParam[c] ? 2 : 1;
		}
		for (f in funcs)
			if (!isOp[f.addr]) invalid();
		fuse(m, code, codesize, [for (f in funcs) f.addr]);
		m.code = code;
		return m;
	}

	static inline function isCmp(op:Int):Bool
		return op == Op.Lt || op == Op.Lte || op == Op.Gt || op == Op.Gte || op == Op.Eq || op == Op.Neq;

	static inline function isImmOp(op:Int):Bool
		return op == Op.Add || op == Op.Sub || op == Op.Mult || isCmp(op);

	// common sequences as one instruction each (fewer dispatches; a comparison
	// jumping without its Bool read back), where no instruction but the first
	// is a jump's target: the instruction's slots keep the sequence's length,
	// the debug positions and the targets stay where they were
	static function fuse(m:Module, code:Vector<Int>, codesize:Int, entries:Array<Int>) {
		var target = new Vector<Bool>(codesize + 1, false);
		target[0] = true;
		for (e in entries)
			target[e] = true;
		var i = 0;
		while (i < codesize) {
			var c = code[i];
			switch c {
				case Op.Jump | Op.JumpIf | Op.JumpIfNot | Op.Trap:
					target[code[i + 1]] = true;
				case _:
			}
			i += Op.hasParam[c] ? 2 : 1;
		}
		// (JumpTable's entries are jumps: their positions targets too)
		i = 0;
		while (i < codesize) {
			var c = code[i];
			if (c == Op.JumpTable) {
				var n = code[i + 1];
				for (k in 0...n + 1)
					if (i + 2 + 2 * k <= codesize) target[i + 2 + 2 * k] = true;
			}
			i += Op.hasParam[c] ? 2 : 1;
		}
		inline function op(k:Int):Int
			return k < codesize ? code[k] : Op.Last;
		inline function free(k:Int):Bool
			return k < codesize && !target[k];
		i = 0;
		while (i < codesize) {
			var c = code[i];
			var len = Op.hasParam[c] ? 2 : 1;
			switch c {
				case Op.Push if (free(i + 1) && op(i + 1) == Op.AccInt && free(i + 3) && isImmOp(op(i + 3))
					&& Tag.isInt(m.consts[code[i + 2]])):
					var k:Int = m.consts[code[i + 2]];
					var cmp = op(i + 3);
					if (isCmp(cmp) && free(i + 4) && (op(i + 4) == Op.JumpIf || op(i + 4) == Op.JumpIfNot)) {
						var t = code[i + 5];
						var flag = op(i + 4) == Op.JumpIf ? 256 : 0;
						code[i] = Op.OpImmJump;
						code[i + 1] = k;
						// (i + 2: the constant's index, kept)
						code[i + 3] = cmp | flag;
						code[i + 5] = t;
						len = 6;
					} else {
						code[i] = Op.OpImm;
						code[i + 1] = k;
						code[i + 3] = cmp;
						len = 4;
					}
				case Op.AccStack0 if (free(i + 1) && op(i + 1) == Op.Push):
					code[i] = Op.PushStack0;
					len = 2;
				case Op.AccStack1 if (free(i + 1) && op(i + 1) == Op.Push):
					code[i] = Op.PushStack1;
					len = 2;
				case Op.AccStack if (free(i + 2) && op(i + 2) == Op.Push):
					code[i] = Op.PushStack;
					len = 3;
				case Op.AccInt if (free(i + 2) && op(i + 2) == Op.Push):
					code[i] = Op.PushConst;
					len = 3;
				case Op.AccGlobal if (free(i + 2) && op(i + 2) == Op.Push):
					code[i] = Op.PushGlobal;
					len = 3;
				case _ if (isCmp(c) && free(i + 1) && (op(i + 1) == Op.JumpIf || op(i + 1) == Op.JumpIfNot)):
					var t = code[i + 2];
					code[i + 1] = c | (op(i + 1) == Op.JumpIf ? 256 : 0);
					code[i] = Op.CmpJump;
					code[i + 2] = t;
					len = 3;
				case _:
			}
			i += len;
		}
	}

	// strtod's prefix (atof)
	public static function parseFloat(s:String):Float {
		var f = Std.parseFloat(s);
		return f;
	}

	// read_debug_infos
	static function readDebug(m:Module, b:Bytes, p:Int, codesize:Int):Int {
		inline function byte():Int {
			if (p >= b.length) invalid();
			return b.get(p++);
		}
		var c = byte();
		var lotOfFiles = false;
		var nfiles = if (c >= 0x80) {
			lotOfFiles = true;
			((c & 0x7F) << 8) | byte();
		} else c;
		if (nfiles == 0) invalid();
		var files:Array<NStr> = [];
		for (_ in 0...nfiles) {
			var start = p;
			while (byte() != 0) {}
			files.push(new NStr(b.sub(start, p - 1 - start)));
		}
		if (p + 4 > b.length) invalid();
		var npos = b.getInt32(p);
		p += 4;
		if (npos != codesize) invalid();
		var idx = new Vector<Int>(npos, -1);
		var tbl:Array<Dynamic> = [];
		var curfile = files[0];
		var curline = 0;
		var pp:Null<Array<Dynamic>> = null;
		var i = 0;
		inline function add() {
			pp = [curfile, curline];
			tbl.push(pp);
		}
		while (i < npos) {
			c = byte();
			if (c & 1 != 0) {
				c >>= 1;
				var n = lotOfFiles ? (c << 8) | byte() : c;
				if (n >= files.length) invalid();
				curfile = files[n];
				pp = null;
			} else if (c & 2 != 0) {
				var delta = c >> 6;
				var count = (c >> 2) & 15;
				if (i + count > npos) invalid();
				if (pp == null) {
					add();
					idx[i++] = tbl.length - 1;
					count--;
				}
				while (count-- > 0)
					idx[i++] = tbl.length - 1;
				if (delta != 0) {
					curline += delta;
					pp = null;
				}
			} else if (c & 4 != 0) {
				curline += c >> 3;
				add();
				idx[i++] = tbl.length - 1;
			} else {
				var b2 = byte();
				var b3 = byte();
				curline = (c >> 3) | (b2 << 5) | (b3 << 13);
				add();
				idx[i++] = tbl.length - 1;
			}
		}
		m.dbgIdx = idx;
		m.dbgTbl = tbl;
		return p;
	}
}

class ReadError {
	public function new() {}
}
