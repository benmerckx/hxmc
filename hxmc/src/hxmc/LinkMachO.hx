package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;
import hxmc.Abi;

// hxmc's linker for macOS and iOS: objects (the program's, the runtime object of
// MkRt.macho) -> a Mach-O executable (MH_EXECUTE, position-independent as
// arm64 macOS requires) that loads /usr/lib/libSystem.B.dylib, written
// without the SDK or ld64, or (-D hxmc.shared) a dylib (MH_DYLIB: the image
// at 0, no __PAGEZERO, dyld or LC_MAIN, its LC_ID_DYLIB and the exports,
// Abi.exports, in the export trie; hxmc dev's builds on macOS and iOS):
//   __PAGEZERO (4 GB), __TEXT (headers, code, import stubs, read-only data,
//   the generated functions' unwind tables in __eh_frame: Unwind), __DATA
//   (import slots, data with pointers, thread-local descriptors and
//   templates, zero-fill), with -debug __DWARF (Dwarf; read-only, nothing
//   reads it at run time), __LINKEDIT (dyld's rebase and bind opcodes, an
//   export trie, the symbol table of the imports, the code signature).
// Addresses are kept relative to the image (vm offset == file offset in
// __TEXT and __DATA); absolute pointers get BASE added and a rebase entry.
// Whatever the objects leave undefined is bound from libSystem (two-level
// namespace, ordinal 1) with its Mach-O name (`_` + the C name): calls go
// through a stub per function, address loads through slots in __got.
// arm64 executables must be signed: an ad-hoc, linker-signed code signature
// (a CodeDirectory of SHA-256 page hashes) ends __LINKEDIT.
// Thread-local variables: the runtime's descriptors (__thread_vars: thunk
// bound to _tlv_bootstrap, key, offset in the template) get their offsets
// here; generated code reaches a variable at its template offset from the
// thread's copy (hxmc_tls_base, through hxmc_tls_start, a descriptor of
// offset 0 defined here). Resolution, the slots and the relocations: LinkCore.
class LinkMachO extends LinkCore {
	static inline var BASE_HI = 1; // the image at 0x100000000 (above __PAGEZERO)
	static inline var HEADER_RESERVE = 0x1000; // load commands (padded)

	var abi:Abi;
	var PAGE:Int;

	public var symbols = false; // a symbol table of the code (profilers, debuggers)
	// the code signature (linker-signed by default; an app bundle's: hxmc.ios.Bundle)
	public var sign = new CodeSign();
	// iOS: the oldest version the output runs on (15.0: UILaunchScreen is
	// 14's, and 15 is the floor of current Xcodes and the App Store's
	// devices: A9 and later), and the SDK version it declares (18.0: the
	// App Store's minimum since 2025; a later one would ask for UIScene)
	public static inline var IOS_MIN = 0x000F0000;
	public static inline var IOS_SDK = 0x00120000;
	public var minos = IOS_MIN; // (iOS: -D hxmc.ios-min-version, hxmc.ios.Bundle)
	// imports from other dylibs than libSystem (@:hxmc.lib): symbol -> install name
	public var dylibs = new Map<String, String>();

	// a dylib (-D hxmc.shared): its install name
	public var installName = "";
	var dylib = false;
	// the high word of the image's addresses (an executable's at 4 GB, a dylib's at 0)
	var baseHi = BASE_HI;

	public function new(objs:Array<Obj>, abi:Abi) {
		super(objs, abi.arm);
		this.abi = abi;
		PAGE = abi.segAlign;
		dylib = abi.output == SharedLibrary;
		if (dylib) {
			baseHi = 0;
			sign.mainBinary = false;
		} else if (abi.output != Executable) throw "hxmc: " + abi.output + " output is not supported yet on macOS";
	}

	static function isBranch(k:RelKind):Bool
		return k == RCall32 || k == RA64Call26 || k == RA64Jump26;

	static function isTlvSection(s:Section):Bool
		return StringTools.endsWith(s.name, "__thread_vars");

	public function link(entry:String):Bytes {
		// __dso_handle (as ld64 defines it): the image's Mach-O header, the
		// start of __TEXT; libuv and mbedtls refer to it (atexit handlers).
		// Its section is not laid out: it is placed at 0 below.
		var header = new Section("__TEXT,__mach_header", RoData, 1);
		var dso = new Obj();
		dso.define("__dso_handle", header, 0, 0);
		objs.push(dso);
		resolve();
		// (the sections nothing reaches left out: LinkCore.gc; a dylib's exports are roots)
		if (dylib) roots = [for (n in abi.exports) if (globals.exists(n)) n];
		gc(entry);
		// imports: what stays undefined (by name), and whether each is weak
		var importWeak = new Map<String, Bool>();
		var importOrder:Array<String> = [];
		function imported(s:Symbol):Bool {
			if (target(s) != null) return false;
			if (!importWeak.exists(s.name)) {
				importWeak.set(s.name, s.weak);
				importOrder.push(s.name);
			} else if (!s.weak) importWeak.set(s.name, false);
			return true;
		}
		// the template-start descriptor (hxmc_tls_start), and the first
		// thread-local section it points at
		var tls = [for (o in objs) for (s in o.sections) if (s.kind == Tdata && isLive(s)) s].concat([for (o in objs) for (s in o.sections) if (s.kind == Tbss && isLive(s)) s]);
		var extra = new Obj();
		var tlv0 = new Section("__DATA,__thread_vars", Data, 8);
		if (tls.length > 0) {
			var start = new Symbol(".Ltls_start");
			start.global = false;
			start.section = tls[0];
			tlv0.buf.zeros(24);
			tlv0.relocs.push(new Reloc(0, RAbs64, extra.sym("_tlv_bootstrap"), 0));
			tlv0.relocs.push(new Reloc(16, RAbs64, start, 0));
			extra.sections.push(tlv0);
			extra.define("hxmc_tls_start", tlv0, 0, 24);
			// hxmc_tls_base: the address of this thread's copy of the template,
			// what the descriptor's thunk returns (it takes the descriptor in
			// rdi / x0): a tail call of it
			var base = new Section("__TEXT,__text", Text, 16);
			if (arm) {
				base.buf.u32(0x90000000); // adrp x0, hxmc_tls_start
				base.relocs.push(new Reloc(0, RA64AdrPage21, extra.sym("hxmc_tls_start"), 0));
				base.buf.u32(0x91000000); // add x0, x0, :lo12:hxmc_tls_start
				base.relocs.push(new Reloc(4, RA64AddLo12, extra.sym("hxmc_tls_start"), 0));
				base.buf.u32(0xF9400010); // ldr x16, [x0]
				base.buf.u32(0xD61F0200); // br x16
			} else {
				for (b in [0x48, 0x8D, 0x3D, 0, 0, 0, 0]) // lea rdi, [rip + hxmc_tls_start]
					base.buf.u8(b);
				base.relocs.push(new Reloc(3, RPc32, extra.sym("hxmc_tls_start"), -4));
				base.buf.u8(0xFF); // jmp qword [rdi]
				base.buf.u8(0x27);
			}
			extra.sections.push(base);
			extra.define("hxmc_tls_base", base, 0, base.buf.len);
		}
		var stubs = new Section("__TEXT,__stubs", Text, 16);
		got = new Section("__DATA,__got", Data, 8);
		extra.sections.push(stubs);
		extra.sections.push(got);
		keep(extra);
		if (tls.length > 0) {
			globals.set("hxmc_tls_start", extra.sym("hxmc_tls_start"));
			globals.set("hxmc_tls_base", extra.sym("hxmc_tls_base"));
		}
		// slots (gotKey) and stubs
		var stubOf = new Map<String, Int>();
		function stub(name:String):Int {
			var at = stubOf.get(name);
			if (at != null) return at;
			at = stubs.buf.len;
			stubOf.set(name, at);
			// (patched once the slots have addresses)
			if (arm) {
				stubs.buf.u32(0x90000010); // adrp x16, slot
				stubs.buf.u32(0xF9400210); // ldr x16, [x16, :lo12:slot]
				stubs.buf.u32(0xD61F0200); // br x16
			} else {
				stubs.buf.u8(0xff); // jmp [rip + slot]
				stubs.buf.u8(0x25);
				stubs.buf.u32(0);
			}
			return at;
		}
		var stubSlot = new Map<String, Int>();
		for (o in objs)
			for (s in o.sections)
				if (isLive(s))
					for (r in s.relocs) {
						var imp = imported(r.sym);
						if (LinkCore.isGotRel(r.kind)) slot(r.sym);
						else if (imp && r.kind != RAbs64) {
							// code (a call, or an address taken pc-relatively): the stub
							stub(r.sym.name);
							if (!stubSlot.exists(r.sym.name)) stubSlot.set(r.sym.name, slot(r.sym));
						}
					}
		// ---- layout
		var text = [], ro = [], roData = [], data = [], init = [], fini = [], tlv = [], tdata = [], tbss = [], bss = [];
		for (o in objs)
			for (s in o.sections) {
				if (!isLive(s)) continue;
				switch s.kind {
					case Text: if (s != stubs) text.push(s);
					case RoData:
						// read-only data with absolute addresses goes where dyld can write
						var abs = false;
						for (r in s.relocs)
							if (r.kind == RAbs64 || r.kind == RAbs32 || r.kind == RAbs32S) {
								var t = target(r.sym);
								if (t == null || !t.abs) abs = true;
							}
						if (abs) roData.push(s) else ro.push(s);
					case Data: if (isTlvSection(s)) tlv.push(s) else if (s != got) data.push(s);
					case InitArray: init.push(s);
					case FiniArray: fini.push(s);
					case Tdata: tdata.push(s);
					case Tbss: tbss.push(s);
					case Bss: bss.push(s);
				}
			}
		text.push(stubs);
		// the unwind tables (the system's unwinder and lldb find __eh_frame by name)
		var recs = [for (o in objs) for (r in o.funcs) if (r.sym.section != null && isLive(r.sym.section)) r];
		var eh = recs.length > 0 ? Unwind.ehFrame(recs, arm, "__TEXT,__eh_frame").sec : null;
		addr.set(header, 0);
		var pos = HEADER_RESERVE;
		function group(list:Array<Section>):{start:Int, end:Int} {
			if (list.length > 0) pos = LinkCore.align(pos, list[0].align);
			var start = pos;
			pos = place(list, pos);
			return {start: start, end: pos};
		}
		// __TEXT
		pos = LinkCore.align(pos, 16);
		var oText = group(text);
		var oConst = group(ro);
		var oEh = group(eh != null ? [eh] : []);
		var textEnd = LinkCore.align(pos, PAGE);
		// __DATA
		pos = textEnd;
		var dataStart = pos;
		var oGot = group([got]);
		var oDConst = group(roData);
		var oData = group(data);
		var oInit = group(init);
		var oFini = group(fini);
		var oTlv = group(tlv);
		pos = LinkCore.align(pos, 16);
		var oTdata = group(tdata);
		var dataFileEnd = pos;
		var oTbss = group(tbss);
		tlsStart = tdata.length > 0 ? addr.get(tdata[0]) : tbss.length > 0 ? addr.get(tbss[0]) : 0;
		var oBss = group(bss);
		var dataEnd = LinkCore.align(pos, PAGE);
		if (dataEnd == dataStart) dataEnd += PAGE;
		var stubAddr = addr.get(stubs);
		var gotAddr = addr.get(got);
		symAddr = function(s:Symbol):Int {
			var t = target(s);
			if (t == null) {
				var st = stubOf.get(s.name);
				if (st != null) return stubAddr + st;
				if (s.weak) return 0;
				throw 'hxmc: link: undefined symbol ${s.name}';
			}
			if (t.abs) return t.offset;
			return addr.get(t.section) + t.offset;
		};
		// the stubs, now that slots have addresses
		for (name => at in stubOf)
			LinkCore.patchStub(stubs.buf, at, arm, gotAddr + stubSlot.get(name), stubAddr + at);
		// (the thread-local descriptors: secRel)
		for (s in tlv) {
			var m = new Map<Int, Reloc>();
			for (r in s.relocs)
				m.set(r.offset, r);
			descRel.set(s, m);
		}
		// relocations; rebase and bind entries (absolute): the slots, then the sections
		for (at => s in gotHeld) {
			var t = target(s);
			if (t == null) binds.push({at: gotAddr + at, name: s.name, addend: 0});
			else if (t.abs) got.buf.set64(at, t.offset, 0);
			else {
				got.buf.set64(at, symAddr(s), baseHi);
				rebases.push(gotAddr + at);
			}
		}
		var all = text.concat(ro).concat(eh != null ? [eh] : []).concat(roData).concat(data).concat(init).concat(fini).concat(tlv).concat(tdata);
		for (s in all)
			applyRelocs(s);
		// ---- __LINKEDIT
		var le = new Buf(1 << 16);
		// rebase opcodes: runs of adjacent pointers
		rebases.sort((a, b) -> a - b);
		var rebaseOff = le.len;
		if (rebases.length > 0) {
			le.u8(0x11); // REBASE_OPCODE_SET_TYPE_IMM pointer
			var k = 0;
			while (k < rebases.length) {
				var n = 1;
				while (k + n < rebases.length && rebases[k + n] == rebases[k] + 8 * n)
					n++;
				le.u8(0x20 | (dylib ? 1 : 2)); // SET_SEGMENT_AND_OFFSET_ULEB __DATA (a dylib has no __PAGEZERO)
				uleb(le, rebases[k] - dataStart);
				le.u8(0x60); // DO_REBASE_ULEB_TIMES
				uleb(le, n);
				k += n;
			}
		}
		le.u8(0);
		le.align(8);
		var rebaseSize = le.len - rebaseOff;
		// bind opcodes (non-lazy: all at load)
		binds.sort((a, b) -> a.at - b.at);
		var bindOff = le.len;
		// the dylibs: libSystem (ordinal 1), then the others in order of use
		var libs = ["/usr/lib/libSystem.B.dylib"];
		var ordinal = new Map<String, Int>();
		for (name in importOrder) {
			var d = dylibs.get(name);
			if (d == null) {
				ordinal.set(name, 1);
				continue;
			}
			var k = libs.indexOf(d);
			if (k < 0) {
				k = libs.length;
				libs.push(d);
			}
			ordinal.set(name, k + 1);
		}
		if (binds.length > 0) {
			var curOrd = 1;
			le.u8(0x11); // BIND_OPCODE_SET_DYLIB_ORDINAL_IMM 1
			le.u8(0x51); // BIND_OPCODE_SET_TYPE_IMM pointer
			var cur = "";
			var curAddend = 0;
			for (b in binds) {
				var ord = ordinal.exists(b.name) ? ordinal.get(b.name) : 1;
				if (ord != curOrd) {
					if (ord < 16) le.u8(0x10 | ord) // BIND_OPCODE_SET_DYLIB_ORDINAL_IMM
					else {
						le.u8(0x20); // BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB
						uleb(le, ord);
					}
					curOrd = ord;
				}
				if (b.name != cur) {
					le.u8(0x40 | (importWeak.get(b.name) ? 1 : 0)); // SET_SYMBOL_TRAILING_FLAGS_IMM
					le.str("_" + b.name);
					le.u8(0);
					cur = b.name;
				}
				if (b.addend != curAddend) {
					le.u8(0x60); // SET_ADDEND_SLEB
					sleb(le, b.addend);
					curAddend = b.addend;
				}
				le.u8(0x70 | (dylib ? 1 : 2)); // SET_SEGMENT_AND_OFFSET_ULEB __DATA
				uleb(le, b.at - dataStart);
				le.u8(0x90); // DO_BIND
			}
		}
		le.u8(0);
		le.align(8);
		var bindSize = le.len - bindOff;
		// the export trie: __mh_execute_header at 0; a dylib's exports
		var exportOff = le.len;
		if (dylib) {
			var names = [for (n in abi.exports) if (target(entrySymOrNull(n)) != null) n];
			exportTrie(le, [for (n in names) {name: "_" + n, addr: symAddr(globals.get(n))}]);
		} else {
			le.u8(0); // root: not terminal
			le.u8(1); // one edge
			le.str("__mh_execute_header");
			le.u8(0);
			le.u8(23); // the child's offset in the trie (just after this byte)
			le.u8(2); // terminal: 2 bytes of information
			le.u8(0); // flags: regular
			le.u8(0); // address 0
			le.u8(0); // no children
		}
		le.align(8);
		var exportSize = le.len - exportOff;
		// the symbol table: (with `symbols`) the functions as locals, then the
		// imports (undefined, from ordinal 1)
		var strtab = new Buf(4096);
		strtab.u8(0x20);
		strtab.u8(0);
		var symtabOff = le.len;
		var nlocals = 0;
		if (symbols)
			codeSymbols(s -> {
				le.u32(strtab.len);
				strtab.str("_" + s.name);
				strtab.u8(0);
				le.u8(0x0e); // N_SECT, local
				le.u8(1); // __text
				le.u16(0);
				le.u64(addr.get(s.section) + s.offset, baseHi);
				nlocals++;
			});
		var nimports = 0;
		for (name in importOrder) {
			le.u32(strtab.len);
			strtab.str("_" + name);
			strtab.u8(0);
			le.u8(0x01); // N_UNDF | N_EXT
			le.u8(0);
			le.u16((ordinal.get(name) << 8) | (importWeak.get(name) ? 0x40 : 0));
			le.u64(0, 0);
			nimports++;
		}
		var nsyms = nlocals + nimports;
		var strOff = le.len;
		le.buf(strtab);
		le.align(16);
		var sigOffInLe = le.len;
		// (-debug) the DWARF sections, between __DATA and __LINKEDIT in the file
		var dwarf = Dwarf.sections(objs, r -> r.sym.section != null && addr.exists(r.sym.section), r -> symAddr(r.sym), baseHi);
		var dwarfOff = dataFileEnd > dataStart ? LinkCore.align(dataFileEnd, PAGE) : dataStart;
		var dwarfSize = 0;
		for (d in dwarf)
			dwarfSize += d.data.len;
		// ---- the file
		var leFileOff = dwarf.length > 0 ? LinkCore.align(dwarfOff + dwarfSize, PAGE) : dwarfOff;
		// (__DWARF, read-only, mapped between __DATA and __LINKEDIT: its sections
		// have addresses, as dsymutil's)
		var dwarfVm = dataEnd;
		var leVm = dataEnd + LinkCore.align(dwarfSize, PAGE);
		var sigLen = sign.size(leFileOff + sigOffInLe);
		var fileSize = leFileOff + sigOffInLe + sigLen;
		var out = new Buf(fileSize + 16);
		out.zeros(fileSize);
		for (s in text.concat(ro).concat(eh != null ? [eh] : []).concat(roData).concat(data).concat(init).concat(fini).concat(tlv).concat(tdata).concat([got]))
			out.b.blit(addr.get(s), s.buf.b, 0, s.buf.len);
		var dsects = [], dwarfAddr = [];
		var at = dwarfOff;
		for (d in dwarf) {
			out.b.blit(at, d.data.b, 0, d.data.len);
			dsects.push({name: "__" + d.name, start: at, end: at + d.data.len, flags: 0x02000000, zerofill: false, align: 1}); // S_ATTR_DEBUG
			dwarfAddr.push(dwarfVm + at - dwarfOff);
			at += d.data.len;
		}
		out.b.blit(leFileOff, le.b, 0, le.len);
		// load commands
		var h = new Buf(HEADER_RESERVE);
		h.u32(0xfeedfacf);
		h.u32(arm ? 0x0100000c : 0x01000007);
		h.u32(arm ? 0 : 3);
		h.u32(dylib ? 6 : 2); // MH_DYLIB, MH_EXECUTE
		var ncmdsAt = h.len;
		h.u32(0);
		h.u32(0); // sizeofcmds
		// NOUNDEFS | DYLDLINK | TWOLEVEL | PIE (a dylib: NO_REEXPORTED_DYLIBS
		// instead) (| HAS_TLV_DESCRIPTORS: dyld sets up the descriptors of
		// __thread_vars only with it)
		h.u32((dylib ? 0x00100085 : 0x00200085) | (tlv.length > 0 ? 0x00800000 : 0));
		h.u32(0);
		var ncmds = 0;
		function seg(name:String, vm:Int, vmsize:Int, fileoff:Int, filesize:Int, prot:Int, sects:Array<{name:String, start:Int, end:Int, flags:Int, zerofill:Bool, align:Int}>) {
			ncmds++;
			var live = [for (x in sects) if (x.end > x.start || x.name == "__text") x];
			h.u32(0x19);
			h.u32(72 + 80 * live.length);
			fixed(h, name, 16);
			h.u64(vm, name == "__PAGEZERO" ? 0 : baseHi);
			h.u64(vmsize, name == "__PAGEZERO" ? 1 : 0);
			var k = 0;
			h.u64(fileoff, 0);
			h.u64(filesize, 0);
			h.u32(prot);
			h.u32(prot);
			h.u32(live.length);
			h.u32(0);
			for (x in live) {
				fixed(h, x.name, 16);
				fixed(h, name, 16);
				h.u64(name == "__DWARF" ? dwarfAddr[k++] : x.start, baseHi);
				h.u64(x.end - x.start, 0);
				h.u32(x.zerofill ? 0 : x.start);
				h.u32(log2(x.align));
				h.u32(0);
				h.u32(0);
				h.u32(x.flags);
				h.u32(0);
				h.u32(0);
				h.u32(0);
			}
		}
		inline function sec(name, o:{start:Int, end:Int}, flags, zerofill = false, al = 16)
			return {name: name, start: o.start, end: o.end, flags: flags, zerofill: zerofill, align: al};
		if (!dylib) seg("__PAGEZERO", 0, 0, 0, 0, 0, []);
		seg("__TEXT", 0, textEnd, 0, textEnd, 5, [
			sec("__text", {start: oText.start, end: addr.get(stubs) + stubs.size()}, 0x80000400),
			sec("__const", oConst, 0),
			sec("__eh_frame", oEh, 0x6800000b, false, 8)
		]);
		seg("__DATA", dataStart, dataEnd - dataStart, dataStart, dataFileEnd - dataStart, 3, [
			sec("__got", oGot, 0, false, 8),
			sec("__const", oDConst, 0),
			sec("__data", oData, 0),
			sec("__mod_init_func", oInit, 9, false, 8),
			sec("__mod_term_func", oFini, 0xa, false, 8),
			sec("__thread_vars", oTlv, 0x13, false, 8),
			sec("__thread_data", oTdata, 0x11),
			sec("__thread_bss", oTbss, 0x12, true),
			sec("__bss", oBss, 1, true)
		]);
		if (dwarf.length > 0) seg("__DWARF", dwarfVm, leVm - dwarfVm, dwarfOff, dwarfSize, 1, dsects);
		seg("__LINKEDIT", leVm, LinkCore.align(sigOffInLe + sigLen, PAGE), leFileOff, sigOffInLe + sigLen, 1, []);
		// dyld info
		ncmds++;
		h.u32(0x80000022);
		h.u32(48);
		h.u32(leFileOff + rebaseOff);
		h.u32(rebaseSize);
		h.u32(leFileOff + bindOff);
		h.u32(bindSize);
		h.u32(0);
		h.u32(0);
		h.u32(0);
		h.u32(0);
		h.u32(leFileOff + exportOff);
		h.u32(exportSize);
		// symbol tables
		ncmds++;
		h.u32(0x2);
		h.u32(24);
		h.u32(leFileOff + symtabOff);
		h.u32(nsyms);
		h.u32(leFileOff + strOff);
		h.u32(strtab.len);
		ncmds++;
		h.u32(0xb);
		h.u32(80);
		h.u32(0); // ilocalsym
		h.u32(nlocals);
		h.u32(nlocals); // iextdefsym
		h.u32(0);
		h.u32(nlocals); // iundefsym
		h.u32(nimports);
		for (_ in 0...12)
			h.u32(0);
		// the dynamic linker (a dylib: its identity instead)
		if (dylib) {
			ncmds++;
			var id = installName;
			var il = LinkCore.align(24 + id.length + 1, 8);
			h.u32(0xd); // LC_ID_DYLIB
			h.u32(il);
			h.u32(24);
			h.u32(2); // timestamp
			h.u32(0x00010000); // current version 1.0.0
			h.u32(0x00010000); // compatibility 1.0.0
			fixed(h, id, il - 24);
		} else {
			ncmds++;
			var dyld = "/usr/lib/dyld";
			var dl = LinkCore.align(12 + dyld.length + 1, 8);
			h.u32(0xe);
			h.u32(dl);
			h.u32(12);
			fixed(h, dyld, dl - 12);
		}
		// UUID (filled below)
		ncmds++;
		h.u32(0x1b);
		h.u32(24);
		var uuidAt = h.len;
		h.zeros(16);
		// build version: macOS, minimum 11.0 (arm64) / 10.15 (x86-64); iOS
		// and its simulator (abi.platform), minimum IOS_MIN, built against
		// IOS_SDK (what UIKit's linked-on-or-after behaviours go by)
		ncmds++;
		var minos = abi.ios() ? this.minos : arm ? 0x000B0000 : 0x000A0F00;
		h.u32(0x32);
		h.u32(32);
		h.u32(abi.platform == "ios" ? 2 : abi.platform == "ios-simulator" ? 7 : 1); // PLATFORM_IOS, PLATFORM_IOSSIMULATOR, PLATFORM_MACOS
		h.u32(minos);
		h.u32(abi.ios() ? IOS_SDK : minos); // sdk
		h.u32(1);
		h.u32(3); // TOOL_LD
		h.u32(0x00010000);
		// main
		if (!dylib) {
			ncmds++;
			var e = target(entrySym(entry));
			h.u32(0x80000028);
			h.u32(24);
			h.u64(symAddr(e), 0);
			h.u64(0, 0);
		}
		// libSystem
		ncmds++;
		var lib = "/usr/lib/libSystem.B.dylib";
		var ll = LinkCore.align(24 + lib.length + 1, 8);
		h.u32(0xc);
		h.u32(ll);
		h.u32(24);
		h.u32(2);
		h.u32(0x05276403); // current version 1319.100.3
		h.u32(0x00010000); // compatibility 1.0.0
		fixed(h, lib, ll - 24);
		// the other dylibs (@:hxmc.lib); @rpath/ names are looked for next to the executable
		var rpath = false;
		for (k in 1...libs.length) {
			var d = libs[k];
			if (StringTools.startsWith(d, "@rpath/")) rpath = true;
			ncmds++;
			var dl = LinkCore.align(24 + d.length + 1, 8);
			h.u32(0xc);
			h.u32(dl);
			h.u32(24);
			h.u32(2);
			h.u32(0);
			h.u32(0);
			fixed(h, d, dl - 24);
		}
		if (rpath) {
			ncmds++;
			var r = "@executable_path";
			var rl = LinkCore.align(12 + r.length + 1, 8);
			h.u32(0x8000001c); // LC_RPATH
			h.u32(rl);
			h.u32(12);
			fixed(h, r, rl - 12);
		}
		// the code signature
		ncmds++;
		h.u32(0x1d);
		h.u32(16);
		h.u32(leFileOff + sigOffInLe);
		h.u32(sigLen);
		if (h.len > HEADER_RESERVE) throw "hxmc: link: Mach-O load commands too large";
		h.set32(ncmdsAt, ncmds);
		h.set32(ncmdsAt + 4, h.len - 32);
		out.b.blit(0, h.b, 0, h.len);
		// UUID: a digest of the file (with a zero UUID), as a version-4 UUID
		var digest = haxe.crypto.Md5.make(out.b.sub(0, leFileOff + sigOffInLe));
		digest.set(6, (digest.get(6) & 0x0f) | 0x40);
		digest.set(8, (digest.get(8) & 0x3f) | 0x80);
		out.b.blit(uuidAt, digest, 0, 16);
		// the signature (CodeSign: linker-signed, or a bundle's)
		var codeLimit = leFileOff + sigOffInLe;
		var sig = sign.sign(out.b, codeLimit, textEnd);
		out.b.blit(codeLimit, sig, 0, sig.length);
		return out.toBytes();
	}

	// ---- the slots: by target (a defined symbol: a global's name, a local
	// itself), or an import's name; what each holds, filled at load time
	// (rebase or bind entries)
	var slotKeys = new Map<String, Symbol>();
	var gotHeld = new Map<Int, Symbol>(); // offset -> the symbol it holds

	override function gotKey(s:Symbol):Symbol {
		var t = target(s);
		if (t != null && !t.global) return t;
		var k = (t == null ? "imp:" : "sym:") + s.name;
		var c = slotKeys.get(k);
		if (c == null) slotKeys.set(k, c = s);
		return c;
	}

	override function gotFill(at:Int, key:Symbol, s:Symbol)
		gotHeld.set(at, s);

	// ---- relocations

	var rebases:Array<Int> = [];
	var binds:Array<{at:Int, name:String, addend:Int}> = [];
	var tlsStart = 0;
	// the thread-local descriptors' relocations by offset (descRel)
	var descRel = new Map<Section, Map<Int, Reloc>>();

	// the thread-local template offset of a variable: its descriptor's
	// third word refers to its storage
	override function secRel(s:Symbol):Int {
		var t = target(s);
		if (t == null || t.section == null || !descRel.exists(t.section)) throw "hxmc: link: " + s.name + " is not a thread-local variable";
		var r = descRel.get(t.section).get(t.offset + 16);
		if (r == null) throw "hxmc: link: no storage for the thread-local variable " + s.name;
		return symAddr(r.sym) + r.addend - tlsStart;
	}

	// an absolute address: a descriptor's offset in the template, an
	// import's (bound), a number, or an address in the image (rebased)
	override function absolute(s:Section, r:Reloc, P:Int) {
		var buf = s.buf, A = r.addend;
		var t = target(r.sym);
		if (r.kind != RAbs64) {
			if (t == null || !t.abs) throw "hxmc: link: a 32-bit absolute address of " + r.sym.name + " (position-independent output)";
			buf.set32(r.offset, t.offset + A);
		} else if (isTlvSection(s) && r.offset % 24 == 16) {
			buf.set64(r.offset, symAddr(r.sym) + A - tlsStart, 0);
		} else if (t == null) {
			buf.set64(r.offset, 0, 0);
			binds.push({at: P, name: r.sym.name, addend: A});
		} else if (t.abs) {
			var v = t.offset + A;
			buf.set64(r.offset, v, v < 0 ? -1 : 0);
		} else {
			buf.set64(r.offset, symAddr(r.sym) + A, baseHi);
			rebases.push(P);
		}
	}

	function entrySymOrNull(name:String):Null<Symbol> {
		var s = globals.get(name);
		return s == null ? new Symbol(name) : s;
	}

	// an export trie of these names (with their `_`) at their addresses:
	// the root's edges, one per name, each to a terminal node
	static function exportTrie(le:Buf, items:Array<{name:String, addr:Int}>) {
		inline function ulebLen(v:Int):Int {
			var n = 1;
			while (v >= 0x80) {
				v >>>= 7;
				n++;
			}
			return n;
		}
		// (the children's offsets, and so the root's size, until stable)
		var rootSize = 2;
		var offs = new haxe.ds.Vector<Int>(items.length);
		for (_ in 0...4) {
			var at = rootSize;
			for (k in 0...items.length) {
				offs[k] = at;
				at += 1 + 1 + ulebLen(items[k].addr) + 1; // terminal size, flags, address, no children
			}
			var size = 2;
			for (k in 0...items.length)
				size += haxe.io.Bytes.ofString(items[k].name).length + 1 + ulebLen(offs[k]);
			if (size == rootSize) break;
			rootSize = size;
		}
		le.u8(0); // root: not terminal
		le.u8(items.length);
		for (k in 0...items.length) {
			le.str(items[k].name);
			le.u8(0);
			uleb(le, offs[k]);
		}
		for (it in items) {
			le.u8(1 + ulebLen(it.addr));
			le.u8(0); // flags: regular
			uleb(le, it.addr);
			le.u8(0);
		}
	}

	static function log2(v:Int):Int {
		var k = 0;
		while ((1 << k) < v)
			k++;
		return k;
	}

	static function fixed(h:Buf, s:String, n:Int) {
		var b = Bytes.ofString(s);
		if (b.length > n) throw "hxmc: link: name too long: " + s;
		h.bytes(b);
		h.zeros(n - b.length);
	}

	static function uleb(b:Buf, v:Int) {
		while (true) {
			var c = v & 0x7f;
			v >>>= 7;
			if (v != 0) b.u8(c | 0x80) else {
				b.u8(c);
				return;
			}
		}
	}

	static function sleb(b:Buf, v:Int) {
		while (true) {
			var c = v & 0x7f;
			v >>= 7;
			if ((v == 0 && (c & 0x40) == 0) || (v == -1 && (c & 0x40) != 0)) {
				b.u8(c);
				return;
			}
			b.u8(c | 0x80);
		}
	}
}

// big-endian words over a Buf (code signatures)
class BeBuf {
	public var b = new Buf(1 << 16);

	public function new() {}

	public inline function u8(v:Int)
		b.u8(v);

	public function u32(v:Int) {
		b.u8(v >>> 24);
		b.u8((v >> 16) & 0xff);
		b.u8((v >> 8) & 0xff);
		b.u8(v & 0xff);
	}

	public function u64(v:Int) {
		u32(v < 0 ? -1 : 0);
		u32(v);
	}

	public inline function toBytes():haxe.io.Bytes
		return b.toBytes();
}
