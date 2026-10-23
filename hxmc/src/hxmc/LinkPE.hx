package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;

// hxmc's linker for Windows: objects (the program's, the runtime object of
// MkRt) -> a PE32+ executable at a fixed base (no base relocations), with
// its import directory written directly from the runtime's import list
// (.hxmc.imports: which DLL exports what), call thunks for imported code,
// the TLS directory of the C runtime (_tls_used) and the exception
// directory (.pdata: the runtime object's, and the generated functions'
// with their unwind information in .xdata, from Unwind; sorted by address,
// as RtlLookupFunctionEntry searches it). With `symbols` (-debug, -D
// hxmc.symbols), a COFF symbol table of the code and, with -debug's lines,
// DWARF sections (Dwarf), as MinGW's toolchain writes them for gdb and lldb
// (no PDB: docs/plans/codegen.md). With `dll` (-D hxmc.shared: hxmc dev's
// builds on Windows) a DLL instead: no entry point, its exports (Abi.exports)
// in an export directory, relocatable (base relocations, x86-64 too) from
// its preferred base (dllBase, x86-64), which it keeps unless taken: no
// DYNAMIC_BASE there; arm64's like its executables (DYNAMIC_BASE, which
// Windows requires on arm64: ERROR_BAD_EXE_FORMAT without it). Resolution
// and the relocations: LinkCore.
class LinkPE extends LinkCore {
	// the image base: x86-64 a fixed 0x400000 (addresses are kept absolute);
	// arm64 0x140000000, relocatable (addresses are kept as RVAs, BASE 0, and
	// the base is added where a 64-bit absolute address is written)
	var BASE = 0x400000;
	var imgLo = 0;
	var imgHi = 0;
	static inline var SECT = 0x1000;
	static inline var FILE = 0x200;

	public var symbols = false;
	var imports = new Map<String, {dll:String, name:String, code:Bool}>();
	var outOf = new Map<Section, Int>(); // section -> output section index

	// a DLL: its exports, its file name, its preferred base
	public var dll = false;
	public var exports:Array<String> = [];
	public var dllName = "";
	public var dllBase = 0x10000000;

	public function new(objs:Array<Obj>, arm:Bool) {
		super(objs, arm);
		if (arm && !diag("lowbase")) {
			BASE = 0;
			imgLo = 0x40000000;
			imgHi = 1;
		}
	}

	function readImports() {
		for (o in objs) {
			var keep = [];
			for (s in o.sections)
				if (s.name == ".hxmc.imports") {
					for (l in s.buf.toBytes().toString().split("\n")) {
						var f = l.split("\t");
						if (f.length >= 4) imports.set(f[1], {dll: f[0], name: f[2], code: f[3] == "code"});
					}
				} else keep.push(s);
			o.sections = keep;
		}
	}

	// HXMC_PE_DIAG=<flag,...>: variants of the output for bisecting a loader's
	// refusal (development)
	static var diags:Null<Array<String>>;

	static function diag(f:String):Bool {
		if (diags == null) {
			var e = Sys.getEnv("HXMC_PE_DIAG");
			diags = e == null ? [] : e.split(",");
		}
		return diags.indexOf(f) >= 0;
	}

	public function link(entry:String):Bytes {
		// (x86-64: a DLL at its preferred base; arm64: as an executable, relocatable with DYNAMIC_BASE, which Windows requires there)
		if (dll && !arm) BASE = dllBase;
		readImports();
		resolve();
		// (the sections nothing reaches left out: LinkCore.gc, with the
		// exception directory's entries of the functions kept)
		roots = [for (n in (dll ? exports : []).concat(["_tls_used"])) if (globals.exists(n)) n];
		unwindOf = pdataLinks();
		gc(entry);
		if (live != null) keepPdata();
		// the imports the objects use: IAT slots (and thunks for code)
		var used = new Map<String, Bool>(); // imported name keys (the symbol names of the list)
		for (o in objs)
			for (s in o.sections)
				if (isLive(s))
					for (r in s.relocs)
					if (target(r.sym) == null && imports.exists(r.sym.name)) used.set(r.sym.name, true);
		// one IAT slot per (dll, name)
		var dlls:Array<String> = [];
		var byDll = new Map<String, Array<String>>(); // dll -> imported names
		var slotKey = new Map<String, String>(); // symbol -> dll + name
		var keys = [for (k in used.keys()) k];
		keys.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (k in keys) {
			var i = imports.get(k);
			var dll = i.dll;
			if (!byDll.exists(dll)) {
				byDll.set(dll, []);
				dlls.push(dll);
			}
			var names = byDll.get(dll);
			if (names.indexOf(i.name) < 0) names.push(i.name);
			slotKey.set(k, dll + "\t" + i.name);
		}
		// synthesized sections: thunks, the import data, constructor lists
		var thunks = new Section(".text$hxmc_thunks", Text, 16);
		var thunkOf = new Map<String, Int>();
		for (k in keys)
			if (!StringTools.startsWith(k, "__imp_")) {
				thunkOf.set(k, thunks.buf.len);
				if (arm) {
					// adrp x16, slot; ldr x16, [x16, :lo12:slot]; br x16
					thunks.buf.u32(0x90000010);
					thunks.buf.u32(0xF9400210);
					thunks.buf.u32(0xD61F0200);
					thunks.buf.u32(0xD503201F);
				} else {
					thunks.buf.u8(0xff);
					thunks.buf.u8(0x25);
					thunks.buf.u32(0);
					thunks.buf.u16(0x9090);
				}
			}
		// __CTOR_LIST__ / __DTOR_LIST__ (MinGW's __do_global_ctors): -1, the
		// objects' .ctors/.dtors sections (constructors of the C library, e.g.
		// winpthreads' initialization), 0; kept together by their names in .data
		var extra = new Obj();
		extra.sections.push(thunks);
		// (a DLL) its export directory: the directory, the function and name
		// tables (names sorted, as the loader searches them), the ordinals, the strings
		var edata:Null<Section> = null;
		if (dll) {
			var names = [for (n in exports) if (globals.exists(n)) n];
			names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			edata = new Section(".rdata$hxmc_edata", RoData, 4);
			var self = new Symbol(".Ledata");
			self.global = false;
			self.section = edata;
			var n = names.length, b = edata.buf;
			var eat = 40, npt = eat + 4 * n, ord = npt + 4 * n, str = ord + 2 * n;
			var strings = [Bytes.ofString(dllName)].concat([for (x in names) Bytes.ofString(x)]);
			var at = str, strAt = [];
			for (x in strings) {
				strAt.push(at);
				at += x.length + 1;
			}
			b.zeros(at);
			function rva(off:Int, to:Int)
				edata.relocs.push(new Reloc(off, RImgRel32, self, to));
			rva(12, strAt[0]); // Name
			b.set32(16, 1); // Base
			b.set32(20, n); // NumberOfFunctions
			b.set32(24, n); // NumberOfNames
			rva(28, eat);
			rva(32, npt);
			rva(36, ord);
			for (i in 0...n) {
				edata.relocs.push(new Reloc(eat + 4 * i, RImgRel32, globals.get(names[i]), 0));
				rva(npt + 4 * i, strAt[i + 1]);
				b.set16(ord + 2 * i, i);
			}
			for (k in 0...strings.length)
				b.b.blit(strAt[k], strings[k], 0, strings[k].length);
			extra.sections.push(edata);
		}
		// (diagnostics: an entry point that returns 42 at once)
		var retEntry = new Section(".text$hxmc_ret42", Text, 16);
		if (arm) {
			retEntry.buf.u32(0x52800540); // mov w0, #42
			retEntry.buf.u32(0xD65F03C0); // ret
		} else {
			retEntry.buf.u8(0xb8); // mov eax, 42
			retEntry.buf.u32(42);
			retEntry.buf.u8(0xc3);
		}
		if (diag("ret42")) extra.sections.push(retEntry);
		var listHead = new Map<String, Section>();
		for (l in ["ctor", "dtor"]) {
			var head = new Section(".data$hxmc_" + l + "0", Data, 8);
			head.buf.u64(-1, -1);
			var tail = new Section(".data$hxmc_" + l + "2", Data, 8);
			tail.buf.u64(0, 0);
			extra.sections.push(head);
			extra.sections.push(tail);
			listHead.set(l, head);
		}
		for (o in objs)
			for (sec in o.sections)
				for (l in ["ctor", "dtor"])
					if (sec.name == "." + l + "s" || StringTools.startsWith(sec.name, "." + l + "s.")) {
						sec.name = ".data$hxmc_" + l + "1" + sec.name;
						sec.kind = Data;
					}
		unwindInfo(extra);
		keep(extra);
		// output sections
		var groups:Array<{name:String, chars:Int, secs:Array<Section>}> = [
			{name: ".text", chars: 0x60000020, secs: []},
			{name: ".rdata", chars: 0x40000040, secs: []},
			{name: ".pdata", chars: 0x40000040, secs: []},
			{name: ".data", chars: 0xC0000040, secs: []},
			{name: ".tls", chars: 0xC0000040, secs: []},
			{name: ".idata", chars: 0xC0000040, secs: []},
			{name: ".bss", chars: 0xC0000080, secs: []},
			{name: ".reloc", chars: 0x42000040, secs: []},
		];
		for (o in objs)
			for (s in o.sections) {
				if (!isLive(s)) continue;
				// (.CRT$X?A ... .CRT$X?Z: arrays of pointers, read-only or not,
				// kept together in .data in name order)
				var g = StringTools.startsWith(s.name, ".CRT$") ? 3 : switch s.kind {
					case Text: 0;
					case RoData: StringTools.startsWith(s.name, ".pdata") ? 2 : 1;
					case Data | InitArray | FiniArray: 3;
					case Tdata | Tbss: 4;
					case Bss: diag("bssdata") ? 3 : 6;
				};
				groups[g].secs.push(s);
			}
		// within a group, by name: grouped sections ("name$suffix") in suffix order
		for (g in groups) {
			var idx = new Map<Section, Int>();
			for (i in 0...g.secs.length)
				idx.set(g.secs[i], i);
			g.secs.sort((a, b) -> a.name < b.name ? -1 : a.name > b.name ? 1 : idx.get(a) - idx.get(b));
		}
		var nsec = groups.length;
		// (-debug: the DWARF sections after the others)
		var hasLines = symbols && Lambda.exists(objs, o -> Lambda.exists(o.funcs, r -> r.lines != null));
		var headers = LinkCore.align(64 + 4 + 20 + 240 + 40 * (nsec + (hasLines ? 5 : 0)), FILE);
		var rva = LinkCore.align(headers, SECT);
		starts = new haxe.ds.Vector<Int>(groups.length);
		var sizes = new haxe.ds.Vector<Int>(groups.length);
		var idata:Buf = null;
		var idataLayout = null;
		for (gi in 0...groups.length) {
			var g = groups[gi];
			starts[gi] = rva;
			var pos = rva;
			if (g.name == ".idata") {
				idataLayout = importData(dlls, byDll, rva);
				idata = idataLayout.buf;
				pos += idata.len;
			} else {
				pos = place(g.secs, pos, BASE);
				for (s in g.secs)
					outOf.set(s, gi);
			}
			sizes[gi] = pos - rva;
			rva = LinkCore.align(pos, SECT);
		}
		var imageSize = rva;
		relocatable = (arm || dll) && !diag("fixed");
		var defined = new Map<String, Int>();
		defined.set("__CTOR_LIST__", addr.get(listHead.get("ctor")));
		defined.set("__DTOR_LIST__", addr.get(listHead.get("dtor")));
		defined.set("__ImageBase", BASE);
		defined.set("WinMain", 0);
		var iatAddr = (k:String) -> BASE + idataLayout.iat.get(slotKey.get(k));
		symAddr = function(s:Symbol):Int {
			var t = target(s);
			if (t == null) {
				var n = s.name;
				if (imports.exists(n)) return StringTools.startsWith(n, "__imp_") ? iatAddr(n) : addr.get(thunks) + thunkOf.get(n);
				var d = defined.get(n);
				if (d != null) return d;
				if (s.weak) return 0;
				throw 'hxmc: link: undefined symbol $n';
			}
			if (t.abs) return t.offset;
			return addr.get(t.section) + t.offset;
		};
		// HXMC_MAP=<file>: the address of every symbol (debugging; no
		// symbol table is written in PE files)
		var mapFile = Sys.getEnv("HXMC_MAP");
		if (mapFile != null) {
			var m = new StringBuf();
			for (o in objs)
				for (s in o.symbols)
					if (s.section != null && addr.exists(s.section))
						m.add(StringTools.hex(addr.get(s.section) + s.offset, 8) + " " + s.name + "\n");
			sys.io.File.saveContent(mapFile, m.toString());
		}
		// the thunks: jmp [rip + IAT slot] (arm64: adrp, ldr, br)
		for (k => off in thunkOf)
			LinkCore.patchStub(thunks.buf, off, arm, iatAddr(k), addr.get(thunks) + off);
		// relocations
		imageBase = BASE;
		for (g in groups)
			for (s in g.secs)
				if (s.kind != Bss && s.kind != Tbss) applyRelocs(s);
		// base relocations (arm64 images must be relocatable): a block per page
		var relocBuf = new Buf(4096);
		if (relocatable && baseRelocs.length > 0) {
			baseRelocs.sort((a, b) -> a.rva - b.rva);
			var k = 0;
			while (k < baseRelocs.length) {
				var page = baseRelocs[k].rva & ~0xfff;
				var at = relocBuf.len;
				relocBuf.u32(page);
				relocBuf.u32(0);
				while (k < baseRelocs.length && (baseRelocs[k].rva & ~0xfff) == page) {
					relocBuf.u16((baseRelocs[k].type << 12) | (baseRelocs[k].rva & 0xfff));
					k++;
				}
				if ((relocBuf.len & 3) != 0) relocBuf.u16(0);
				relocBuf.set32(at + 4, relocBuf.len - at);
			}
			sizes[7] = relocBuf.len;
			imageSize = starts[7] + LinkCore.align(relocBuf.len, SECT);
		}
		// the file
		var out = new Buf(1 << 20);
		out.zeros(headers);
		var rawPos = new haxe.ds.Vector<Int>(groups.length), rawSize = new haxe.ds.Vector<Int>(groups.length);
		for (gi in 0...groups.length) {
			var g = groups[gi];
			if (g.name == ".bss" || sizes[gi] == 0) continue; // (none in the file)
			out.align(FILE);
			var at = out.len;
			rawPos[gi] = at;
			out.zeros(LinkCore.align(sizes[gi], FILE));
			rawSize[gi] = LinkCore.align(sizes[gi], FILE);
			if (g.name == ".idata") out.b.blit(at, idata.b, 0, idata.len) else if (g.name == ".reloc") out.b.blit(at, relocBuf.b, 0, relocBuf.len) else
				for (s in g.secs)
					if (s.kind != Bss && s.kind != Tbss) out.b.blit(at + addr.get(s) - BASE - starts[gi], s.buf.b, 0, s.buf.len);
			if (g.name == ".pdata") sortPdata(out, at, sizes[gi]);
		}
		// (-debug) the DWARF sections: discardable, named through the string table
		var strtab = new Buf(4096);
		strtab.u32(0);
		var debug = [];
		if (hasLines)
			for (d in Dwarf.sections(objs, r -> r.sym.section != null && addr.exists(r.sym.section), r -> symAddr(r.sym) + imgLo, imgHi)) {
				var name = "/" + strtab.len;
				strtab.str("." + d.name);
				strtab.u8(0);
				out.align(FILE);
				var at = out.len;
				out.buf(d.data);
				out.zeros(LinkCore.align(d.data.len, FILE) - d.data.len);
				debug.push({name: name, rva: imageSize, size: d.data.len, raw: at, rawSize: LinkCore.align(d.data.len, FILE)});
				imageSize += LinkCore.align(d.data.len, SECT);
			}
		// (`symbols`) the COFF symbol table of the code, then the string table
		var symOff = 0, nsyms = 0;
		if (symbols) {
			var syms = new Buf(1 << 16);
			codeSymbols(sy -> {
				var n = Bytes.ofString(sy.name);
				if (n.length <= 8) {
					syms.bytes(n);
					syms.zeros(8 - n.length);
				} else {
					syms.u32(0);
					syms.u32(strtab.len);
					strtab.bytes(n);
					strtab.u8(0);
				}
				syms.u32(addr.get(sy.section) + sy.offset - BASE - starts[0]);
				syms.u16(1); // .text, the first section
				syms.u16(0x20); // a function
				syms.u8(sy.global ? 2 : 3); // IMAGE_SYM_CLASS_EXTERNAL, _STATIC
				syms.u8(0);
				nsyms++;
			});
			symOff = out.len;
			out.buf(syms);
		}
		if (symbols || debug.length > 0) {
			strtab.set32(0, strtab.len);
			if (!symbols) symOff = out.len;
			out.buf(strtab);
		}
		// headers
		var h = new Buf(headers);
		h.u16(0x5a4d); // MZ
		h.zeros(58);
		h.u32(64); // e_lfanew
		h.u32(0x4550); // PE\0\0
		h.u16(arm ? 0xaa64 : 0x8664);
		var present = [for (gi in 0...groups.length) if (sizes[gi] > 0) gi];
		h.u16(present.length + debug.length);
		h.u32(0);
		h.u32(symOff); // PointerToSymbolTable (the string table follows the symbols)
		h.u32(nsyms);
		h.u16(240);
		h.u16((relocatable ? 0x0022 : 0x0023) | (dll ? 0x2000 : 0)); // (RELOCS_STRIPPED |) EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE (| DLL)
		h.u16(0x20b); // PE32+
		h.u8(14);
		h.u8(0);
		h.u32(rawSize[0]); // SizeOfCode
		h.u32(rawSize[1] + rawSize[2] + rawSize[3] + rawSize[4] + rawSize[5]); // SizeOfInitializedData
		h.u32(sizes[6]); // SizeOfUninitializedData
		var e = dll ? null : globals.get(entry);
		if (e == null && !dll) throw "hxmc: link: no entry point " + entry;
		h.u32(dll ? 0 : diag("ret42") ? addr.get(retEntry) - BASE : symAddr(e) - BASE); // (a DLL: none)
		h.u32(starts[0]); // BaseOfCode
		h.u64(BASE + imgLo, imgHi); // ImageBase
		h.u32(SECT);
		h.u32(FILE);
		h.u16(6);
		h.u16(0); // OS version
		h.u16(0);
		h.u16(0); // image version
		h.u16(6);
		h.u16(0); // subsystem version
		h.u32(0);
		h.u32(imageSize);
		h.u32(headers);
		h.u32(0); // checksum
		h.u16(3); // console
		// NX_COMPAT | TERMINAL_SERVER_AWARE (x86-64: no DYNAMIC_BASE, a fixed
		// image; arm64: DYNAMIC_BASE, with base relocations)
		h.u16(dll && !arm ? 0x8100 : relocatable ? (imgHi != 0 ? 0x8160 : 0x8140) : 0x8100); // (| HIGH_ENTROPY_VA above 4 GB; an x86-64 DLL: at its preferred base when free)
		h.u64(0x1000000, 0); // stack reserve
		h.u64(0x1000, 0);
		h.u64(0x100000, 0); // heap
		h.u64(0x1000, 0);
		h.u32(0);
		h.u32(16);
		// data directories
		var dirs = new haxe.ds.Vector<Array<Int>>(16);
		for (k in 0...16)
			dirs[k] = [0, 0];
		if (edata != null) dirs[0] = [addr.get(edata) - BASE, edata.buf.len];
		if (dlls.length > 0) {
			dirs[1] = [starts[5] + idataLayout.dir, 20 * (dlls.length + 1)];
			dirs[12] = [starts[5] + idataLayout.iatStart, idataLayout.iatSize];
		}
		if (sizes[2] > 0 && !diag("nopdata")) dirs[3] = [starts[2], sizes[2]];
		if (sizes[7] > 0) dirs[5] = [starts[7], sizes[7]];
		var tlsUsed = globals.get("_tls_used");
		if (tlsUsed != null && !diag("notls")) dirs[9] = [symAddr(tlsUsed) - BASE, 40];
		for (d in dirs) {
			h.u32(d[0]);
			h.u32(d[1]);
		}
		// section table
		for (gi in present) {
			var g = groups[gi];
			var nm = Bytes.alloc(8);
			nm.fill(0, 8, 0);
			nm.blit(0, Bytes.ofString(g.name), 0, g.name.length);
			h.bytes(nm);
			h.u32(sizes[gi]);
			h.u32(starts[gi]);
			h.u32(rawSize[gi]);
			h.u32(rawPos[gi]);
			h.u32(0);
			h.u32(0);
			h.u16(0);
			h.u16(0);
			h.u32(g.chars);
		}
		for (d in debug) {
			var nm = Bytes.alloc(8);
			nm.fill(0, 8, 0);
			nm.blit(0, Bytes.ofString(d.name), 0, d.name.length);
			h.bytes(nm);
			h.u32(d.size);
			h.u32(d.rva);
			h.u32(d.rawSize);
			h.u32(d.raw);
			h.zeros(12);
			h.u32(0x42000040); // INITIALIZED_DATA | DISCARDABLE | READ
		}
		out.b.blit(0, h.b, 0, h.len);
		return out.toBytes();
	}

	// ---- relocations

	var starts:haxe.ds.Vector<Int>; // the output sections' RVAs
	var relocatable = false;
	var baseRelocs:Array<{rva:Int, type:Int}> = [];

	// an absolute address of the image (a number: as it is): with the
	// image's base, and a base relocation when relocatable
	override function absolute(s:Section, r:Reloc, P:Int) {
		var v = symAddr(r.sym) + r.addend;
		if (r.kind == RAbs64) {
			if (isAbs(r.sym)) s.buf.set64(r.offset, v, v < 0 ? -1 : 0) else {
				s.buf.set64(r.offset, v + imgLo, imgHi);
				if (relocatable) baseRelocs.push({rva: P - BASE, type: 10});
			}
		} else {
			s.buf.set32(r.offset, v);
			if (!isAbs(r.sym)) {
				if (imgHi != 0) throw "hxmc: link: a 32-bit absolute address of " + r.sym.name + " (an image above 4 GB)";
				if (relocatable) baseRelocs.push({rva: P - BASE, type: 3});
			}
		}
	}

	function isAbs(sym:Symbol):Bool {
		var t = target(sym);
		// (linker-defined: addresses, but for the zero of an undefined weak symbol)
		return t != null ? t.abs : sym.name != "__ImageBase" && symAddr(sym) == 0;
	}

	// a thread-local variable: its offset in its output section (.tls)
	override function secRel(sym:Symbol):Int {
		var t = target(sym);
		var sec = t != null && t.section != null ? outOf.get(t.section) : -1;
		return symAddr(sym) - BASE - (sec >= 0 ? starts[sec] : 0);
	}

	// ---- dead sections (LinkCore.gc)

	// roots besides the entry, the other objects and the exports: the C
	// runtime's initializer, terminator and TLS callback lists (.CRT$X??,
	// .ctors, .dtors); the exception directory is no root (keepPdata)
	override function gcRoot(o:Obj, s:Section):Bool {
		if (isPdata(s)) return false;
		var n = s.name;
		return super.gcRoot(o, s) || StringTools.startsWith(n, ".CRT$") || n == ".ctors" || n == ".dtors" || StringTools.startsWith(n, ".ctors.")
			|| StringTools.startsWith(n, ".dtors.");
	}

	override function gcOpaque(s:Section):Bool
		return super.gcOpaque(s) || isPdata(s);

	// a kept function keeps its unwind information (.xdata, and the handlers it names)
	override function gcAlso(s:Section, mark:Section->Void) {
		var u = unwindOf.get(s);
		if (u != null)
			for (x in u)
				mark(x);
	}

	static inline function isPdata(s:Section):Bool
		return StringTools.startsWith(s.name, ".pdata");

	var unwindOf = new Map<Section, Array<Section>>();

	// the size of an exception directory entry: x86-64 begin, end, unwind
	// information; arm64 begin, unwind information (or packed)
	inline function pdataEntry():Int
		return arm ? 8 : 12;

	// what the objects' exception directory entries name for each function's
	// section: the sections of its unwind information
	function pdataLinks():Map<Section, Array<Section>> {
		var m = new Map<Section, Array<Section>>();
		var n = pdataEntry();
		for (o in objs)
			for (s in o.sections)
				if (isPdata(s)) {
					var fn = new Map<Int, Section>();
					for (r in s.relocs)
						if (r.offset % n == 0) {
							var t = target(r.sym);
							if (t != null && t.section != null) fn.set(Std.int(r.offset / n), t.section);
						}
					for (r in s.relocs) {
						var f = fn.get(Std.int(r.offset / n));
						var t = target(r.sym);
						if (f == null || t == null || t.section == null || t.section == f) continue;
						var l = m.get(f);
						if (l == null) m.set(f, l = []);
						if (l.indexOf(t.section) < 0) l.push(t.section);
					}
				}
		return m;
	}

	// the objects' exception directory entries of the functions kept (the
	// others' left out), their sections kept when any are
	function keepPdata() {
		var n = pdataEntry();
		for (o in objs)
			for (s in o.sections)
				if (isPdata(s)) {
					var byEntry = new Map<Int, Array<Reloc>>();
					for (r in s.relocs) {
						var k = Std.int(r.offset / n);
						var l = byEntry.get(k);
						if (l == null) byEntry.set(k, l = []);
						l.push(r);
					}
					var buf = new Buf(s.buf.len), relocs = [];
					for (k in 0...Std.int(s.buf.len / n)) {
						var l = byEntry.get(k);
						var first = l == null ? null : Lambda.find(l, r -> r.offset == k * n);
						var t = first == null ? null : target(first.sym);
						if (t == null || t.section == null || !live.exists(t.section)) continue;
						for (r in l)
							relocs.push(new Reloc(buf.len + r.offset - k * n, r.kind, r.sym, r.addend));
						buf.bytes(s.buf.b, k * n, n);
					}
					s.buf = buf;
					s.relocs = relocs;
					if (buf.len > 0) live.set(s, true);
				}
	}

	// the .pdata entries and .xdata of the generated functions (Unwind):
	// x86-64 (begin, end, unwind info), arm64 (begin, .xdata); a function
	// whose frame needs no description (a leaf leaving the stack alone) has
	// none. Identical unwind information is shared.
	function unwindInfo(extra:Obj) {
		var pdata = new Section(".pdata$hxmc", RoData, 4);
		var xdata = new Section(".xdata$hxmc", RoData, 4);
		var xsym = new Symbol(".Lxdata");
		xsym.global = false;
		xsym.section = xdata;
		var shared = new Map<String, Int>();
		for (o in objs)
			for (r in o.funcs) {
				if (r.sym.section == null || !isLive(r.sym.section)) continue;
				var u = arm ? Unwind.winA64(r.ops, r.sym.size) : Unwind.winX64(r.ops);
				if (u == null) continue;
				var key = u.toBytes().toHex();
				var at = shared.get(key);
				if (at == null) {
					at = xdata.buf.len;
					xdata.buf.buf(u);
					shared.set(key, at);
				}
				pdata.relocs.push(new Reloc(pdata.buf.len, RImgRel32, r.sym, 0));
				pdata.buf.u32(0);
				if (!arm) {
					pdata.relocs.push(new Reloc(pdata.buf.len, RImgRel32, r.sym, r.sym.size));
					pdata.buf.u32(0);
				}
				pdata.relocs.push(new Reloc(pdata.buf.len, RImgRel32, xsym, at));
				pdata.buf.u32(0);
			}
		if (pdata.buf.len == 0) return;
		extra.sections.push(pdata);
		extra.sections.push(xdata);
	}

	// the exception directory's entries in address order (each object's are,
	// the whole is not: the runtime object's and the generated functions')
	function sortPdata(out:Buf, at:Int, size:Int) {
		var n = arm ? 8 : 12;
		var entries = [for (k in 0...Std.int(size / n)) out.b.sub(at + k * n, n)];
		entries.sort((a, b) -> {
			var x = a.getInt32(0), y = b.getInt32(0);
			x < y ? -1 : x > y ? 1 : 0;
		});
		for (k in 0...entries.length)
			out.b.blit(at + k * n, entries[k], 0, n);
	}

	// the import directory, ILTs, IATs, hint/name entries and DLL names of
	// .idata at `rva`; iat: (dll + name) -> RVA of its IAT slot
	function importData(dlls:Array<String>, byDll:Map<String, Array<String>>, rva:Int) {
		var b = new Buf(4096);
		var dir = 0;
		b.zeros(20 * (dlls.length + 1));
		var n = 0;
		for (d in dlls)
			n += byDll.get(d).length + 1;
		// (the lookup and address tables hold 8-byte entries: aligned, which
		// the arm64 loader requires)
		b.align(8);
		var ilt = b.len;
		b.zeros(8 * n);
		var iatStart = b.len;
		b.zeros(8 * n);
		var iat = new Map<String, Int>();
		var k = 0;
		for (di in 0...dlls.length) {
			var d = dlls[di];
			var names = byDll.get(d);
			var first = k;
			for (name in names) {
				b.align(2);
				var hn = b.len;
				b.u16(0);
				b.str(name);
				b.u8(0);
				b.set64(ilt + 8 * k, rva + hn, 0);
				b.set64(iatStart + 8 * k, rva + hn, 0);
				iat.set(d + "\t" + name, rva + iatStart + 8 * k);
				k++;
			}
			k++; // the terminating zero entry
			var dn = b.len;
			b.str(d);
			b.u8(0);
			var e = dir + 20 * di;
			b.set32(e, rva + ilt + 8 * first);
			b.set32(e + 12, rva + dn);
			b.set32(e + 16, rva + iatStart + 8 * first);
		}
		return {buf: b, dir: dir, iat: iat, iatStart: iatStart, iatSize: 8 * n};
	}
}
