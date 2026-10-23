package hxmc;

import hxmc.Obj;

// What every native linker does whatever the file format (Link and LinkDyn
// for ELF, LinkMachO, LinkPE): symbol resolution, dead sections, the slots
// of the global offset table (or import slots), placement and the
// relocations of the generic kinds, x86-64's and every arm64 kind A64Reloc
// patches. A format keeps its layout (segments, headers, import tables,
// unwind and debugging tables) and says through hooks what the core cannot
// know: what an absolute address becomes (a rebase entry, a base
// relocation, a dynamic relocation: `absolute`), the offset of a
// thread-local variable (`secRel`, `tpoff`), which sections are roots of
// the reachability (`gcRoot`) and which keep nothing (`gcOpaque`), the key
// of a GOT slot (`gotKey`) and what a new slot holds (`gotFill`). LinkWasm
// shares the resolution and the reachability's worklist (Reach): its model
// (functions by index, linear memory) is not the native one.
class LinkCore {
	var objs:Array<Obj>;
	var arm:Bool;
	var globals = new Map<String, Symbol>();
	var addr = new Map<Section, Int>(); // section -> address
	// a reference's address, once the layout is known
	var symAddr:Symbol->Int;
	// what RImgRel32 is relative to (PE's image base; ELF's base address)
	var imageBase = 0;

	function new(objs:Array<Obj>, arm:Bool) {
		this.objs = objs;
		this.arm = arm;
	}

	// ---- symbols

	function resolve()
		resolveInto(objs, globals);

	// the global definitions of `objs` by name: a strong one wins over weak ones, two strong ones are an error
	public static function resolveInto(objs:Array<Obj>, globals:Map<String, Symbol>) {
		for (o in objs)
			for (s in o.symbols) {
				if (!s.global || (s.section == null && !s.abs)) continue;
				var prev = globals.get(s.name);
				if (prev == null || prev.weak && !s.weak) globals.set(s.name, s);
				else if (!prev.weak && !s.weak) throw 'hxmc: link: ${s.name} defined twice';
			}
	}

	// the definition a reference resolves to (null: undefined)
	inline function target(s:Symbol):Null<Symbol>
		return targetIn(globals, s);

	public static inline function targetIn(globals:Map<String, Symbol>, s:Symbol):Null<Symbol>
		return (s.section != null || s.abs) ? s : globals.get(s.name);

	function entrySym(name:String):Symbol {
		var s = globals.get(name);
		if (s == null) throw 'hxmc: link: no entry point $name';
		return s;
	}

	public static inline function align(v:Int, a:Int):Int
		return a <= 1 ? v : (v + a - 1) & ~(a - 1);

	// ---- dead sections: the sections of `collect` (the runtime objects) that
	// nothing reaches from the entry, the other objects and the initializers
	// are left out (the runtime is compiled with a section per function and per
	// datum), and so are the sections of any object named GC_PREFIX... that
	// nothing reaches (the runtime's Haxe functions: Driver)

	public var collect:Null<Array<Obj>>;
	public static inline var GC_PREFIX = ".text.gc.";
	var live:Null<Map<Section, Bool>>;
	// more roots than the entry (a shared library's exports)
	var roots:Array<String> = [];

	// a section kept whatever reaches it
	function gcRoot(o:Obj, s:Section):Bool
		return (collect.indexOf(o) < 0 && !StringTools.startsWith(s.name, GC_PREFIX)) || s.kind == InitArray || s.kind == FiniArray;

	// a section whose references keep nothing (the stack table names every
	// function: it is rebuilt of the kept ones, StackTable)
	function gcOpaque(s:Section):Bool
		return StackTable.isTable(s);

	// what a kept section keeps besides what it refers to (LinkPE: a
	// function's unwind information)
	function gcAlso(s:Section, mark:Section->Void) {}

	function gc(entry:String) {
		if (collect == null) return;
		var r = new Reach<Section>();
		for (o in objs)
			for (s in o.sections)
				if (gcRoot(o, s)) r.mark(s);
		var e = globals.get(entry);
		if (e != null && e.section != null) r.mark(e.section);
		for (n in roots) {
			var x = globals.get(n);
			if (x != null && x.section != null) r.mark(x.section);
		}
		r.run(s -> {
			if (gcOpaque(s)) return;
			for (x in s.relocs) {
				var t = target(x.sym);
				if (t != null && t.section != null) r.mark(t.section);
			}
			gcAlso(s, r.mark);
		});
		live = new Map();
		for (s in r.seen.keys())
			live.set(s, true);
		StackTable.rebuild(objs, f -> live.exists(f.sym.section));
	}

	inline function isLive(s:Section):Bool
		return live == null || live.exists(s);

	// an object of the linker's own, kept
	function keep(o:Obj) {
		objs.push(o);
		if (live != null)
			for (s in o.sections)
				live.set(s, true);
	}

	// ---- the global offset table (Mach-O's __got): a slot per symbol reached
	// through it, its address filled at load time or by a relocation (gotFill)

	var got:Null<Section>;
	var gotSlot = new Map<Symbol, Int>(); // key (gotKey) -> offset in got

	// the key of a reference's slot: what it resolves to; undefined, undefKey's
	function gotKey(s:Symbol):Symbol {
		var t = target(s);
		return t != null ? t : undefKey(s);
	}

	// the key of an undefined symbol: itself (LinkDyn: its import)
	function undefKey(s:Symbol):Symbol
		return s;

	// what a new slot holds (by default a relocation against its key, which
	// the relocations fill: an absolute address, `absolute`)
	function gotFill(at:Int, key:Symbol, s:Symbol)
		got.relocs.push(new Reloc(at, RAbs64, key, 0));

	// the slot of a reference (made on first use)
	function slot(s:Symbol):Int {
		var key = gotKey(s);
		var at = gotSlot.get(key);
		if (at == null) {
			if (got == null) got = new Section(".got", Data, 8);
			at = got.buf.len;
			gotSlot.set(key, at);
			gotFill(at, key, s);
			got.buf.u64(0, 0);
		}
		return at;
	}

	function gotAddr(s:Symbol):Int
		return addr.get(got) + gotSlot.get(gotKey(s));

	public static inline function isGotRel(k:RelKind):Bool
		return k == RA64GotPage21 || k == RA64GotLo12 || k == RGotPcRel32;

	// an import's stub, `jmp [slot]` (x86-64: 6 bytes; arm64: adrp x16,
	// slot; ldr x16, [x16, :lo12:slot]; br x16, 12 bytes) at `at` in `buf`, at
	// address p, written for the slot's address
	public static function patchStub(buf:Buf, at:Int, arm:Bool, slotAddr:Int, p:Int) {
		if (arm) {
			A64Reloc.adrp(buf, at, slotAddr, p);
			A64Reloc.imm12(buf, at + 4, (slotAddr & 0xfff) >> 3);
		} else buf.set32(at + 2, slotAddr - (p + 6));
	}

	// ---- placement

	// lays `list` out from pos, each section at its alignment, at address
	// base + its position: the end
	function place(list:Array<Section>, pos:Int, base = 0):Int {
		for (s in list) {
			pos = align(pos, s.align);
			addr.set(s, base + pos);
			pos += s.size();
		}
		return pos;
	}

	// the symbols of the laid out code a symbol table names (profilers, debuggers)
	function codeSymbols(f:Symbol->Void) {
		for (o in objs)
			for (s in o.symbols) {
				var sec = s.section;
				if (sec == null || sec.kind != Text || !addr.exists(sec) || s.abs || s.name.length == 0 || StringTools.startsWith(s.name, ".L")) continue;
				f(s);
			}
	}

	// ---- relocations

	// an absolute address (RAbs64, RAbs32, RAbs32S) at P: by default S + A
	function absolute(s:Section, r:Reloc, P:Int) {
		var v = symAddr(r.sym) + r.addend;
		if (r.kind == RAbs64) s.buf.set64(r.offset, v, v < 0 ? -1 : 0) else s.buf.set32(r.offset, v);
	}

	// the offset of a thread-local variable in the TLS area its code reaches
	// it from (RSecRel32, RA64SecRel*: the module's TLS block, the template)
	function secRel(sym:Symbol):Int
		throw "hxmc: link: relocation " + RSecRel32 + " against " + sym.name + " not supported here";

	// the thread-pointer-relative offset of a TLS address (local-exec:
	// RTpOff32, RA64TlsLe*)
	function tpoff(a:Int):Int
		throw "hxmc: link: local-exec thread-local relocations not supported here";

	// the relocations of a section laid out
	function applyRelocs(s:Section) {
		var base = addr.get(s);
		var buf = s.buf;
		for (r in s.relocs) {
			var A = r.addend;
			var P = base + r.offset;
			switch r.kind {
				case RAbs64 | RAbs32 | RAbs32S:
					absolute(s, r, P);
				case RPc32 | RCall32:
					buf.set32(r.offset, symAddr(r.sym) + A - P);
				case RImgRel32:
					var S = symAddr(r.sym);
					buf.set32(r.offset, S == 0 ? 0 : S + A - imageBase);
				case RGotPcRel32:
					buf.set32(r.offset, gotAddr(r.sym) + A - P);
				case RTpOff32:
					buf.set32(r.offset, tpoff(symAddr(r.sym)) + A);
				case RSecRel32:
					buf.set32(r.offset, secRel(r.sym) + A);
				case RA64GotPage21 | RA64GotLo12:
					A64Reloc.apply(buf, r.offset, r.kind, gotAddr(r.sym), P, r.sym.name);
				case RA64TlsLeHi12 | RA64TlsLeLo12Nc:
					A64Reloc.apply(buf, r.offset, r.kind, tpoff(symAddr(r.sym)) + A, P, r.sym.name);
				case RA64SecRelHi12 | RA64SecRelLo12A | RA64SecRelLo12L:
					A64Reloc.apply(buf, r.offset, r.kind, secRel(r.sym) + A, P, r.sym.name);
				case _:
					if (!A64Reloc.apply(buf, r.offset, r.kind, symAddr(r.sym) + A, P, r.sym.name))
						throw "hxmc: link: relocation " + r.kind + " not supported yet";
			}
		}
	}
}

// A worklist over a graph whose nodes are marked once (the linkers' reachability)
class Reach<T:{}> {
	public var seen = new haxe.ds.ObjectMap<T, Bool>();
	var work:Array<T> = [];

	public function new() {}

	public function mark(x:T) {
		if (x != null && !seen.exists(x)) {
			seen.set(x, true);
			work.push(x);
		}
	}

	public inline function has(x:T):Bool
		return seen.exists(x);

	public inline function pending():Bool
		return work.length > 0;

	public inline function next():T
		return work.pop();

	// visits each marked node once, until no more are marked
	public function run(visit:T->Void) {
		while (work.length > 0)
			visit(work.pop());
	}
}
