package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Os.Report;
import hxmc.rt.C;
import hxmc.unsafe.*;

// The heap census of a debug build (-D hxmc.census; once hxmc/c/rt_census.c,
// the runtime object's debug build). RT_CENSUS=1: a census at exit (after a
// major collection, so only live objects are counted); RT_CENSUS=2 also after
// every major collection. Reports live bytes and object counts per type, what
// the same data would take in OCaml's representation (an estimate), where
// arrays, strings and maps hang from (the first object referring to them, by
// type and field), the heap's own sizes and the process's RSS.
@:hxmc.native @:keep
class Census {
	static inline var K_OBJ = 0;
	static var mapTypes:Ptr; // per type: 1 for the haxe.ds maps

	static inline function ntypes():Int
		return Mem.getI32(Mem.sym("rt_ntypes"), 0);

	static inline function nslotsOf(o:Ptr):Int
		return Mem.getI32(o, -8) & 0x0FFFFFFF;

	static inline function kindOf(o:Ptr):Int
		return (Mem.getI32(o, -8) >>> 28) & 15;

	static inline function tindexOf(o:Ptr):Int
		return Mem.getU16(o, -4);

	static inline function objSize(o:Ptr):I64
		return ((nslotsOf(o) + 1 : I64)) * 8;

	static inline function r8(n:I64):I64
		return (n + 7) - ((n + 7) & 7);

	static inline function mb(b:I64):Float {
		var f:Float = cast b;
		return f / 1048576.0;
	}

	static inline function cstrEq(p:Ptr, s:String):Bool
		return !p.isNull() && LibC.strcmp(p, Mem.cstr(s)) == 0;

	@:hxmc.noGc static function findMaps() {
		var n = ntypes();
		mapTypes = LibC.malloc((n : I64));
		LibC.memset(mapTypes, 0, (n : I64));
		for (t in Types.T_FIRST...n) {
			var ty = Types.ty(t);
			var nm = Types.name(ty);
			if (Types.tk(ty) == Types.TK_CLASS
				&& (cstrEq(nm, "haxe.ds.StringMap") || cstrEq(nm, "haxe.ds.IntMap") || cstrEq(nm, "haxe.ds.ObjectMap")))
				Mem.setI8(mapTypes, t, 1);
		}
	}

	static inline function isMap(t:Int):Bool
		return Mem.getU8(mapTypes, t) != 0;

	// a type's display name into buf (at most n - 1 bytes, NUL-terminated):
	// anonymous structures list their fields
	@:hxmc.noGc static function tname(t:Int, buf:Ptr, n:Int) {
		var k = 0;
		inline function put(c:Int)
			if (k < n - 1) Mem.setI8(buf, k++, c);
		inline function puts(p:Ptr)
			if (!p.isNull()) {
				var i = 0;
				while (Mem.getU8(p, i) != 0)
					put(Mem.getU8(p, i++));
			}
		inline function lit(s:String)
			for (i in 0...s.length)
				put(StringTools.fastCodeAt(s, i));
		var ty = Types.ty(t);
		if (Types.tk(ty) == Types.TK_ANON) {
			put("{".code);
			for (i in 0...Types.nfields(ty)) {
				if (i > 0) put(",".code);
				puts(Names.fidName(Types.fFid(Types.field(ty, i))));
			}
			put("}".code);
		} else if (Types.tk(ty) == Types.TK_CTOR && Types.sup(ty) >= 0) {
			puts(Types.name(Types.ty(Types.sup(ty))));
			put(".".code);
			puts(Types.name(ty));
		} else if (t == Types.T_ADATA_P)
			lit("ArrayData<ptr>")
		else if (t == Types.T_ADATA_RAW)
			lit("ArrayData<raw>")
		else if (t == 11 || t == 12 || t == 13) {
			lit("Ref<");
			put(t == 11 ? "p".code : t == 12 ? "i".code : "f".code);
			put(">".code);
		} else
			puts(Types.name(ty));
		Mem.setI8(buf, k, 0);
	}

	// bytes of an object and what it owns exclusively in our layout: arrays
	// with their data, maps with their arrays
	@:hxmc.noGc static function deep(o:Ptr):I64 {
		if (o.isNull()) return 0;
		var t = tindexOf(o);
		var b = objSize(o);
		if (t == Types.T_ARRAY) {
			var d = Mem.getPtr(o, 8);
			if (!d.isNull()) b += objSize(d);
		} else if (kindOf(o) == K_OBJ && isMap(t)) {
			var ty = Types.ty(t);
			for (i in 0...Types.nfields(ty)) {
				var f = Types.field(ty, i);
				if (Types.fKind(f) == "p".code) b += deep(Mem.getPtr(o, 8 * Types.fSlot(f)));
			}
		}
		return b;
	}

	// indices 0...n ordered by the I64 at base + stride * i + off, largest first
	// (a merge sort: stable)
	@:hxmc.noGc static function sortDesc(base:Ptr, stride:Int, off:Int, n:Int):Ptr {
		var idx = LibC.malloc(((n + 1) : I64) * 4), tmp = LibC.malloc(((n + 1) : I64) * 4);
		for (i in 0...n)
			Mem.setI32(idx, 4 * i, i);
		inline function key(i:Int):I64
			return Mem.getI64(base, stride * i + off);
		var w = 1;
		while (w < n) {
			var lo = 0;
			while (lo < n) {
				var mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n;
				var a = lo, b = mid, k = lo;
				while (a < mid || b < hi) {
					var takeA = b >= hi || (a < mid && !(key(Mem.getI32(idx, 4 * a)) < key(Mem.getI32(idx, 4 * b))));
					if (takeA) Mem.setI32(tmp, 4 * k++, Mem.getI32(idx, 4 * a++)) else Mem.setI32(tmp, 4 * k++, Mem.getI32(idx, 4 * b++));
				}
				lo += 2 * w;
			}
			LibC.memcpy(idx, tmp, (n : I64) * 4);
			w *= 2;
		}
		LibC.free(tmp);
		return idx;
	}

	// "    length <label>:<count> ...": the labels separated by spaces, the counts at h
	@:hxmc.noGc static function hist(r:Report, labels:Ptr, h:Ptr) {
		r.str("    length ");
		var k = 0, i = 0;
		while (Mem.getU8(labels, i) != 0) {
			var c = Mem.getU8(labels, i++);
			if (c == " ".code) {
				r.ch(":".code);
				r.int(Mem.getI64(h, 8 * k++), 0);
			}
			r.ch(c);
		}
		r.ch(":".code);
		r.int(Mem.getI64(h, 8 * k), 0);
		r.str("\n");
		r.flush();
	}

	@:hxmc.noGc public static function run(start:Ptr, end:Ptr, when:Ptr, young:I64, oldLimit:I64, remembered:I64, gcstack:I64, shadow:I64,
			minors:Int, majors:Int, nglobals:Int) {
		if (mapTypes.isNull()) findMaps();
		var top = Os.envInt("RT_CENSUS_TOP", 40);
		var nt = ntypes();
		// per type: count, bytes, OCaml bytes
		var ts = LibC.malloc((nt : I64) * 24);
		LibC.memset(ts, 0, (nt : I64) * 24);
		var total:I64 = 0, objs:I64 = 0, ocaml:I64 = 0;
		// strings
		var sN:I64 = 0, sBytes:I64 = 0, sLatin1:I64 = 0, sUnits:I64 = 0, sBytes1:I64 = 0, sOcaml:I64 = 0, sEmpty:I64 = 0;
		var sHist = Mem.stack(64); // length buckets: 0, 1-7, 8-15, 16-31, 32-63, 64-255, 256+
		LibC.memset(sHist, 0, 64);
		// arrays
		var aN:I64 = 0, aNodata:I64 = 0, aLen0:I64 = 0, aLen:I64 = 0, aCap:I64 = 0, aWaste:I64 = 0, aHdr:I64 = 0, aData:I64 = 0, aOcaml:I64 = 0;
		var aHist = Mem.stack(64); // length buckets: 0, 1, 2, 3-4, 5-8, 9-16, 17-64, 65+
		LibC.memset(aHist, 0, 64);
		// enum values, anonymous objects, classes
		var cN:I64 = 0, cBytes:I64 = 0, anN:I64 = 0, anOvf:I64 = 0, clN:I64 = 0, clBytes:I64 = 0, kIb:I64 = 0, kObj:I64 = 0, kNullp:I64 = 0, kPtrs:I64 = 0;
		var boxes0:I64 = 0, boxes1:I64 = 0;
		// a string census by content, for duplicates
		var hcap = 1 << 20;
		var hs = LibC.malloc((hcap : I64) * 8);
		LibC.memset(hs, 0, (hcap : I64) * 8);
		var sDistinct:I64 = 0, sDupbytes:I64 = 0;
		var p = start;
		while (p.ult(end)) {
			var o = p.add(8);
			var t = tindexOf(o), k = kindOf(o);
			var b = objSize(o), oc = b;
			p = p.addL(b);
			objs++;
			total += b;
			if (t >= nt) t = 0;
			var ty = Types.ty(t);
			if (t == Types.T_STRING) {
				var len = Mem.getI32(o, 0);
				var lat = true;
				for (i in 0...len)
					if (Mem.getU16(o, 8 + 2 * i) > 0xFF) {
						lat = false;
						break;
					}
				sN++;
				sBytes += b;
				sUnits += len;
				if (len == 0) sEmpty++;
				if (lat) sLatin1++;
				sBytes1 += r8(lat ? len : (len : I64) * 2) + 16;
				oc = r8((len : I64) + 1) + 8; // UTF-8 for non-Latin-1: about as many bytes
				sOcaml += oc;
				var hb = len == 0 ? 0 : len < 8 ? 1 : len < 16 ? 2 : len < 32 ? 3 : len < 64 ? 4 : len < 256 ? 5 : 6;
				Mem.setI64(sHist, 8 * hb, Mem.getI64(sHist, 8 * hb) + 1);
				var h = 0x811C9DC5; // FNV-1a
				for (i in 0...len)
					h = (h ^ Mem.getU16(o, 8 + 2 * i)) * 16777619;
				if (sDistinct * 2 < hcap) {
					var j = h & (hcap - 1);
					while (true) {
						var e = Mem.getPtr(hs, 8 * j);
						if (e.isNull()) {
							Mem.setPtr(hs, 8 * j, o);
							sDistinct++;
							break;
						}
						if (Mem.getI32(e, 0) == len && LibC.memcmp(e.add(8), o.add(8), (len : I64) * 2) == 0) {
							sDupbytes += b;
							break;
						}
						j = (j + 1) & (hcap - 1);
					}
				}
			} else if (t == Types.T_ARRAY && k == K_OBJ) {
				var len = Mem.getI32(o, 0), kind = Mem.getI32(o, 4);
				var d = Mem.getPtr(o, 8);
				var cap = d.isNull() ? 0 : (nslotsOf(d) << (Types.ak4(kind) ? 1 : 0));
				var es = Types.ak4(kind) ? 4 : 8;
				aN++;
				aHdr += b;
				if (d.isNull()) aNodata++;
				if (len == 0) aLen0++;
				aLen += len;
				if (!d.isNull()) {
					aCap += cap;
					aWaste += ((cap - len : I64)) * es;
				}
				var hb = len == 0 ? 0 : len == 1 ? 1 : len == 2 ? 2 : len <= 4 ? 3 : len <= 8 ? 4 : len <= 16 ? 5 : len <= 64 ? 6 : 7;
				Mem.setI64(aHist, 8 * hb, Mem.getI64(aHist, 8 * hb) + 1);
				// OCaml: an array (header + elements; ints and floats unboxed)
				oc = len != 0 ? (len : I64) * 8 + 8 : 0;
				aOcaml += oc;
			} else if (t == Types.T_ADATA_P || t == Types.T_ADATA_RAW) {
				aData += b;
				oc = 0; // counted with the array
			} else if (t == Types.T_BOXINT || t == Types.T_BOXBOOL) {
				boxes0++;
				oc = 0; // immediate
			} else if (t == Types.T_BOXFLOAT) {
				boxes1++;
			} else if (k == K_OBJ && Types.tk(ty) == Types.TK_CTOR) {
				cN++;
				cBytes += b; // as in OCaml: the tag is the header's type index
			} else if (k == K_OBJ && Types.tk(ty) == Types.TK_ANON) {
				anN++;
				if (!Mem.getPtr(o, 0).isNull()) anOvf++;
				oc = (Types.nfields(ty) : I64) * 8 + 8; // a record: a word per field, no overflow slot
			} else if (k == K_OBJ && Types.tk(ty) == Types.TK_CLASS) {
				oc = ((Types.nfields(ty) != 0 ? Types.nfields(ty) : 1) : I64) * 8 + 8; // a word per field (Int/Bool are packed here)
			} else if (k == K_OBJ && Types.tk(ty) == Types.TK_CLOSURE) {
				clN++;
				clBytes += b;
				oc = b + 8; // code pointer, closure info, environment
			}
			if (k == K_OBJ && t >= Types.T_FIRST && (Types.tk(ty) == Types.TK_CLASS || Types.tk(ty) == Types.TK_CTOR || Types.tk(ty) == Types.TK_ANON)) {
				kObj++;
				for (i in 0...Types.nfields(ty)) {
					var f = Types.field(ty, i);
					var fk = Types.fKind(f);
					if (fk == "i".code || fk == "b".code) kIb++ else if (fk == "p".code) {
						kPtrs++;
						if (Mem.getPtr(o, 8 * Types.fSlot(f)).isNull()) kNullp++;
					}
				}
			}
			var e = ts.add(24 * t);
			Mem.setI64(e, 0, Mem.getI64(e, 0) + 1);
			Mem.setI64(e, 8, Mem.getI64(e, 8) + b);
			Mem.setI64(e, 16, Mem.getI64(e, 16) + oc);
			ocaml += oc;
		}
		// first-referrer attribution of arrays, strings and maps: (src, fid,
		// count, bytes, ttype) entries of 32 bytes
		var nattr = 0, attrCap = 1 << 16;
		var attr = LibC.malloc((attrCap : I64) * 32);
		LibC.memset(attr, 0, (attrCap : I64) * 32);
		var words = end.diff(start) >> 3;
		var seen = LibC.malloc((words >> 3) + 1);
		LibC.memset(seen, 0, (words >> 3) + 1);
		inline function bit(o:Ptr):I64
			return o.diff(start) >> 3;
		p = start;
		while (p.ult(end)) {
			var o = p.add(8);
			var t = tindexOf(o), k = kindOf(o);
			p = p.addL(objSize(o));
			if (k != K_OBJ || t < Types.T_FIRST || t >= nt) continue;
			if (isMap(t)) continue; // a map's own arrays are counted with it
			var ty = Types.ty(t);
			for (i in 0...Types.nfields(ty)) {
				var f = Types.field(ty, i);
				if (Types.fKind(f) != "p".code) continue;
				var v = Mem.getPtr(o, 8 * Types.fSlot(f));
				if (v.isNull() || v.ult(start) || !v.ult(end)) continue;
				var bi = bit(v);
				if ((Mem.getU8(seen, (bi >> 3).toInt()) >> (bi & 7).toInt()) & 1 != 0) continue;
				var vt = tindexOf(v);
				if (!(vt == Types.T_ARRAY || vt == Types.T_STRING || (kindOf(v) == K_OBJ && isMap(vt)))) continue;
				Mem.setI8(seen, (bi >> 3).toInt(), Mem.getU8(seen, (bi >> 3).toInt()) | (1 << (bi & 7).toInt()));
				var b = deep(v);
				var fid = Types.fFid(f);
				var j = 0;
				while (j < nattr) {
					if (Mem.getI32(attr, 32 * j) == t && Mem.getI32(attr, 32 * j + 4) == fid) break;
					j++;
				}
				if (j == nattr) {
					if (nattr == attrCap) continue;
					Mem.setI32(attr, 32 * j, t);
					Mem.setI32(attr, 32 * j + 4, fid);
					Mem.setI32(attr, 32 * j + 24, vt);
					nattr++;
				}
				Mem.setI64(attr, 32 * j + 8, Mem.getI64(attr, 32 * j + 8) + 1);
				Mem.setI64(attr, 32 * j + 16, Mem.getI64(attr, 32 * j + 16) + b);
			}
		}
		var rss = Mem.stack(16);
		Gc.procRss(rss);
		var r = new Report(Mem.stack(Report.BYTES));
		r.str("census (");
		r.cstr(when, 0, -1);
		r.str("): ");
		r.int(objs, 0);
		r.str(" objects, ");
		r.fixed(mb(total), 1, 0);
		r.str(" MB live; OCaml representation estimate ");
		r.fixed(mb(ocaml), 1, 0);
		r.str(" MB\n");
		r.flush();
		r.str("  heap: young ");
		r.fixed(mb(young), 1, 0);
		r.str(" MB, old ");
		r.fixed(mb(end.diff(start)), 1, 0);
		r.str(" MB used of ");
		r.fixed(mb(oldLimit), 1, 0);
		r.str(" MB limit, old reserve populated 0.0 + 0.0 MB (to/from), ");
		r.int(minors, 0);
		r.str(" minor, ");
		r.int(majors, 0);
		r.str(" major\n");
		r.flush();
		r.str("  other: remembered set ");
		r.fixed(mb(remembered), 1, 0);
		r.str(" MB, gc stack ");
		r.fixed(mb(gcstack), 1, 0);
		r.str(" MB, shadow stack used ");
		r.fixed(mb(shadow), 1, 0);
		r.str(" MB, globals ");
		r.int(nglobals, 0);
		r.str("\n");
		r.flush();
		r.str("  process: RSS ");
		var f:Float = cast Mem.getI64(rss, 0);
		r.fixed(f / 1024.0, 1, 0);
		r.str(" MB, peak RSS ");
		f = cast Mem.getI64(rss, 8);
		r.fixed(f / 1024.0, 1, 0);
		r.str(" MB\n");
		r.flush();
		r.str("  strings: ");
		r.int(sN, 0);
		r.str(" (");
		r.int(sEmpty, 0);
		r.str(" empty), ");
		r.fixed(mb(sBytes), 1, 0);
		r.str(" MB, ");
		r.int(sUnits, 0);
		r.str(" units, ");
		var l1:Float = cast sLatin1, sn:Float = cast sN;
		r.fixed(sN != 0 ? 100.0 * l1 / sn : 0, 1, 0);
		r.str("% Latin-1; 1-byte Latin-1 would be ");
		r.fixed(mb(sBytes1), 1, 0);
		r.str(" MB; OCaml ");
		r.fixed(mb(sOcaml), 1, 0);
		r.str(" MB; ");
		r.int(sDistinct, 0);
		r.str(" distinct (duplicates ");
		r.fixed(mb(sDupbytes), 1, 0);
		r.str(" MB)\n");
		r.flush();
		hist(r, Mem.cstr("0 1-7 8-15 16-31 32-63 64-255 256+"), sHist);
		r.str("  arrays: ");
		r.int(aN, 0);
		r.str(" (");
		r.int(aNodata, 0);
		r.str(" without data, ");
		r.int(aLen0, 0);
		r.str(" empty), headers ");
		r.fixed(mb(aHdr), 1, 0);
		r.str(" MB + data ");
		r.fixed(mb(aData), 1, 0);
		r.str(" MB, ");
		r.int(aLen, 0);
		r.str(" elements, capacity ");
		r.int(aCap, 0);
		r.str(" (slack ");
		r.fixed(mb(aWaste), 1, 0);
		r.str(" MB); OCaml arrays ");
		r.fixed(mb(aOcaml), 1, 0);
		r.str(" MB\n");
		r.flush();
		hist(r, Mem.cstr("0 1 2 3-4 5-8 9-16 17-64 65+"), aHist);
		r.str("  enum values: ");
		r.int(cN, 0);
		r.str(", ");
		r.fixed(mb(cBytes), 1, 0);
		r.str(" MB; anonymous objects: ");
		r.int(anN, 0);
		r.str(" (");
		r.int(anOvf, 0);
		r.str(" with overflow; the slot: ");
		r.fixed(mb(anN * 8), 1, 0);
		r.str(" MB); closures: ");
		r.int(clN, 0);
		r.str(", ");
		r.fixed(mb(clBytes), 1, 0);
		r.str(" MB\n");
		r.flush();
		r.str("  fields of ");
		r.int(kObj, 0);
		r.str(" objects: ");
		r.int(kIb, 0);
		r.str(" Int/Bool (");
		r.fixed(mb(kIb * 4), 1, 0);
		r.str(" MB as 4-byte values), ");
		r.int(kPtrs, 0);
		r.str(" pointers (");
		r.int(kNullp, 0);
		r.str(" null); boxes: ");
		r.int(boxes0, 0);
		r.str(" Int/Bool, ");
		r.int(boxes1, 0);
		r.str(" Float\n");
		r.flush();
		// types by bytes
		var order = sortDesc(ts, 24, 8, nt);
		r.str("  type");
		for (_ in 0...52)
			r.ch(" ".code);
		r.str("      count        MB  OCaml MB   B/obj\n");
		r.flush();
		var nb = Mem.stack(256), vb = Mem.stack(64), full = Mem.stack(320);
		var shown = 0;
		for (i in 0...nt) {
			var t = Mem.getI32(order, 4 * i);
			var e = ts.add(24 * t);
			if (Mem.getI64(e, 0) == 0) continue;
			if (shown >= top) break;
			shown++;
			tname(t, nb, 200);
			r.str("  ");
			r.cstr(nb, 56, 56);
			r.ch(" ".code);
			r.int(Mem.getI64(e, 0), 10);
			r.ch(" ".code);
			r.fixed(mb(Mem.getI64(e, 8)), 2, 9);
			r.ch(" ".code);
			r.fixed(mb(Mem.getI64(e, 16)), 2, 9);
			r.ch(" ".code);
			var by:Float = cast Mem.getI64(e, 8), cnt:Float = cast Mem.getI64(e, 0);
			r.fixed(by / cnt, 1, 7);
			r.str("\n");
			r.flush();
		}
		LibC.free(order);
		order = sortDesc(attr, 32, 16, nattr);
		r.str("  arrays (with data), strings and maps (with their arrays) by first referrer:\n");
		r.flush();
		var i = 0;
		while (i < nattr && i < top) {
			var a = attr.add(32 * Mem.getI32(order, 4 * i));
			tname(Mem.getI32(a, 0), nb, 200);
			tname(Mem.getI32(a, 24), vb, 64);
			// "%s.%s (%s)" in 300 bytes
			var k = 0;
			inline function put(c:Int)
				if (k < 299) Mem.setI8(full, k++, c);
			var j = 0;
			while (Mem.getU8(nb, j) != 0)
				put(Mem.getU8(nb, j++));
			put(".".code);
			var fnm = Names.fidName(Mem.getI32(a, 4));
			j = 0;
			while (!fnm.isNull() && Mem.getU8(fnm, j) != 0)
				put(Mem.getU8(fnm, j++));
			put(" ".code);
			put("(".code);
			j = 0;
			while (Mem.getU8(vb, j) != 0)
				put(Mem.getU8(vb, j++));
			put(")".code);
			Mem.setI8(full, k, 0);
			r.str("  ");
			r.cstr(full, 66, 66);
			r.ch(" ".code);
			r.int(Mem.getI64(a, 8), 10);
			r.ch(" ".code);
			r.fixed(mb(Mem.getI64(a, 16)), 2, 9);
			r.str("\n");
			r.flush();
			i++;
		}
		LibC.free(order);
		LibC.free(attr);
		LibC.free(seen);
		LibC.free(hs);
		LibC.free(ts);
	}

	// ---- allocations (RT_CENSUS set): every object allocated, by type. The
	// collector counts the nursery's objects before each collection empties
	// it (with one thread its used part is contiguous objects and zeroed
	// gaps) and large objects allocated in the old space as they come.
	static var allocTab:Ptr; // per type: count, bytes
	static var allocMulti:Bool; // the nursery was counted with several threads: approximate

	@:hxmc.noGc static inline function allocEntry(t:Int):Ptr {
		var nt = ntypes();
		if (allocTab.isNull()) {
			allocTab = LibC.malloc((nt : I64) * 16);
			LibC.memset(allocTab, 0, (nt : I64) * 16);
		}
		return allocTab.add(16 * (t < nt ? t : 0));
	}

	@:hxmc.noGc public static function countAlloc(header:I64, bytes:I64) {
		var e = allocEntry((header >> 32).toInt() & 0xFFFF);
		Mem.setI64(e, 0, Mem.getI64(e, 0) + 1);
		Mem.setI64(e, 8, Mem.getI64(e, 8) + bytes);
	}

	@:hxmc.noGc public static function countYoung(start:Ptr, end:Ptr) {
		if (Mem.getI32(Mem.sym("rt_nthreads"), 0) > 1) allocMulti = true;
		var p = start;
		while (p.ult(end)) {
			var h = Mem.getI64(p, 0);
			if (h == 0) {
				p = p.add(8);
				continue;
			}
			var b = objSize(p.add(8));
			countAlloc(h, b);
			p = p.addL(b);
		}
	}

	@:hxmc.noGc public static function allocReport() {
		if (allocTab.isNull()) return;
		var top = Os.envInt("RT_CENSUS_TOP", 40);
		var nt = ntypes();
		var n:I64 = 0, total:I64 = 0;
		for (t in 0...nt) {
			n += Mem.getI64(allocTab, 16 * t);
			total += Mem.getI64(allocTab, 16 * t + 8);
		}
		var r = new Report(Mem.stack(Report.BYTES));
		r.str("allocations: ");
		r.int(n, 0);
		r.str(" objects, ");
		r.fixed(mb(total), 1, 0);
		if (allocMulti) r.str(" MB (approximate: several threads)\n") else r.str(" MB\n");
		r.flush();
		r.str("  type");
		for (_ in 0...52)
			r.ch(" ".code);
		r.str("      count        MB   B/obj\n");
		r.flush();
		var order = sortDesc(allocTab, 16, 8, nt);
		var nb = Mem.stack(256);
		var shown = 0;
		for (i in 0...nt) {
			var t = Mem.getI32(order, 4 * i);
			var e = allocTab.add(16 * t);
			if (Mem.getI64(e, 0) == 0) continue;
			if (shown >= top) break;
			shown++;
			tname(t, nb, 200);
			r.str("  ");
			r.cstr(nb, 56, 56);
			r.ch(" ".code);
			r.int(Mem.getI64(e, 0), 10);
			r.ch(" ".code);
			r.fixed(mb(Mem.getI64(e, 8)), 2, 9);
			r.ch(" ".code);
			var by:Float = cast Mem.getI64(e, 8), cnt:Float = cast Mem.getI64(e, 0);
			r.fixed(by / cnt, 1, 7);
			r.str("\n");
			r.flush();
		}
		LibC.free(order);
	}
}
