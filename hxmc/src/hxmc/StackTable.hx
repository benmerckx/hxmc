package hxmc;

import hxmc.Obj;

// The program's table of its functions and their source lines, which the
// runtime reads to name the frames of a stack (hxmc.rt.Stacks: haxe.CallStack,
// exception stacks, the report of an uncaught exception or a fault). It is
// written from the same records as -debug's DWARF lines (FuncRec.lines: the
// typed AST's positions through Mir and LIR to the emitted offsets, Dwarf),
// so the two cannot disagree. Written when the functions have lines: with
// -debug or -D hxmc.lines, and when the program can turn a stack into
// haxe.CallStack items (haxe.NativeStackTrace.toHaxe kept by the compiler's
// DCE, Main.usesStacks; -D hxmc.no-stacks leaves it out); else an empty
// table, which the runtime reads as such. docs/hxmc.md, "Debugging".
//
// At the symbol `hxmc_stacks`, read-only, little-endian:
//   u32 magic "HXST", u32 version (1), u32 count, u32 strings (the offset of
//   the string area from the table), u32 rows (the offset of the line area)
//   per function, 16 bytes, in no order (the runtime sorts them once):
//     i32 its address from the entry's own (a PC-relative relocation: no
//     load-time fixup), u32 its size, u32 its class (of its Haxe name
//     pack.Class.field: pack.Class, a string; 0 none), u32 the rest (an
//     offset in the line area; 0: no name, no lines)
//   strings: NUL-terminated UTF-8, each once (offset 0 is the empty string)
//   the rest of a function, LEB128 numbers: its field (a string), the count
//     of its rows, then per row the offset in the function where it starts
//     from the previous row's, shifted left once with the low bit set when
//     the file changes, then that file (a string), and the line from the
//     previous row's (signed); the first row's file always given; each row
//     holds until the next
class StackTable {
	public static inline var SYMBOL = "hxmc_stacks";
	public static inline var SECTION = ".rodata.hxmc_stacks";
	static inline var MAGIC = 0x54535848;
	// (HXMC_STATS) the parts of the last table written
	public static var stats = "";

	// the table's section in `data`, of every function of `objs` and `data`
	// (Link drops those of the functions it does not keep: rebuild); empty
	// unless `withLines`
	public static function add(data:Obj, objs:Array<Obj>, withLines:Bool) {
		var s = new Section(SECTION, RoData, 8);
		data.sections.push(s);
		data.define(SYMBOL, s, 0);
		fill(s, withLines ? [data].concat(objs) : [], _ -> true);
	}

	// the table again, of the functions `live` keeps (the linker's dead code
	// elimination: the table refers to every function, which would keep them)
	public static function rebuild(objs:Array<Obj>, live:FuncRec->Bool) {
		for (o in objs)
			for (s in o.sections)
				if (s.name == SECTION) {
					var any = s.buf.get32(8) != 0;
					s.buf = new Buf(1024);
					s.relocs = [];
					fill(s, any ? objs : [], live);
				}
	}

	// what the program reads of stacks (hxmc.rt.Stacks.flags), an absolute
	// symbol: 1 exception stacks (haxe.NativeStackTrace.exceptionStack live:
	// throws record their stack), 2 an exception's stack (haxe.Exception.get_stack
	// live: an exception records its stack when made)
	public static inline var FLAGS = "hxmc_stack_flags";

	public static function flags(p:hxmc.ir.Ir.Program):Int {
		var r = 0;
		for (f in p.funcs)
			if (p.isLive(f))
				switch f.display {
					case "haxe.NativeStackTrace.exceptionStack": r |= 1;
					// (and its stack from the throw, for a value caught: Exception.caught)
					case "haxe.Exception.get_stack": r |= 3;
					case _:
				}
		return r;
	}

	public static inline function isTable(s:Section):Bool
		return s.name == SECTION;

	static function fill(s:Section, objs:Array<Obj>, live:FuncRec->Bool) {
		var recs:Array<{r:FuncRec, files:Array<String>}> = [];
		for (o in objs)
			for (r in o.funcs)
				if (r.sym.section != null && live(r)) recs.push({r: r, files: o.files});
		var strings = new Buf(4096), at = new Map<String, Int>();
		strings.u8(0);
		function str(x:String):Int {
			if (x == null || x == "") return 0;
			var k = at.get(x);
			if (k != null) return k;
			k = strings.len;
			at.set(x, k);
			strings.bytes(haxe.io.Bytes.ofString(x));
			strings.u8(0);
			return k;
		}
		var rows = new Buf(4096);
		rows.u8(0);
		var b = s.buf;
		b.u32(MAGIC);
		b.u32(1);
		b.u32(recs.length);
		var fix = b.len;
		b.u32(0);
		b.u32(0);
		for (x in recs) {
			var r = x.r;
			s.relocs.push(new Reloc(b.len, RPc32, r.sym, 0));
			b.u32(0);
			b.u32(r.sym.size);
			// (the name in two strings: the classes' paths are shared)
			// (a name only where the function has a Haxe name: the symbol, which
			// DWARF names the others with, is not one)
			var owner = null, field = r.name == r.sym.name ? null : r.name;
			if (field != null) {
				var dot = field.lastIndexOf(".");
				if (dot > 0) {
					owner = field.substr(0, dot);
					field = field.substr(dot + 1);
				}
			}
			b.u32(str(owner));
			var lines = r.lines != null ? r.lines : new haxe.ds.Vector<Int>(0);
			// (rows: a row only where the file or the line changes)
			var kept = [];
			var k = 0;
			while (k < lines.length) {
				var n = kept.length;
				if (n == 0 || kept[n - 2] != lines[k + 1] || kept[n - 1] != lines[k + 2]) {
					kept.push(lines[k]);
					kept.push(lines[k + 1]);
					kept.push(lines[k + 2]);
				}
				k += 3;
			}
			if (field == null && kept.length == 0) {
				b.u32(0);
				continue;
			}
			b.u32(rows.len);
			rows.uleb(str(field));
			rows.uleb(Std.int(kept.length / 3));
			var off = 0, file = -1, line = 0;
			k = 0;
			while (k < kept.length) {
				var f = str(x.files[kept[k + 1]]);
				rows.uleb(((kept[k] - off) << 1) | (f != file ? 1 : 0));
				if (f != file) rows.uleb(f);
				rows.sleb(kept[k + 2] - line);
				off = kept[k];
				file = f;
				line = kept[k + 2];
				k += 3;
			}
		}
		b.set32(fix, b.len);
		b.buf(strings);
		b.set32(fix + 4, b.len);
		b.buf(rows);
		stats = '${recs.length} functions ${16 * recs.length} bytes, strings ${strings.len} bytes, lines ${rows.len} bytes';
	}
}
