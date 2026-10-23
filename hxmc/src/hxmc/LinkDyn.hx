package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;
import hxmc.Abi;
import hxmc.Link.SecHdr;

// hxmc's linker for dynamically linked Linux executables (-D hxmc.libc=glibc,
// Abi.interp): what Link does for a static one (resolution, dead code, the
// three loadable segments, local-exec TLS, ET_EXEC at a fixed address), plus
// what ld.so needs to bind the C library at load time, as a C toolchain's
// linker writes it for a position-dependent executable:
//   PT_PHDR, PT_INTERP (the program interpreter), PT_DYNAMIC; .dynsym,
//   .dynstr, .hash (DT_HASH), .gnu.version and .gnu.version_r (the symbol
//   versions the imports need, per library), .rela.dyn; DT_NEEDED per
//   library; DT_FLAGS BIND_NOW and DT_FLAGS_1 NOW: everything is bound
//   before the program starts (no PLT, no lazy binding, no TEXTREL).
// The imports are what the objects leave undefined and the runtime object's
// table names (.hxmc.imports, hxmc/deps/mkrt.sh: library, name, version,
// kind, size, aliases), and the program's own C functions of shared libraries
// (@:hxmc.lib, `libs`). Functions are called through a slot of the GOT each
// (R_*_GLOB_DAT), through a stub (jmp [slot]) for direct calls; a function's
// address stored in data is an R_*_64 relocation (such read-only data moves to
// the writable segment); a variable (environ) is copied into the executable
// (R_*_COPY, as for any position-dependent executable), with its aliases
// defined there too, so that the library's own references reach the copy.
// The start: a generated _start calls __libc_start_main(main, argc, argv,
// init, fini = 0, rtld_fini, stack_end), so glibc sets up TLS, stdio, locale
// and IFUNCs before main; init runs .init_array and registers .fini_array
// with __cxa_atexit (the same on glibc before and after 2.34). Section
// headers are written for the tools (readelf, objdump -T).
//
// A shared library (Abi.output SharedLibrary: Android's lib<name>.so, -D
// hxmc.shared in the glibc mode) is the same at address 0 (ET_DYN), without
// PT_INTERP, _start or copies: an absolute address in data is an
// R_*_RELATIVE relocation (such read-only data moves to the writable
// segment), a variable of a library is reached through a GOT slot (the
// address computation that names it, adrp+add or lea, becomes a load of
// the slot: the reverse of a linker's GOT relaxation), thread-locals through
// TLSDESC (hxmc_tls_base: the module's block for this thread, a 16-byte
// GOT pair with R_*_TLSDESC; Abi.tls Desc), and the names of Abi.exports are
// defined in .dynsym (with DT_SONAME). The section headers are the loader's
// too: Bionic finds .dynamic and .dynstr through them.
class LinkDyn extends Link {
	var abi:Abi;
	var shared:Bool;
	// a shared library's DT_SONAME (null: none)
	public var soname:Null<String> = null;
	// the exports left out when nothing defines them (Android's
	// ANativeActivity_onCreate in a lib<name>.so that is not an app's)
	public var optional:Array<String> = [];
	// the program's imports from shared libraries (@:hxmc.lib): name -> file
	public var libs = new Map<String, String>();
	// DT_RUNPATH $ORIGIN: a library looked for next to the executable
	public var origin = false;

	var imports = new Map<String, Imp>();
	var used:Array<Imp> = [];
	// the linker's own names (Link.link defines them; __dso_handle: below)
	static final LINKER = ["__init_array_start", "__init_array_end", "__fini_array_start", "__fini_array_end", "_end", "end", "_DYNAMIC", "__ehdr_start"];

	public function new(objs:Array<Obj>, abi:Abi) {
		super(objs, abi);
		this.abi = abi;
			shared = abi.output == SharedLibrary;
			tlsGd = abi.android && !abi.arm;
		}

	// the runtime objects' import tables (dropped from the output)
	function readImports() {
		for (o in objs) {
			var keep = [];
			for (s in o.sections)
				if (s.name == ".hxmc.imports") {
					for (l in s.buf.toBytes().toString().split("\n")) {
						var f = l.split("\t");
						if (f.length < 5) continue;
						imports.set(f[1], {
							name: f[1], lib: f[0], version: abi.versioned && f[2] != "" ? f[2] : null, object: f[3] == "object", size: Std.parseInt(f[4]),
							aliases: f.length > 5 && f[5] != "" ? f[5].split(",") : [], sym: new Symbol(f[1]), stub: -1, copyAt: -1, index: 0, vers: 0, alias: false
						});
					}
				} else keep.push(s);
			o.sections = keep;
		}
		// the program's own: unversioned unless the table names the same library
		for (n => lib in libs) {
			var t = imports.get(n);
			if (t != null && t.lib == lib) continue;
			imports.set(n, {name: n, lib: lib, version: null, object: false, size: 0, aliases: [], sym: new Symbol(n), stub: -1, copyAt: -1, index: 0, vers: 0, alias: false});
		}
	}

	override function undefKey(s:Symbol):Symbol {
		var i = imports.get(s.name);
		return i != null ? i.sym : s;
	}

	// _start, the init and fini of __libc_start_main, __dso_handle
	function startObj(hasFini:Bool):Obj {
		var o = new Obj();
		var t = new Section(".text.hxmc.start", Text, 16);
		var b = t.buf;
		function rel(kind:RelKind, name:String, add = 0)
			t.relocs.push(new Reloc(b.len, kind, o.sym(name), add));
		function bytes(a:Array<Int>)
			for (x in a)
				b.u8(x);
		inline function w(x:Int)
			b.u32(x);
		var start = 0, init = 0, fini = 0, initEnd = 0, finiEnd = 0;
		if (arm) {
			start = b.len;
			for (x in [0xd280001d, 0xd280001e, 0xaa0003e5, 0xf94003e1, 0x910023e2, 0x910003e6]) w(x);
			rel(RA64AdrPage21, "main"); w(0x90000000);
			rel(RA64AddLo12, "main"); w(0x91000000);
			rel(RA64AdrPage21, "hxmc_init"); w(0x90000003);
			rel(RA64AddLo12, "hxmc_init"); w(0x91000063);
			w(0xd2800004);
			rel(RA64GotPage21, "__libc_start_main"); w(0x90000010);
			rel(RA64GotLo12, "__libc_start_main"); w(0xf9400210);
			w(0xd63f0200);
			w(0xd4200000);
			init = b.len;
			for (x in [0xa9bc7bfd, 0x910003fd, 0xa90153f3, 0xa9025bf5, 0xf9001bf7, 0xaa0003f5, 0xaa0103f6, 0xaa0203f7]) w(x);
			rel(RA64AdrPage21, "__init_array_start"); w(0x90000013);
			rel(RA64AddLo12, "__init_array_start"); w(0x91000273);
			rel(RA64AdrPage21, "__init_array_end"); w(0x90000014);
			rel(RA64AddLo12, "__init_array_end"); w(0x91000294);
			var loop = b.len;
			w(0xeb14027f);
			var bhs = b.len;
			w(0x54000002); // b.hs done
			for (x in [0xaa1503e0, 0xaa1603e1, 0xaa1703e2, 0xf8408670, 0xd63f0200]) w(x);
			w(0x14000000 | (((loop - b.len) >> 2) & 0x3ffffff));
			b.set32(bhs, 0x54000002 | ((((b.len - bhs) >> 2) & 0x7ffff) << 5));
			if (hasFini) {
				rel(RA64AdrPage21, "hxmc_fini"); w(0x90000000);
				rel(RA64AddLo12, "hxmc_fini"); w(0x91000000);
				w(0xd2800001);
				w(0xd2800002);
				rel(RA64GotPage21, "__cxa_atexit"); w(0x90000010);
				rel(RA64GotLo12, "__cxa_atexit"); w(0xf9400210);
				w(0xd63f0200);
			}
			for (x in [0xf9401bf7, 0xa9425bf5, 0xa94153f3, 0xa8c47bfd, 0xd65f03c0]) w(x);
			initEnd = b.len;
			if (hasFini) {
				fini = b.len;
				for (x in [0xa9be7bfd, 0x910003fd, 0xa90153f3]) w(x);
				rel(RA64AdrPage21, "__fini_array_end"); w(0x90000013);
				rel(RA64AddLo12, "__fini_array_end"); w(0x91000273);
				rel(RA64AdrPage21, "__fini_array_start"); w(0x90000014);
				rel(RA64AddLo12, "__fini_array_start"); w(0x91000294);
				var loop = b.len;
				w(0xeb14027f);
				var bls = b.len;
				w(0x54000009); // b.ls done
				w(0xf85f8e70); // ldr x16, [x19, #-8]!
				w(0xd63f0200);
				w(0x14000000 | (((loop - b.len) >> 2) & 0x3ffffff));
				b.set32(bls, 0x54000009 | ((((b.len - bls) >> 2) & 0x7ffff) << 5));
				for (x in [0xa94153f3, 0xa8c27bfd, 0xd65f03c0]) w(x);
				finiEnd = b.len;
			}
		} else {
			start = b.len;
			bytes([0x31, 0xED, 0x49, 0x89, 0xD1, 0x5E, 0x48, 0x89, 0xE2, 0x48, 0x83, 0xE4, 0xF0, 0x50, 0x54, 0x45, 0x31, 0xC0]);
			bytes([0x48, 0x8D, 0x0D]); rel(RPc32, "hxmc_init", -4); w(0);
			bytes([0x48, 0x8D, 0x3D]); rel(RPc32, "main", -4); w(0);
			bytes([0xFF, 0x15]); rel(RGotPcRel32, "__libc_start_main", -4); w(0);
			bytes([0xF4]);
			b.align(16, 0xCC);
			init = b.len;
			bytes([0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x49, 0x89, 0xFC, 0x49, 0x89, 0xF5, 0x49, 0x89, 0xD6]);
			bytes([0x48, 0x8D, 0x1D]); rel(RPc32, "__init_array_start", -4); w(0);
			bytes([0x4C, 0x8D, 0x3D]); rel(RPc32, "__init_array_end", -4); w(0);
			var loop = b.len;
			bytes([0x4C, 0x39, 0xFB, 0x73, 0]);
			var jae = b.len;
			bytes([0x4C, 0x89, 0xE7, 0x4C, 0x89, 0xEE, 0x4C, 0x89, 0xF2, 0xFF, 0x13, 0x48, 0x83, 0xC3, 0x08, 0xEB]);
			b.u8((loop - (b.len + 1)) & 0xff);
			b.set8(jae - 1, b.len - jae);
			if (hasFini) {
				bytes([0x48, 0x8D, 0x3D]); rel(RPc32, "hxmc_fini", -4); w(0);
				bytes([0x31, 0xF6, 0x31, 0xD2, 0xFF, 0x15]); rel(RGotPcRel32, "__cxa_atexit", -4); w(0);
			}
			bytes([0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5B, 0xC3]);
			initEnd = b.len;
			if (hasFini) {
				b.align(16, 0xCC);
				fini = b.len;
				bytes([0x53, 0x41, 0x57, 0x41, 0x56]);
				bytes([0x48, 0x8D, 0x1D]); rel(RPc32, "__fini_array_end", -4); w(0);
				bytes([0x4C, 0x8D, 0x3D]); rel(RPc32, "__fini_array_start", -4); w(0);
				var loop = b.len;
				bytes([0x4C, 0x39, 0xFB, 0x76, 0]);
				var jbe = b.len;
				bytes([0x48, 0x83, 0xEB, 0x08, 0xFF, 0x13, 0xEB]);
				b.u8((loop - (b.len + 1)) & 0xff);
				b.set8(jbe - 1, b.len - jbe);
				bytes([0x41, 0x5E, 0x41, 0x5F, 0x5B, 0xC3]);
				finiEnd = b.len;
			}
		}
		o.sections.push(t);
		// (and what their prologues and epilogues do: Unwind; _start is the outermost frame)
		o.funcs.push(new FuncRec(o.define("_start", t, start, init - start), core.ds.VectorTools.vector(Unwind.ENTRY, 0, 0, 0)));
		var U = Unwind;
		var initOps = [], finiOps = [];
		function op(ops:Array<Int>, kind:Int, at:Int, x = 0, y = 0) {
			ops.push(kind);
			ops.push(at);
			ops.push(x);
			ops.push(y);
		}
		if (arm) {
			var e = initEnd - init - 20;
			for (x in [[U.SAVEFPLR, 4, 64, 0], [U.SETFP, 8, 0, 0], [U.SAVE, 12, 19, 16], [U.SAVE, 12, 20, 24], [U.SAVE, 16, 21, 32], [U.SAVE, 16, 22, 40],
				[U.SAVE, 20, 23, 48], [U.ENDPROLOGUE, 20, 0, 0], [U.EPILOGUE, e, 0, 0], [U.RESTOREFPLR, e + 16, 64, 0], [U.RET, e + 20, 0, 0]])
				op(initOps, x[0], x[1], x[2], x[3]);
			var e = finiEnd - fini - 12;
			for (x in [[U.SAVEFPLR, 4, 32, 0], [U.SETFP, 8, 0, 0], [U.SAVE, 12, 19, 16], [U.SAVE, 12, 20, 24], [U.ENDPROLOGUE, 12, 0, 0], [U.EPILOGUE, e, 0, 0],
				[U.RESTOREFPLR, e + 8, 32, 0], [U.RET, e + 12, 0, 0]])
				op(finiOps, x[0], x[1], x[2], x[3]);
		} else {
			// push rbx, r12, r13, r14, r15; pop them, ret
			var e = initEnd - init - 10;
			for (x in [[U.PUSH, 1, 3], [U.PUSH, 3, 12], [U.PUSH, 5, 13], [U.PUSH, 7, 14], [U.PUSH, 9, 15], [U.ENDPROLOGUE, 9, 0], [U.EPILOGUE, e, 0],
				[U.POP, e + 2, 15], [U.POP, e + 4, 14], [U.POP, e + 6, 13], [U.POP, e + 8, 12], [U.POP, e + 9, 3], [U.RET, e + 10, 0]])
				op(initOps, x[0], x[1], x[2]);
			// push rbx, r15, r14; pop r14, r15, rbx, ret
			var e = finiEnd - fini - 6;
			for (x in [[U.PUSH, 1, 3], [U.PUSH, 3, 15], [U.PUSH, 5, 14], [U.ENDPROLOGUE, 5, 0], [U.EPILOGUE, e, 0], [U.POP, e + 2, 14], [U.POP, e + 4, 15],
				[U.POP, e + 5, 3], [U.RET, e + 6, 0]])
				op(finiOps, x[0], x[1], x[2]);
		}
		o.funcs.push(new FuncRec(o.define("hxmc_init", t, init, initEnd - init, false), haxe.ds.Vector.fromArrayCopy(initOps)));
		if (hasFini) o.funcs.push(new FuncRec(o.define("hxmc_fini", t, fini, finiEnd - fini, false), haxe.ds.Vector.fromArrayCopy(finiOps)));
		// (atexit, libc_nonshared's, passes its value to __cxa_atexit)
		var d = new Section(".data.hxmc.dso_handle", Data, 8);
		d.buf.u64(0, 0);
		o.sections.push(d);
		o.define("__dso_handle", d, 0, 8, true);
		return o;
	}

	// a shared library's: __dso_handle (hidden, for __cxa_atexit), and with
	// thread-locals hxmc_tls_base, the address of this thread's copy of the
	// module's TLS block (generated code calls it once per function: Abi.tls
	// Desc), through the pair .data.hxmc.tlsdesc: a TLSDESC descriptor, or
	// on Android x86-64 (Bionic implements TLSDESC on arm64 only: its
	// linker_relocate.cpp) the general dynamic model's tls_index (module
	// and offset: R_X86_64_DTPMOD64, DTPOFF64) passed to __tls_get_addr
	function sharedStartObj(tls:Bool):Obj {
		var o = new Obj();
		var d = new Section(".data.hxmc.dso_handle", Data, 8);
		d.buf.u64(0, 0);
		o.sections.push(d);
		o.define("__dso_handle", d, 0, 8, true);
		if (!tls) return o;
		var pair = new Section(".data.hxmc.tlsdesc", Data, 16);
		pair.buf.zeros(16);
		o.sections.push(pair);
		tlsDesc = o.define(".Ltlsdesc", pair, 0, 16, false);
		var t = new Section(".text.hxmc.tls_base", Text, 16);
		var b = t.buf;
		function rel(kind:RelKind, add = 0)
			t.relocs.push(new Reloc(b.len, kind, tlsDesc, add));
		var ops = [];
		var U = Unwind;
		if (arm) {
			b.u32(0xa9bf7bfd); // stp x29, x30, [sp, #-16]!
			b.u32(0x910003fd); // mov x29, sp
			rel(RA64AdrPage21); b.u32(0x90000000); // adrp x0, pair
			rel(RA64Ldst64Lo12); b.u32(0xf9400001); // ldr x1, [x0, :lo12:pair]
			rel(RA64AddLo12); b.u32(0x91000000); // add x0, x0, :lo12:pair
			b.u32(0xd63f0020); // blr x1: x0 = the block's offset from the thread pointer
			b.u32(0xd53bd041); // mrs x1, tpidr_el0
			b.u32(0x8b000020); // add x0, x1, x0
			b.u32(0xa8c17bfd); // ldp x29, x30, [sp], #16
			b.u32(0xd65f03c0); // ret
			for (x in [[U.SAVEFPLR, 4, 16, 0], [U.SETFP, 8, 0, 0], [U.ENDPROLOGUE, 8, 0, 0], [U.EPILOGUE, 32, 0, 0], [U.RESTOREFPLR, 36, 16, 0], [U.RET, 40, 0, 0]])
				for (v in x) ops.push(v);
		} else if (tlsGd) {
			for (x in [0x55, 0x48, 0x89, 0xE5, 0x48, 0x8D, 0x3D]) b.u8(x); // push rbp; mov rbp, rsp; lea rdi, [rip + pair]
			rel(RPc32, -4); b.u32(0);
			b.u8(0xE8); // call __tls_get_addr: rax = the block's address
			t.relocs.push(new Reloc(b.len, RCall32, o.sym("__tls_get_addr"), -4));
			b.u32(0);
			for (x in [0x5D, 0xC3]) b.u8(x); // pop rbp; ret
			for (x in [[U.PUSH, 1, 5, 0], [U.SETFP, 4, 0, 0], [U.ENDPROLOGUE, 4, 0, 0], [U.EPILOGUE, 16, 0, 0], [U.POP, 17, 5, 0], [U.RET, 18, 0, 0]])
				for (v in x) ops.push(v);
		} else {
			for (x in [0x55, 0x48, 0x89, 0xE5, 0x48, 0x8D, 0x05]) b.u8(x); // push rbp; mov rbp, rsp; lea rax, [rip + pair]
			rel(RPc32, -4); b.u32(0);
			for (x in [0xFF, 0x10]) b.u8(x); // call [rax]: rax = the block's offset from fs
			for (x in [0x64, 0x48, 0x03, 0x04, 0x25, 0, 0, 0, 0]) b.u8(x); // add rax, fs:[0]
			for (x in [0x5D, 0xC3]) b.u8(x); // pop rbp; ret
			for (x in [[U.PUSH, 1, 5, 0], [U.SETFP, 4, 0, 0], [U.ENDPROLOGUE, 4, 0, 0], [U.EPILOGUE, 22, 0, 0], [U.POP, 23, 5, 0], [U.RET, 24, 0, 0]])
				for (v in x) ops.push(v);
		}
		o.sections.push(t);
		o.funcs.push(new FuncRec(o.define("hxmc_tls_base", t, 0, b.len, true), haxe.ds.Vector.fromArrayCopy(ops)));
		return o;
	}

	// the TLSDESC pair's symbol (null: no thread-locals); general dynamic instead
	var tlsDesc:Null<Symbol> = null;
	var tlsGd = false;

	// a shared library: the address computation of a library's variable
	// (adrp + add, lea) made a load of its GOT slot
	function relaxToGot(s:Section, r:Reloc) {
		switch r.kind {
			case RA64AdrPage21:
				r.kind = RA64GotPage21;
			case RA64AddLo12:
				var w = s.buf.get32(r.offset);
				if ((w & 0xffc00000) != 0x91000000) throw "hxmc: link: the address of " + r.sym.name + ", a shared library's variable, in an instruction other than add";
				s.buf.set32(r.offset, 0xf9400000 | (w & 0x3ff)); // ldr xd, [xn, :got_lo12:]
				r.kind = RA64GotLo12;
			case RPc32 if (r.offset >= 2 && s.buf.get8(r.offset - 2) == 0x8D):
				s.buf.set8(r.offset - 2, 0x8B); // lea -> mov from the slot
				r.kind = RGotPcRel32;
			case _:
				throw "hxmc: link: relocation " + r.kind + " against " + r.sym.name + ", a shared library's variable, in a shared library";
		}
	}

	static inline function isCode(k:RelKind):Bool
		return k == RCall32 || k == RPc32 || k == RA64Call26 || k == RA64Jump26 || k == RA64AdrPage21 || k == RA64AddLo12;

	override public function link(entry:String):Bytes {
		readImports();
		var hasFini = false, hasTls = false;
		for (o in objs)
			for (s in o.sections) {
				if (s.kind == FiniArray && s.size() > 0) hasFini = true;
				if (s.kind == Tdata || s.kind == Tbss) hasTls = true;
			}
		var start = shared ? sharedStartObj(hasTls && abi.tls == Desc) : startObj(hasFini);
		objs.push(start);
		resolve();
		if (shared) {
			roots = [];
			for (n in abi.exports)
				if (globals.exists(n)) roots.push(n);
				else if (optional.indexOf(n) < 0) throw 'hxmc: link: the shared library exports $n, which nothing defines' + (n == "ANativeActivity_onCreate" ? " (an Android app's entry: hxmc.os.App, packages/os)" : "");
		}
		gc(entry);
		// the imports the live code refers to, and how
		var stubs = new Section(".text.hxmc.stubs", Text, 16);
		var copies = new Section(".bss.hxmc.copy", Bss, 16);
		var absRelocs = 0;
		var moved = new Map<Section, Bool>(); // read-only data with a function's address
		function use(i:Imp) {
			if (i.index == 0) {
				i.index = used.length + 1;
				used.push(i);
			}
		}
		for (o in objs)
			for (s in o.sections) {
				if (!isLive(s)) continue;
				for (r in s.relocs) {
					// (a shared library is loaded anywhere: an absolute address in 32 bits
					// or in instructions cannot be relocated; program-wide numbers, absolute
					// symbols, can)
					if (shared && (r.kind == RAbs32 || r.kind == RAbs32S || r.kind == RA64MovwG0Nc || r.kind == RA64MovwG1Nc) && target(r.sym) != null && !target(r.sym).abs)
						throw "hxmc: link: an absolute address of " + r.sym.name + " in 32 bits, in a shared library";
					if (shared && r.kind == RAbs64 && target(r.sym) != null && !target(r.sym).abs) {
						// (an address in the image: R_*_RELATIVE)
						if (s.kind == RoData) moved.set(s, true);
						else if (s.kind == Text) throw "hxmc: link: an absolute address of " + r.sym.name + " in code, in a shared library";
						continue;
					}
					if (target(r.sym) != null || LINKER.indexOf(r.sym.name) >= 0) continue;
					var i = imports.get(r.sym.name);
					if (i == null) {
						if (r.sym.weak) continue;
						if (abi.android && (StringTools.startsWith(r.sym.name, "mbedtls_") || StringTools.startsWith(r.sym.name, "uv_")))
							throw 'hxmc: link: ${r.sym.name}: sys.ssl and eval.luv (mbedtls, libuv) are not supported on Android yet';
						throw 'hxmc: link: undefined symbol ${r.sym.name} (in none of the shared libraries of the ${abi.libc} mode: a C function of another library needs @:hxmc.lib("<file>.so"))';
					}
					use(i);
					if (!r.sym.weak) strong.set(i.name, true);
					if (i.object && shared) {
						if (r.kind == RAbs64) {
							absRelocs++;
							if (s.kind == RoData) moved.set(s, true);
						} else if (!LinkCore.isGotRel(r.kind)) relaxToGot(s, r);
					} else if (i.object) {
						if (i.copyAt < 0) {
							var al = i.size >= 16 ? 16 : i.size >= 8 ? 8 : 4;
							copies.bssSize = LinkCore.align(copies.bssSize, al);
							i.copyAt = copies.bssSize;
							copies.bssSize += i.size;
						}
					} else if (isCode(r.kind)) {
						if (i.stub < 0) {
							i.stub = stubs.buf.len;
							if (arm) {
								stubs.relocs.push(new Reloc(stubs.buf.len, RA64GotPage21, i.sym, 0));
								stubs.buf.u32(0x90000010); // adrp x16, slot
								stubs.relocs.push(new Reloc(stubs.buf.len, RA64GotLo12, i.sym, 0));
								stubs.buf.u32(0xf9400210); // ldr x16, [x16, :lo12:slot]
								stubs.buf.u32(0xd61f0200); // br x16
								stubs.buf.u32(0xd503201f); // nop
							} else {
								stubs.buf.u8(0xFF); // jmp [rip + slot]
								stubs.buf.u8(0x25);
								stubs.relocs.push(new Reloc(stubs.buf.len, RGotPcRel32, i.sym, -4));
								stubs.buf.u32(0);
								stubs.buf.u8(0xCC);
								stubs.buf.u8(0xCC);
							}
						}
					} else if (r.kind == RAbs64) {
						absRelocs++;
						if (s.kind == RoData) moved.set(s, true);
						else if (s.kind == Text) throw "hxmc: link: an absolute address of " + r.sym.name + " in code";
					} else if (!LinkCore.isGotRel(r.kind))
						throw "hxmc: link: relocation " + r.kind + " against " + r.sym.name + ", a shared library's";
				}
			}
		var extra = new Obj();
		extra.sections.push(stubs);
		extra.sections.push(copies);
		keep(extra);
		makeGot();
		unwindObj();
		// GLOB_DAT relocations: the slots of functions
		var gotImports = 0;
		if (got != null)
			for (r in got.relocs) {
				var i = target(r.sym) == null ? imports.get(r.sym.name) : null;
				if (i != null && (!i.object || shared)) gotImports++;
			}
		for (i in used)
			if (i.object && !shared) {
				// (the aliases: defined at the copy too)
				for (a in i.aliases)
					if (!imports.exists(a) || imports.get(a).index == 0) {
						var x:Imp = {name: a, lib: i.lib, version: i.version, object: true, size: i.size, aliases: [], sym: new Symbol(a), stub: -1, copyAt: i.copyAt, index: 0, vers: 0, alias: true};
						imports.set(a, x);
						use(x);
					}
			}
		// copy relocations: one per variable (not per alias)
		var copyOwners = [for (i in used) if (i.object && !i.alias && !shared) i];
		// a shared library's addresses in its own image (data, GOT slots of its
		// own symbols): R_*_RELATIVE, first (DT_RELACOUNT)
		var relatives = 0;
		if (shared)
			for (o in objs)
				for (s in o.sections)
					if (isLive(s) || s == got)
						for (r in s.relocs)
							if (r.kind == RAbs64 && target(r.sym) != null && !target(r.sym).abs) relatives++;
		var nrela = relatives + gotImports + absRelocs + copyOwners.length + (tlsDesc != null ? (tlsGd ? 2 : 1) : 0);
		// the exports: defined in .dynsym after the imports
		var exported = shared ? [for (n in roots) globals.get(n)] : [];

		// ---- the dynamic tables (contents once the layout is known)
		var dynstr = new Buf(4096);
		dynstr.u8(0);
		var strOf = new Map<String, Int>();
		function str(s:String):Int {
			var at = strOf.get(s);
			if (at == null) {
				at = dynstr.len;
				strOf.set(s, at);
				dynstr.str(s);
				dynstr.u8(0);
			}
			return at;
		}
		// the libraries: the program's own first, then the C library's (libc last, as a C toolchain orders them)
		var libList:Array<String> = [];
		for (i in used)
			if (libList.indexOf(i.lib) < 0) libList.push(i.lib);
		function rank(l:String):Int
			return StringTools.startsWith(l, "libc.so") ? 3 : StringTools.startsWith(l, "libpthread.so") ? 2 : StringTools.startsWith(l, "libdl.so") || StringTools.startsWith(l, "libm.so") ? 1 : 0;
		var order = [for (k in 0...libList.length) k];
		order.sort((a, b) -> rank(libList[a]) != rank(libList[b]) ? rank(libList[a]) - rank(libList[b]) : a - b);
		libList = [for (k in order) libList[k]];
		for (l in libList)
			str(l);
		var runpath = origin ? str("$ORIGIN") : -1;
		var sonameAt = soname != null ? str(soname) : -1;
		for (i in used)
			str(i.name);
		for (x in exported)
			str(x.name);
		// the versions each library must define (vna_other from 2)
		var vers:Array<{lib:String, names:Array<String>}> = [];
		var nextVer = 2;
		var verIndex = new Map<String, Int>();
		for (l in libList) {
			var names = [];
			for (i in used)
				if (i.lib == l && i.version != null) {
					var key = l + "\t" + i.version;
					if (!verIndex.exists(key)) {
						verIndex.set(key, nextVer++);
						names.push(i.version);
						str(i.version);
					}
					i.vers = verIndex.get(key);
				}
			if (names.length > 0) vers.push({lib: l, names: names});
		}
		var nsym = used.length + exported.length + 1;
		var nbucket = nsym < 8 ? 1 : nsym >> 1;
		var interp = new Section(".interp", RoData, 1);
		if (!shared) {
			interp.buf.str(abi.interp);
			interp.buf.u8(0);
		}
		var hash = new Section(".hash", RoData, 8);
		hash.buf.zeros(4 * (2 + nbucket + nsym));
		var dynsym = new Section(".dynsym", RoData, 8);
		dynsym.buf.zeros(24 * nsym);
		var dynstrSec = new Section(".dynstr", RoData, 1);
		dynstrSec.buf.buf(dynstr);
		var versym = new Section(".gnu.version", RoData, 2);
		var verneed = new Section(".gnu.version_r", RoData, 4);
		if (vers.length > 0) {
			versym.buf.zeros(2 * nsym);
			for (v in vers)
				verneed.buf.zeros(16 + 16 * v.names.length);
		}
		var rela = new Section(".rela.dyn", RoData, 8);
		rela.buf.zeros(24 * nrela);
		var initSize = 0, finiSize = 0;
		for (o in objs)
			for (s in o.sections)
				if (isLive(s)) {
					if (s.kind == InitArray) initSize += s.size();
					if (s.kind == FiniArray) finiSize += s.size();
				}
		var ndyn = shared ? libList.length + (soname != null ? 1 : 0) + (origin ? 1 : 0) + 8 + (relatives > 0 ? 1 : 0) + (nrela > 0 ? 3 : 0) + (vers.length > 0 ? 3 : 0)
			+ (initSize > 0 ? 2 : 0) + (finiSize > 0 ? 2 : 0) : libList.length + (origin ? 1 : 0) + 9 + (nrela > 0 ? 3 : 0) + (vers.length > 0 ? 3 : 0);
		var dynSec = new Section(".dynamic", Data, 8);
		dynSec.buf.zeros(16 * ndyn);
		var dynObj = new Obj();
		for (s in [interp, hash, dynsym, dynstrSec, versym, verneed, rela, dynSec])
			if (s != interp || !shared) dynObj.sections.push(s);
		objs.push(dynObj);

		// ---- layout (as Link.link, with the dynamic tables)
		var defined = new Map<String, Int>();
		var all:Array<Section> = [];
		for (o in objs)
			for (s in o.sections)
				if (o == dynObj || isLive(s)) all.push(s);
		var ro = [for (s in all) if (s.kind == RoData && o(dynObj, s) == false && !moved.exists(s)) s];
		var text = [for (s in all) if (s.kind == Text) s];
		var tdata = [for (s in all) if (s.kind == Tdata) s];
		var tbss = [for (s in all) if (s.kind == Tbss) s];
		var init = [for (s in all) if (s.kind == InitArray) s];
		var fini = [for (s in all) if (s.kind == FiniArray) s];
		var data = [for (s in all) if (s.kind == Data && s != dynSec && s != got) s].concat([for (s in all) if (moved.exists(s)) s]);
		var bss = [for (s in all) if (s.kind == Bss) s];
		// PHDR, INTERP, LOAD r, LOAD rx, LOAD rw, DYNAMIC, TLS, GNU_STACK, GNU_EH_FRAME (a shared library: no PHDR, no INTERP)
		var nph = (ehFrame != null ? 9 : 8) - (shared ? 2 : 0);
		var BASE = shared ? 0 : Link.BASE;
		imageBase = BASE;
		var headers = 64 + 56 * nph;
		var pos = BASE + headers;
		pos = place(shared ? [hash, dynsym, dynstrSec, versym, verneed, rela] : [interp, hash, dynsym, dynstrSec, versym, verneed, rela], pos);
		var roStart = pos;
		pos = place(ro, pos);
		var roEnd = pos;
		pos = LinkCore.align(pos, PAGE);
		var textStart = pos;
		pos = place(text, pos);
		var textEnd = pos;
		pos = LinkCore.align(pos, PAGE);
		var dataStart = pos;
		pos = place(tdata, pos);
		tlsStart = dataStart;
		var tdataEnd = pos;
		var tpos = place(tbss, pos);
		for (s in tdata.concat(tbss))
			if (s.align > tlsAlign) tlsAlign = s.align;
		tlsSize = tpos - tlsStart;
		pos = LinkCore.align(pos, 8);
		var initStart = pos;
		defined.set("__init_array_start", pos);
		pos = place(init, pos);
		defined.set("__init_array_end", pos);
		defined.set("__fini_array_start", pos);
		pos = place(fini, pos);
		defined.set("__fini_array_end", pos);
		pos = place([dynSec], pos);
		var gotStart = pos;
		if (got != null) pos = place([got], pos);
		var gotEnd = pos;
		pos = place(data, pos);
		var fileEnd = pos;
		pos = place(bss, pos);
		var dataEnd = pos;
		defined.set("_end", dataEnd);
		defined.set("end", dataEnd);
		defined.set("_DYNAMIC", addr.get(dynSec));
		defined.set("__ehdr_start", BASE);
		var stubAddr = addr.get(stubs), copyAddr = addr.get(copies);
		symAddr = function(s:Symbol):Int {
			var t = target(s);
			if (t == null) {
				var i = imports.get(s.name);
				if (i != null && i.index > 0) {
					if (i.object) return copyAddr + i.copyAt;
					// (no stub: reached through its GOT slot only, S unused)
					return i.stub >= 0 ? stubAddr + i.stub : 0;
				}
				var d = defined.get(s.name);
				if (d != null) return d;
				if (s.weak) return 0;
				throw 'hxmc: link: undefined symbol ${s.name}';
			}
			if (t.abs) return t.offset;
			return addr.get(t.section) + t.offset;
		};
		// the dynamic relocations
		var relaAt = 0;
		inline function relType(k:String):Int
			return switch k {
				case "glob": arm ? 1025 : 6;
				case "abs": arm ? 257 : 1;
				case _: arm ? 1024 : 5;
			}
		function addRela(at:Int, i:Imp, type:Int, addend:Int) {
			rela.buf.set64(relaAt, at, 0);
			rela.buf.set64(relaAt + 8, type, i.index);
			rela.buf.set64(relaAt + 16, addend, addend < 0 ? -1 : 0);
			relaAt += 24;
		}
		// (RELATIVE first, then the others: two cursors)
		var relAt = 0;
		relaAt = 24 * relatives;
		dynReloc = function(s:Section, r:Reloc):Bool {
			if (r.kind != RAbs64) return false;
			var t = target(r.sym);
			if (t != null) {
				if (!shared || t.abs) return false;
				var v = symAddr(r.sym) + r.addend;
				s.buf.set64(r.offset, v, v < 0 ? -1 : 0);
				rela.buf.set64(relAt, addr.get(s) + r.offset, 0);
				rela.buf.set64(relAt + 8, arm ? 1027 : 8, 0); // R_*_RELATIVE
				rela.buf.set64(relAt + 16, v, v < 0 ? -1 : 0);
				relAt += 24;
				return true;
			}
			var i = imports.get(r.sym.name);
			if (i == null || i.index == 0 || (i.object && !shared)) return false;
			s.buf.set64(r.offset, 0, 0);
			if (s == got) addRela(addr.get(s) + r.offset, i, relType("glob"), 0) else addRela(addr.get(s) + r.offset, i, relType("abs"), r.addend);
			return true;
		};
		for (i in copyOwners)
			addRela(copyAddr + i.copyAt, i, relType("copy"), 0);
		if (tlsDesc != null) {
			// (the module's own block: symbol 0, as ld.bfd and lld write it for a local thread-local)
			// R_AARCH64_TLSDESC, R_X86_64_TLSDESC; general dynamic: R_X86_64_DTPMOD64, R_X86_64_DTPOFF64
			for (k in 0...(tlsGd ? 2 : 1)) {
				rela.buf.set64(relaAt, addr.get(tlsDesc.section) + 8 * k, 0);
				rela.buf.set64(relaAt + 8, tlsGd ? 16 + k : arm ? 1031 : 36, 0);
				rela.buf.set64(relaAt + 16, 0, 0);
				relaAt += 24;
			}
		}
		for (s in all)
			if (s.kind != Bss && s.kind != Tbss && o(dynObj, s) == false) applyRelocs(s);
		if (relaAt != rela.buf.len || relAt != 24 * relatives) throw "hxmc: link: " + Std.int(relaAt / 24) + " dynamic relocations for " + nrela;
		fillUnwind();
		// .dynsym, .hash, .gnu.version, .gnu.version_r
		var buckets = new haxe.ds.Vector<Int>(nbucket);
		var chains = new haxe.ds.Vector<Int>(nsym);
		var bssIndex = 15; // the section header of .bss (below)
		for (i in used) {
			var at = 24 * i.index;
			dynsym.buf.set32(at, strOf.get(i.name));
			var weak = !i.object && !strong.exists(i.name);
			dynsym.buf.set8(at + 4, ((weak ? 2 : 1) << 4) | (i.object ? 1 : 2));
			if (i.object && !shared) {
				dynsym.buf.set16(at + 6, bssIndex);
				dynsym.buf.set64(at + 8, copyAddr + i.copyAt, 0);
				dynsym.buf.set64(at + 16, i.size, 0);
			}
			var h = elfHash(i.name) % nbucket;
			chains[i.index] = buckets[h];
			buckets[h] = i.index;
				if (vers.length > 0) versym.buf.set16(2 * i.index, i.version != null ? i.vers : 1);
			}
			// (a shared library's exports: functions of .text, global, in the base version)
			var textIndex = shared ? 8 : 9;
			for (k in 0...exported.length) {
				var x = exported[k], index = used.length + 1 + k;
				var at = 24 * index;
				dynsym.buf.set32(at, strOf.get(x.name));
				dynsym.buf.set8(at + 4, (1 << 4) | (x.section.kind == Text ? 2 : 1));
				dynsym.buf.set16(at + 6, switch x.section.kind {
					case Text: textIndex;
					case RoData: moved.exists(x.section) ? textIndex + 7 : textIndex - 1;
					case Bss: textIndex + 6;
					case Data | InitArray | FiniArray: textIndex + 7;
					case _: throw "hxmc: link: the export " + x.name + " is thread-local";
				});
				dynsym.buf.set64(at + 8, symAddr(x), 0);
				dynsym.buf.set64(at + 16, x.size, 0);
				var h = elfHash(x.name) % nbucket;
				chains[index] = buckets[h];
				buckets[h] = index;
				if (vers.length > 0) versym.buf.set16(2 * index, 1);
			}
			hash.buf.set32(0, nbucket);
		hash.buf.set32(4, nsym);
		for (k in 0...nbucket)
			hash.buf.set32(8 + 4 * k, buckets[k]);
		for (k in 0...nsym)
			hash.buf.set32(8 + 4 * nbucket + 4 * k, chains[k]);
		var vat = 0;
		for (vi in 0...vers.length) {
			var v = vers[vi];
			var size = 16 + 16 * v.names.length;
			verneed.buf.set16(vat, 1);
			verneed.buf.set16(vat + 2, v.names.length);
			verneed.buf.set32(vat + 4, strOf.get(v.lib));
			verneed.buf.set32(vat + 8, 16);
			verneed.buf.set32(vat + 12, vi == vers.length - 1 ? 0 : size);
			for (k in 0...v.names.length) {
				var a = vat + 16 + 16 * k;
				var n = v.names[k];
				verneed.buf.set32(a, elfHash(n));
				verneed.buf.set16(a + 4, 0);
				verneed.buf.set16(a + 6, verIndex.get(v.lib + "\t" + n));
				verneed.buf.set32(a + 8, strOf.get(n));
				verneed.buf.set32(a + 12, k == v.names.length - 1 ? 0 : 16);
			}
			vat += size;
		}
		// .dynamic
		var dat = 0;
		function dyn(tag:Int, v:Int) {
			dynSec.buf.set64(dat, tag, 0);
			dynSec.buf.set64(dat + 8, v, 0);
			dat += 16;
		}
		for (l in libList)
			dyn(1, strOf.get(l)); // DT_NEEDED
		if (shared && soname != null) dyn(14, sonameAt); // DT_SONAME
		if (origin) dyn(29, runpath); // DT_RUNPATH
		dyn(4, addr.get(hash)); // DT_HASH
		dyn(5, addr.get(dynstrSec)); // DT_STRTAB
		dyn(6, addr.get(dynsym)); // DT_SYMTAB
		dyn(10, dynstr.len); // DT_STRSZ
		dyn(11, 24); // DT_SYMENT
		if (!shared) dyn(21, 0); // DT_DEBUG
		if (nrela > 0) {
			dyn(7, addr.get(rela)); // DT_RELA
			dyn(8, rela.buf.len); // DT_RELASZ
			dyn(9, 24); // DT_RELAENT
		}
		if (shared && relatives > 0) dyn(0x6ffffff9, relatives); // DT_RELACOUNT
		if (shared && initSize > 0) {
			dyn(25, defined.get("__init_array_start")); // DT_INIT_ARRAY
			dyn(27, initSize); // DT_INIT_ARRAYSZ
		}
		if (shared && finiSize > 0) {
			dyn(26, defined.get("__fini_array_start")); // DT_FINI_ARRAY
			dyn(28, finiSize); // DT_FINI_ARRAYSZ
		}
		dyn(30, 8); // DT_FLAGS: DF_BIND_NOW
		dyn(0x6ffffffb, 1); // DT_FLAGS_1: DF_1_NOW
		if (vers.length > 0) {
			dyn(0x6ffffffe, addr.get(verneed)); // DT_VERNEED
			dyn(0x6fffffff, vers.length); // DT_VERNEEDNUM
			dyn(0x6ffffff0, addr.get(versym)); // DT_VERSYM
		}
		dyn(0, 0);
		if (dat != dynSec.buf.len) throw "hxmc: link: .dynSec size";
		// the image
		var out = new Buf(fileEnd - BASE + 4096);
		out.zeros(fileEnd - BASE);
		for (s in all)
			if (s.kind != Bss && s.kind != Tbss) out.b.blit(addr.get(s) - BASE, s.buf.b, 0, s.buf.len);
		// section headers (for the tools: glibc's ld.so reads none; Bionic's
		// linker finds .dynamic and its .dynstr through them; a shared library
		// has no .interp, the others are one lower)
		var secs:Array<SecHdr> = [];
		function sec(name:String, type:Int, flags:Int, a:Int, size:Int, link = 0, info = 0, al = 1, entsize = 0)
			secs.push({name: name, type: type, flags: flags, addr: a, off: a - BASE, size: size, link: link, info: info, align: al, entsize: entsize});
		var sx = shared ? 1 : 0;
		if (!shared) sec(".interp", 1, 2, addr.get(interp), interp.size()); // 1
		sec(".hash", 5, 2, addr.get(hash), hash.size(), 3 - sx, 0, 8, 4); // 2
		sec(".dynsym", 11, 2, addr.get(dynsym), dynsym.size(), 4 - sx, 1, 8, 24); // 3
		sec(".dynstr", 3, 2, addr.get(dynstrSec), dynstrSec.size()); // 4
		sec(".gnu.version", 0x6fffffff, 2, addr.get(versym), versym.size(), 3 - sx, 0, 2, 2); // 5
		sec(".gnu.version_r", 0x6ffffffe, 2, addr.get(verneed), verneed.size(), 4 - sx, vers.length, 4); // 6
		sec(".rela.dyn", 4, 2, addr.get(rela), rela.size(), 3 - sx, 0, 8, 24); // 7
		sec(".rodata", 1, 2, roStart, roEnd - roStart); // 8
		sec(".text", 1, 6, textStart, textEnd - textStart, 0, 0, 16); // 9
		sec(".tdata", 1, 0x403, tlsStart, tdataEnd - tlsStart, 0, 0, tlsAlign); // 10
		sec(".tbss", 8, 0x403, tdataEnd, tlsStart + tlsSize - tdataEnd, 0, 0, tlsAlign); // 11
		sec(".init_array", 1, 3, initStart, addr.get(dynSec) - initStart, 0, 0, 8); // 12
		sec(".dynamic", 6, 3, addr.get(dynSec), dynSec.size(), 4 - sx, 0, 8, 16); // 13
		sec(".got", 1, 3, gotStart, gotEnd - gotStart, 0, 0, 8, 8); // 14
		sec(".bss", 8, 3, fileEnd, dataEnd - fileEnd, 0, 0, 16); // 15 (bssIndex)
		sec(".data", 1, 3, gotEnd, fileEnd - gotEnd, 0, 0, 16); // 16
		unwindHeaders(secs);
		// (the .tbss header takes no file room: its offset is that of .tdata's end)
		var shoff = sectionHeaders(out, secs, textIndex);
		// ELF header
		var h = new Buf(64 + 56 * nph);
		h.u32(0x464c457f);
		h.u8(2);
		h.u8(1);
		h.u8(1);
		h.zeros(9);
		h.u16(shared ? 3 : 2); // ET_DYN, ET_EXEC
		h.u16(arm ? 183 : 62);
		h.u32(1);
		h.i64(shared ? 0 : symAddr(entrySym(entry)));
		h.i64(64);
		h.i64(shoff);
		h.u32(0);
		h.u16(64);
		h.u16(56);
		h.u16(nph);
		h.u16(64);
		h.u16(secs.length + 2);
		h.u16(secs.length + 1); // .shstrtab, the last
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
		if (!shared) {
			ph(6, 4, 64, BASE + 64, 56 * nph, 56 * nph, 8); // PT_PHDR
			ph(3, 4, addr.get(interp) - BASE, addr.get(interp), interp.size(), interp.size(), 1); // PT_INTERP
		}
		ph(1, 4, 0, BASE, roEnd - BASE, roEnd - BASE, PAGE);
		ph(1, 5, textStart - BASE, textStart, textEnd - textStart, textEnd - textStart, PAGE);
		ph(1, 6, dataStart - BASE, dataStart, fileEnd - dataStart, dataEnd - dataStart, PAGE);
		ph(2, 6, addr.get(dynSec) - BASE, addr.get(dynSec), dynSec.size(), dynSec.size(), 8); // PT_DYNAMIC
		ph(7, 4, tlsStart - BASE, tlsStart, tdataEnd - tlsStart, tlsSize, tlsAlign);
		if (ehFrameHdr != null) ph(0x6474e550, 4, addr.get(ehFrameHdr) - BASE, addr.get(ehFrameHdr), ehFrameHdr.size(), ehFrameHdr.size(), 4);
		ph(0x6474e551, 6, 0, 0, 0, 0, 16);
		out.b.blit(0, h.b, 0, h.len);
		return out.toBytes();
	}

	// a relocation that becomes a dynamic one (true: done)
	var dynReloc:Null<(Section, Reloc) -> Bool> = null;

	override function absolute(s:Section, r:Reloc, P:Int) {
		if (dynReloc == null || !dynReloc(s, r)) super.absolute(s, r, P);
	}

	// a section's object is `o`
	static function o(x:Obj, s:Section):Bool
		return x.sections.indexOf(s) >= 0;

	// the imports a reference names without being weak (the others: a
	// missing symbol binds to 0)
	var strong = new Map<String, Bool>();

	static function elfHash(s:String):Int {
		var h = 0;
		for (k in 0...s.length) {
			h = (h << 4) + s.charCodeAt(k);
			var g = h & 0xf0000000;
			if (g != 0) h ^= g >>> 24;
			h &= ~g;
		}
		return h;
	}
}

typedef Imp = {
	name:String,
	lib:String,
	version:Null<String>,
	object:Bool,
	size:Int,
	aliases:Array<String>,
	sym:Symbol, // the GOT slot's key
	stub:Int, // the offset of its stub (-1: none)
	copyAt:Int, // a variable: its copy's offset (-1: none)
	index:Int, // its .dynsym index (0: unused)
	vers:Int, // its version's index (vna_other)
	alias:Bool // another name of a copied variable
}

