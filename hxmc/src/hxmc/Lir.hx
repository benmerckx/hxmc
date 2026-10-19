package hxmc;

// Target instructions over registers, before and after register allocation
// (Regalloc). Registers: 0-63 physical (the target numbers them: general
// registers from 0, floating-point/vector ones from LFunc.fprBase), 64 and
// up virtual. Each target's
// instruction selection produces an LFunc and tells the allocator what an
// instruction defines, uses and clobbers (Target).
class LIns {
	public var op:Int;
	public var size:Int = 8; // operation width in bytes
	public var d:Int = -1; // destination register
	public var s1:Int = -1; // sources
	public var s2:Int = -1;
	public var s3:Int = -1;
	// memory operand: base (register, or FRAME with `slot`), index, scale, disp, sym
	public var base:Int = -1;
	public var index:Int = -1;
	public var scale:Int = 1;
	public var disp:Int = 0;
	public var slot:Int = -1; // frame slot (base == FRAME)
	public var sym:Null<String>;
	public var secrel:Null<String>; // [base + the offset of this TLS variable in .tls] (Windows)
	public var mem = -1; // LOAD/STORE: the Mir memory class (statistics)
	public var dsym:Null<String>; // [base + disp + this absolute symbol] (x86-64: a global's offset)
	public var imm:Int = 0;
	public var isym:Null<String>; // the immediate is this absolute symbol + imm
	public var imm2:Int = 0;
	public var cond:Int = 0;
	public var target:Null<LBlock>;
	public var target2:Null<LBlock>;
	public var table:Null<Array<LBlock>>; // jump tables
	public var uses:Null<Array<Int>>; // calls: the argument registers
	public var defs:Null<Array<Int>>; // calls: the result registers
	public var f:Float = 0;
	public var flag:Bool = false; // target specific (zero/sign extension, ...)
	public var pos = 0; // (-debug) the source position of the Mir instruction it comes from (SrcPos)

	public static inline var FRAME = -2;

	public function new(op:Int)
		this.op = op;
}

class LBlock {
	public var id:Int;
	public var ins:Array<LIns> = [];
	public var succs:Array<LBlock> = [];
	public var preds:Array<LBlock> = [];
	public var label:Int = -1; // the assembler's label
	public var cold = false;
	public var loopDepth = 0;
	// liveness (Regalloc)
	public var liveIn:Null<Bits>;
	public var liveOut:Null<Bits>;
	public var from = 0; // positions
	public var to = 0;

	public function new(id)
		this.id = id;
}

class LFunc {
	public var name:String;
	public var blocks:Array<LBlock> = []; // in layout order
	public var nregs:Int; // registers 0..nregs-1 (physical and virtual)
	public static inline var NPHYS = 64;

	public var isFloat:Array<Bool> = []; // per virtual register (index - NPHYS)
	public var fprBase:Int; // the first floating-point physical register
	public var slots:Array<{size:Int, align:Int}> = []; // frame slots (MIR slots, then spills)
	public var outArgs = 0; // bytes of outgoing stack arguments
	public var hasCalls = false;
	public var display:Null<String>; // (-debug) the Haxe name of the function (FuncRec.name)
	var hints:Array<Int> = []; // vreg - NPHYS -> preferred register (physical or virtual), -1

	// jump threading, before emission: a branch (or a jump table's entry)
	// to a block that holds only an unconditional jump (an empty join, once
	// its moves are placed) branches to that jump's target instead (isJump:
	// the target's jump). The instructions that emit nothing (isNop: a move
	// of a register to itself, once registers are allocated) go first, and
	// the blocks no branch reaches any more after (the entry is reached).
	public function threadJumps(isJump:LIns->Bool, isNop:LIns->Bool) {
		for (b in blocks) {
			var ins = b.ins, k = 0;
			for (i in ins)
				if (!isNop(i)) ins[k++] = i;
			if (k < ins.length) ins.resize(k);
		}
		function dest(t:LBlock):LBlock {
			var n = 0;
			while (t != blocks[0] && t.ins.length == 1 && isJump(t.ins[0]) && t.ins[0].target != t && n++ < 16)
				t = t.ins[0].target;
			return t;
		}
		for (b in blocks)
			for (i in b.ins) {
				if (i.target != null) i.target = dest(i.target);
				if (i.table != null)
					for (k in 0...i.table.length)
						i.table[k] = dest(i.table[k]);
			}
		// (every block ends with its jumps: none falls into the next one)
		var n = blocks.length;
		for (k in 0...n)
			blocks[k].id = k;
		var reached = new haxe.ds.Vector<Bool>(n);
		reached[0] = true;
		var stack = [blocks[0]];
		inline function reach(t:LBlock)
			if (!reached[t.id]) {
				reached[t.id] = true;
				stack.push(t);
			}
		while (stack.length > 0)
			for (i in stack.pop().ins) {
				if (i.target != null) reach(i.target);
				if (i.table != null)
					for (t in i.table)
						reach(t);
			}
		var live = 0;
		for (k in 0...n)
			if (reached[k]) live++;
		if (live < n) blocks = [for (b in blocks) if (reached[b.id]) b];
	}

	// a block's last two instructions: a conditional branch (isCond) to the
	// next block in the layout, then a jump (isJump) elsewhere: the branch
	// takes the jump's target with the opposite condition (invert), the jump
	// goes to the next block (not encoded); a conditional branch to the jump's
	// own target goes
	public static function fallThrough(b:LBlock, next:Null<LBlock>, isJump:LIns->Bool, isCond:LIns->Bool, invert:LIns->Void) {
		var ins = b.ins;
		while (ins.length >= 2 && isJump(ins[ins.length - 1]) && isCond(ins[ins.length - 2])
			&& ins[ins.length - 2].target == ins[ins.length - 1].target)
			ins.splice(ins.length - 2, 1);
		var n = ins.length;
		if (n < 2 || next == null) return;
		var j = ins[n - 1], c = ins[n - 2];
		if (isJump(j) && isCond(c) && c.target == next && j.target != next) {
			invert(c);
			c.target = j.target;
			j.target = next;
		}
	}

	public inline function hint(r:Int):Int
		return r - NPHYS < hints.length ? hints[r - NPHYS] : -1;

	public function setHint(r:Int, h:Int) {
		var k = r - NPHYS;
		while (hints.length <= k)
			hints.push(-1);
		hints[k] = h;
	}

	public function new(name, fprBase:Int) {
		this.name = name;
		this.fprBase = fprBase;
		nregs = NPHYS;
	}

	public function newReg(float:Bool):Int {
		isFloat.push(float);
		return nregs++;
	}

	public inline function floatReg(r:Int):Bool
		return r < NPHYS ? r >= fprBase : isFloat[r - NPHYS];

	public function slot(size:Int, align:Int):Int {
		slots.push({size: size, align: align});
		return slots.length - 1;
	}
}

class Arrays {
	// an Int vector of n copies of v
	public static function filled(n:Int, v:Int):haxe.ds.Vector<Int> {
		var a = new haxe.ds.Vector<Int>(n);
		if (v != 0) a.fill(v);
		return a;
	}
}

// a fixed-size bit set
class Bits {
	public var w:haxe.ds.Vector<Int>;

	public function new(n:Int) {
		w = Arrays.filled((n + 31) >> 5, 0);
	}

	public inline function get(i:Int):Bool
		return (w[i >> 5] & (1 << (i & 31))) != 0;

	public inline function set(i:Int)
		w[i >> 5] |= 1 << (i & 31);

	public inline function clear(i:Int)
		w[i >> 5] &= ~(1 << (i & 31));

	// this |= o; true when it changed
	public function union(o:Bits):Bool {
		var changed = false;
		for (k in 0...w.length) {
			var v = w[k] | o.w[k];
			if (v != w[k]) {
				w[k] = v;
				changed = true;
			}
		}
		return changed;
	}

	public function copy():Bits {
		var b = new Bits(0);
		b.w = w.copy();
		return b;
	}
}
