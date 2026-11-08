package hxmc;

import haxe.Int64;
import haxe.io.Bytes;
import hxmc.Mir;
import hxmc.Obj;

// An experimental back end: memory-level Mir (after MemLower and
// the passes on it) as LLVM IR, one module per hxmc module, compiled by an
// external clang (-D hxmc.llvm: Options.llvm; -D hxmc.llvm-clang, else `clang`) to
// an object of the target's format, read back (MachOReader, ElfReader,
// CoffReader) and appended to the module's object; hxmc's own linker links
// it. The functions it does not take (accepts: struct values in the C ABI,
// vectors, entries from C) go through the native instruction selection as
// before, into the same object.
//
// The mapping:
// - values are i32, i64 and double as in Mir; addresses are i64, turned
//   into pointers at each load and store (inttoptr);
// - program-wide numbers (Const with a symbol) are the address of an
//   extern_weak global (so that LLVM assumes nothing of it, not even that it
//   is not null), turned into an integer;
// - setjmp is a returns_twice call; the values live into a handler block
//   (its second return) go through volatile frame slots, since LLVM does
//   not keep a register's value across a longjmp (see handlerSlots);
// - every function keeps its frame record (frame-pointer=all), as hxmc's
//   stack walks need; no unwind tables (exceptions are setjmp/longjmp).
class LlvmGen {
	final abi:Abi;
	final optLevel:String;
	final clang:String;
	final module:String;
	final dir:String;
	var out = new StringBuf();
	var defined = new Map<String, Bool>();
	// the symbols referred to: called directly, as an address (data or code), absolute, thread-local
	var called = new Map<String, Bool>();
	var addressed = new Map<String, Bool>();
	var absolute = new Map<String, Bool>();
	var tls = new Map<String, Bool>();
	var returnsTwice = new Map<String, Bool>();
	var intrinsics = new Map<String, Bool>();
	// Apple: the thread-local variables reached from hxmc_tls_base, by their offsets
	var tlsOff = new Map<String, Bool>();

	public static inline var TLS_OFF = "$tlsoff";

	public var count(default, null) = 0;

	final cpu:Null<String>;
	// the module's metadata nodes (md), numbered in order
	var mds:Array<String> = [];
	var mdIndex = new Map<String, Int>();

	public function new(abi:Abi, optLevel:String, clang:String, module:String, dir:String, ?cpu:String) {
		this.abi = abi;
		this.cpu = cpu;
		this.optLevel = optLevel;
		this.clang = clang;
		this.module = module;
		this.dir = dir;
	}

	// LLVM's profile runtime for the target (the clang's, Apple's: universal).
	// macOS: all of it (it writes the profile at exit). Linux, static with
	// musl: its writer's parts only, which call no more of the C library than
	// memcpy, memset and (value profiles) calloc; the runtime writes the file
	// (hxmc.rt.Pgo), as a C library built for glibc does not link with musl's
	public static function profileRuntime(abi:Abi, clang:String):String {
		var linux = abi.os == "linux" && !abi.linksDynamically() && !abi.android;
		if ((abi.os != "macos" || abi.ios()) && !linux)
			throw "hxmc: -D hxmc.llvm-pgo=gen: macOS, and Linux static with musl (the clang's profile runtime)";
		var p = new sys.io.Process(clang, ["-print-resource-dir"]);
		var dir = StringTools.trim(p.stdout.readAll().toString());
		p.exitCode();
		p.close();
		var arch = abi.arm ? "aarch64" : "x86_64";
		var a = linux ? dir + "/lib/linux/libclang_rt.profile-" + arch + ".a" : dir + "/lib/darwin/libclang_rt.profile_osx.a";
		// (a clang with a runtime directory per target triple)
		if (linux && !sys.FileSystem.exists(a)) for (t in ["-unknown-linux-gnu", "-unknown-linux-musl", "-linux-gnu"]) {
			var b = dir + "/lib/" + arch + t + "/libclang_rt.profile.a";
			if (sys.FileSystem.exists(b)) {
				a = b;
				break;
			}
		}
		if (!sys.FileSystem.exists(a)) throw "hxmc: -D hxmc.llvm-pgo=gen: no profile runtime at " + a;
		return a;
	}

	public static function triple(abi:Abi):Null<String> {
		return switch abi.name {
			case "macos-arm64": abi.ios() ? (abi.platform == "ios-simulator" ? "arm64-apple-ios15.0-simulator" : "arm64-apple-ios15.0") : "arm64-apple-macos11.0";
			case "macos-x86_64": "x86_64-apple-macos10.15";
			case "linux-arm64": "aarch64-unknown-linux-musl";
			case "linux-x86_64": "x86_64-unknown-linux-musl";
			case "windows-x86_64": "x86_64-pc-windows-gnu";
			case "windows-arm64": "aarch64-pc-windows-gnu";
			case _: null;
		}
	}

	// whether this back end takes the function (else the native one does)
	public function accepts(f:MFunc):Null<String> {
		if (f.cParams.length > 0 || f.structRet || f.allRegs) return "entered from C with structs";
		if (f.entry.preds.length > 0) return "a loop to the entry";
		if (f.ret == V128) return "vectors";
		for (p in f.params)
			if (p == V128) return "vectors";
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.isObj()) return "an object-level operation";
				if (i.ty == V128) return "vectors";
				switch i.op {
					case VOp | VConst:
						return "vectors";
					case Param if (i.imm < 0):
						return "a struct result's address";
					case Call if (i.structRet || i.cGroups.length > 0 || i.cRet.length > 0):
						return "a C call with structs";
					case Call if (abi.arm && abi.os == "macos" && i.cCall && i.cSizes.length > 8):
						return "a C call with stack arguments (Apple arm64 packs them by size)";
					case _:
				}
			}
		return null;
	}

	static inline function ty(t:MTy):String
		return switch t {
			case I32: "i32";
			case I64: "i64";
			case F64: "double";
			case Void: "void";
			case V128: "<4 x i32>";
		};

	static function name(s:String):String {
		var ok = true;
		for (k in 0...s.length) {
			var c = StringTools.fastCodeAt(s, k);
			if (!(c >= "a".code && c <= "z".code || c >= "A".code && c <= "Z".code || c >= "0".code && c <= "9".code || c == "_".code || c == ".".code
				|| c == "$".code)) {
				ok = false;
				break;
			}
		}
		if (ok && s.length > 0) return "@" + s;
		var b = new StringBuf();
		b.add('@"');
		for (k in 0...s.length) {
			var c = StringTools.fastCodeAt(s, k);
			if (c == '"'.code || c == "\\".code || c < 32 || c > 126) b.add("\\" + StringTools.hex(c, 2)) else b.addChar(c);
		}
		b.add('"');
		return b.toString();
	}

	// the function as LLVM IR into this module
	// display: the function's Haxe name (FuncRec.name; null: none)
	public function func(f:MFunc, ?display:String) {
		if (shared) lock.acquire();
		count++;
		defined.set(f.name, true);
		if (display != null) displays.set(f.name, display);
		try new FnWriter(this, f).write(out) catch (e:haxe.Exception) {
			if (shared) lock.release();
			throw e;
		}
		if (shared) lock.release();
	}

	var displays = new Map<String, String>();

	// ---- source lines (hxmc.ir.Lower.lines: the program reads its stacks, or
	// -debug): LLVM's debug locations from MIns.pos, a line-tables-only
	// compile unit; its line table read back from the object (lineTable) into
	// the functions' records (records), as the native emitters write them
	public var lines = false;
	// the program reads its stacks (Program.stacks): the frames as the native code has them
	public var keepFrames = false;

	static function mdString(s:String):String {
		var b = new StringBuf();
		b.add("\"");
		for (k in 0...s.length) {
			var c = StringTools.fastCodeAt(s, k);
			if (c == "\"".code || c == "\\".code || c < 32 || c > 126) b.add("\\" + StringTools.hex(c, 2)) else b.addChar(c);
		}
		b.add("\"");
		return b.toString();
	}

	@:allow(hxmc.LlvmGen.FnWriter)
	function diFile(file:String):String
		return md('!DIFile(filename: ${mdString(file)}, directory: "")');

	@:allow(hxmc.LlvmGen.FnWriter)
	function diUnit():String
		return md('distinct !DICompileUnit(language: DW_LANG_C99, file: ${diFile("hxmc")}, producer: "hxmc", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)');

	@:allow(hxmc.LlvmGen.FnWriter)
	function diSubprogram(name:String, file:String, line:Int):String {
		var f = diFile(file);
		return md('distinct !DISubprogram(name: ${mdString(name)}, scope: $f, file: $f, line: $line, type: ${md("!DISubroutineType(types: !{})")}, scopeLine: $line, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: ${diUnit()})');
	}

	// written to by the modules' threads (the whole program's: Driver.llvmFor)
	public var shared = false;
	final lock = new sys.thread.Mutex();

	// an object with the symbols the module's code refers to (undefined), for
	// the data, which makes some of them, when this module is compiled after
	// it (DataGen.allocStubs, cstrLiterals...)
	public function refs():Obj {
		var o = new Obj();
		for (m in [called, addressed, absolute, tls])
			for (k in m.keys())
				if (!defined.exists(k)) o.sym(k);
		return o;
	}

	// a program-wide number (Const of a symbol) in the text, replaced in
	// text(): by its value when known (-D hxmc.llvm-consts), else the address
	// of its extern_weak symbol
	static inline var ABS_OPEN = "%%abs(";
	static inline var ABS_CLOSE = ")%%";

	@:allow(hxmc.LlvmGen.FnWriter)
	function absRef(sym:String):String {
		useSym(sym, 2);
		return ABS_OPEN + sym + ABS_CLOSE;
	}

	function substAbs(text:String, abs:Null<Map<String, Int>>):String {
		var b = new StringBuf();
		var at = 0;
		while (true) {
			var k = text.indexOf(ABS_OPEN, at);
			if (k < 0) break;
			var e = text.indexOf(ABS_CLOSE, k);
			b.addSub(text, at, k - at);
			var sym = text.substring(k + ABS_OPEN.length, e);
			var v = abs != null ? abs.get(sym) : null;
			b.add(v != null ? Std.string(v) : 'ptrtoint (ptr ${name(sym)} to i64)');
			at = e + ABS_CLOSE.length;
		}
		b.addSub(text, at);
		return b.toString();
	}

	@:allow(hxmc.LlvmGen.FnWriter)
	function useSym(s:String, how:Int) {
		switch how {
			case 0: called.set(s, true);
			case 1: addressed.set(s, true);
			case 2: absolute.set(s, true);
			case 3: tls.set(s, true);
			case _: returnsTwice.set(s, true);
		}
	}

	// the alias classes tagged (hxmc.llvm-tbaa: a comma-separated list, or 1
	// for all; default: none). Off: correct on the corpus, but no gain measured
	// (docs/plans/llvm.md: the loops' slow-path calls reload everything anyway)
	static final TBAA_ALL = ["tls", "frame", "const", "hdr", "elem", "field", "global", "callonly"];
	var tbaaOn:Null<Map<String, Bool>>;
	public var tbaa:Null<String>; // (Options.llvmTbaa)
	public var flags:Null<String>; // (Options.llvmFlags)
	public var pgo:Null<String>; // (Options.llvmPgo: gen, or a profile)

	// the TBAA tag of an access of class c (a type of its own under hxmc's
	// root, one per thread-local variable: name), or "" when c is not tagged.
	// Accesses of two different types never alias for LLVM; untagged ones
	// may alias anything
	@:allow(hxmc.LlvmGen.FnWriter)
	function tbaaTag(c:String, name:String, ?parent:String):String {
		if (tbaaOn == null) {
			var e = tbaa;
			var on = new Map<String, Bool>();
			for (k in (e == null || e == "" || e == "0" ? [] : e == "1" ? TBAA_ALL : e.split(",")))
				on.set(StringTools.trim(k), true);
			tbaaOn = on;
		}
		if (!tbaaOn.exists(c)) return "";
		var root = md('!{!"hxmc"}');
		var up = parent == null ? root : md('!{!"$parent", $root, i64 0}');
		var ty = md('!{!"$name", $up, i64 0}');
		return ", !tbaa " + md('!{$ty, $ty, i64 0}');
	}

	// a metadata node (by its text, once per module): its reference
	@:allow(hxmc.LlvmGen.FnWriter)
	function md(text:String):String {
		var k = mdIndex.get(text);
		if (k == null) {
			k = mds.length;
			mds.push(text);
			mdIndex.set(text, k);
		}
		return "!" + k;
	}

	@:allow(hxmc.LlvmGen.FnWriter)
	static function symName(s:String):String
		return name(s);

	// the module as text
	public function text(?abs:Map<String, Int>):String {
		var b = new StringBuf();
		b.add('; hxmc module $module\n');
		b.add('target triple = "${triple(abi)}"\n\n');
		var tlsModel = abi.os == "linux" && abi.tls == LocalExec ? "thread_local(localexec)" : "thread_local";
		var offs = [for (k in tlsOff.keys()) k];
		offs.sort(Reflect.compare);
		for (s in offs)
			b.add('${name(s + TLS_OFF)} = external dso_local constant i32\n');
		if (offs.length > 0 && !defined.exists("hxmc_tls_base")) b.add("declare i64 @hxmc_tls_base() #3\n");
		var keys = [for (k in tls.keys()) k];
		keys.sort(Reflect.compare);
		for (s in keys)
			b.add('${name(s)} = external $tlsModel global i64\n');
		var done = new Map<String, Bool>();
		for (s in tls.keys())
			done.set(s, true);
		var fns = [for (k in called.keys()) if (!defined.exists(k) && !done.exists(k)) k];
		fns.sort(Reflect.compare);
		for (s in fns) {
			b.add('declare void ${name(s)}()${returnsTwice.exists(s) ? " returns_twice" : ""}\n');
			done.set(s, true);
		}
		var datas = [for (k in addressed.keys()) if (!defined.exists(k) && !done.exists(k)) k];
		datas.sort(Reflect.compare);
		for (s in datas) {
			// (a weak reference: the address may be anything, an absolute
			// symbol's too, so LLVM must not assume it is not null)
			b.add('${name(s)} = extern_weak global i8\n');
			done.set(s, true);
		}
		var abss = [for (k in absolute.keys()) if (!done.exists(k)) k];
		abss.sort(Reflect.compare);
		for (s in abss)
			b.add('${name(s)} = extern_weak global i8\n');
		var ints = [for (k in intrinsics.keys()) k];
		ints.sort(Reflect.compare);
		for (k in ints)
			b.add(k + "\n");
		b.add("\n");
		b.add(substAbs(out.toString(), abs));
		// (a program that reads its stacks keeps the frames the native code has:
		// LLVM inlines nothing more than hxmc did, nor turns calls into jumps)
		b.add('\nattributes #0 = { nounwind uwtable "frame-pointer"="all"${keepFrames ? ' noinline "disable-tail-calls"="true"' : ""} }\n');
		b.add('attributes #1 = { noreturn nounwind }\n');
		b.add('attributes #2 = { returns_twice }\n');
		b.add('attributes #3 = { nounwind willreturn memory(none) }\n');
		if (lines && count > 0) {
			var cu = diUnit();
			var v = md("!{i32 7, !\"Dwarf Version\", i32 4}"), dv = md("!{i32 2, !\"Debug Info Version\", i32 3}");
			b.add('!llvm.dbg.cu = !{$cu}\n!llvm.module.flags = !{$v, $dv}\n');
		}
		for (k in 0...mds.length)
			b.add('!$k = ${mds[k]}\n');
		return b.toString();
	}

	// ---- the functions' records (Driver: into the object LLVM's code is in)

	// per function (LLVM's): its rows, three numbers each (offset, file in
	// rowFiles, line), from the object's line table
	var rows = new Map<String, Array<Int>>();
	var rowFiles:Array<String> = [];

	// the records of this module's functions, into obj (where their symbols
	// are defined): no unwind operations, the Haxe name and lines when lines
	public function records(obj:Obj) {
		var fileAt = new Map<String, Int>();
		for (k in 0...obj.files.length)
			fileAt.set(obj.files[k], k);
		function file(f:String):Int {
			var k = fileAt.get(f);
			if (k == null) {
				k = obj.files.length;
				obj.files.push(f);
				fileAt.set(f, k);
			}
			return k;
		}
		var names = [for (n in defined.keys()) n];
		names.sort(Reflect.compare);
		for (n in names) {
			if (!obj.exists(n)) continue;
			var s = obj.sym(n);
			if (s.section == null) continue;
			// (an arm64 frame: CFI for the system's unwinders, Unwind.LLVMFRAME; else none)
			var enc = encodings.get(n), dw = dwarfCfi.get(n);
			var ops = if (dw != null) {
				// (LLVMCFI, 0, the count, 0, then the bytes + 256, padded to fours)
				var l = [Unwind.LLVMCFI, 0, dw.length, 0].concat([for (x in dw) x + 256]);
				while (l.length % 4 != 0)
					l.push(256);
				haxe.ds.Vector.fromArrayCopy(l);
			} else if (enc != null && (enc & 0x0F000000) == 0x04000000) core.ds.VectorTools.vector(Unwind.LLVMFRAME, 0, enc, 0) else core.ds.VectorTools.vector(Unwind.NONE, 0, 0, 0);
			var r = new FuncRec(s, ops);
			if (lines) {
				r.name = displays.exists(n) ? displays.get(n) : n;
				var rs = rows.get(n);
				var v = new haxe.ds.Vector<Int>(rs == null ? 0 : rs.length);
				if (rs != null) {
					var k = 0;
					while (k < rs.length) {
						v[k] = rs[k];
						v[k + 1] = file(rowFiles[rs[k + 1]]);
						v[k + 2] = rs[k + 2];
						k += 3;
					}
				}
				r.lines = v;
			}
			obj.funcs.push(r);
		}
	}

	// the compact unwind encodings of the module's functions (__LD,__compact_unwind:
	// 32-byte entries, the function's address relocated, its encoding at 12),
	// then the section dropped
	var encodings = new Map<String, Int>();

	function frames(obj:Obj) {
		var cu = null;
		for (s in obj.sections)
			if (s.name == "__LD,__compact_unwind") cu = s;
		if (cu == null) return;
		var byOff = new Map<String, String>();
		for (s in obj.symbols)
			if (s.section != null && s.section.kind == Text && defined.exists(s.name)) byOff.set(s.section.name + "@" + s.offset, s.name);
		for (r in cu.relocs) {
			if (r.offset % 32 != 0) continue;
			var t = r.sym;
			if (t.section == null) continue;
			var fn = byOff.get(t.section.name + "@" + (t.offset + r.addend));
			if (fn != null) encodings.set(fn, cu.buf.get32(r.offset + 12));
		}
		obj.sections.remove(cu);
		for (s in obj.symbols.copy())
			if (s.section == cu) {
				s.section = null;
				s.global = false;
			}
	}

	// the CFI of the module's functions LLVM describes in DWARF (compact
	// unwind's DWARF mode: the object's __eh_frame), by function: the FDE's
	// instructions, their advances rescaled to hxmc's CIE (Unwind.cie: code
	// alignment 4 on arm64, data alignment -8, the CFA at sp on entry), as
	// LLVMCFI operations (Unwind.cfi)
	var dwarfCfi = new Map<String, Array<Int>>();

	function ehFrame(b:Bytes, obj:Obj) {
		var secs = machoSections(b);
		var eh = -1, text = null;
		for (k in 0...secs.length) {
			if (secs[k].sect == "__eh_frame") eh = k;
			if (secs[k].seg == "__TEXT" && secs[k].sect == "__text") text = secs[k];
		}
		if (eh < 0 || text == null) return;
		var s = secs[eh];
		// the section's relocations and the symbol table (raw: an FDE's start
		// is a SUBTRACTOR pair, its UNSIGNED half names the function or a
		// label before it, the field the distance from that)
		var hdr = -1, k = 0, symoff = 0, nsyms = 0;
		for (c in MachOReader.commands(b)) {
			if (c.cmd == 0x19)
				for (j in 0...b.getInt32(c.at + 64)) {
					if (k == eh) hdr = c.at + 72 + 80 * j;
					k++;
				}
			if (c.cmd == 0x2) {
				symoff = b.getInt32(c.at + 8);
				nsyms = b.getInt32(c.at + 12);
			}
		}
		if (hdr < 0) return;
		var reloff = b.getInt32(hdr + 56), nreloc = b.getInt32(hdr + 60);
		var targetAt = new Map<Int, {sym:Int, ext:Bool, len:Int}>();
		var minusAt = new Map<Int, Int>(); // (the SUBTRACTOR's symbol, M)
		for (j in 0...nreloc) {
			var at = b.getInt32(reloff + 8 * j), info = b.getInt32(reloff + 8 * j + 4);
			var type = (info >>> 28) & 0xf;
			if (type == 0) targetAt.set(at, {sym: info & 0xffffff, ext: (info >>> 27) & 1 == 1, len: (info >>> 25) & 3});
			if (type == 1) minusAt.set(at, info & 0xffffff);
		}
		function symValue(n:Int):Int
			return b.getInt32(symoff + 16 * n + 8);
		// the functions by address
		var fns = new Map<Int, String>();
		for (sy in obj.symbols)
			if (sy.section != null && sy.section.kind == Text && defined.exists(sy.name)) fns.set(text.addr + sy.offset, sy.name);
		var p = s.off, end = s.off + s.size;
		function uleb():Int {
			var r = 0, sh = 0, c;
			do {
				c = b.get(p++);
				r |= (c & 0x7f) << sh;
				sh += 7;
			} while (c & 0x80 != 0);
			return r;
		}
		function sleb():Int {
			var r = 0, sh = 0, c;
			do {
				c = b.get(p++);
				r |= (c & 0x7f) << sh;
				sh += 7;
			} while (c & 0x80 != 0);
			if (sh < 32 && (c & 0x40) != 0) r |= -1 << sh;
			return r;
		}
		var cies = new Map<Int, {codeAlign:Int, dataAlign:Int, ptr:Int, aug:Bool}>();
		while (p + 8 <= end) {
			var at = p;
			var len = b.getInt32(p);
			if (len == 0) break;
			var next = p + 4 + len;
			var id = b.getInt32(p + 4);
			p += 8;
			if (id == 0) {
				// a CIE: version, augmentation, alignments, the return register, its data
				p++;
				var e = p;
				while (b.get(e) != 0)
					e++;
				var aug = b.getString(p, e - p);
				p = e + 1;
				var ca = uleb(), da = sleb();
				p++; // (the return address register)
				var ptr = 0;
				if (StringTools.startsWith(aug, "z")) {
					uleb();
					for (ch in aug.substr(1).split(""))
						switch ch {
							case "R": ptr = b.get(p++);
							case "P":
								var enc = b.get(p++);
								p += (enc & 0x0f) == 0x0b ? 4 : 8;
							case "L": p++;
							case _:
						}
				}
				cies.set(at, {codeAlign: ca, dataAlign: da, ptr: ptr, aug: StringTools.startsWith(aug, "z")});
				p = next;
				continue;
			}
			var cie = cies.get(p - 4 - id);
			var field = p;
			var t = targetAt.get(field - s.off);
			if (cie == null || t == null || !t.ext) {
				p = next;
				continue;
			}
			var wide = (cie.ptr & 0x0f) != 0x0b;
			// (T - M + field, the start relative to the field: T + field + (P - M))
			var m = minusAt.get(field - s.off);
			var addend = b.getInt32(field) + (m == null ? 0 : s.addr + (field - s.off) - symValue(m));
			var fn = fns.get(symValue(t.sym) + addend);
			p += wide ? 16 : 8; // (start and range)
			if (cie.aug) p += uleb();
			if (fn == null || cie.dataAlign != -8) {
				p = next;
				continue;
			}
			// the instructions, advances rescaled (arm64: 4-byte instructions)
			var out = [];
			var scale = cie.codeAlign, unit = abi.arm ? 4 : 1;
			function adv(d:Int) {
				var n = Std.int(d * scale / unit);
				if (n < 64) out.push(0x40 | n) else if (n < 256) {
					out.push(0x02);
					out.push(n);
				} else if (n < 65536) {
					out.push(0x03);
					out.push(n & 0xff);
					out.push(n >> 8);
				} else {
					out.push(0x04);
					for (q in 0...4)
						out.push((n >> (8 * q)) & 0xff);
				}
			}
			var ok = true;
			while (p < next && ok) {
				var op = b.get(p++);
				var from = p;
				switch op >> 6 {
					case 1:
						adv(op & 0x3f);
						continue;
					case 2:
						out.push(op);
						uleb();
					case 3:
						out.push(op);
					case _:
						switch op {
							case 0x00 | 0x0a | 0x0b | 0x2d:
								out.push(op);
							case 0x02:
								adv(b.get(p++));
								continue;
							case 0x03:
								adv(b.getUInt16(p));
								p += 2;
								continue;
							case 0x04:
								adv(b.getInt32(p));
								p += 4;
								continue;
							case 0x0c | 0x05 | 0x09:
								out.push(op);
								uleb();
								uleb();
							case 0x0d | 0x0e | 0x06 | 0x07 | 0x08 | 0x2e:
								out.push(op);
								uleb();
							case 0x11 | 0x12:
								out.push(op);
								uleb();
								sleb();
							case 0x13:
								out.push(op);
								sleb();
							case _:
								ok = false;
						}
				}
				// (the operands as they were)
				for (q in from...p)
					out.push(b.get(q));
			}
			if (ok) dwarfCfi.set(fn, out);
			p = next;
		}
	}

	// a Mach-O object's sections: name, address, size, file offset
	static function machoSections(b:Bytes):Array<{seg:String, sect:String, addr:Int, size:Int, off:Int}> {
		var out = [];
		inline function cstr(at:Int, max:Int):String {
			var e = at;
			while (e - at < max && b.get(e) != 0)
				e++;
			return b.getString(at, e - at);
		}
		for (c in MachOReader.commands(b))
			if (c.cmd == 0x19) {
				var n = b.getInt32(c.at + 64);
				for (k in 0...n) {
					var s = c.at + 72 + 80 * k;
					out.push({sect: cstr(s, 16), seg: cstr(s + 16, 16), addr: b.getInt32(s + 32), size: b.getInt32(s + 40), off: b.getInt32(s + 48)});
				}
			}
		return out;
	}

	// the sizes of the module's functions in the object (Mach-O symbols have
	// none): to the next symbol of their section, or its end
	function sizeFunctions(obj:Obj) {
		var bySec = new haxe.ds.ObjectMap<Obj.Section, Array<Symbol>>();
		for (s in obj.symbols)
			if (s.section != null && s.section.kind == Text) {
				var l = bySec.get(s.section);
				if (l == null) bySec.set(s.section, l = []);
				l.push(s);
			}
		for (sec => l in bySec) {
			l.sort((a, b) -> a.offset - b.offset);
			for (k in 0...l.length) {
				var s = l[k];
				if (!defined.exists(s.name) || s.size > 0) continue;
				var end = sec.buf.len;
				for (j in k + 1...l.length)
					if (l[j].offset > s.offset) {
						end = l[j].offset;
						break;
					}
				s.size = end - s.offset;
			}
		}
	}

	// the object's line table (DWARF 4 __debug_line: LLVM's, a line-tables-only
	// unit) as rows of this module's functions (rows, rowFiles)
	function lineTable(b:Bytes, obj:Obj) {
		var secs = machoSections(b);
		var text = null, dl = null;
		for (s in secs) {
			if (s.seg == "__TEXT" && s.sect == "__text") text = s;
			if (s.sect == "__debug_line") dl = s;
		}
		if (text == null || dl == null) return;
		// the functions by their address in the object
		var fns = [];
		for (s in obj.symbols)
			if (s.section != null && s.section.kind == Text && defined.exists(s.name)) fns.push({at: text.addr + s.offset, size: s.size, name: s.name});
		linePrograms(b, dl.off, dl.off + dl.size, fns, p -> b.getInt32(p));
	}

	// the same of an ELF object: DW_LNE_set_address's operand is 0 in the
	// section, its address a relocation (RELA: a symbol plus the addend); each
	// text section placed after the one before (the functions' addresses and
	// the rows' only need to agree)
	function elfLineTable(b:Bytes, obj:Obj) {
		var shoff = b.getInt32(40), shnum = b.getUInt16(60), shstrndx = b.getUInt16(62);
		inline function sh(i:Int)
			return shoff + 64 * i;
		var strOff = b.getInt32(sh(shstrndx) + 24);
		function cstr(at:Int):String {
			var e = at;
			while (b.get(e) != 0)
				e++;
			return b.getString(at, e - at);
		}
		var dl = -1, rela = -1, symtab = -1;
		for (i in 0...shnum) {
			var h = sh(i), type = b.getInt32(h + 4);
			if (type == 2) symtab = i;
			if (type == 1 && cstr(strOff + b.getInt32(h)) == ".debug_line") dl = i;
		}
		if (dl < 0 || symtab < 0) return;
		for (i in 0...shnum)
			if (b.getInt32(sh(i) + 4) == 4 && b.getInt32(sh(i) + 44) == dl) rela = i;
		// the text sections' places (by ELF index)
		var base = new Map<Int, Int>(), at = 0;
		for (s in obj.sections)
			if (s.kind == Text) {
				base.set(s.index, at);
				at += (s.buf.len + 15) & ~15;
			}
		var fns = [];
		for (s in obj.symbols)
			if (s.section != null && s.section.kind == Text && defined.exists(s.name) && base.exists(s.section.index))
				fns.push({at: base.get(s.section.index) + s.offset, size: s.size, name: s.name});
		// each relocated operand's address (its offset in the section: symbol + addend)
		var dlOff = b.getInt32(sh(dl) + 24), dlSize = b.getInt32(sh(dl) + 32);
		var addrs = new Map<Int, Int>();
		if (rela >= 0) {
			var symOff = b.getInt32(sh(symtab) + 24);
			var off = b.getInt32(sh(rela) + 24), n = Std.int(b.getInt32(sh(rela) + 32) / 24);
			for (k in 0...n) {
				var r = off + 24 * k;
				var y = symOff + 24 * b.getInt32(r + 12);
				var bs = base.get(b.getUInt16(y + 6));
				if (bs != null) addrs.set(dlOff + b.getInt32(r), bs + b.getInt32(y + 8) + b.getInt32(r + 16));
			}
		}
		linePrograms(b, dlOff, dlOff + dlSize, fns, p -> addrs.exists(p) ? addrs.get(p) : -1);
	}

	// the line programs of a DWARF 4 line table (bytes [p, end) of b) as rows of
	// the functions fns (their addresses as setAddr's: the address of the operand
	// of DW_LNE_set_address at an offset in b)
	function linePrograms(b:Bytes, p:Int, end:Int, fns:Array<{at:Int, size:Int, name:String}>, setAddr:Int->Int) {
		fns.sort((x, y) -> x.at - y.at);
		function fnAt(a:Int):Null<{at:Int, size:Int, name:String}> {
			var lo = 0, hi = fns.length - 1, r = null;
			while (lo <= hi) {
				var m = (lo + hi) >> 1;
				if (fns[m].at <= a) {
					r = fns[m];
					lo = m + 1;
				} else hi = m - 1;
			}
			return r != null && a < r.at + r.size ? r : null;
		}
		inline function u8():Int return b.get(p++);
		function uleb():Int {
			var r = 0, sh = 0, c;
			do {
				c = b.get(p++);
				r |= (c & 0x7f) << sh;
				sh += 7;
			} while (c & 0x80 != 0);
			return r;
		}
		function sleb():Int {
			var r = 0, sh = 0, c;
			do {
				c = b.get(p++);
				r |= (c & 0x7f) << sh;
				sh += 7;
			} while (c & 0x80 != 0);
			if (sh < 32 && (c & 0x40) != 0) r |= -1 << sh;
			return r;
		}
		function cstr():String {
			var e = p;
			while (b.get(e) != 0)
				e++;
			var s = b.getString(p, e - p);
			p = e + 1;
			return s;
		}
		while (p < end) {
			var unitEnd = p + 4 + b.getInt32(p);
			p += 4;
			var version = b.getUInt16(p);
			p += 2;
			if (version != 4) throw "hxmc: llvm: DWARF line table version " + version;
			var hdrLen = b.getInt32(p);
			p += 4;
			var progStart = p + hdrLen;
			var minInst = u8();
			u8(); // (maximum operations per instruction)
			u8(); // (default is_stmt)
			var lineBase = u8();
			if (lineBase > 127) lineBase -= 256;
			var lineRange = u8(), opBase = u8();
			var opLens = [for (_ in 1...opBase) u8()];
			while (b.get(p) != 0)
				cstr(); // (include directories)
			p++;
			var files = [""];
			while (b.get(p) != 0) {
				files.push(cstr());
				uleb();
				uleb();
				uleb();
			}
			p = progStart;
			// the state machine
			var addr = 0, fileK = 1, line = 1;
			// (no row at line 0, code without a position: the row before holds, as
			// the native emitters record none for it)
			function row() {
				var fn = fnAt(addr);
				if (fn == null || line == 0) return;
				var rs = rows.get(fn.name);
				if (rs == null) rows.set(fn.name, rs = []);
				var f = files[fileK];
				var fk = rowFiles.indexOf(f);
				if (fk < 0) {
					fk = rowFiles.length;
					rowFiles.push(f);
				}
				rs.push(addr - fn.at);
				rs.push(fk);
				rs.push(line);
			}
			while (p < unitEnd) {
				var op = u8();
				if (op >= opBase) {
					var adj = op - opBase;
					addr += Std.int(adj / lineRange) * minInst;
					line += lineBase + adj % lineRange;
					row();
					continue;
				}
				switch op {
					case 0:
						var len = uleb(), next = p + len, sub = u8();
						switch sub {
							case 1:
								addr = 0;
								fileK = 1;
								line = 1;
							case 2: addr = setAddr(p);
							case _:
						}
						p = next;
					case 1: row();
					case 2: addr += uleb() * minInst;
					case 3: line += sleb();
					case 4: fileK = uleb();
					case 5: uleb();
					case 8: addr += Std.int((255 - opBase) / lineRange) * minInst;
					case 9:
						addr += b.getUInt16(p);
						p += 2;
					case 6 | 7 | 10 | 11:
					case _:
						for (_ in 0...opLens[op - 1])
							uleb();
				}
			}
			p = unitEnd;
		}
	}

	// the module compiled to an object (null: nothing to compile)
	public function compile(?abs:Map<String, Int>):Null<Obj> {
		if (count == 0) return null;
		var safe = ~/[^A-Za-z0-9_.-]/g.replace(module, "_");
		var ll = dir + "/" + safe + ".ll", o = dir + "/" + safe + ".o";
		sys.io.File.saveContent(ll, text(abs));
		var args = ["-target", triple(abi), "-" + optLevel, "-c", "-Wno-override-module", ll, "-o", o];
		// (hxmc.llvm-flags: more of clang's arguments, separated by spaces)
		// (arm64: no ldp/stp pairing of neighbouring loads and stores, whose
		// partial overlaps defeat store-to-load forwarding: nbody 1.75x slower with it)
		if (abi.arm) args = args.concat(["-mllvm", "-aarch64-enable-ldst-opt=0"]);
		// (a trap after a call that does not return: the return address, which
		// names the frame in a stack, stays in the caller rather than at the
		// next function)
		args = args.concat(["-mllvm", "-trap-unreachable"]);
		// (profile-guided optimization: Driver links the profile runtime with gen)
		if (pgo == "gen") args.push("-fprofile-generate") else if (pgo != null) args = args.concat(["-fprofile-use=" + pgo, "-Wno-backend-plugin", "-Wno-profile-instr-unprofiled"]);
		// (-D hxmc.llvm-cpu: the oldest CPU the program runs on; clang's default is the target's baseline: apple-m1 on macOS arm64, x86-64 v1)
		if (cpu != null) args.push((abi.arm ? "-mcpu=" : "-march=") + cpu);
		var extra = flags;
		if (extra != null) for (a in extra.split(" ")) if (a != "") args.push(a);
		var p = new sys.io.Process(clang, args);
		var err = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		if (code != 0) throw 'hxmc: llvm: clang failed on $ll ($code):\n$err';
		var bytes = sys.io.File.getBytes(o);
		var obj = switch abi.os {
			case "macos":
				var mo = MachOReader.read(bytes, true).obj;
				sizeFunctions(mo);
				frames(mo);
				ehFrame(bytes, mo);
				if (lines) lineTable(bytes, mo);
				mo;
			case "windows": CoffReader.read(bytes).obj;
			case _:
				var eo = ElfReader.read(bytes);
				if (lines) elfLineTable(bytes, eo);
				eo;
		}
		obj.ehFrame = null;
		// (the offsets of the thread-local variables in the TLS template: tlsAddr)
		if (tlsOff.keys().hasNext()) {
			var ro = obj.section(".rodata.hxmc_tlsoff", RoData, 8);
			var names = [for (k in tlsOff.keys()) k];
			names.sort(Reflect.compare);
			for (n in names) {
				ro.buf.align(8);
				var at = ro.buf.len;
				ro.buf.u32(0);
				ro.buf.u32(0);
				var v = obj.sym(n);
				v.tls = true;
				ro.relocs.push(new Reloc(at, RSecRel32, v, 0));
				obj.define(n + TLS_OFF, ro, at, 4, false);
			}
		}
		return obj;
	}
}

// one function
@:access(hxmc.LlvmGen)
private class FnWriter {
	final g:LlvmGen;
	final f:MFunc;
	var b:StringBuf;
	var tmp = 0;
	var alias:Array<Int> = [];
	var reach:Map<Int, Bool>;
	// values live into a handler block: their volatile slot; the blocks reachable from a handler
	var slotOf = new Map<Int, String>();
	var inHandler = new Map<Int, Bool>();

	public function new(g, f) {
		this.g = g;
		this.f = f;
	}

	inline function t():String
		return "%t" + (tmp++);

	// the debug location of the instructions written (g.lines; null: none)
	var dbg:Null<String> = null;
	var sp:Null<String> = null;
	var spFile = "";

	function line(s:String) {
		b.add("  ");
		b.add(s);
		if (dbg != null && s.indexOf(" = phi ") < 0) {
			b.add(", !dbg ");
			b.add(dbg);
		}
		b.add("\n");
	}

	function res(id:Int):Int {
		while (alias[id] >= 0)
			id = alias[id];
		return id;
	}

	// a value as an operand (in block `at`: through its slot there when it lives across a setjmp)
	function v(id:Int, at:MBlock):String {
		id = res(id);
		var i = f.vals[id];
		var s = slotOf.get(id);
		if (s != null && inHandler.exists(at.id)) {
			var r = t();
			line('$r = load volatile ${LlvmGen.ty(i.ty)}, ptr $s');
			return r;
		}
		return "%v" + id;
	}

	function vt(id:Int, at:MBlock):String
		return LlvmGen.ty(f.vals[res(id)].ty) + " " + v(id, at);

	static function int64(lo:Int, hi:Int):String
		return Int64.toStr(Int64.make(hi, lo));

	static function double(x:Float):String {
		var bits = haxe.io.FPHelper.doubleToI64(x);
		return "0x" + StringTools.hex(bits.high, 8) + StringTools.hex(bits.low, 8);
	}

	function ptr(i:MIns, at:MBlock):String {
		// base + index * scale + displacement
		var addr = v(i.a, at);
		if (i.b >= 0) {
			var ix = v(i.b, at);
			if (f.vals[res(i.b)].ty == I32) {
				var w = t();
				line('$w = sext i32 $ix to i64');
				ix = w;
			}
			var m = t();
			line('$m = mul i64 $ix, ${i.imm2}');
			var s = t();
			line('$s = add i64 $addr, $m');
			addr = s;
		}
		if (i.imm != 0) {
			var s = t();
			line('$s = add i64 $addr, ${i.imm}');
			addr = s;
		}
		var p = t();
		line('$p = inttoptr i64 $addr to ptr');
		return p;
	}

	static function memTy(t:MTy, size:Int):String
		return t == F64 ? (size == 4 ? "float" : "double") : switch size {
			case 1: "i8";
			case 2: "i16";
			case 4: "i32";
			case _: "i64";
		};

	function reachable() {
		reach = new Map();
		var stack = [f.entry];
		reach.set(f.entry.id, true);
		while (stack.length > 0) {
			var bl = stack.pop();
			for (s in bl.succs)
				if (!reach.exists(s.id)) {
					reach.set(s.id, true);
					stack.push(s);
				}
		}
	}

	// the values live into a handler block (the second return of setjmp):
	// LLVM may keep them in registers the code after setjmp reuses, which
	// longjmp does not restore, so they go through volatile slots, stored
	// where they are made and read where code reachable from a handler uses
	// them (the slot holds the value's last definition, as in reg2mem)
	function handlerSlots() {
		var handlers = [for (bl in f.blocks) if (bl.handler && reach.exists(bl.id)) bl];
		if (handlers.length == 0) return;
		var stack = handlers.copy();
		for (h in handlers)
			inHandler.set(h.id, true);
		while (stack.length > 0) {
			var bl = stack.pop();
			for (s in bl.succs)
				if (!inHandler.exists(s.id)) {
					inHandler.set(s.id, true);
					stack.push(s);
				}
		}
		// liveness: live-in = uses (not phis) + (live-out - defs); a phi's argument is used at the end of its pred
		var blocks = [for (bl in f.blocks) if (reach.exists(bl.id)) bl];
		var liveIn = new Map<Int, Map<Int, Bool>>();
		for (bl in blocks)
			liveIn.set(bl.id, new Map());
		var changed = true;
		while (changed) {
			changed = false;
			var k = blocks.length;
			while (k-- > 0) {
				var bl = blocks[k];
				var live = new Map<Int, Bool>();
				for (s in bl.succs) {
					if (!reach.exists(s.id)) continue;
					for (x in liveIn.get(s.id).keys())
						live.set(x, true);
					var pi = s.preds.indexOf(bl);
					for (i in s.ins)
						if (!i.dead && i.op == Phi && pi >= 0 && pi < i.args.length) live.set(res(i.args[pi]), true);
				}
				var j = bl.ins.length;
				while (j-- > 0) {
					var i = bl.ins[j];
					if (i.dead) continue;
					live.remove(i.id);
					if (i.op == Phi) continue;
					for (x in operands(i))
						live.set(res(x), true);
				}
				var old = liveIn.get(bl.id);
				for (x in live.keys())
					if (!old.exists(x)) {
						old.set(x, true);
						changed = true;
					}
			}
		}
		for (h in handlers)
			for (x in liveIn.get(h.id).keys()) {
				var i = f.vals[x];
				if (i.op == Const || i.op == ConstF || i.op == SymAddr || i.op == StackAddr) continue;
				slotOf.set(x, "%s" + x);
			}
	}

	static function operands(i:MIns):Array<Int> {
		var r = [];
		if (i.a >= 0) r.push(i.a);
		if (i.b >= 0) r.push(i.b);
		if (i.c >= 0) r.push(i.c);
		if (i.op != Switch) for (x in i.args)
			r.push(x);
		return r;
	}

	public function write(into:StringBuf) {
		alias = [for (_ in 0...f.vals.length) -1];
		for (bl in f.blocks)
			for (i in bl.ins)
				if (!i.dead && i.op == Copy) alias[i.id] = i.a;
		reachable();
		handlerSlots();
		var ps = [for (k in 0...f.params.length) LlvmGen.ty(f.params[k] == Void ? I64 : f.params[k]) + " %p" + k];
		if (g.lines) {
			// (the subprogram at the function's first position; instructions before any at line 0)
			var file = "", ln = 0;
			for (bl in f.blocks) {
				for (i in bl.ins)
					if (!i.dead && i.pos != 0) {
						var p = SrcPos.get(i.pos);
						file = p.file;
						ln = p.line;
						break;
					}
				if (file != "") break;
			}
			sp = g.diSubprogram(f.name, file, ln);
			spFile = file;
			dbg = g.md('!DILocation(line: 0, column: 0, scope: $sp)');
		}
		into.add('define ${LlvmGen.ty(f.ret)} ${LlvmGen.symName(f.name)}(${ps.join(", ")}) #0${sp != null ? " !dbg " + sp : ""} {\n');
		// each block's body and terminator apart: a phi's argument read from a
		// slot is loaded at the end of its pred (pending), before the terminator
		var bodies = [], terms = [], order = [];
		for (bl in f.blocks) {
			if (!reach.exists(bl.id)) continue;
			if (order.length == 0 && bl != f.entry) throw "hxmc: llvm: the entry is not the first block";
			order.push(bl);
			b = new StringBuf();
			var tb = new StringBuf();
			var phisDone = false;
			for (i in bl.ins) {
				if (i.dead) continue;
				if (i.op != Phi && !phisDone) {
					phisDone = true;
					for (p in bl.ins)
						if (!p.dead && p.op == Phi && slotOf.exists(p.id)) line('store volatile ${LlvmGen.ty(p.ty)} %v${p.id}, ptr ${slotOf.get(p.id)}');
				}
				if (i.isTerm()) {
					var body = b;
					b = tb;
					ins(bl, i);
					b = body;
				} else {
					ins(bl, i);
					if (i.op != Phi && slotOf.exists(i.id)) line('store volatile ${LlvmGen.ty(i.ty)} %v${i.id}, ptr ${slotOf.get(i.id)}');
				}
			}
			bodies.push(b.toString());
			terms.push(tb.toString());
		}
		for (k in 0...order.length) {
			var bl = order[k];
			into.add('b${bl.id}:\n');
			if (k == 0) {
				for (x in slotOf.keys())
					into.add('  %s$x = alloca ${LlvmGen.ty(f.vals[x].ty)}\n');
				for (j in 0...f.slots.length) {
					var sl = f.slots[j];
					into.add('  %slot$j = alloca [${sl.size > 0 ? sl.size : 1} x i8], align ${sl.align > 0 ? sl.align : 8}\n');
				}
			}
			into.add(bodies[k]);
			var pl = pending.get(bl.id);
			if (pl != null) for (l in pl)
				into.add('  $l\n');
			into.add(terms[k]);
		}
		into.add("}\n\n");
		for (k in intrinsics.keys())
			g.intrinsics.set(k, true);
	}

	function cond(c:Cond):String
		return switch c {
			case CEq: "icmp eq";
			case CNe: "icmp ne";
			case CLt: "icmp slt";
			case CLe: "icmp sle";
			case CGt: "icmp sgt";
			case CGe: "icmp sge";
			case CULt: "icmp ult";
			case CULe: "icmp ule";
			case CUGt: "icmp ugt";
			case CUGe: "icmp uge";
			case FEq: "fcmp oeq";
			case FNe: "fcmp une";
			case FLt: "fcmp olt";
			case FLe: "fcmp ole";
			case FGt: "fcmp ogt";
			case FGe: "fcmp oge";
		};

	function ins(bl:MBlock, i:MIns) {
		if (sp != null && i.pos != 0) {
			// (code of another file, inlined: a scope of that file in the subprogram)
			var p = SrcPos.get(i.pos);
			var scope = p.file == spFile ? sp : g.md('!DILexicalBlockFile(scope: $sp, file: ${g.diFile(p.file)}, discriminator: 0)');
			dbg = g.md('!DILocation(line: ${p.line}, column: 0, scope: $scope)');
		}
		var d = "%v" + i.id;
		var T = LlvmGen.ty(i.ty);
		// (an operand of another width: as the machine has it, an I32 zero-extended in its register)
		inline function bin(op:String)
			line('$d = $op $T ${conv(i.a, i.ty, bl)}, ${conv(i.b, i.ty, bl)}');
		switch i.op {
			case Param:
				// (a copy, so that a parameter is a value like the others)
				var pt = f.params[i.imm] == Void ? I64 : f.params[i.imm];
				if (i.ty == Void) {} else if (pt != i.ty) throw 'hxmc: llvm: parameter ${i.imm} of type ${LlvmGen.ty(pt)} read as ${T}' else
					line(i.ty == F64 ? '$d = fadd double %p${i.imm}, -0.0' : '$d = add $T %p${i.imm}, 0');
			case Const:
				if (i.sym != null) {
					var a = t();
					line('$a = add i64 ${g.absRef(i.sym)}, 0');
					var s = a;
					if (i.imm != 0) {
						s = t();
						line('$s = add i64 $a, ${i.imm}');
					}
					line(i.ty == I32 ? '$d = trunc i64 $s to i32' : '$d = add i64 $s, 0');
				} else
					line(i.ty == I32 ? '$d = add i32 ${i.imm}, 0' : '$d = add i64 ${int64(i.imm, i.imm2)}, 0');
			case ConstF:
				line('$d = fadd double ${double(i.f)}, -0.0');
			case SymAddr:
				g.useSym(i.sym, 1);
				line('$d = ptrtoint ptr getelementptr (i8, ptr ${LlvmGen.symName(i.sym)}, i64 ${i.imm}) to i64');
			case TlsLoad:
				g.useSym(i.sym, 3);
				line('$d = load i64, ptr ${tlsAddr(i.sym)}, align 8${g.tbaaTag("tls", "tls." + i.sym)}');
			case TlsStore:
				g.useSym(i.sym, 3);
				var val = vt(i.a, bl);
				line('store $val, ptr ${tlsAddr(i.sym)}, align 8${g.tbaaTag("tls", "tls." + i.sym)}');
			case StackAddr:
				line('$d = ptrtoint ptr %slot${i.imm} to i64');
			case Copy:
			// (an alias: res)
			case Phi:
				// (an entry per edge: a switch with several cases to this block, or a
				// branch with both targets here, is a pred once in Mir and as many
				// times as it has edges here in LLVM)
				var parts = [], seen = new Map<Int, Bool>();
				for (k in 0...bl.preds.length) {
					var p = bl.preds[k];
					if (!reach.exists(p.id) || k >= i.args.length || seen.exists(p.id)) continue;
					seen.set(p.id, true);
					var tm = p.term(), edges = 0;
					if (tm != null) for (t in tm.targets) if (t == bl) edges++;
					var e = '[ ${phiArg(i.args[k], p)}, %b${p.id} ]';
					for (_ in 0...(edges > 1 ? edges : 1))
						parts.push(e);
				}
				line('$d = phi $T ${parts.join(", ")}');
			case Add: bin("add");
			case Sub: bin("sub");
			case Mul: bin("mul");
			case And: bin("and");
			case Or: bin("or");
			case Xor: bin("xor");
			case Shl | Sar | Shr:
				var c = t();
				line('$c = and $T ${count(i, bl)}, ${i.ty == I32 ? 31 : 63}');
				line('$d = ${i.op == Shl ? "shl" : i.op == Sar ? "ashr" : "lshr"} $T ${v(i.a, bl)}, $c');
			case Rotr:
				var a = v(i.a, bl);
				line('$d = call $T @llvm.fshr.$T($T $a, $T $a, $T ${count(i, bl)})');
				intrinsic('declare $T @llvm.fshr.$T($T, $T, $T)');
			case Neg:
				line('$d = sub $T 0, ${v(i.a, bl)}');
			case Not:
				line('$d = xor $T ${v(i.a, bl)}, -1');
			case Div: bin("sdiv");
			case Rem: bin("srem");
			case UDiv: bin("udiv");
			case URem: bin("urem");
			case FAdd: bin("fadd");
			case FSub: bin("fsub");
			case FMul: bin("fmul");
			case FDiv: bin("fdiv");
			case FNeg:
				line('$d = fneg double ${v(i.a, bl)}');
			case FSqrt:
				line('$d = call double @llvm.sqrt.f64(double ${v(i.a, bl)})');
				intrinsic("declare double @llvm.sqrt.f64(double)");
			case FAbs:
				line('$d = call double @llvm.fabs.f64(double ${v(i.a, bl)})');
				intrinsic("declare double @llvm.fabs.f64(double)");
			case Cmp:
				var at = LlvmGen.ty(f.vals[res(i.a)].ty);
				var c = t();
				var ca = f.vals[res(i.a)].ty;
				line('$c = ${cond(i.imm)} $at ${v(i.a, bl)}, ${conv(i.b, ca, bl)}');
				line('$d = zext i1 $c to i32');
			case SExt:
				line('$d = sext i32 ${v(i.a, bl)} to i64');
			case ZExt:
				line('$d = zext i32 ${v(i.a, bl)} to i64');
			case Trunc:
				line('$d = trunc i64 ${v(i.a, bl)} to i32');
			case I2F:
				line('$d = sitofp ${vt(i.a, bl)} to double');
			case F2I:
				// (machine semantics out of range: arm64's fcvtzs saturates, as this does;
				// x86-64's cvttsd2si gives the smallest integer, also for NaN, as the native code)
				if (g.abi.arm) {
					line('$d = call $T @llvm.fptosi.sat.$T.f64(double ${v(i.a, bl)})');
					intrinsic('declare $T @llvm.fptosi.sat.$T.f64(double)');
				} else {
					var x = t(), cv = T == "i64" ? "cvttsd2si64" : "cvttsd2si";
					line('$x = insertelement <2 x double> poison, double ${v(i.a, bl)}, i32 0');
					line('$d = call $T @llvm.x86.sse2.$cv(<2 x double> $x)');
					intrinsic('declare $T @llvm.x86.sse2.$cv(<2 x double>)');
				}
			case BitsToF:
				line('$d = bitcast i64 ${v(i.a, bl)} to double');
			case FToBits:
				line('$d = bitcast double ${v(i.a, bl)} to i64');
			case Select:
				var c = t();
				line('$c = icmp ne i32 ${v(i.a, bl)}, 0');
				line('$d = select i1 $c, $T ${conv(i.b, i.ty, bl)}, $T ${conv(i.c, i.ty, bl)}');
			case Load:
				var p = ptr(i, bl);
				var mt = memTy(i.ty, i.size);
				if (mt == T) {
					line('$d = load $T, ptr $p, align 1${tbaa(i)}');
				} else {
					var x = t();
					line('$x = load $mt, ptr $p, align 1${tbaa(i)}');
					line(i.ty == F64 ? '$d = fpext float $x to double' : '$d = ${i.signed ? "sext" : "zext"} $mt $x to $T');
				}
			case Store:
				var p = ptr(i, bl);
				var vi = f.vals[res(i.c)];
				var mt = memTy(vi.ty, i.size);
				var val = v(i.c, bl);
				if (mt != LlvmGen.ty(vi.ty)) {
					var x = t();
					line(vi.ty == F64 ? '$x = fptrunc double $val to float' : '$x = trunc ${LlvmGen.ty(vi.ty)} $val to $mt');
					val = x;
				}
				if (i.release && i.size == 8) line('store atomic $mt $val, ptr $p release, align 8${tbaa(i)}') else line('store $mt $val, ptr $p, align 1${tbaa(i)}');
			case Call:
				call(bl, i, d);
			case Jmp:
				line('br label %b${i.targets[0].id}');
			case Br:
				var c = t();
				line('$c = icmp ne ${vt(i.a, bl)}, 0');
				line('br i1 $c, label %b${i.targets[0].id}, label %b${i.targets[1].id}${weights(i)}');
			case Switch:
				var at = LlvmGen.ty(f.vals[res(i.a)].ty);
				var cs = [
					for (k in 0...i.cases.length)
						'$at ${i.cases[k]}, label %b${i.targets[k].id}'
				];
				line('switch $at ${v(i.a, bl)}, label %b${i.targets[i.targets.length - 1].id} [ ${cs.join(" ")} ]${weights(i)}');
			case Ret:
				line(i.a < 0 ? (f.ret == Void ? "ret void" : 'ret ${LlvmGen.ty(f.ret)} ${f.ret == F64 ? "0.0" : "0"}') : 'ret ${LlvmGen.ty(f.ret)} ${v(i.a, bl)}');
			case Unreachable:
				line("unreachable");
			case _:
				throw "hxmc: llvm: " + MFunc.opName(i.op);
		}
	}

	// a phi's argument: from a slot when its pred is reachable from a handler
	// (loaded at the end of the pred, before its terminator)
	function phiArg(x:Int, p:MBlock):String {
		x = res(x);
		var i = f.vals[x];
		if (slotOf.exists(x) && inHandler.exists(p.id)) {
			// (read in the pred: pending loads, emitted before its terminator)
			return pendingLoad(x, p);
		}
		return "%v" + x;
	}

	var pending = new Map<Int, Array<String>>();

	function pendingLoad(x:Int, p:MBlock):String {
		var r = "%e" + p.id + "_" + x;
		var l = pending.get(p.id);
		if (l == null) pending.set(p.id, l = []);
		var s = '$r = load volatile ${LlvmGen.ty(f.vals[x].ty)}, ptr ${slotOf.get(x)}';
		if (l.indexOf(s) < 0) l.push(s);
		return r;
	}

	function intrinsic(decl:String)
		intrinsics.set(decl, true);

	public var intrinsics = new Map<String, Bool>();

	// the inline expansions of MirWriter.special (as a64.Isel.special): atomics sequentially consistent
	function special(bl:MBlock, i:MIns, d:String, name:String) {
		var n = StringTools.endsWith(name, "8") ? "i64" : "i32";
		var al = n == "i64" ? 8 : 4;
		inline function arg(k:Int) return v(i.args[k], bl);
		inline function addr() {
			var p = t();
			line('$p = inttoptr i64 ${arg(0)} to ptr');
			return p;
		}
		switch name {
			case "atomic_load4" | "atomic_load8":
				line('$d = load atomic $n, ptr ${addr()} seq_cst, align $al');
			case "atomic_store4" | "atomic_store8":
				var p = addr();
				line('store atomic $n ${arg(1)}, ptr $p seq_cst, align $al');
			case "atomic_add4" | "atomic_add8" | "atomic_xchg4" | "atomic_xchg8":
				var p = addr();
				var x = arg(1), c = f.vals[res(i.args[1])];
				// (an addition of 0 is a write to the word, as the native code's lock
				// xadd: Gc's prefaulter touches pages with it. LLVM turns an idempotent
				// atomicrmw into a fence, without the access: the 0 hidden from it)
				if (StringTools.startsWith(name, "atomic_add") && c.op == Const && c.imm == 0 && (c.ty == I32 || c.imm2 == 0)) {
					x = t();
					line('$x = call $n asm sideeffect "", "=r,0"($n 0)');
				}
				line('$d = atomicrmw ${StringTools.startsWith(name, "atomic_add") ? "add" : "xchg"} ptr $p, $n $x seq_cst, align $al');
			case "atomic_cas4" | "atomic_cas8":
				var p = addr();
				var r = t();
				line('$r = cmpxchg ptr $p, $n ${arg(1)}, $n ${arg(2)} seq_cst seq_cst, align $al');
				line('$d = extractvalue { $n, i1 } $r, 0');
			case "fence":
				line("fence seq_cst");
			case "floor" | "ceil":
				line('$d = call double @llvm.$name.f64(double ${arg(0)})');
				intrinsic('declare double @llvm.$name.f64(double)');
			case "f32_to_f64":
				var x = t();
				line('$x = bitcast i32 ${arg(0)} to float');
				line('$d = fpext float $x to double');
			case "f64_to_f32":
				var x = t();
				line('$x = fptrunc double ${arg(0)} to float');
				line('$d = bitcast float $x to i32');
			case "f32bits_to_freg":
				var x = t();
				line('$x = zext i32 ${arg(0)} to i64');
				line('$d = bitcast i64 $x to double');
			case "freg_to_f32bits":
				var x = t();
				line('$x = bitcast double ${arg(0)} to i64');
				line('$d = trunc i64 $x to i32');
			case _:
				throw "hxmc: llvm: unknown special " + i.sym;
		}
	}

	// a load's or store's alias class (Opt's memory classes, MIns.mem): none
	// for MOther (anything) and MInit (a fresh object's stores, which loads
	// of another class read back)
	function tbaa(i:MIns):String {
		var c = switch i.mem {
			case 1: "hdr"; // Opt.MHdr
			case 2: "elem"; // Opt.MElem
			case 3: "field"; // Opt.MField
			case 4: "global"; // Opt.MGlobal
			case 5: "callonly"; // Opt.MCallOnly
			case 6: "frame"; // Opt.MFrame
			case 7: "const"; // Opt.MConst
			case _: null;
		}
		if (c == null) return "";
		// (fields and shadow-stack slots at a constant offset from their base:
		// one type per 8-byte slot under the class's, as Opt.fieldClass:
		// objects do not overlap and a field is read at its own offset; at
		// dynamic offsets the class's own type, which aliases them all)
		if ((c == "field" || c == "frame") && i.b < 0) return g.tbaaTag(c, c + "." + ((i.imm + dispOf(i.a)) >> 3), c);
		return g.tbaaTag(c, c);
	}

	// the constant added to an address (Opt.dispOf)
	function dispOf(a:Int):Int {
		var x = f.vals[res(a)];
		if (x.op == Add && x.ty == I64) {
			var c = f.vals[res(x.b)];
			if (c.op == Const && c.sym == null && c.imm2 == (c.imm < 0 ? -1 : 0)) return c.imm;
		}
		return 0;
	}

	// a branch's weights when some of its targets are slow paths (MBlock.cold:
	// MemLower's), for LLVM's block placement and register allocation, as
	// hxmc's own layout puts them last (Switch: the default first)
	function weights(i:MIns):String {
		var cold = 0;
		for (b in i.targets)
			if (b.cold) cold++;
		if (cold == 0 || cold == i.targets.length) return "";
		inline function w(b:MBlock) return b.cold ? 1 : 2000;
		var ws = i.op == Switch ? [w(i.targets[i.targets.length - 1])].concat([for (k in 0...i.cases.length) w(i.targets[k])]) : [for (b in i.targets) w(b)];
		return ", !prof " + g.md('!{!"branch_weights", ${[for (x in ws) "i32 " + x].join(", ")}}');
	}

	// a thread-local variable's address: through llvm.threadlocal.address,
	// which LLVM knows is the same within the function (merged, hoisted out of
	// loops: Darwin's TLV access is a call each)
	function tlsAddr(sym:String):String {
		if (g.abi.os == "macos") {
			// as the native code does on Apple: the thread's copy of the TLS
			// template (hxmc_tls_base, one call, merged and hoisted by LLVM: it
			// reads no memory) and the variable's offset in it (a word the
			// linker fills in: LlvmGen.compile, RSecRel32)
			g.tlsOff.set(sym, true);
			var b = t(), o = t(), oz = t(), a = t(), p = t();
			line('$b = call i64 @hxmc_tls_base() #3');
			line('$o = load i32, ptr ${LlvmGen.symName(sym + LlvmGen.TLS_OFF)}, align 4');
			line('$oz = zext i32 $o to i64');
			line('$a = add i64 $b, $oz');
			line('$p = inttoptr i64 $a to ptr');
			return p;
		}
		var a = t();
		line('$a = call ptr @llvm.threadlocal.address.p0(ptr ${LlvmGen.symName(sym)})');
		intrinsic("declare ptr @llvm.threadlocal.address.p0(ptr)");
		return a;
	}

	// a value in another type: an integer of another width (zero-extended, as
	// a 32-bit register's upper half is), a double's bits as an integer or back
	function conv(x:Int, to:MTy, bl:MBlock):String {
		var from = f.vals[res(x)].ty;
		var val = v(x, bl);
		if (from == to) return val;
		var c = t();
		switch [from, to] {
			case [I32, I64]: line('$c = zext i32 $val to i64');
			case [I64, I32]: line('$c = trunc i64 $val to i32');
			case [F64, I64]: line('$c = bitcast double $val to i64');
			case [I64, F64]: line('$c = bitcast i64 $val to double');
			case [F64, I32]:
				var w = t();
				line('$w = bitcast double $val to i64');
				line('$c = trunc i64 $w to i32');
			case [I32, F64]:
				var w = t();
				line('$w = zext i32 $val to i64');
				line('$c = bitcast i64 $w to double');
			case _: throw 'hxmc: llvm: ${LlvmGen.ty(from)} as ${LlvmGen.ty(to)}';
		}
		return c;
	}

	// a shift's count in the type of the value shifted
	function count(i:MIns, bl:MBlock):String {
		var c = v(i.b, bl);
		var ct = f.vals[res(i.b)].ty;
		if (ct == i.ty) return c;
		var x = t();
		line(ct == I32 ? '$x = zext i32 $c to i64' : '$x = trunc i64 $c to i32');
		return x;
	}

	function call(bl:MBlock, i:MIns, d:String) {
		if (i.sym != null && StringTools.startsWith(i.sym, MirBuild.SPECIAL)) {
			special(bl, i, d, i.sym.substr(MirBuild.SPECIAL.length));
			return;
		}
		var n = i.args.length;
		var tys = [];
		var vals = [];
		for (k in 0...n) {
			var x = i.args[k];
			var vt0 = f.vals[res(x)].ty;
			var at = k < i.argTys.length ? i.argTys[k] : vt0;
			if (at == Void) at = I64; // (a Void parameter: a word, as a register is)
			var val = v(x, bl);
			var lt = LlvmGen.ty(at);
			if (at != vt0) val = conv(x, at, bl);
			// (a C float argument is a double whose low half holds its bits, MirBuild.cCall: passed as such, the callee reads the low half)
			tys.push(lt);
			vals.push('$lt $val');
		}
		var fixed = i.variadic >= 0 ? tys.slice(0, i.variadic).concat(["..."]) : tys;
		var fnTy = '${LlvmGen.ty(i.ty)} (${fixed.join(", ")})';
		var callee;
		if (i.sym != null) {
			g.useSym(i.sym, 0);
			if (i.returnsTwice) g.useSym(i.sym, 4);
			callee = LlvmGen.symName(i.sym);
		} else {
			callee = t();
			line('$callee = inttoptr i64 ${v(i.a, bl)} to ptr');
		}
		var attrs = i.noReturn ? " #1" : i.returnsTwice ? " #2" : "";
		var lhs = i.ty == Void ? "" : '$d = ';
		line('${lhs}call $fnTy $callee(${vals.join(", ")})$attrs');
	}

}
