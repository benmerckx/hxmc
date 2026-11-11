package hxmc;

import hxmc.Obj;

// An Obj as an ELF64 relocatable file (x86-64 or aarch64), for development
// builds linked by the system's linker and for inspection with
// objdump/readelf.
class ElfWriter {
	public static function relocType(k:RelKind, arm:Bool):Int {
		if (!arm) return switch k {
			case RAbs64: 1;
			case RPc32: 2;
			case RPc64: 24;
			case RCall32: 4;
			case RGotPcRel32: 9;
			case RAbs32: 10;
			case RAbs32S: 11;
			case RTpOff32: 23;
			case RSecRel32: 250; // (hxmc's runtime container only)
			case RImgRel32: 251;
			case _: throw "hxmc: relocation " + k + " on x86-64";
		}
		return switch k {
			case RAbs64: 257;
			case RAbs32: 258;
			case RPc32: 261;
			case RPc64: 260;
			case RA64AdrPage21: 275;
			case RA64AddLo12: 277;
			case RA64Ldst8Lo12: 278;
			case RA64Jump26: 282;
			case RA64Call26: 283;
			case RA64Ldst16Lo12: 284;
			case RA64Ldst32Lo12: 285;
			case RA64Ldst64Lo12: 286;
			case RA64Ldst128Lo12: 299;
			case RA64GotPage21: 311;
			case RA64GotLo12: 312;
			case RA64TlsLeHi12: 549;
			case RA64TlsLeLo12Nc: 551;
			case RA64MovwG0Nc: 264;
			case RA64MovwG1Nc: 266;
			case RA64Cond19: 280;
			case RA64Tst14: 279;
			case RA64SecRelHi12: 0x1001; // (hxmc's containers only)
			case RA64SecRelLo12A: 0x1002;
			case RA64SecRelLo12L: 0x1003;
			case RSecRel32: 0x1004;
			case RImgRel32: 0x1005;
			case RAbs32S: 0x1006;
			case _: throw "hxmc: relocation " + k + " on aarch64";
		}
	}

	public static function write(o:Obj, arm:Bool):haxe.io.Bytes {
		var shstr = new Buf();
		shstr.u8(0);
		function name(buf:Buf, s:String):Int {
			var at = buf.len;
			buf.str(s);
			buf.u8(0);
			return at;
		}
		var strtab = new Buf();
		strtab.u8(0);
		// section indices: 0 null, then the sections, then their .rela, then symtab, strtab, shstrtab, note
		var secs = o.sections;
		// (the function records: a section nothing loads)
		var funcs = FuncRec.section(o);
		if (funcs != null) secs = secs.concat([funcs]);
		for (i in 0...secs.length)
			secs[i].index = i + 1;
		// symbols: null, one per section (local), locals, then globals
		var locals = [for (s in o.symbols) if (!s.global && (s.section != null || s.abs)) s];
		var globals = [for (s in o.symbols) if (s.global || s.section == null && !s.abs) s];
		var symtab = new Buf();
		symtab.zeros(24);
		var nsym = 1;
		for (s in secs) {
			symtab.u32(0);
			symtab.u8(3); // STB_LOCAL, STT_SECTION
			symtab.u8(0);
			symtab.u16(s.index);
			symtab.u64(0, 0);
			symtab.u64(0, 0);
			nsym++;
		}
		function sym(s:Symbol) {
			s.index = nsym++;
			symtab.u32(name(strtab, s.name));
			var type = s.tls ? 6 : s.section == null ? 0 : s.func ? 2 : 1;
			symtab.u8(((s.global || s.section == null && !s.abs) ? (s.weak ? 2 : 1) : 0) << 4 | type);
			symtab.u8(0);
			symtab.u16(s.abs ? 0xfff1 : s.section == null ? 0 : s.section.index);
			symtab.i64(s.offset);
			symtab.i64(s.size);
		}
		for (s in locals)
			sym(s);
		var firstGlobal = nsym;
		for (s in globals)
			sym(s);
		// file layout: header, section contents, section headers
		var out = new Buf(4096);
		out.zeros(64);
		var headers:Array<{name:Int, type:Int, flags:Int, off:Int, size:Int, link:Int, info:Int, align:Int, entsize:Int}> = [];
		headers.push({name: 0, type: 0, flags: 0, off: 0, size: 0, link: 0, info: 0, align: 0, entsize: 0});
		for (s in secs) {
			var flags = 2; // ALLOC
			var type = 1;
			switch s.kind {
				case Text: flags |= 4;
				case Data: flags |= 1;
				case RoData:
				case Bss:
					flags |= 1;
					type = 8;
				case Tdata: flags |= 1 | 0x400;
				case Tbss:
					flags |= 1 | 0x400;
					type = 8;
				case InitArray:
					flags |= 1;
					type = 14;
				case FiniArray:
					flags |= 1;
					type = 15;
			}
			if (s == funcs) flags = 0;
			out.align(s.align < 1 ? 1 : s.align);
			var off = out.len;
			if (type != 8) out.buf(s.buf);
			headers.push({name: name(shstr, s.name), type: type, flags: flags, off: off, size: s.size(), link: 0, info: 0, align: s.align, entsize: 0});
		}
		var symtabIndex = secs.length + 1 + [for (s in secs) if (s.relocs.length > 0) s].length;
		for (s in secs) {
			if (s.relocs.length == 0) continue;
			out.align(8);
			var off = out.len;
			for (r in s.relocs) {
				out.i64(r.offset);
				var si = r.sym.index;
				out.u32(relocType(r.kind, arm));
				out.u32(si);
				out.i64(r.addend);
			}
			headers.push({name: name(shstr, ".rela" + s.name), type: 4, flags: 0x40, off: off, size: s.relocs.length * 24, link: symtabIndex, info: s.index, align: 8, entsize: 24});
		}
		out.align(8);
		var symOff = out.len;
		out.buf(symtab);
		headers.push({name: name(shstr, ".symtab"), type: 2, flags: 0, off: symOff, size: symtab.len, link: symtabIndex + 1, info: firstGlobal, align: 8, entsize: 24});
		var strOff = out.len;
		out.buf(strtab);
		headers.push({name: name(shstr, ".strtab"), type: 3, flags: 0, off: strOff, size: strtab.len, link: 0, info: 0, align: 1, entsize: 0});
		var noteName = name(shstr, ".note.GNU-stack");
		var shstrName = name(shstr, ".shstrtab");
		headers.push({name: noteName, type: 1, flags: 0, off: out.len, size: 0, link: 0, info: 0, align: 1, entsize: 0});
		var shstrOff = out.len;
		out.buf(shstr);
		headers.push({name: shstrName, type: 3, flags: 0, off: shstrOff, size: shstr.len, link: 0, info: 0, align: 1, entsize: 0});
		out.align(8);
		var shoff = out.len;
		for (h in headers) {
			out.u32(h.name);
			out.u32(h.type);
			out.i64(h.flags);
			out.i64(0);
			out.i64(h.off);
			out.i64(h.size);
			out.u32(h.link);
			out.u32(h.info);
			out.i64(h.align);
			out.i64(h.entsize);
		}
		// the ELF header
		var hb = new Buf(64);
		hb.u32(0x464c457f);
		hb.u8(2);
		hb.u8(1);
		hb.u8(1);
		hb.zeros(9);
		hb.u16(1); // ET_REL
		hb.u16(arm ? 183 : 62);
		hb.u32(1);
		hb.i64(0);
		hb.i64(0);
		hb.i64(shoff);
		hb.u32(0);
		hb.u16(64);
		hb.u16(0);
		hb.u16(0);
		hb.u16(64);
		hb.u16(headers.length);
		hb.u16(headers.length - 1);
		out.b.blit(0, hb.b, 0, 64);
		return out.toBytes();
	}
}
