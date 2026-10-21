package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;

// Mach-O relocatable objects (MH_OBJECT, x86-64 and arm64) as Obj, for the
// macOS runtime object (MkRt.macho). Names lose their leading underscore (C
// symbols are `_name` in Mach-O, hxmc's code uses the C names); unwind and
// debug sections are left out; relocations get explicit addends (arm64:
// from ARM64_RELOC_ADDEND; x86-64: from the field), section-relative ones
// (r_extern = 0) refer to a local symbol at the start of their section.
// Thread-local variables keep Mach-O's form: the variable's symbol names
// its descriptor in __thread_vars (thunk, key, offset), whose third word
// refers to the storage in __thread_data/__thread_bss (LinkMachO).
class MachOReader {
	var b:Bytes;
	var arm = false;

	function new(b:Bytes)
		this.b = b;

	inline function u8(at:Int):Int
		return b.get(at);

	inline function u16(at:Int):Int
		return b.getUInt16(at);

	inline function u32(at:Int):Int
		return b.getInt32(at);

	function cstr(at:Int, max = 0x7fffffff):String {
		var e = at;
		while (e - at < max && e < b.length && b.get(e) != 0)
			e++;
		return b.getString(at, e - at);
	}

	public static function read(b:Bytes):{obj:Obj, arm:Bool} {
		var r = new MachOReader(b);
		var o = r.run();
		return {obj: o, arm: r.arm};
	}

	// the Mach-O name of a C symbol -> hxmc's
	public static function cName(n:String):String
		return StringTools.startsWith(n, "_") ? n.substr(1) : n;

	static inline function sext(v:Int, bits:Int):Int
		return (v << (32 - bits)) >> (32 - bits);

	function run():Obj {
		if (u32(0) != 0xfeedfacf) throw "hxmc: not a 64-bit Mach-O object";
		var cpu = u32(4);
		arm = cpu == 0x0100000c;
		if (!arm && cpu != 0x01000007) throw "hxmc: Mach-O cpu type " + StringTools.hex(cpu);
		if (u32(12) != 1) throw "hxmc: not a Mach-O relocatable object";
		var ncmds = u32(16);
		var o = new Obj();
		// every section of the file, by ordinal (1-based), null when left out
		var secs:Array<Null<Section>> = [null];
		var secAddr:Array<Int> = [0];
		var secHdr:Array<Int> = [0];
		var secSym:Array<Null<Symbol>> = [null];
		var symoff = 0, nsyms = 0, stroff = 0;
		var at = 32;
		for (_ in 0...ncmds) {
			var cmd = u32(at), size = u32(at + 4);
			if (cmd == 0x19) {
				var nsect = u32(at + 64);
				for (k in 0...nsect) {
					var h = at + 72 + 80 * k;
					var sect = cstr(h, 16), seg = cstr(h + 16, 16);
					var addr = u32(h + 32); // (objects start at 0: 32 bits are enough)
					var sz = u32(h + 40);
					var off = u32(h + 48);
					var align = 1 << u32(h + 52);
					var flags = u32(h + 64);
					var type = flags & 0xff;
					// (pointer sections: 8, whatever the object says)
					if ((type == 0x13 || type == 9 || type == 0xa || type == 0x14) && align < 8) align = 8;
					secAddr.push(addr);
					secHdr.push(h);
					var skip = seg == "__DWARF" || (flags & 0x02000000) != 0 || sect == "__eh_frame" || sect == "__compact_unwind" || sect == "__llvm_addrsig";
					if (skip) {
						secs.push(null);
						secSym.push(null);
						continue;
					}
					var kind:SecKind = switch type {
						case 1: Bss;
						case 0x11: Tdata;
						case 0x12: Tbss;
						case 9: InitArray;
						case 0xa: FiniArray;
						case _: if ((flags & 0x80000400) != 0) Text else if (seg == "__TEXT") RoData else Data;
					};
					var s = new Section(seg + "," + sect, kind, align);
					if (kind == Bss || kind == Tbss) s.bssSize = sz else s.buf.bytes(b, off, sz);
					o.sections.push(s);
					secs.push(s);
					var ss = new Symbol(".Lsec" + secs.length + "$" + sect);
					ss.global = false;
					ss.section = s;
					o.symbols.push(ss);
					secSym.push(ss);
				}
			} else if (cmd == 0x2) {
				symoff = u32(at + 8);
				nsyms = u32(at + 12);
				stroff = u32(at + 16);
			}
			at += size;
		}
		// symbols
		var syms = new haxe.ds.Vector<Null<Symbol>>(nsyms > 0 ? nsyms : 0);
		for (k in 0...nsyms) {
			var e = symoff + 16 * k;
			var name = cName(cstr(stroff + u32(e)));
			var type = u8(e + 4), sect = u8(e + 5), desc = u16(e + 6);
			var value = u32(e + 8);
			if ((type & 0xe0) != 0) continue; // a debugging entry
			var ext = (type & 1) != 0;
			var t = type & 0x0e;
			var s:Symbol;
			if (ext) {
				s = o.sym(name);
				s.weak = (desc & 0x80) != 0 || (t == 0 && (desc & 0x40) != 0);
			} else {
				s = new Symbol(name);
				s.global = false;
				o.symbols.push(s);
			}
			switch t {
				case 0xe:
					var sec = secs[sect];
					if (sec != null) {
						s.section = sec;
						s.offset = value - secAddr[sect];
						s.func = sec.kind == Text;
					}
				case 2:
					s.abs = true;
					s.offset = value;
				case 0 if (ext && value != 0):
					// a common symbol: its own zeroed section
					var al = 1 << ((desc >> 8) & 0xf);
					var c = new Section("__DATA,__common", Bss, al < 8 ? 8 : al);
					c.bssSize = value;
					o.sections.push(c);
					s.section = c;
					s.offset = 0;
				case _:
			}
			syms[k] = s;
		}
		// relocations
		for (n in 1...secs.length) {
			var s = secs[n];
			if (s == null) continue;
			var h = secHdr[n];
			var reloff = u32(h + 56), nreloc = u32(h + 60);
			var addend = 0;
			var hasAddend = false;
			var minus:Null<Symbol> = null; // a SUBTRACTOR's symbol, for the UNSIGNED after it
			for (k in 0...nreloc) {
				var e = reloff + 8 * k;
				var addr = u32(e);
				var info = u32(e + 4);
				var symnum = info & 0xffffff;
				var pcrel = (info >> 24) & 1, len = (info >> 25) & 3, ext = (info >> 27) & 1, type = (info >>> 28) & 0xf;
				if ((addr & 0x80000000) != 0) throw "hxmc: Mach-O scattered relocation in " + s.name;
				if (arm && type == 10) {
					addend = sext(symnum, 24);
					hasAddend = true;
					continue;
				}
				// the target: a symbol, or a section and the address in the field
				var sym:Symbol = ext == 1 ? (symnum < syms.length ? syms[symnum] : null) : secSym[symnum];
				if (sym == null) throw "hxmc: Mach-O relocation against a section left out, in " + s.name;
				var buf = s.buf;
				// SUBTRACTOR (arm64 1, x86-64 5) then UNSIGNED: T - M + field, 32
				// bits (jump tables, offset tables of mbedtls and libuv), with M a
				// symbol of this section: T + A - P with A = field + (addr - M)
				if (type == (arm ? 1 : 5)) {
					if (ext != 1 || sym.section != s || len != 2) throw "hxmc: Mach-O SUBTRACTOR relocation other than within " + s.name;
					minus = sym;
					continue;
				}
				if (minus != null) {
					if (type != 0 || len != 2) throw "hxmc: Mach-O SUBTRACTOR followed by relocation type " + type + " in " + s.name;
					var field = buf.get32(addr);
					buf.set32(addr, 0);
					// the field: the addend (an external minuend) or T - M in the object's addresses
					var fa = ext == 1 ? field : field + secAddr[n] + minus.offset - secAddr[symnum];
					s.relocs.push(new Reloc(addr, RPc32, sym, fa + addr - minus.offset));
					minus = null;
					continue;
				}
				var kind:RelKind;
				var a = 0;
				if (arm) {
					switch type {
						case 0: // UNSIGNED
							if (len == 3) {
								kind = RAbs64;
								a = buf.get32(addr);
								buf.set64(addr, 0, 0);
							} else {
								kind = RAbs32;
								a = buf.get32(addr);
								buf.set32(addr, 0);
							}
							if (ext == 0) a -= secAddr[symnum];
						case 2:
							kind = (buf.get32(addr) & 0x80000000) != 0 ? RA64Call26 : RA64Jump26;
						case 3:
							kind = RA64AdrPage21;
						case 4:
							var w = buf.get32(addr);
							if ((w & 0x3b000000) == 0x39000000) {
								kind = switch A64Reloc.ldstScale(w) {
									case 0: RA64Ldst8Lo12;
									case 1: RA64Ldst16Lo12;
									case 2: RA64Ldst32Lo12;
									case 3: RA64Ldst64Lo12;
									case _: RA64Ldst128Lo12;
								};
							} else kind = RA64AddLo12;
						case 5 | 8:
							kind = RA64GotPage21; // (TLVP: the slot holds the descriptor's address)
						case 6 | 9:
							kind = RA64GotLo12;
						case _:
							throw "hxmc: Mach-O arm64 relocation type " + type + " in " + s.name;
					}
					if (hasAddend) a += addend;
					hasAddend = false;
					if (ext == 0 && type != 0) throw "hxmc: Mach-O arm64 section-relative relocation type " + type + " in " + s.name;
				} else {
					switch type {
						case 0:
							if (len == 3) {
								kind = RAbs64;
								a = buf.get32(addr);
								buf.set64(addr, 0, 0);
							} else {
								kind = RAbs32;
								a = buf.get32(addr);
								buf.set32(addr, 0);
							}
							if (ext == 0) a -= secAddr[symnum];
						case 1 | 2 | 3 | 4 | 6 | 7 | 8 | 9:
							// pc-relative 32 bits: SIGNED(_1/_2/_4), BRANCH, GOT_LOAD, GOT, TLV
							var field = buf.get32(addr);
							buf.set32(addr, 0);
							kind = switch type {
								case 2: RCall32;
								case 3 | 4 | 9: RGotPcRel32;
								case _: RPc32;
							};
							if (ext == 1) a = field - 4 else {
								if (type != 1) throw "hxmc: Mach-O x86-64 section-relative relocation type " + type + " in " + s.name;
								// the field is the displacement from the next instruction
								var target = secAddr[n] + addr + 4 + field;
								a = target - secAddr[symnum] - 4;
							}
						case _:
							throw "hxmc: Mach-O x86-64 relocation type " + type + " in " + s.name;
					}
				}
				if (pcrel == 1 && (kind == RAbs64 || kind == RAbs32)) throw "hxmc: Mach-O pc-relative absolute relocation in " + s.name;
				s.relocs.push(new Reloc(addr, kind, sym, a));
			}
		}
		return o;
	}
}
