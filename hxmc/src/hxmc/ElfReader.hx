package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;

// An ELF64 relocatable file (the runtime object made by tools/mkrt.sh) as an
// Obj: its allocated sections, symbols and relocations. Sections that are
// not loaded (debug information, notes, address-significance tables) are
// dropped, and so are relocations in them; hxmc's function records
// (FuncRec.SECTION) become Obj.funcs, the C code's .eh_frame Obj.ehFrame.
class ElfReader {
	var b:Bytes;
	var arm:Bool;

	function new(b:Bytes) {
		this.b = b;
	}

	inline function u8(at:Int):Int
		return b.get(at);

	inline function u16(at:Int):Int
		return b.getUInt16(at);

	inline function u32(at:Int):Int
		return b.getInt32(at);

	// a 64-bit field that must fit in 32 bits (offsets, sizes, addends)
	function i64(at:Int):Int {
		var lo = b.getInt32(at), hi = b.getInt32(at + 4);
		if (!(hi == 0 && lo >= 0 || hi == -1 && lo < 0)) throw "hxmc: ELF value out of range";
		return lo;
	}

	function cstr(at:Int):String {
		var e = at;
		while (b.get(e) != 0)
			e++;
		return b.getString(at, e - at);
	}

	public static function read(bytes:Bytes):Obj
		return new ElfReader(bytes).run();

	function relocKind(t:Int):RelKind {
		if (!arm) return switch t {
			case 1: RAbs64;
			case 2: RPc32;
			case 4: RCall32;
			case 9 | 41 | 42: RGotPcRel32; // (GOTPCRELX, REX_GOTPCRELX: relaxable, the same here)
			case 10: RAbs32;
			case 11: RAbs32S;
			case 23: RTpOff32;
			case 250: RSecRel32;
			case 251: RImgRel32;
			case _: throw "hxmc: x86-64 relocation type " + t + " in the runtime object";
		}
		return switch t {
			case 257: RAbs64;
			case 258: RAbs32;
			case 261: RPc32;
			case 275: RA64AdrPage21;
			case 277: RA64AddLo12;
			case 278: RA64Ldst8Lo12;
			case 282: RA64Jump26;
			case 283: RA64Call26;
			case 284: RA64Ldst16Lo12;
			case 285: RA64Ldst32Lo12;
			case 286: RA64Ldst64Lo12;
			case 299: RA64Ldst128Lo12;
			case 311: RA64GotPage21;
			case 312: RA64GotLo12;
			case 549: RA64TlsLeHi12;
			case 551: RA64TlsLeLo12Nc;
			case 264: RA64MovwG0Nc;
			case 266: RA64MovwG1Nc;
			case 280: RA64Cond19;
			case 279: RA64Tst14;
			case 0x1001: RA64SecRelHi12;
			case 0x1002: RA64SecRelLo12A;
			case 0x1003: RA64SecRelLo12L;
			case 0x1004: RSecRel32;
			case 0x1005: RImgRel32;
			case 0x1006: RAbs32S;
			case _: throw "hxmc: aarch64 relocation type " + t + " in the runtime object";
		}
	}

	function run():Obj {
		if (u32(0) != 0x464c457f) throw "hxmc: not an ELF file";
		arm = u16(18) == 183;
		var shoff = i64(40);
		var shnum = u16(60);
		var shstrndx = u16(62);
		inline function sh(i:Int)
			return shoff + 64 * i;
		var strOff = i64(sh(shstrndx) + 24);
		var o = new Obj();
		var secs = new haxe.ds.Vector<Null<Section>>(shnum);
		// (an index read from the file: none out of range, as a malformed file may have)
		inline function secAt(i:Int):Null<Section>
			return i >= 0 && i < shnum ? secs[i] : null;
		var symtab = -1;
		var funcs:Null<Section> = null;
		for (i in 0...shnum) {
			var h = sh(i);
			var name = cstr(strOff + u32(h));
			var type = u32(h + 4);
			var flags = u32(h + 8);
			var off = i64(h + 24);
			var size = i64(h + 32);
			var align = i64(h + 48);
			if (type == 2) symtab = i;
			if (name == FuncRec.SECTION && type == 1) {
				// the function records (hxmc's objects): read once the relocations are
				funcs = new Section(name, RoData, 8);
				funcs.buf.bytes(b, off, size);
				secs[i] = funcs;
				continue;
			}
			if ((flags & 2) == 0 || (type != 1 && type != 8 && type != 14 && type != 15 && type != 0x70000001)) continue;
			if (name == ".eh_frame") {
				// (the C code's unwind tables: Obj.ehFrame, not laid out as data)
				o.ehFrame = new Section(name, RoData, align < 1 ? 1 : align);
				o.ehFrame.buf.bytes(b, off, size);
				secs[i] = o.ehFrame;
				continue;
			}
			if (StringTools.startsWith(name, ".eh_frame")) continue;
			var kind:SecKind = if ((flags & 0x400) != 0) (type == 8 ? Tbss : Tdata) else if (type == 14) InitArray else if (type == 15) FiniArray else if ((flags & 4) != 0) Text
			else if (type == 8) Bss else if ((flags & 1) != 0) Data else RoData;
			// each input section stays a section of its own (the linker places them)
			var s = new Section(name, kind, align < 1 ? 1 : align);
			s.index = i;
			if (type == 8) s.bssSize = size else s.buf.bytes(b, off, size);
			o.sections.push(s);
			secs[i] = s;
		}
		if (symtab < 0) throw "hxmc: no symbol table";
		var h = sh(symtab);
		var symOff = i64(h + 24);
		var nsyms = Std.int(i64(h + 32) / 24);
		var strtab = i64(sh(u32(h + 40)) + 24);
		var syms = new haxe.ds.Vector<Null<Symbol>>(nsyms > 0 ? nsyms : 0);
		var nlocal = 0;
		for (k in 0...nsyms) {
			var at = symOff + 24 * k;
			var info = u8(at + 4);
			var bind = info >> 4, type = info & 15;
			var shndx = u16(at + 6);
			var name = cstr(strtab + u32(at));
			var value = i64(at + 8);
			if (k == 0) continue;
			var s:Symbol;
			if (bind == 0) {
				// local: its own object (names may repeat)
				s = new Symbol(name == "" ? ".Lsec" + shndx : name);
				s.global = false;
				o.symbols.push(s);
				nlocal++;
			} else {
				s = o.sym(name);
				s.weak = bind == 2;
			}
			s.tls = type == 6;
			s.func = type == 2;
			if (shndx == 0xfff1) {
				s.abs = true;
				s.offset = value;
			} else if (shndx != 0 && shndx < 0xff00) {
				var sec = secAt(shndx);
				if (sec == null || sec == funcs || sec == o.ehFrame) continue; // (a symbol of a dropped section)
				s.section = sec;
				s.offset = value;
				s.size = i64(at + 16);
			}
			syms[k] = s;
		}
		// relocations of the kept sections
		for (i in 0...shnum) {
			var h = sh(i);
			if (u32(h + 4) != 4) continue;
			var target = secAt(u32(h + 44));
			if (target == null) continue;
			var off = i64(h + 24);
			var n = Std.int(i64(h + 32) / 24);
			for (k in 0...n) {
				var at = off + 24 * k;
				var type = u32(at + 8);
				var si = u32(at + 12);
				var sym = si >= 0 && si < nsyms ? syms[si] : null;
				if (sym == null) throw "hxmc: relocation against a dropped symbol in " + target.name;
				target.relocs.push(new Reloc(i64(at), relocKind(type), sym, i64(at + 16)));
			}
		}
		if (funcs != null) FuncRec.read(o, funcs);
		return o;
	}
}
