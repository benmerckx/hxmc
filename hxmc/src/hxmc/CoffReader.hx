package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;

// COFF input for the Windows runtime (MkRt): object files as Obj, archives
// (their symbol index and members), and the short import members of import
// libraries (which DLL exports a symbol). Relocations get explicit addends
// (COFF keeps them in the relocated field).
class CoffReader {
	var b:Bytes;
	var base:Int;
	var arm:Bool;
	public var isArm(get, never):Bool;

	inline function get_isArm()
		return arm;

	// COMDAT sections (by section): the name of their COMDAT symbol, the
	// selection, the associated section for selection 5
	public var comdat = new Map<Section, {sym:String, selection:Int, assoc:Null<Section>}>();
	// weak externals: symbol -> its default symbol
	public var weakDefaults = new Map<Symbol, Symbol>();

	function new(b:Bytes, base:Int) {
		this.b = b;
		this.base = base;
	}

	inline function u8(at:Int):Int
		return b.get(base + at);

	inline function u16(at:Int):Int
		return b.getUInt16(base + at);

	inline function i16(at:Int):Int {
		var v = b.getUInt16(base + at);
		return v >= 0x8000 ? v - 0x10000 : v;
	}

	inline function u32(at:Int):Int
		return b.getInt32(base + at);

	function cstr(at:Int):String {
		var e = at;
		while (b.get(base + e) != 0)
			e++;
		return b.getString(base + at, e - at);
	}

	public static function isShortImport(b:Bytes, at:Int):Bool
		return b.getUInt16(at) == 0 && b.getUInt16(at + 2) == 0xffff;

	// a short import member: {symbol, dll, import name, code}
	public static function shortImport(b:Bytes, at:Int):{sym:String, dll:String, name:String, code:Bool, ordinal:Int, byOrdinal:Bool} {
		var r = new CoffReader(b, at);
		var hint = r.u16(16);
		var info = r.u16(18);
		var type = info & 3, nameType = (info >> 2) & 7;
		var sym = r.cstr(20);
		var dll = r.cstr(20 + Bytes.ofString(sym).length + 1);
		var name = sym;
		switch nameType {
			case 2:
				while (name.length > 0 && (name.charAt(0) == "?" || name.charAt(0) == "@" || name.charAt(0) == "_"))
					name = name.substr(1);
			case 3:
				while (name.length > 0 && (name.charAt(0) == "?" || name.charAt(0) == "@" || name.charAt(0) == "_"))
					name = name.substr(1);
				var k = name.indexOf("@");
				if (k >= 0) name = name.substr(0, k);
			case _:
		}
		return {sym: sym, dll: dll, name: name, code: type == 0, ordinal: hint, byOrdinal: nameType == 0};
	}

	public static function read(b:Bytes, at = 0):{obj:Obj, reader:CoffReader} {
		var r = new CoffReader(b, at);
		return {obj: r.run(), reader: r};
	}

	function relocKind(t:Int):{kind:RelKind, extra:Int} {
		if (!arm) return switch t {
			case 1: {kind: RAbs64, extra: 0};
			case 2: {kind: RAbs32, extra: 0};
			case 3: {kind: RImgRel32, extra: 0};
			case 4: {kind: RPc32, extra: -4};
			case 5 | 6 | 7 | 8 | 9: {kind: RPc32, extra: -4 - (t - 4)};
			case 0xb: {kind: RSecRel32, extra: 0};
			case _: throw "hxmc: COFF relocation type " + t;
		}
		return switch t {
			case 0x1: {kind: RAbs32, extra: 0};
			case 0x2: {kind: RImgRel32, extra: 0};
			case 0x3: {kind: RA64Call26, extra: 0};
			case 0x4: {kind: RA64AdrPage21, extra: 0};
			case 0x6: {kind: RA64AddLo12, extra: 0};
			case 0x7: {kind: RA64Ldst64Lo12, extra: 0}; // (the size from the instruction)
			case 0x8: {kind: RSecRel32, extra: 0};
			case 0x9: {kind: RA64SecRelLo12A, extra: 0};
			case 0xa: {kind: RA64SecRelHi12, extra: 0};
			case 0xb: {kind: RA64SecRelLo12L, extra: 0};
			case 0xe: {kind: RAbs64, extra: 0};
			case 0xf: {kind: RA64Cond19, extra: 0};
			case 0x10: {kind: RA64Tst14, extra: 0};
			case 0x11: {kind: RPc32, extra: -4};
			case _: throw "hxmc: COFF arm64 relocation type " + t;
		}
	}

	static inline function sext(v:Int, bits:Int):Int
		return (v << (32 - bits)) >> (32 - bits);

	// arm64: the addend a relocated instruction or datum holds (COFF keeps it
	// in the field), the field cleared; the kind refined by the instruction
	function armAddend(s:Section, va:Int, kind:RelKind):{kind:RelKind, addend:Int} {
		var buf = s.buf;
		var w = buf.get32(va);
		switch kind {
			case RAbs32 | RImgRel32 | RSecRel32 | RPc32:
				buf.set32(va, 0);
				return {kind: kind, addend: w};
			case RAbs64:
				buf.set64(va, 0, 0);
				return {kind: kind, addend: w};
			case RA64Call26:
				buf.set32(va, w & 0xfc000000);
				return {kind: (w & 0x80000000) != 0 ? RA64Call26 : RA64Jump26, addend: sext(w & 0x3ffffff, 26) << 2};
			case RA64Cond19:
				buf.set32(va, w & ~(0x7ffff << 5));
				return {kind: kind, addend: sext((w >> 5) & 0x7ffff, 19) << 2};
			case RA64Tst14:
				buf.set32(va, w & ~(0x3fff << 5));
				return {kind: kind, addend: sext((w >> 5) & 0x3fff, 14) << 2};
			case RA64AdrPage21:
				buf.set32(va, w & ~((3 << 29) | (0x7ffff << 5)));
				return {kind: kind, addend: ((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2)}; // (an unsigned byte offset, as lld reads it)
			case RA64AddLo12 | RA64SecRelLo12A:
				buf.set32(va, w & ~(0xfff << 10));
				return {kind: kind, addend: (w >> 10) & 0xfff};
			case RA64SecRelHi12:
				buf.set32(va, w & ~(0xfff << 10));
				return {kind: kind, addend: ((w >> 10) & 0xfff) << 12};
			case RA64Ldst64Lo12 | RA64SecRelLo12L:
				buf.set32(va, w & ~(0xfff << 10));
				var sc = A64Reloc.ldstScale(w);
				var k = kind == RA64SecRelLo12L ? kind : switch sc {
					case 0: RA64Ldst8Lo12;
					case 1: RA64Ldst16Lo12;
					case 2: RA64Ldst32Lo12;
					case 3: RA64Ldst64Lo12;
					case _: RA64Ldst128Lo12;
				};
				return {kind: k, addend: ((w >> 10) & 0xfff) << sc};
			case _:
				throw "hxmc: COFF arm64 relocation " + kind;
		}
	}

	function run():Obj {
		var machine = u16(0);
		arm = machine == 0xaa64;
		if (machine != 0x8664 && !arm) throw "hxmc: COFF machine " + StringTools.hex(machine);
		var nsec = u16(2);
		var symOff = u32(8);
		var nsym = u32(12);
		var optSize = u16(16);
		var strOff = symOff + 18 * nsym;
		function name8(at:Int):String {
			if (u32(at) == 0 && u8(at) == 0) return cstr(strOff + u32(at + 4));
			var e = 0;
			while (e < 8 && u8(at + e) != 0)
				e++;
			var s = b.getString(base + at, e);
			if (s.charAt(0) == "/") return cstr(strOff + Std.parseInt(s.substr(1)));
			return s;
		}
		var o = new Obj();
		// (by section number, from 1)
		var secs = new haxe.ds.Vector<Null<Section>>(nsec + 1);
		var secChars = new haxe.ds.Vector<Int>(nsec + 1);
		// (a section number read from the file: out of range as none, as a malformed file may have it)
		inline function secAt(i:Int):Null<Section>
			return i >= 0 && i <= nsec ? secs[i] : null;
		for (i in 0...nsec) {
			var h = 20 + optSize + 40 * i;
			var name = name8(h);
			var size = u32(h + 16);
			var raw = u32(h + 20);
			var chars = u32(h + 36);
			secChars[i + 1] = chars;
			// not loaded: debug information, linker directives, removed sections
			if ((chars & 0x800) != 0 || (chars & 0x200) != 0 || StringTools.startsWith(name, ".debug") || name == ".llvm_addrsig") continue;
			var alignBits = (chars >> 20) & 0xf;
			var align = alignBits == 0 ? 16 : 1 << (alignBits - 1);
			var kind:SecKind = if (StringTools.startsWith(name, ".tls")) Tdata else if ((chars & 0x20000020) != 0) Text else if ((chars & 0x80) != 0) Bss
				else if ((chars & 0x80000000) != 0) Data else RoData;
			var s = new Section(name, kind, align);
			if (kind == Bss) s.bssSize = size else if (raw != 0) s.buf.bytes(b, base + raw, size) else s.buf.zeros(size);
			o.sections.push(s);
			secs[i + 1] = s;
		}
		// symbols, by index (an auxiliary record's: none)
		var syms = new haxe.ds.Vector<Null<Symbol>>(nsym > 0 ? nsym : 0);
		inline function symAt(i:Int):Null<Symbol>
			return i >= 0 && i < syms.length ? syms[i] : null;
		var k = 0;
		var pendingComdat = new Map<Int, Int>(); // section number -> selection, until its COMDAT symbol
		var assocOf = new Map<Int, Int>();
		while (k < nsym) {
			var at = symOff + 18 * k;
			var name = name8(at);
			var value = u32(at + 8);
			var secNum = i16(at + 12);
			var cls = u8(at + 16);
			var naux = u8(at + 17);
			var s:Null<Symbol> = null;
			if (cls == 104 /* section */ || cls == 3 && naux > 0 && secNum > 0 && value == 0 && secAt(secNum) != null && name == secAt(secNum).name) {
				// a section symbol; its aux record holds the COMDAT selection
				if (secNum > 0 && secAt(secNum) != null) {
					s = new Symbol(".Lsec" + secNum + name);
					s.global = false;
					s.section = secAt(secNum);
					o.symbols.push(s);
					if (naux > 0 && (secChars[secNum] & 0x1000) != 0) {
						var aux = at + 18;
						var sel = u8(aux + 14);
						var number = u16(aux + 12);
						if (sel == 5) assocOf.set(secNum, number);
						pendingComdat.set(secNum, sel);
					}
				}
			} else if (cls == 2 || cls == 105 || cls == 3 || cls == 6) {
				var external = cls == 2 || cls == 105;
				if (secNum == -2) {
					// debug
				} else if (external) {
					s = o.sym(name);
					if (secNum > 0) {
						if (secAt(secNum) != null) {
							if (s.section != null) throw "hxmc: COFF: " + name + " defined twice in one object";
							s.section = secAt(secNum);
							s.offset = value;
						}
					} else if (secNum == -1) {
						s.abs = true;
						s.offset = value;
					} else if (value > 0 && cls == 2) {
						// a common symbol: its own zeroed section
						var c = new Section(".bss$common", Bss, value >= 16 ? 16 : 8);
						c.bssSize = value;
						o.sections.push(c);
						s.section = c;
						s.offset = 0;
					}
					if (cls == 105) {
						s.weak = true;
						var tag = u32(at + 18);
						weakDefaults.set(s, null);
						weakTags.push({sym: s, tag: tag});
					}
				} else if (secNum > 0 && secAt(secNum) != null) {
					s = new Symbol(name);
					s.global = false;
					s.section = secAt(secNum);
					s.offset = value;
					o.symbols.push(s);
				}
				// the first symbol of a COMDAT section names it
				if (secNum > 0 && pendingComdat.exists(secNum)) {
					comdat.set(secAt(secNum), {sym: name, selection: pendingComdat.get(secNum), assoc: null});
					pendingComdat.remove(secNum);
				}
			}
			syms[k] = s;
			k += 1 + naux;
		}
		for (w in weakTags)
			weakDefaults.set(w.sym, symAt(w.tag));
		for (secNum => target in assocOf) {
			var s = secAt(secNum);
			if (s == null) continue;
			var c = comdat.get(s);
			if (c == null) comdat.set(s, {sym: null, selection: 5, assoc: secAt(target)}) else c.assoc = secAt(target);
		}
		for (secNum => sel in pendingComdat)
			if (secAt(secNum) != null && !comdat.exists(secAt(secNum))) comdat.set(secAt(secNum), {sym: null, selection: sel, assoc: null});
		// relocations, with their addends taken out of the fields
		for (i in 0...nsec) {
			var s = secs[i + 1];
			if (s == null) continue;
			var h = 20 + optSize + 40 * i;
			var off = u32(h + 24);
			var n = u16(h + 32);
			if ((secChars[i + 1] & 0x01000000) != 0 && n == 0xffff) {
				n = u32(off);
				off += 10;
			}
			for (j in 0...n) {
				var at = off + 10 * j;
				var va = u32(at);
				var sym = symAt(u32(at + 4));
				var t = u16(at + 8);
				var rk = relocKind(t);
				if (sym == null) throw "hxmc: COFF relocation against a dropped symbol in " + s.name;
				if (arm) {
					var x = armAddend(s, va, rk.kind);
					s.relocs.push(new Reloc(va, x.kind, sym, x.addend));
					continue;
				}
				var field = rk.kind == RAbs64 ? s.buf.get32(va) : s.buf.get32(va);
				if (rk.kind == RAbs64) s.buf.set64(va, 0, 0) else s.buf.set32(va, 0);
				s.relocs.push(new Reloc(va, rk.kind, sym, field + rk.extra));
			}
		}
		return o;
	}

	var weakTags:Array<{sym:Symbol, tag:Int}> = [];
}

// a Unix/COFF archive (.a, .lib): members by offset, symbol index
class Archive {
	public var b:Bytes;
	public var index = new Map<String, Int>(); // symbol -> member offset (of the member's data)
	public var path:String;

	public function new(b:Bytes, path:String) {
		this.b = b;
		this.path = path;
		if (b.getString(0, 8) != "!<arch>\n") throw "hxmc: not an archive: " + path;
		var at = 8;
		var first = true;
		while (at + 60 <= b.length) {
			var name = StringTools.trim(b.getString(at, 16));
			var size = Std.parseInt(StringTools.trim(b.getString(at + 48, 10)));
			var data = at + 60;
			if (name == "/" && first) {
				// the first linker member: big-endian count, offsets, names
				var n = be32(data);
				var p = data + 4 + 4 * n;
				for (k in 0...n) {
					var e = p;
					while (b.get(e) != 0)
						e++;
					var sym = b.getString(p, e - p);
					var memberHeader = be32(data + 4 + 4 * k);
					if (!index.exists(sym)) index.set(sym, memberHeader + 60);
					p = e + 1;
				}
				first = false;
			}
			at = data + size;
			if (at & 1 != 0) at++;
		}
	}

	// a member's bytes, from the offset of its data (the index's)
	public function member(at:Int):Bytes
		return b.sub(at, Std.parseInt(StringTools.trim(b.getString(at - 60 + 48, 10))));

	function be32(at:Int):Int
		return (b.get(at) << 24) | (b.get(at + 1) << 16) | (b.get(at + 2) << 8) | b.get(at + 3);
}
