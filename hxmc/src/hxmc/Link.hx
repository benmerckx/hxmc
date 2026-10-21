package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;
import hxmc.Abi;

// hxmc's static linker for Linux: objects (the program's, the runtime
// object of tools/mkrt.sh with the C library) -> a static ELF executable
// (no dynamic section, no interpreter): symbol resolution, layout in three
// loadable segments (read-only with the headers, code, data with TLS),
// relocation, the symbols a C toolchain's linker defines (__init_array_*,
// ...), the unwind tables of the generated code (.eh_frame and its search
// table .eh_frame_hdr, PT_GNU_EH_FRAME: Unwind) and with -debug its DWARF
// line information (Dwarf). LinkDyn extends it for dynamically linked
// executables (-D hxmc.libc=glibc).
class Link {
	static inline var BASE = 0x400000;
	// the image's address (a shared library's: 0, LinkDyn)
	var imageBase = BASE;

	var objs:Array<Obj>;
	// the segment alignment: 4K on x86-64, 64K on aarch64 (the largest page size kernels use)
	var PAGE:Int;
	var arm:Bool;
	var globals = new Map<String, Symbol>();
	var addr = new Map<Section, Int>(); // section -> address
	var symAddr:Symbol->Int;
	var tlsStart = 0;
	var tlsSize = 0;
	var tlsAlign = 1;

	public function new(objs:Array<Obj>, abi:Abi) {
		this.objs = objs;
		this.arm = abi.arm;
		PAGE = abi.segAlign;
		// (position-independent output, shared libraries: LinkDyn; a PIE is
		// not written yet)
		if (!abi.linksDynamically() && (abi.reloc != Static || abi.output != Executable)) throw "hxmc: " + abi.reloc + " " + abi.output + " output is not supported yet";
	}

	// ---- symbols

	function resolve() {
		for (o in objs)
			for (s in o.symbols) {
				if (!s.global || (s.section == null && !s.abs)) continue;
				var prev = globals.get(s.name);
				if (prev == null || prev.weak && !s.weak) globals.set(s.name, s);
				else if (!prev.weak && !s.weak) throw 'hxmc: link: ${s.name} defined twice';
			}
	}

	// the key of an undefined symbol (its GOT slot): itself; LinkDyn: the
	// import of that name, one slot per import
	function undefKey(s:Symbol):Symbol
		return s;

	// the definition a reference resolves to (null: undefined)
	function target(s:Symbol):Null<Symbol> {
		if (s.section != null || s.abs) return s;
		return globals.get(s.name);
	}

	// ---- layout

	// a slot per symbol reached through the global offset table (aarch64
	// GOT relocations of the C library): its address, filled by a relocation
	var got:Null<Section>;
	var gotSlot = new Map<Symbol, Int>();

	// ---- dead code: the sections of `collect` (the runtime objects) that
	// nothing reaches from the entry, the other objects and the
	// initializers are left out (the runtime is compiled with a section per
	// function and per datum)
	public var collect:Null<Array<Obj>>;
	// sections of any object kept only when reached (the runtime's Haxe functions)
	public static inline var GC_PREFIX = ".text.gc.";
	var live:Null<Map<Section, Bool>>;
	// more roots than the entry (a shared library's exports: LinkDyn)
	var roots:Array<String> = [];

	function gc(entry:String) {
		if (collect == null) return;
		live = new Map();
		var work:Array<Section> = [];
		function mark(s:Section) {
			if (s != null && !live.exists(s)) {
				live.set(s, true);
				work.push(s);
			}
		}
		for (o in objs)
			for (s in o.sections)
				if ((collect.indexOf(o) < 0 && !StringTools.startsWith(s.name, GC_PREFIX)) || s.kind == InitArray || s.kind == FiniArray) mark(s);
		var e = globals.get(entry);
		if (e != null) mark(e.section);
		for (r in roots) {
			var x = globals.get(r);
			if (x != null && x.section != null) mark(x.section);
		}
		while (work.length > 0) {
			var s = work.pop();
			// (the stack table names every function: it keeps none, StackTable)
			if (StackTable.isTable(s)) continue;
			for (r in s.relocs) {
				var t = target(r.sym);
				if (t != null && t.section != null) mark(t.section);
			}
		}
		StackTable.rebuild(objs, r -> live.exists(r.sym.section));
	}

	inline function isLive(s:Section):Bool
		return live == null || live.exists(s);

	function makeGot() {
		for (o in objs)
			for (s in o.sections)
				if (isLive(s))
				for (r in s.relocs)
					if (r.kind == RA64GotPage21 || r.kind == RA64GotLo12 || r.kind == RGotPcRel32) {
						var t = target(r.sym);
						var key = t != null ? t : undefKey(r.sym);
						if (!gotSlot.exists(key)) {
							if (got == null) got = new Section(".got", Data, 8);
							gotSlot.set(key, got.buf.len);
							got.relocs.push(new Reloc(got.buf.len, RAbs64, key, 0));
							got.buf.u64(0, 0);
						}
					}
		if (got != null) {
			if (live != null) live.set(got, true);
			var o = new Obj();
			o.sections.push(got);
			objs.push(o);
		}
	}

	function gotAddr(s:Symbol):Int {
		var t = target(s);
		return addr.get(got) + gotSlot.get(t != null ? t : undefKey(s));
	}

	// ---- unwind tables (Unwind) and debugging information (Dwarf)

	var ehFrame:Null<Section>;
	var ehFrameHdr:Null<Section>;
	// the search table's entries: each FDE's function (a symbol and an addend)
	var fdes:Array<{sym:Symbol, addend:Int, at:Int}> = [];

	// .eh_frame and .eh_frame_hdr of the live generated functions and of
	// the live C code of the runtime objects (their own .eh_frame's
	// entries): read-only sections of their own object (laid out with the
	// others; the search table is filled once the functions have addresses:
	// fillUnwind)
	function unwindObj() {
		var unwound = [];
		for (o in objs)
			for (r in o.funcs)
				if (r.sym.section != null && isLive(r.sym.section)) unwound.push(r);
		if (unwound.length == 0) return;
		var e = Unwind.ehFrame(unwound, arm, ".eh_frame");
		ehFrame = e.sec;
		for (k in 0...unwound.length)
			fdes.push({sym: unwound[k].sym, addend: 0, at: e.fdes[k]});
		// (the terminator goes after the C code's entries)
		ehFrame.buf.len -= 4;
		for (o in objs)
			if (o.ehFrame != null) importEhFrame(o.ehFrame);
		ehFrame.buf.u32(0);
		ehFrameHdr = new Section(".eh_frame_hdr", RoData, 4);
		ehFrameHdr.buf.zeros(Unwind.ehFrameHdrSize(fdes.length));
		var o = new Obj();
		o.sections.push(ehFrameHdr);
		o.sections.push(ehFrame);
		if (live != null) {
			live.set(ehFrameHdr, true);
			live.set(ehFrame, true);
		}
		objs.push(o);
	}

	// the CIEs and FDEs of a C object's .eh_frame whose functions are live
	// (their own CIEs, copied once each; the FDEs' relocations kept)
	function importEhFrame(src:Section) {
		var b = src.buf, out = ehFrame.buf;
		var relocAt = new Map<Int, Reloc>();
		for (r in src.relocs)
			relocAt.set(r.offset, r);
		var cieAt = new Map<Int, Int>(); // the CIE's offset in src -> in ehFrame
		function copy(from:Int, len:Int):Int {
			var at = out.len;
			out.bytes(b.b, from, len);
			for (k in from...from + len) {
				var r = relocAt.get(k);
				if (r != null) ehFrame.relocs.push(new Reloc(at + k - from, r.kind, r.sym, r.addend));
			}
			return at;
		}
		var pos = 0;
		while (pos + 4 <= b.len) {
			var len = b.get32(pos);
			if (len == 0) break;
			if (len == -1) throw "hxmc: link: a 64-bit .eh_frame entry";
			var id = b.get32(pos + 4);
			if (id != 0) {
				// an FDE: its function's section (the relocation of its pc_begin)
				var r = relocAt.get(pos + 8);
				var t = r != null ? target(r.sym) : null;
				if (t != null && t.section != null && isLive(t.section)) {
					var cie = pos + 4 - id;
					var to = cieAt.get(cie);
					if (to == null) {
						to = copy(cie, 4 + b.get32(cie));
						cieAt.set(cie, to);
					}
					var at = copy(pos, 4 + len);
					out.set32(at + 4, at + 4 - to);
					fdes.push({sym: r.sym, addend: r.addend, at: at});
				}
			}
			pos += 4 + len;
		}
	}

	function fillUnwind() {
		if (ehFrame == null) return;
		var base = addr.get(ehFrame);
		var list = [for (f in fdes) {pc: symAddr(f.sym) + f.addend, fde: base + f.at}];
		ehFrameHdr.buf.len = 0;
		Unwind.ehFrameHdr(addr.get(ehFrameHdr), base, list, ehFrameHdr.buf);
	}

	// the section headers of the unwind tables (for the tools: the C
	// library's unwinder finds them through PT_GNU_EH_FRAME)
	function unwindHeaders(secs:Array<SecHdr>) {
		if (ehFrame == null) return;
		for (s in [ehFrameHdr, ehFrame])
			secs.push({name: s.name, type: s == ehFrame && !arm ? 0x70000001 : 1, flags: 2, addr: addr.get(s), off: addr.get(s) - imageBase, size: s.size(), link: 0, info: 0, align: s.align, entsize: 0});
	}

	// (-debug) the DWARF sections of the live functions
	function debugSections():Array<{name:String, data:Buf}>
		return [
			for (d in Dwarf.sections(objs, r -> r.sym.section != null && isLive(r.sym.section) && addr.exists(r.sym.section), r -> symAddr(r.sym), 0))
				{name: "." + d.name, data: d.data}
		];

	public var symbols = true; // write a symbol table of the code (profilers, debuggers)
	// -D hxmc.jit: every global symbol of the executable, "<name> <kind> <value>" per
	// line (t code, d data, a absolute, l TLS: the thread-pointer offset), for
	// the native macros the executable loads (hxmc.macro.Loader)
	public var hostSyms:Null<StringBuf> = null;

	public function link(entry:String):Bytes {
		resolve();
		gc(entry);
		makeGot();
		unwindObj();
		// linker-defined symbols, defined below once the layout is known
		var defined = new Map<String, Int>();
		var all:Array<Section> = [];
		for (o in objs)
			for (s in o.sections)
				if (isLive(s)) all.push(s);
		var ro = [for (s in all) if (s.kind == RoData) s];
		var text = [for (s in all) if (s.kind == Text) s];
		var tdata = [for (s in all) if (s.kind == Tdata) s];
		var tbss = [for (s in all) if (s.kind == Tbss) s];
		var init = [for (s in all) if (s.kind == InitArray) s];
		var fini = [for (s in all) if (s.kind == FiniArray) s];
		var data = [for (s in all) if (s.kind == Data) s];
		var bss = [for (s in all) if (s.kind == Bss) s];
		var nph = ehFrame != null ? 6 : 5; // LOAD r, LOAD rx, LOAD rw, TLS, GNU_STACK, GNU_EH_FRAME
		var headers = 64 + 56 * nph;
		var pos = BASE + headers;
		function place(list:Array<Section>) {
			for (s in list) {
				pos = align(pos, s.align);
				addr.set(s, pos);
				pos += s.size();
			}
		}
		// segment 1: headers + read-only data
		place(ro);
		var roEnd = pos;
		// segment 2: code (file offset = address - BASE: one image)
		pos = align(pos, PAGE);
		var textStart = pos;
		place(text);
		var textEnd = pos;
		// segment 3: TLS image, init/fini arrays, data, bss
		pos = align(pos, PAGE);
		var dataStart = pos;
		place(tdata);
		tlsStart = dataStart;
		var tdataEnd = pos;
		// .tbss takes no room in the segment
		var tpos = pos;
		for (s in tbss) {
			tpos = align(tpos, s.align);
			addr.set(s, tpos);
			tpos += s.size();
		}
		for (s in tdata.concat(tbss))
			if (s.align > tlsAlign) tlsAlign = s.align;
		tlsSize = tpos - tlsStart;
		pos = align(pos, 8);
		defined.set("__init_array_start", pos);
		place(init);
		defined.set("__init_array_end", pos);
		defined.set("__fini_array_start", pos);
		place(fini);
		defined.set("__fini_array_end", pos);
		place(data);
		var fileEnd = pos;
		place(bss);
		var dataEnd = pos;
		defined.set("_end", dataEnd);
		defined.set("end", dataEnd);
		defined.set("_DYNAMIC", 0);
		defined.set("__ehdr_start", BASE);
		symAddr = function(s:Symbol):Int {
			var t = target(s);
			if (t == null) {
				var d = defined.get(s.name);
				if (d != null) return d;
				if (s.weak) return 0;
				throw 'hxmc: link: undefined symbol ${s.name}' + (StringTools.startsWith(s.name, "dl") ? " (loading shared libraries needs the dynamic glibc mode, -D hxmc.libc=glibc: Linux executables are static with musl)" : "");
			}
			if (t.abs) return t.offset;
			return addr.get(t.section) + t.offset;
		};
		// relocations
		for (s in all)
			if (s.kind != Bss && s.kind != Tbss) apply(s);
		fillUnwind();
		if (hostSyms != null) writeHostSyms(defined);
		// the image
		var out = new Buf(fileEnd - BASE + 4096);
		out.zeros(fileEnd - BASE);
		for (s in all)
			if (s.kind != Bss && s.kind != Tbss) out.b.blit(addr.get(s) - BASE, s.buf.b, 0, s.buf.len);
		// ELF header
		var e = BASE + 0;
		var h = new Buf(64);
		h.u32(0x464c457f);
		h.u8(2);
		h.u8(1);
		h.u8(1);
		h.zeros(9);
		h.u16(2); // ET_EXEC
		h.u16(arm ? 183 : 62);
		h.u32(1);
		h.i64(symAddr(entrySym(entry)));
		h.i64(64); // phoff
		var secs:Array<SecHdr> = [{name: ".text", type: 1, flags: 6, addr: textStart, off: textStart - BASE, size: textEnd - textStart, link: 0, info: 0, align: 16, entsize: 0}];
		unwindHeaders(secs);
		var shoff = sectionHeaders(out, secs, 1);
		h.i64(shoff); // shoff
		h.u32(0);
		h.u16(64);
		h.u16(56);
		h.u16(nph);
		h.u16(64);
		h.u16(secs.length + 2);
		h.u16(secs.length + 1);
		// program headers
		function ph(type:Int, flags:Int, off:Int, vaddr:Int, filesz:Int, memsz:Int, al:Int) {
			h.u32(type);
			h.u32(flags);
			h.i64(off);
			h.i64(vaddr);
			h.i64(vaddr);
			h.i64(filesz);
			h.i64(memsz);
			h.i64(al);
		}
		ph(1, 4, 0, BASE, roEnd - BASE, roEnd - BASE, PAGE);
		ph(1, 5, textStart - BASE, textStart, textEnd - textStart, textEnd - textStart, PAGE);
		ph(1, 6, dataStart - BASE, dataStart, fileEnd - dataStart, dataEnd - dataStart, PAGE);
		ph(7, 4, tlsStart - BASE, tlsStart, tdataEnd - tlsStart, tlsSize, tlsAlign);
		if (ehFrameHdr != null) ph(0x6474e550, 4, addr.get(ehFrameHdr) - BASE, addr.get(ehFrameHdr), ehFrameHdr.size(), ehFrameHdr.size(), 4);
		ph(0x6474e551, 6, 0, 0, 0, 0, 16);
		out.b.blit(0, h.b, 0, h.len);
		return out.toBytes();
	}

	// appends what nothing loads to the image: (-debug) the DWARF sections,
	// (with `symbols`) .symtab and .strtab of the code, .shstrtab and the
	// section headers (null, `secs`, those, .shstrtab last; textIndex: the
	// header of .text, the symbols' section); returns the headers' offset
	function sectionHeaders(out:Buf, secs:Array<SecHdr>, textIndex:Int):Int {
		for (d in debugSections()) {
			var off = out.len;
			out.buf(d.data);
			secs.push({name: d.name, type: 1, flags: 0, addr: 0, off: off, size: d.data.len, link: 0, info: 0, align: 1, entsize: 0});
		}
		if (symbols) {
			var strtab = new Buf(1 << 16);
			strtab.u8(0);
			var symtab = new Buf(1 << 16);
			symtab.zeros(24);
			var locals = new Buf(1 << 16), globals = new Buf(1 << 16);
			var nlocal = 1;
			for (o in objs)
				for (s in o.symbols) {
					var sec = s.section;
					if (sec == null || sec.kind != Text || !addr.exists(sec) || s.abs || s.name.length == 0 || StringTools.startsWith(s.name, ".L")) continue;
					var b = s.global ? globals : locals;
					if (!s.global) nlocal++;
					b.u32(strtab.len);
					strtab.str(s.name);
					strtab.u8(0);
					b.u8((s.global ? 0x10 : 0) | 2); // STT_FUNC
					b.u8(0);
					b.u16(textIndex);
					b.i64(addr.get(sec) + s.offset);
					b.i64(s.size);
				}
			symtab.buf(locals);
			symtab.buf(globals);
			out.align(8);
			var symOff = out.len;
			out.buf(symtab);
			var strOff = out.len;
			out.buf(strtab);
			var n = secs.length + 1;
			secs.push({name: ".symtab", type: 2, flags: 0, addr: 0, off: symOff, size: symtab.len, link: n + 1, info: nlocal, align: 8, entsize: 24});
			secs.push({name: ".strtab", type: 3, flags: 0, addr: 0, off: strOff, size: strtab.len, link: 0, info: 0, align: 1, entsize: 0});
		}
		var shstr = new Buf(256);
		shstr.u8(0);
		var names = [];
		for (s in secs) {
			names.push(shstr.len);
			shstr.str(s.name);
			shstr.u8(0);
		}
		var shName = shstr.len;
		shstr.str(".shstrtab");
		shstr.u8(0);
		var shstrOff = out.len;
		out.buf(shstr);
		out.align(8);
		var shoff = out.len;
		function sh(name:Int, type:Int, flags:Int, a:Int, off:Int, size:Int, link:Int, info:Int, al:Int, entsize:Int) {
			out.u32(name);
			out.u32(type);
			out.i64(flags);
			out.i64(a);
			out.i64(off);
			out.i64(size);
			out.u32(link);
			out.u32(info);
			out.i64(al);
			out.i64(entsize);
		}
		sh(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		for (k in 0...secs.length) {
			var s = secs[k];
			sh(names[k], s.type, s.flags, s.addr, s.off, s.size, s.link, s.info, s.align, s.entsize);
		}
		sh(shName, 3, 0, 0, shstrOff, shstr.len, 0, 0, 1, 0);
		return shoff;
	}

	function writeHostSyms(defined:Map<String, Int>) {
		var names = [for (n in globals.keys()) n].concat([for (n in defined.keys()) if (!globals.exists(n)) n]);
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in names) {
			var s = globals.get(n);
			if (s == null) {
				hostSyms.add(n + " d " + defined.get(n) + "\n");
				continue;
			}
			if (!s.abs && !isLive(s.section)) continue;
			var v = symAddr(s);
			var k = s.abs ? "a" : switch s.section.kind {
				case Text: "t";
				case Tdata | Tbss: v = tpoff(v); "l";
				case _: "d";
			};
			hostSyms.add(n + " " + k + " " + v + "\n");
		}
	}

	function entrySym(name:String):Symbol {
		var s = globals.get(name);
		if (s == null) throw 'hxmc: link: no entry point $name';
		return s;
	}

	static inline function align(v:Int, a:Int):Int
		return a <= 1 ? v : (v + a - 1) & ~(a - 1);

	// the thread-pointer-relative offset of a TLS symbol (local-exec):
	// x86-64 (variant II) below the thread pointer, aarch64 (variant I) above
	// the 16-byte control block
	function tpoff(a:Int):Int {
		if (arm) return align(16, tlsAlign) + (a - tlsStart);
		return (a - tlsStart) - align(tlsSize, tlsAlign);
	}

	static function imm12(buf:Buf, at:Int, v:Int)
		buf.set32(at, (buf.get32(at) & ~(0xfff << 10)) | ((v & 0xfff) << 10));

	static function adrp(buf:Buf, at:Int, target:Int, p:Int) {
		var imm = ((target & ~0xfff) - (p & ~0xfff)) >> 12;
		var w = buf.get32(at) & ~((3 << 29) | (0x7ffff << 5));
		buf.set32(at, w | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5));
	}

	// LinkDyn: a relocation that becomes a dynamic one (true: done)
	var dynReloc:Null<(Section, Reloc) -> Bool> = null;

	function apply(s:Section) {
		var base = addr.get(s);
		var buf = s.buf;
		for (r in s.relocs) {
			if (dynReloc != null && dynReloc(s, r)) continue;
			var S = symAddr(r.sym);
			var A = r.addend;
			var P = base + r.offset;
			switch r.kind {
				case RAbs64:
					var v = S + A;
					buf.set64(r.offset, v, v < 0 ? -1 : 0);
				case RAbs32 | RAbs32S:
					buf.set32(r.offset, S + A);
				case RPc32 | RCall32:
					buf.set32(r.offset, S + A - P);
				case RTpOff32:
					buf.set32(r.offset, tpoff(S) + A);
				// (the offset in the module's TLS block: LinkDyn's TLSDESC, hxmc_tls_base)
				case RSecRel32:
					buf.set32(r.offset, S + A - tlsStart);
				case RA64SecRelHi12 | RA64SecRelLo12A | RA64SecRelLo12L:
					A64Reloc.apply(buf, r.offset, r.kind, S + A - tlsStart, P, r.sym.name);
				case RGotPcRel32:
					buf.set32(r.offset, gotAddr(r.sym) + A - P);
				case RA64AdrPage21:
					adrp(buf, r.offset, S + A, P);
				case RA64GotPage21:
					adrp(buf, r.offset, gotAddr(r.sym), P);
				case RA64AddLo12:
					imm12(buf, r.offset, (S + A) & 0xfff);
				case RA64Ldst8Lo12:
					imm12(buf, r.offset, (S + A) & 0xfff);
				case RA64Ldst16Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 1);
				case RA64Ldst32Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 2);
				case RA64Ldst64Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 3);
				case RA64Ldst128Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 4);
				case RA64GotLo12:
					imm12(buf, r.offset, (gotAddr(r.sym) & 0xfff) >> 3);
				case RA64Call26 | RA64Jump26:
					var d = S + A - P;
					if (d >= (1 << 27) || d < -(1 << 27)) throw "hxmc: link: branch out of range to " + r.sym.name;
					buf.set32(r.offset, (buf.get32(r.offset) & 0xfc000000) | ((d >> 2) & 0x3ffffff));
				case RA64TlsLeHi12:
					imm12(buf, r.offset, ((tpoff(S) + A) >> 12) & 0xfff);
				case RA64TlsLeLo12Nc:
					imm12(buf, r.offset, (tpoff(S) + A) & 0xfff);
				case RA64MovwG0Nc:
					buf.set32(r.offset, (buf.get32(r.offset) & ~(0xffff << 5)) | (((S + A) & 0xffff) << 5));
				case RA64MovwG1Nc:
					buf.set32(r.offset, (buf.get32(r.offset) & ~(0xffff << 5)) | ((((S + A) >>> 16) & 0xffff) << 5));
				case _:
					throw "hxmc: link: relocation " + r.kind + " not supported yet";
			}
		}
	}
}

typedef SecHdr = {name:String, type:Int, flags:Int, addr:Int, off:Int, size:Int, link:Int, info:Int, align:Int, entsize:Int}
