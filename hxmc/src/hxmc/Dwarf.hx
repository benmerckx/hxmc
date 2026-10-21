package hxmc;

import hxmc.Obj;

// DWARF debugging information of the functions compiled with -debug
// (FuncRec.lines, FuncRec.name), for ELF and Mach-O executables: a
// compilation unit per object (a Haxe module), with a subprogram per
// function (its Haxe name, pack.Class.field) and a line program from the typed AST's positions (hxmc.ir.Ir.SPos
// through Mir and LIR to the emitted offsets). DWARF 4, addresses absolute
// (the executable's), file names as the compiler saw them (relative to the
// compilation directory).
class Dwarf {
	static inline var DW_TAG_compile_unit = 0x11;
	static inline var DW_TAG_subprogram = 0x2e;

	// the sections (.debug_abbrev, .debug_info, .debug_line, .debug_aranges,
	// .debug_ranges) for the functions of `objs` that have lines; addr: a
	// function's address (its low 32 bits; hi: the high 32 bits of every
	// address, Mach-O's image above 4 GB); none when no function has lines
	// (-debug or -D hxmc.lines: written; lines kept for the stacks alone, StackTable, are not)
	public static var enabled = false;

	public static function sections(objs:Array<Obj>, live:FuncRec->Bool, addr:FuncRec->Int, hi:Int):Array<{name:String, data:Buf}> {
		if (!enabled) return [];
		var units = [];
		for (o in objs) {
			var fs = [for (r in o.funcs) if (r.lines != null && r.lines.length > 0 && live(r)) r];
			if (fs.length > 0) units.push({obj: o, funcs: fs});
		}
		if (units.length == 0) return [];
		var abbrev = new Buf(64), info = new Buf(1 << 16), line = new Buf(1 << 16), aranges = new Buf(4096), ranges = new Buf(4096);
		// abbreviations: 1 the unit, 2 a function
		abbrev.uleb(1);
		abbrev.uleb(DW_TAG_compile_unit);
		abbrev.u8(1); // children
		for (a in [[0x25, 0x08], [0x13, 0x05], [0x03, 0x08], [0x1b, 0x08], [0x10, 0x17], [0x11, 0x01], [0x55, 0x17]]) {
			// producer string, language data2, name string, comp_dir string,
			// stmt_list sec_offset, low_pc addr, ranges sec_offset
			abbrev.uleb(a[0]);
			abbrev.uleb(a[1]);
		}
		abbrev.u16(0);
		abbrev.uleb(2);
		abbrev.uleb(DW_TAG_subprogram);
		abbrev.u8(0);
		for (a in [[0x03, 0x08], [0x11, 0x01], [0x12, 0x06], [0x40, 0x18], [0x3a, 0x0f], [0x3b, 0x0f]]) {
			// name string, low_pc addr, high_pc data4 (the size), frame_base
			// exprloc, decl_file udata, decl_line udata (no linkage name:
			// debuggers would show the symbol instead)
			abbrev.uleb(a[0]);
			abbrev.uleb(a[1]);
		}
		abbrev.u16(0);
		abbrev.u8(0);
		var compDir = Sys.getCwd();
		if (compDir.length > 1 && (StringTools.endsWith(compDir, "/") || StringTools.endsWith(compDir, "\\"))) compDir = compDir.substr(0, compDir.length - 1);
		for (u in units) {
			var o = u.obj;
			// the line program
			var lineAt = line.len;
			line.u32(0);
			line.u16(4);
			var hlenAt = line.len;
			line.u32(0);
			line.u8(1); // minimum instruction length
			line.u8(1); // maximum operations per instruction
			line.u8(1); // default is_stmt
			line.u8(-5 & 0xff); // line base
			line.u8(14); // line range
			line.u8(13); // opcode base
			for (n in [0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1])
				line.u8(n);
			line.u8(0); // no include directories (0: the compilation directory)
			for (f in o.files) {
				line.str(f);
				line.u8(0);
				line.uleb(0);
				line.uleb(0);
				line.uleb(0);
			}
			line.u8(0);
			line.set32(hlenAt, line.len - hlenAt - 4);
			for (r in u.funcs) {
				var a = addr(r);
				line.u8(0); // DW_LNE_set_address
				line.uleb(9);
				line.u8(2);
				line.u64(a, hi);
				var file = 0, ln = 1, pc = 0;
				var rows = r.lines;
				var k = 0;
				while (k < rows.length) {
					// (the first row from the function's start: its prologue)
					var off = k == 0 ? 0 : rows[k];
					var f = rows[k + 1], l = rows[k + 2];
					k += 3;
					if (f != file) {
						line.u8(4); // DW_LNS_set_file
						line.uleb(f + 1);
						file = f;
					}
					if (l != ln) {
						line.u8(3); // DW_LNS_advance_line
						line.sleb(l - ln);
						ln = l;
					}
					if (off > pc) {
						line.u8(2); // DW_LNS_advance_pc
						line.uleb(off - pc);
						pc = off;
					}
					line.u8(1); // DW_LNS_copy
				}
				if (r.sym.size > pc) {
					line.u8(2);
					line.uleb(r.sym.size - pc);
				}
				line.u8(0); // DW_LNE_end_sequence
				line.uleb(1);
				line.u8(1);
			}
			line.set32(lineAt, line.len - lineAt - 4);
			// the address ranges of the unit
			var rangesAt = ranges.len;
			var arAt = aranges.len;
			aranges.u32(0);
			aranges.u16(2);
			aranges.u32(info.len);
			aranges.u8(8);
			aranges.u8(0);
			aranges.zeros(4); // (the tuples are aligned to their size)
			for (r in u.funcs) {
				var a = addr(r);
				ranges.u64(a, hi);
				ranges.u64(a + r.sym.size, hi);
				aranges.u64(a, hi);
				aranges.u64(r.sym.size, 0);
			}
			ranges.u64(0, 0);
			ranges.u64(0, 0);
			aranges.u64(0, 0);
			aranges.u64(0, 0);
			aranges.set32(arAt, aranges.len - arAt - 4);
			// the unit
			var at = info.len;
			info.u32(0);
			info.u16(4);
			info.u32(0); // the abbreviations' offset
			info.u8(8);
			info.uleb(1);
			cstr(info, "hxmc");
			info.u16(0x000c); // DW_LANG_C99 (no number for Haxe; the closest debuggers know)
			cstr(info, o.files[u.funcs[0].lines[1]]);
			cstr(info, compDir);
			info.u32(lineAt);
			info.u64(0, 0);
			info.u32(rangesAt);
			for (r in u.funcs) {
				info.uleb(2);
				cstr(info, r.name != null ? r.name : r.sym.name);
				info.u64(addr(r), hi);
				info.u32(r.sym.size);
				info.uleb(1);
				info.u8(0x9c); // DW_OP_call_frame_cfa
				info.uleb(r.lines[1] + 1);
				info.uleb(r.lines[2]);
			}
			info.u8(0);
			info.set32(at, info.len - at - 4);
		}
		return [
			{name: "debug_abbrev", data: abbrev},
			{name: "debug_info", data: info},
			{name: "debug_line", data: line},
			{name: "debug_aranges", data: aranges},
			{name: "debug_ranges", data: ranges}
		];
	}

	static function cstr(b:Buf, s:String) {
		b.str(s);
		b.u8(0);
	}
}
