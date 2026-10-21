package hxmc;

// A relocatable object in memory, independent of the file format: sections
// of bytes, symbols and relocations. The code generators fill one; the
// writers (ElfWriter, ...) serialize it, the linker (Link) consumes it.
enum abstract SecKind(Int) {
	var Text;
	var Data;
	var RoData;
	var Bss;
	var Tdata;
	var Tbss;
	var InitArray;
	var FiniArray;
}

// relocation kinds (each writer maps them to its format's types)
enum abstract RelKind(Int) to Int {
	var RAbs64; // S + A, 64 bits
	var RAbs32; // S + A, 32 bits (zero-extended)
	var RAbs32S; // S + A, 32 bits (sign-extended)
	var RPc32; // S + A - P, 32 bits
	var RCall32; // a call or jump: S + A - P (ELF PLT32)
	var RTpOff32; // x86-64 local-exec TLS: S - TP + A, signed 32 bits (fs:disp32)
	var RGotPcRel32; // x86-64: G + GOT + A - P (mov reg, [rip + sym@GOTPCREL])
	// arm64
	var RA64Call26; // bl
	var RA64Jump26; // b
	var RA64AdrPage21; // adrp: Page(S + A) - Page(P)
	var RA64AddLo12; // add: (S + A) & 0xfff
	var RA64Ldst8Lo12;
	var RA64Ldst16Lo12;
	var RA64Ldst32Lo12;
	var RA64Ldst64Lo12;
	var RA64Ldst128Lo12;
	var RA64TlsLeHi12; // add xd, xn, #:tprel_hi12:S
	var RA64TlsLeLo12Nc; // add xd, xd, #:tprel_lo12_nc:S
	var RA64GotPage21;
	var RA64GotLo12;
	var RA64MovwG0Nc; // movz/movk: bits 0-15 of S + A
	var RA64MovwG1Nc; // bits 16-31
	var RA64Prel32;
	var RA64Cond19; // b.cond, cbz, cbnz: (S + A - P) >> 2 in bits 5-23
	var RA64Tst14; // tbz, tbnz: (S + A - P) >> 2 in bits 5-18
	// arm64 thread-local variables at an offset from a base register (Windows:
	// the module's TLS block; Apple: the image's TLV template): the offset of
	// S + A in the TLS area, in pieces
	var RA64SecRelHi12; // add xd, xn, #off >> 12, lsl 12
	var RA64SecRelLo12A; // add xd, xn, #off & 0xfff
	var RA64SecRelLo12L; // ldr/str [xn, #off & 0xfff] (scaled by the access size)
	// COFF
	var RSecRel32; // the offset of S + A in its output section (TLS variables in .tls)
	var RImgRel32; // S + A - the image base (an RVA)
	// WebAssembly (wasm.LinkWasm rewrites each as a minimal LEB128)
	var RWasmFunc; // a function index (5-byte padded LEB)
	var RWasmType; // a type index; the symbol names the signature ($t:<params>><result>)
	var RWasmGlobal; // a global index (a thread-local variable or the stack pointer)
	var RWasmAddr; // i64.const operand: S + A (a data address, a function's table index or an absolute value), 10 bytes
	var RWasmAddr32; // i32.const operand: S + A (a link-time number), 5 bytes
}

class Section {
	public var name:String;
	public var kind:SecKind;
	public var align:Int;
	public var buf = new Buf(1024);
	public var bssSize = 0; // Bss/Tbss: the size (no bytes)
	public var relocs:Array<Reloc> = [];
	public var index = -1; // writers

	public function new(name, kind, align) {
		this.name = name;
		this.kind = kind;
		this.align = align;
	}

	public inline function size():Int
		return kind == Bss || kind == Tbss ? bssSize : buf.len;
}

class Symbol {
	public var name:String;
	public var section:Null<Section>; // null: undefined (defined elsewhere)
	public var offset = 0;
	public var size = 0;
	public var global = true;
	public var func = false;
	public var tls = false;
	public var weak = false;
	public var abs = false; // an absolute value (offset), no section
	public var index = -1; // writers

	public function new(name) {
		this.name = name;
	}
}

class Reloc {
	public var offset:Int;
	public var kind:RelKind;
	public var sym:Symbol;
	public var addend:Int;

	public function new(offset, kind, sym, addend) {
		this.offset = offset;
		this.kind = kind;
		this.sym = sym;
		this.addend = addend;
	}
}

// What unwinders and debuggers need of a generated function (Unwind, Dwarf):
// what its prologue and epilogues do to the frame, as the emitter wrote
// them, and with -debug its Haxe name and source lines. The linkers turn
// them into the format's tables (.eh_frame, .pdata/.xdata, __eh_frame,
// .debug_line).
class FuncRec {
	public var sym:Symbol;
	// the frame operations, four numbers each: Unwind.OP_*, the offset in the
	// function where the frame is as the operation leaves it (the end of its
	// instruction), two operands
	public var ops:haxe.ds.Vector<Int>;
	public var name:Null<String> = null; // (-debug) the Haxe name, pack.Class.field
	// (-debug) rows of three numbers: an offset in the function, a file
	// (Obj.files), a line; each row holds until the next (null: not recorded,
	// which the section tells from no rows)
	public var lines:Null<haxe.ds.Vector<Int>> = null;

	public function new(sym, ops) {
		this.sym = sym;
		this.ops = ops;
	}

	// an object's records (and source files) as a section for its file
	// (ElfWriter): the files, then per function an 8-byte word relocated
	// against it, its operations, name and lines (unsigned LEB128 numbers)
	public static inline var SECTION = ".hxmc.funcs";

	public static function section(o:Obj):Null<Section> {
		if (o.funcs.length == 0) return null;
		var s = new Section(SECTION, RoData, 8);
		var b = s.buf;
		b.uleb(o.files.length);
		for (f in o.files)
			str(b, f);
		for (r in o.funcs) {
			b.align(8);
			s.relocs.push(new Reloc(b.len, RAbs64, r.sym, 0));
			b.u64(0, 0);
			b.uleb(r.ops.length);
			for (v in r.ops)
				b.uleb(v);
			if (r.name == null) b.uleb(0) else {
				b.uleb(1);
				str(b, r.name);
			}
			if (r.lines == null) b.uleb(0) else {
				b.uleb(r.lines.length + 1);
				for (v in r.lines)
					b.uleb(v);
			}
		}
		return s;
	}

	static function str(b:Buf, s:String) {
		var x = haxe.io.Bytes.ofString(s);
		b.uleb(x.length);
		b.bytes(x);
	}

	// the records of a section that section() wrote (its relocations read back)
	public static function read(o:Obj, s:Section) {
		var b = s.buf.b, at = 0;
		var symAt = new Map<Int, Symbol>();
		for (r in s.relocs)
			symAt.set(r.offset, r.sym);
		function uleb():Int {
			var v = 0, shift = 0;
			while (true) {
				var c = b.get(at++);
				v |= (c & 0x7f) << shift;
				if (c < 0x80) return v;
				shift += 7;
			}
		}
		function str():String {
			var n = uleb();
			var x = b.getString(at, n);
			at += n;
			return x;
		}
		for (_ in 0...uleb())
			o.files.push(str());
		while (true) {
			at = (at + 7) & ~7;
			if (at >= s.buf.len) break;
			var sym = symAt.get(at);
			if (sym == null) throw "hxmc: a function record without its function";
			at += 8;
			var ops = new haxe.ds.Vector<Int>(uleb());
			for (k in 0...ops.length)
				ops[k] = uleb();
			var r = new FuncRec(sym, ops);
			if (uleb() != 0) r.name = str();
			var n = uleb();
			if (n != 0) {
				var lines = new haxe.ds.Vector<Int>(n - 1);
				for (k in 0...n - 1)
					lines[k] = uleb();
				r.lines = lines;
			}
			o.funcs.push(r);
		}
	}
}

class Obj {
	public var sections:Array<Section> = [];
	public var symbols:Array<Symbol> = [];
	public var funcs:Array<FuncRec> = []; // the generated functions' (FuncRec)
	// a C object's .eh_frame (the runtime object's: ElfReader), with its
	// relocations; Link keeps the entries of the functions it keeps
	public var ehFrame:Null<Section> = null;
	public var files:Array<String> = []; // the source files FuncRec.lines name
	var byName = new Map<String, Symbol>();

	public function new() {}

	public function section(name:String, kind:SecKind, align:Int):Section {
		for (s in sections)
			if (s.name == name) return s;
		var s = new Section(name, kind, align);
		sections.push(s);
		return s;
	}

	// the symbol of that name (undefined until defined)
	public function sym(name:String):Symbol {
		var s = byName.get(name);
		if (s == null) {
			s = new Symbol(name);
			byName.set(name, s);
			symbols.push(s);
		}
		return s;
	}

	public function define(name:String, sec:Section, offset:Int, size = 0, global = true):Symbol {
		var s = sym(name);
		if (s.section != null) throw 'hxmc: symbol $name defined twice';
		s.section = sec;
		s.offset = offset;
		s.size = size;
		s.global = global;
		s.func = sec.kind == Text;
		s.tls = sec.kind == Tdata || sec.kind == Tbss;
		return s;
	}

	// a symbol with an absolute value (program-wide numbers: Prep.tySym...)
	public function defineAbs(name:String, value:Int):Symbol {
		var s = sym(name);
		if (s.section != null || s.abs) throw 'hxmc: symbol $name defined twice';
		s.abs = true;
		s.offset = value;
		return s;
	}

	public inline function exists(name:String):Bool
		return byName.exists(name);
}
