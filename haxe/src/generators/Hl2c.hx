/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package generators;

import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.ds.Vector;
import core.ds.Failure;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import core.ds.OcamlHashtbl;
import core.ds.OcamlHash;
import generators.Hlcode;
import generators.Hlcode.*;

// port: OCaml evaluates the arguments of an application right to left; where
// several of them add defines to the same file, this translation computes them
// in that order explicitly.

enum Comparison {
	CEq;
	CNeq;
	CLt;
	CGt;
	CLte;
	CGte;
}

enum OutputOptions {
	OOLabel;
	OOCase(i:Int);
	OODefault;
	OOIncreaseIndent;
	OODecreaseIndent;
	OOBeginBlock;
	OOEndBlock;
	OOBreak;
}

class CodeModule {
	public final mName:String;
	public var mFunctions:Array<FunctionEntry> = []; // port: lists, head first
	public var mTypes:Array<Ttype> = [];

	public function new(mName:String) this.mName = mName;
}

class FunctionEntry {
	public final feIndex:Int;
	public var feName:String = "";
	public var feDecl:Null<Fundecl> = null;
	public var feArgs:Array<Ttype> = [];
	public var feRet:Ttype = HVoid;
	public var feModule:Null<CodeModule> = null;
	public var feCalledBy:Array<FunctionEntry> = []; // port: lists, head first
	public var feCalling:Array<FunctionEntry> = [];

	public function new(feIndex:Int) this.feIndex = feIndex;
}

class GlobalContext {
	public var version:Int;
	// port: the hash mutex is not needed: modules are generated sequentially
	public var hashCache:IntMap<Int> = new IntMap();
	public var hashMem:IntMap<Bool> = new IntMap();
	public var hashCacheList:Array<Int> = []; // port: list, head first
	public var hlcode:Code;
	public var dir:String;
	public var cfiles:Array<String> = []; // port: list, head first
	public var ftable:Vector<FunctionEntry>;
	public var htypes:TtypeMap<String>;
	public var gnames:Vector<String>;
	public var bytesNames:Vector<String>;
	public var typeModule:TtypeMap<CodeModule> = new TtypeMap();
	public var gcon:Gctx;

	public function new() {}
}

class FileContext {
	public var out:StringBuf = new StringBuf();
	public var tabs:String = "";
	public var dir:String;
	public var curfile:String;
	public var defines:Array<String> = []; // port: list, head first
	public var definedFuns:IntMap<Bool> = new IntMap();
	public var hdefines:StringMap<Bool> = new StringMap();
	public var definedTypes:TtypeMap<Bool> = new TtypeMap();
	public var funIndex:Int = 0;
	public var filePrefix:String;

	public function new(dir:String, curfile:String, filePrefix:String) {
		this.dir = dir;
		this.curfile = curfile;
		this.filePrefix = filePrefix;
	}
}

enum TypeDesc {
	DSimple(t:Ttype);
	DFun(args:Array<TypeDesc>, ret:TypeDesc, isFun:Bool);
	// port: `ident` stands for the physical identity of the name string (Marshal sharing)
	DNamed(n:String, ident:Dynamic);
	DVirtual(arr:Vector<VDescField>);
	DContext(arr:Vector<TypeDesc>);
}

class VDescField {
	public var name:String;
	// port: the name string itself where strings have an identity
	// (core.ds.StrTools.hasIdentity): field names are shared between the
	// virtuals of copies of one class field (`{cf with cf_type = ...}` in
	// apply_params), and Marshal shares them. Elsewhere the HField, so that a
	// name is never shared outside its own virtual.
	public var ident:Dynamic;
	public var d:TypeDesc;

	public function new(name:String, ident:Dynamic, d:TypeDesc) {
		this.name = name;
		this.ident = ident;
		this.d = d;
	}
}

// port: OCaml 5 `Marshal.to_bytes v [Marshal.Closures]` (runtime/extern.c), for the
// values make_sign digests. Physical sharing is reproduced through identity
// tokens, separately for strings and for blocks.
//
// The prototype records of HObj/HStruct/HVirtual hold PMaps, and a PMap holds its
// comparison closure (extlib's `PMap.empty`: `{ cmp = compare; map = Empty }`, one
// static closure shared by every map). OCaml writes a closure's code pointers as
// their offset in the reference compiler's code fragment followed by that
// fragment's MD5 (extern_code_pointer), i.e. bytes of the reference binary's own
// machine code. The port writes the closure in the same format (CODE_CODEPOINTER,
// the closure info of a 2-ary closure) with offset 0 and an all-zero digest, so
// the `t$fun_`/`t$vrt_`/`t$ctx_` names of the descriptions that reach a prototype
// intentionally differ from the reference's (the conformance harnesses normalize
// them: docs/testing.md). Everything else of the value is written as OCaml
// does: the records in their field order, the PMaps' AVL trees (rebuilt from the
// keys' first-insertion order, as extlib's PMap.add builds them), sharing and cycles.
private class OcamlExtern {
	final out = new haxe.io.BytesBuffer();
	var objCounter = 0;
	var size32 = 0;
	var size64 = 0;
	final strIds = new IdTable();
	final strsByValue = new StringMap<Array<{s:String, pos:Int}>>();
	final blockIds = new IdTable();
	final listTokens:Array<{arr:Array<Ttype>, tokens:Array<{}>}> = [];

	public function new() {}

	inline function byte(b:Int) out.addByte(b & 0xFF);

	function code8(c:Int, v:Int) {
		byte(c);
		byte(v);
	}

	function code16(c:Int, v:Int) {
		byte(c);
		byte(v >> 8);
		byte(v);
	}

	function code32(c:Int, v:Int) {
		byte(c);
		byte(v >>> 24);
		byte(v >> 16);
		byte(v >> 8);
		byte(v);
	}

	function lookupStr(id:Dynamic):Int {
		if (id == null) return -1;
		if (Std.isOfType(id, String)) {
			var b = strsByValue.get(id);
			if (b != null) for (e in b) if (core.ds.StrTools.physEq(e.s, id)) return e.pos;
			return -1;
		}
		return strIds.get(id);
	}

	function recordStr(id:Dynamic) {
		if (id != null) {
			if (Std.isOfType(id, String)) {
				var b = strsByValue.get(id);
				if (b == null) strsByValue.set(id, b = []);
				b.push({s: id, pos: objCounter});
			} else {
				strIds.set(id, objCounter);
			}
		}
		objCounter++;
	}

	function shared(pos:Int) {
		var d = objCounter - pos;
		if (d < 0x100) code8(0x04, d) else if (d < 0x10000) code16(0x05, d) else code32(0x06, d);
	}

	public function int(n:Int) {
		if (n >= 0 && n < 0x40) byte(0x40 + n) else if (n >= -(1 << 7) && n < (1 << 7)) code8(0x00, n) else if (n >= -(1 << 15) && n < (1 << 15))
			code16(0x01, n) else code32(0x02, n);
	}

	function intOpt(n:Null<Int>) {
		if (n == null) int(0) else block(0, 1, null, () -> int(n));
	}

	function intArray(a:Vector<Int>) {
		block(0, a.length, a, () -> for (n in a) int(n));
	}

	public function str(s:String, id:Dynamic) {
		var p = lookupStr(id);
		if (p >= 0) return shared(p);
		var b = haxe.io.Bytes.ofString(s);
		var len = b.length;
		if (len < 0x20) byte(0x20 + len) else if (len < 0x100) code8(0x09, len) else code32(0x0A, len);
		out.add(b);
		size32 += 1 + Std.int((len + 4) / 4);
		size64 += 1 + Std.int((len + 8) / 8);
		recordStr(id);
	}

	public function block(tag:Int, sz:Int, id:Dynamic, fields:Void->Void) {
		if (sz == 0) return header(0, tag);
		var p = id == null ? -1 : blockIds.get(id);
		if (p >= 0) return shared(p);
		header(sz, tag);
		size32 += 1 + sz;
		size64 += 1 + sz;
		if (id != null) blockIds.set(id, objCounter);
		objCounter++;
		fields();
	}

	function header(sz:Int, tag:Int) {
		if (tag < 16 && sz < 8) byte(0x80 + tag + (sz << 4)) else code32(0x08, (sz << 10) | 0x300 | tag);
	}

	function listToken(arr:Array<Ttype>, i:Int):{} {
		for (e in listTokens) if (e.arr == arr) return e.tokens[i];
		var tokens:Array<{}> = [for (_ in 0...arr.length) {}];
		listTokens.push({arr: arr, tokens: tokens});
		return tokens[i];
	}

	function ttypeList(arr:Array<Ttype>, i:Int) {
		if (i == arr.length) return int(0);
		block(0, 2, listToken(arr, i), () -> {
			ttype(arr[i]);
			ttypeList(arr, i + 1);
		});
	}

	public function ttype(t:Ttype) {
		var c = constIndex(t);
		if (c >= 0) return int(c);
		var tag = blockTag(t);
		switch t {
			case HFun(args, ret) | HMethod(args, ret):
				block(tag, 2, t, () -> {
					ttypeList(args, 0);
					ttype(ret);
				});
			case HArray(x) | HRef(x) | HNull(x) | HPacked(x):
				block(tag, 1, t, () -> ttype(x));
			case HAbstract(name, idx, ident):
				block(tag, 2, t, () -> {
					str(name, ident);
					int(idx);
				});
			case HEnum(e):
				block(tag, 1, t, () -> block(0, 4, e, () -> {
					str(e.ename, e.ename == "" ? emptyEname : e);
					int(e.eid);
					if (e.eglobal == null) int(0) else block(0, 1, null, () -> int(e.eglobal));
					block(0, e.efields.length, e.efields, () -> for (f in e.efields) block(0, 3, f, () -> {
						str(f.name, f.name == "" ? emptyEfield : f);
						int(f.nid);
						block(0, f.args.length, f.args, () -> for (a in f.args) ttype(a));
					}));
				}));
			case HObj(p) | HStruct(p):
				block(tag, 1, t, () -> classProto(p));
			case HVirtual(vp):
				block(tag, 1, t, () -> block(0, 2, vp, () -> {
					hfields(vp.vfields);
					strPMap(vp.vindex, int);
				}));
			case _:
				core.Globals.die("", "hl2c.ml");
		}
	}

	static final emptyEname = {};
	static final emptyEfield = {};

	// port: hlcode.ml's class_proto record, in its field order.
	function classProto(p:ClassProto) {
		block(0, 12, p, () -> {
			str(p.pname, p); // port: the token of DNamed (p.pname, p)
			int(p.pid);
			intOpt(p.pclassglobal);
			if (p.psuper == null) int(0) else block(0, 1, null, () -> classProto(p.psuper));
			intArray(p.pvirtuals);
			block(0, p.pproto.length, p.pproto, () -> for (f in p.pproto) block(0, 4, f, () -> {
				str(f.fname, if (core.ds.StrTools.hasIdentity) f.fname else f);
				int(f.fid);
				int(f.fmethod);
				intOpt(f.fvirtual);
			}));
			int(p.pnfields);
			hfields(p.pfields);
			strPMap(p.pindex, v -> block(0, 2, v, () -> {
				int(v.fid);
				ttype(v.t);
			}));
			strPMap(p.pfunctions, int);
			var keys = [for (k in p.pinterfaces.keys) p.pinterfaces.keyOf(k)];
			pmap(keys, Hlcode.tCompare, p.pinterfaces, k -> ttype(k), k -> int(p.pinterfaces.get(k)));
			function bindings(i:Int) {
				if (i == p.pbindings.length) return int(0);
				block(0, 2, null, () -> {
					var b = p.pbindings[i];
					block(0, 2, b, () -> {
						int(b.fid);
						int(b.fidx);
					});
					bindings(i + 1);
				});
			}
			bindings(0);
		});
	}

	// port: `(string * string index * ttype) array`
	function hfields(arr:Vector<HField>) {
		block(0, arr.length, arr, () -> for (f in arr) block(0, 3, f, () -> {
			str(f.name, if (core.ds.StrTools.hasIdentity) f.name else f);
			int(f.nid);
			ttype(f.t);
		}));
	}

	function strPMap<V>(m:StrPMap<V>, value:V->Void) {
		pmap(m.keys, Hlcode.strCompare, m, k -> str(k, if (core.ds.StrTools.hasIdentity) k else null), k -> value(m.get(k)));
	}

	// port: extlib's `('k, 'v) PMap.t` record `{ cmp; map }`, the tree built by
	// PMap.add from PMap.empty with the keys in their first-insertion order.
	function pmap<K>(keys:Array<K>, cmp:K->K->Int, token:{}, key:K->Void, value:K->Void) {
		var tree:Null<PMapNode<K>> = null;
		for (k in keys) tree = PMapNode.add(cmp, k, tree);
		block(0, 2, token, () -> {
			compareClosure();
			function node(n:Null<PMapNode<K>>) {
				if (n == null) return int(0); // Empty
				block(0, 5, n, () -> {
					node(n.l);
					key(n.k);
					value(n.k);
					node(n.r);
					int(n.h);
				});
			}
			node(tree);
		});
	}

	static final compareToken = {};

	// port: the closure of `compare` (arity 2: caml_curry2, the closure info, the
	// direct entry point; no environment) as extern.c writes it, with the code
	// pointers' offset 0 and digest all zeros in place of the reference binary's
	// (see the comment of this class).
	function compareClosure() {
		block(247, 3, compareToken, () -> {
			codePointer();
			// Long_val (Make_closinfo (2, 3)): arity 2 in the top byte, the environment at 3
			byte(0x03);
			for (b in [0x01, 0, 0, 0, 0, 0, 0, 0x03]) byte(b);
			codePointer();
		});
	}

	function codePointer() {
		code32(0x10, 0);
		for (_ in 0...16) byte(0);
	}

	public function desc(d:TypeDesc) {
		switch d {
			case DSimple(t):
				block(0, 1, d, () -> ttype(t));
			case DFun(args, ret, b):
				block(1, 3, d, () -> {
					function list(i:Int) {
						if (i == args.length) return int(0);
						block(0, 2, null, () -> {
							desc(args[i]);
							list(i + 1);
						});
					}
					list(0);
					desc(ret);
					int(b ? 1 : 0);
				});
			case DNamed(n, ident):
				block(2, 1, d, () -> str(n, ident));
			case DVirtual(arr):
				block(3, 1, d, () -> block(0, arr.length, arr, () -> for (f in arr) block(0, 2, f, () -> {
					str(f.name, f.ident);
					desc(f.d);
				})));
			case DContext(arr):
				block(4, 1, d, () -> block(0, arr.length, arr, () -> for (x in arr) desc(x)));
		}
	}

	public function getBytes():haxe.io.Bytes {
		var data = out.getBytes();
		var b = new haxe.io.BytesBuffer();
		function w32(v:Int) {
			b.addByte((v >>> 24) & 0xFF);
			b.addByte((v >> 16) & 0xFF);
			b.addByte((v >> 8) & 0xFF);
			b.addByte(v & 0xFF);
		}
		w32(0x8495A6BE);
		w32(data.length);
		w32(objCounter);
		w32(size32);
		w32(size64);
		b.add(data);
		return b.getBytes();
	}
}

// port: extlib's PMap tree (`Node (l, k, v, r, h)`, Empty is null), built by
// `add` with `bal` as in extlib/pMap.ml; the values are looked up when written.
private class PMapNode<K> {
	public final l:Null<PMapNode<K>>;
	public final k:K;
	public final r:Null<PMapNode<K>>;
	public final h:Int;

	function new(l:Null<PMapNode<K>>, k:K, r:Null<PMapNode<K>>, h:Int) {
		this.l = l;
		this.k = k;
		this.r = r;
		this.h = h;
	}

	static inline function height<K>(n:Null<PMapNode<K>>):Int return n == null ? 0 : n.h;

	static function make<K>(l:Null<PMapNode<K>>, k:K, r:Null<PMapNode<K>>):PMapNode<K> {
		var hl = height(l), hr = height(r);
		return new PMapNode(l, k, r, (hl > hr ? hl : hr) + 1);
	}

	static function bal<K>(l:Null<PMapNode<K>>, k:K, r:Null<PMapNode<K>>):PMapNode<K> {
		var hl = height(l);
		var hr = height(r);
		if (hl > hr + 2) {
			if (height(l.l) >= height(l.r)) return make(l.l, l.k, make(l.r, k, r));
			var lr = l.r;
			return make(make(l.l, l.k, lr.l), lr.k, make(lr.r, k, r));
		} else if (hr > hl + 2) {
			if (height(r.r) >= height(r.l)) return make(make(l, k, r.l), r.k, r.r);
			var rl = r.l;
			return make(make(l, k, rl.l), rl.k, make(rl.r, r.k, r.r));
		}
		return new PMapNode(l, k, r, (hl > hr ? hl : hr) + 1);
	}

	public static function add<K>(cmp:K->K->Int, x:K, n:Null<PMapNode<K>>):PMapNode<K> {
		if (n == null) return new PMapNode(null, x, null, 1);
		var c = cmp(x, n.k);
		if (c == 0) return new PMapNode(n.l, x, n.r, n.h);
		if (c < 0) return bal(add(cmp, x, n.l), n.k, n.r);
		return bal(n.l, n.k, add(cmp, x, n.r));
	}
}

// port: physical identity of the marshalled values' tokens.
private class IdTable {
	#if (target.name == "hxmc")
	final m = new haxe.ds.ObjectMap<{}, Int>();

	public function new() {}

	public function get(id:Dynamic):Int {
		var p = m.get(id);
		return p == null ? -1 : p;
	}

	public function set(id:Dynamic, pos:Int) m.set(id, pos);
	#else
	final ids:Array<Dynamic> = [];
	final poss:Array<Int> = [];

	public function new() {}

	public function get(id:Dynamic):Int {
		for (i in 0...ids.length) if (ids[i] == id) return poss[i];
		return -1;
	}

	public function set(id:Dynamic, pos:Int) {
		ids.push(id);
		poss.push(pos);
	}
	#end
}

class Hl2c {
	static final keywords:StringMap<Bool> = {
		var cKwds = [
			"auto", "bool", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto",
			"if", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
			"void", "volatile", "while",
			/* Values */
			"NULL", "true", "false",
			/* MS specific */
			"asm", "dllimport2", "dllexport2", "naked2", "thread2",
			/* reserved by HLC */
			"t",
			/* GCC */
			"typeof",
			/* C11 */
			"_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local", "_Pragma",
			"inline", "restrict", "_restrict"
		];
		var h = new StringMap<Bool>();
		for (i in cKwds) h.set(i, true);
		h;
	}

	static function ident(i:String):String return if (keywords.exists(i) || StringTools.startsWith(i, "__")) "_hx_" + i else i;

	static function sComp(c:Comparison):String {
		return switch c {
			case CLt: "<";
			case CGt: ">";
			case CEq: "==";
			case CLte: "<=";
			case CGte: ">=";
			case CNeq: "!=";
		}
	}

	static final coreTypes:Array<Ttype> = [
		HVoid, HUI8, HUI16, HI32, HI64, HF32, HF64, HBool, HBytes, HDyn, HFun([], HVoid), HObj(nullProto), HArray(HDyn), HType, HRef(HVoid),
		HVirtual(new VirtualProto()), HDynObj, HAbstract("", 0, null), HEnum(new EnumProto("", 0, null, vector())), HMethod([], HVoid), HStruct(nullProto)
	];

	// port: ExtString.String.nsplit (an empty string gives [])
	static function nsplit(s:String, sep:String):Array<String> return s == "" ? [] : s.split(sep);

	static function tname(str:String):String {
		var n = nsplit(str, ".").join("__");
		return ident(n);
	}

	static function isGcPtr(t:Ttype):Bool {
		return switch t {
			case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HType | HRef(_) | HMethod(_) | HPacked(_) | HGUID: false;
			case HBytes | HDyn | HFun(_) | HObj(_) | HArray(_) | HVirtual(_) | HDynObj | HAbstract(_) | HEnum(_) | HNull(_) | HStruct(_): true;
		}
	}

	static function isPtr(t:Ttype):Bool {
		return switch t {
			case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HGUID: false;
			case _: true;
		}
	}

	static function ctypeNoPtr(t:Ttype):{s:String, n:Int} {
		return switch t {
			case HVoid: {s: "void", n: 0};
			case HUI8: {s: "unsigned char", n: 0};
			case HUI16: {s: "unsigned short", n: 0};
			case HI32: {s: "int", n: 0};
			case HI64: {s: "int64", n: 0};
			case HF32: {s: "float", n: 0};
			case HF64: {s: "double", n: 0};
			case HBool: {s: "bool", n: 0};
			case HBytes: {s: "vbyte", n: 1};
			case HDyn: {s: "vdynamic", n: 1};
			case HFun(_): {s: "vclosure", n: 1};
			case HObj(p) | HStruct(p): {s: tname(p.pname), n: 0};
			case HArray(_): {s: "varray", n: 1};
			case HType: {s: "hl_type", n: 1};
			case HRef(t):
				var r = ctypeNoPtr(t);
				{s: r.s, n: r.n + 1};
			case HVirtual(_): {s: "vvirtual", n: 1};
			case HDynObj: {s: "vdynobj", n: 1};
			case HAbstract(name, _, _): {s: name, n: 1};
			case HEnum(_): {s: "venum", n: 1};
			case HNull(_): {s: "vdynamic", n: 1};
			case HMethod(_): {s: "void", n: 1};
			case HPacked(t):
				var r = ctypeNoPtr(t);
				{s: "struct _" + r.s, n: r.n};
			case HGUID: {s: "int64", n: 0};
		}
	}

	static function stars(n:Int):String {
		var s = "";
		for (_ in 0...n) s += "*";
		return s;
	}

	static function ctype(t:Ttype):String {
		var r = ctypeNoPtr(t);
		return if (r.n == 0) r.s else r.s + stars(r.n);
	}

	static function argsRepr(args:Array<Ttype>):String return if (args.length == 0) "void" else [for (a in args) ctype(a)].join(",");

	static function castFun(s:String, args:Array<Ttype>, t:Ttype):String return '((${ctype(t)} (*)(${argsRepr(args)}))$s)';

	static function dynValueField(t:Ttype):String {
		return "v." + switch t {
			case HUI8: "ui8";
			case HUI16: "ui16";
			case HI32: "i";
			case HI64 | HGUID: "i64";
			case HF32: "f";
			case HF64: "d";
			case HBool: "b";
			case _: "ptr";
		}
	}

	static function typeKindInfo(t:Ttype):{id:Int, kind:Ttype, wrap:String, dyn:String} {
		/* type_kind_id, type_kind, wrap_char, dyn_prefix */
		return switch [getGroup(t), t] {
			case [_, HVoid]:
				{id: 0, kind: t, wrap: "v", dyn: "p"};
			case [GBool | GInt, _]:
				var nb = typeSizeBits(t);
				if (nb <= 2) {id: 1, kind: HI32, wrap: "i", dyn: "i"} /* same int representation */ else {id: 4, kind: HI64, wrap: "i64", dyn: "i64"};
			case [GFloat, _]:
				var nb = typeSizeBits(t);
				if (nb <= 2) {id: 2, kind: HF32, wrap: "f", dyn: "f"} else {id: 3, kind: HF64, wrap: "d", dyn: "d"};
			case _:
				{id: 5, kind: HDyn, wrap: "p", dyn: "p"};
		}
	}

	static function typeId(t:Ttype):String {
		return switch t {
			case HVoid: "HVOID";
			case HUI8: "HUI8";
			case HUI16: "HUI16";
			case HI32: "HI32";
			case HI64: "HI64";
			case HF32: "HF32";
			case HF64: "HF64";
			case HBool: "HBOOL";
			case HBytes: "HBYTES";
			case HDyn: "HDYN";
			case HFun(_): "HFUN";
			case HObj(_): "HOBJ";
			case HArray(_): "HARRAY";
			case HType: "HTYPE";
			case HRef(_): "HREF";
			case HVirtual(_): "HVIRTUAL";
			case HDynObj: "HDYNOBJ";
			case HAbstract(_): "HABSTRACT";
			case HEnum(_): "HENUM";
			case HNull(_): "HNULL";
			case HMethod(_): "HMETHOD";
			case HStruct(_): "HSTRUCT";
			case HPacked(_): "HPACKED";
			case HGUID: "HGUID";
		}
	}

	static function varType(n:String, t:Ttype):String return ctype(t) + " " + ident(n);

	static function block(ctx:FileContext):Void ctx.tabs = ctx.tabs + "\t";

	static function unblock(ctx:FileContext):Void ctx.tabs = ctx.tabs.substr(0, ctx.tabs.length - 1);

	static function hash(ctx:GlobalContext, sid:Int):Int {
		var h = ctx.hashCache.get(sid);
		if (h != null) return h;
		var h = hlHash(ctx.hlcode.strings[sid]);
		while (ctx.hashMem.exists(h)) h = (h + 1) | 0;
		ctx.hashCache.set(sid, h);
		ctx.hashMem.set(h, true);
		ctx.hashCacheList.unshift(sid);
		return h;
	}

	static function typeName(ctx:GlobalContext, t:Ttype):String {
		var n = ctx.htypes.get(t);
		if (n == null) return core.Globals.die(tstr(t), "hl2c.ml");
		return n;
	}

	static function define(ctx:FileContext, s:String):Void {
		if (!ctx.hdefines.exists(s)) {
			ctx.defines.unshift(s);
			ctx.hdefines.set(s, true);
		}
	}

	static function defineType(gctx:GlobalContext, ctx:FileContext, t:Ttype):Void {
		switch t {
			case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HBytes | HDyn | HArray(_) | HType | HDynObj | HNull(_) | HRef(_) | HGUID:
			case HAbstract(_):
				define(ctx, "#include <hl/natives.h>");
			case HFun(args, ret) | HMethod(args, ret):
				for (a in args) defineType(gctx, ctx, a);
				defineType(gctx, ctx, ret);
			case HEnum(_) | HObj(_) | HStruct(_) if (!ctx.definedTypes.exists(t)):
				ctx.definedTypes.set(t, true);
				var m = gctx.typeModule.get(t);
				if (m == null) core.Globals.die("", "hl2c.ml");
				define(ctx, '#include <${m.mName}.h>');
			case HVirtual(vp) if (!ctx.definedTypes.exists(t)):
				ctx.definedTypes.set(t, true);
				for (f in vp.vfields) defineType(gctx, ctx, f.t);
			case HPacked(t):
				defineType(gctx, ctx, t);
			case HEnum(_) | HObj(_) | HStruct(_) | HVirtual(_):
		}
	}

	static function typeValue(gctx:GlobalContext, ctx:FileContext, t:Ttype):String {
		var n = typeName(gctx, t);
		define(ctx, 'extern hl_type $n;');
		return "&" + n;
	}

	static function enumConstrType(gctx:GlobalContext, ctx:FileContext, e:EnumProto, i:Int):String {
		defineType(gctx, ctx, HEnum(e));
		var f = e.efields[i];
		var cname = f.name, tl = f.args;
		if (tl.length == 0) return "venum";
		var name = if (e.eid == 0) {
			var name = gctx.htypes.get(HEnum(e));
			if (name == null) core.Globals.die("", "hl2c.ml");
			"Enum" + name;
		} else nsplit(e.ename, ".").join("_");
		return if (cname == "") name else name + "_" + cname;
	}

	static inline function output(ctx:FileContext, str:String):Void ctx.out.add(str);

	static function linec(ctx:FileContext, str:String):Void {
		output(ctx, ctx.tabs);
		output(ctx, str);
		output(ctx, "\n");
	}

	static function exprc(ctx:FileContext, str:String):Void {
		output(ctx, ctx.tabs);
		output(ctx, str);
		output(ctx, ";\n");
	}

	static function unamedField(fid:Int):String return "f$" + fid;

	static function objField(fid:Int, name:String):String return if (name == "") unamedField(fid) else ident(name);

	static final bom = "\u{FEFF}";

	static function saveCfile(gctx:GlobalContext, file:String):Void {
		if (StringTools.endsWith(file, ".c")) gctx.cfiles.unshift(file);
	}

	static function closeFile(ctx:FileContext):Void {
		var out = ctx.out.toString();
		var defines = ctx.defines.copy();
		defines.reverse();
		var content = if (defines.length == 0) out else defines.join("\n") + "\n\n" + out;
		var str = if (ctx.curfile == "hlc.json") content else bom + content;
		ctx.defines = [];
		ctx.definedTypes = new TtypeMap();
		ctx.hdefines = new StringMap();
		ctx.definedFuns = new IntMap();
		ctx.out = new StringBuf();
		var fpath = ctx.dir + "/" + ctx.curfile;
		var bytes = haxe.io.Bytes.ofString(str);
		var fcontent = try sys.io.File.getBytes(fpath) catch (_:Dynamic) null;
		if (fcontent == null || fcontent.compare(bytes) != 0) sys.io.File.saveBytes(fpath, bytes);
	}

	static function defineGlobal(gctx:GlobalContext, ctx:FileContext, g:Int):Void {
		var t = gctx.hlcode.globals[g];
		defineType(gctx, ctx, t);
		define(ctx, 'extern ${varType(gctx.gnames[g], t)};');
	}

	static function defineFunction(gctx:GlobalContext, ctx:FileContext, fid:Int):String {
		var ft = gctx.ftable[fid];
		var fid = if (ft.feDecl == null) -1 else fid;
		if (!ctx.definedFuns.exists(fid)) {
			ctx.definedFuns.set(fid, true);
			switch ft.feDecl {
				case null:
					define(ctx, "#include <hl/natives.h>");
				case f:
					defineType(gctx, ctx, f.ftype);
					ctx.defines.unshift('${ctype(ft.feRet)} ${ft.feName}(${argsRepr(ft.feArgs)});');
			}
		}
		return ft.feName;
	}

	static function md5hex(b:haxe.io.Bytes):String return haxe.crypto.Md5.make(b).toHex();

	static function shortDigest(str:String):String return md5hex(haxe.io.Bytes.ofString(str)).substr(0, 7);

	static function createFileContext(dir:String, file:String):FileContext return new FileContext(dir, file, shortDigest(file) + "_");

	static function openFile(gctx:GlobalContext, file:String):FileContext {
		var ctx = createFileContext(gctx.dir, file);
		if (file != "hlc.json") Gctx.mapSourceHeader(gctx.gcon.defines, s -> define(ctx, '// $s'));
		return ctx;
	}

	static inline var stringDataLimit = 64;

	static function utf8Length(s:String):Int return haxe.io.Bytes.ofString(s).length;

	static function string(gctx:GlobalContext, ctx:FileContext, sid:Int):String {
		var s = gctx.hlcode.strings[sid];
		if (utf8Length(s) < stringDataLimit) return 'USTR("${core.StringHelper.sEscape(s)}")' else {
			var id = shortDigest(s);
			define(ctx, 'extern vbyte string$$$id[];');
			return 'string$$$id';
		}
	}

	// port: the `(ttype list * ttype)` keys of funByArgs, as OCaml values for Hashtbl.hash
	static function kindKeyHash(k:{args:Array<Int>, t:Int}):Int
		return OcamlHash.hash(OBlock(0, [OcamlHash.ofList([for (a in k.args) OInt(a)]), OInt(k.t)]));

	static function kindOf(i:Int):Ttype {
		return switch i {
			case 0: HVoid;
			case 3: HI32;
			case 4: HI64;
			case 5: HF32;
			case 6: HF64;
			case _: HDyn;
		}
	}

	static function generateReflection(gctx:GlobalContext, ctx:FileContext):Void {
		function line(s:String) linec(ctx, s);
		function expr(s:String) exprc(ctx, s);

		var funByArgs = new IntMap<OcamlHashtbl<{args:Array<Int>, t:Int}, Bool>>();
		function typeKind(t:Ttype):Ttype return typeKindInfo(t).kind;
		function typeKindId(t:Ttype):Int return typeKindInfo(t).id;
		function addFun(args:Array<Ttype>, t:Ttype):Void {
			var nargs = args.length;
			var kargs = [for (a in args) constIndex(typeKind(a))];
			var kt = constIndex(typeKind(t));
			var h = funByArgs.get(nargs);
			if (h == null) {
				h = new OcamlHashtbl(kindKeyHash, (a, b) -> a.t == b.t && a.args.join(",") == b.args.join(","));
				funByArgs.set(nargs, h);
			}
			h.replace({args: kargs, t: kt}, true);
		}
		for (f in gctx.hlcode.functions) {
			for (op in f.code) {
				switch op {
					case OSafeCast(dst, _) | ODynGet(dst, _, _):
						switch f.regs[dst] {
							case HFun(args, t): addFun(args, t);
							case _:
						}
					case _:
				}
			}
		}
		for (f in gctx.ftable) addFun(f.feArgs, f.feRet);
		var argsCounts = [for (k in funByArgs.keys()) k];
		haxe.ds.ArraySort.sort(argsCounts, (a, b) -> a - b);
		function kinds(k:{args:Array<Int>, t:Int}):{args:Array<Ttype>, t:Ttype} return {args: [for (a in k.args) kindOf(a)], t: kindOf(k.t)};
		function chkOf(args:Array<Ttype>, t:Ttype):Int {
			var s = -1;
			var chk = 0;
			for (t in [t].concat(args)) {
				s++;
				chk = chk | (typeKindId(t) << (s * 3));
			}
			return chk;
		}
		expr('static int TKIND[] = {${[for (t in coreTypes) Std.string(typeKindId(t))].join(",")}}');
		line("");
		line("void *hlc_static_call( void *fun, hl_type *t, void **args, vdynamic *out ) {");
		block(ctx);
		expr("int chk = TKIND[t->fun->ret->kind]");
		expr("vdynamic *d");
		line("switch( t->fun->nargs ) {");
		for (nargs in argsCounts) {
			line('case $nargs:');
			block(ctx);
			if (nargs > 9) expr("hl_fatal(\"Too many arguments, TODO:use more bits\")") else {
				for (i in 0...nargs) expr('chk |= TKIND[t->fun->args[$i]->kind] << ${(i + 1) * 3}');
				line("switch( chk ) {");
				funByArgs.get(nargs).iter((k, _) -> {
					var kk = kinds(k);
					var args = kk.args, t = kk.t;
					var chk = chkOf(args, t);
					line('case $chk:');
					block(ctx);
					var vargs = [
						for (idx in 0...args.length) {
							var t = args[idx];
							if (isPtr(t)) '(${ctype(t)})args[$idx]' else '*(${ctype(t)}*)args[$idx]';
						}
					];
					var call = '${castFun("fun", args, t)}(${vargs.join(",")})';
					if (isPtr(t)) expr('return $call') else if (tEq(t, HVoid)) {
						expr(call);
						expr("return NULL");
					} else {
						expr('out->${dynValueField(t)} = $call');
						expr('return &out->${dynValueField(t)}');
					}
					unblock(ctx);
				});
				line("}");
				expr("break");
			}
			unblock(ctx);
		}
		line("}");
		expr("hl_fatal(\"Unsupported dynamic call\")");
		expr("return NULL");
		unblock(ctx);
		line("}");
		line("");
		function wrapChar(t:Ttype):String return typeKindInfo(t).wrap;
		function makeWrapName(args:Array<Ttype>, t:Ttype):String return [for (a in args) wrapChar(a)].join("") + "_" + wrapChar(t);
		for (nargs in argsCounts) {
			funByArgs.get(nargs).iter((k, _) -> {
				var kk = kinds(k);
				var args = kk.args, t = kk.t;
				var name = makeWrapName(args, t);
				line('static ${ctype(t)} wrap_$name(void *value${[for (i in 0...args.length) "," + varType("p" + i, args[i])].join("")}) {');
				block(ctx);
				if (args.length != 0) expr('void *args[] = {${[for (i in 0...args.length) if (!isPtr(args[i])) "&p" + i else "p" + i].join(",")}}');
				var vargs = if (args.length == 0) "NULL" else "args";
				if (tEq(t, HVoid)) expr('hl_wrapper_call(value,$vargs,NULL)') else if (isPtr(t)) expr('return hl_wrapper_call(value,$vargs,NULL)') else {
					expr("vdynamic ret");
					expr('hl_wrapper_call(value,$vargs,&ret)');
					expr('return ret.v.${wrapChar(t)}');
				}
				unblock(ctx);
				line("}");
			});
		}
		line("");
		line("void *hlc_get_wrapper( hl_type *t ) {");
		block(ctx);
		expr("int chk = TKIND[t->fun->ret->kind]");
		line("switch( t->fun->nargs ) {");
		for (nargs in argsCounts) {
			line('case $nargs:');
			block(ctx);
			if (nargs > 9) expr("hl_fatal(\"Too many arguments, TODO:use more bits\")") else {
				for (i in 0...nargs) expr('chk |= TKIND[t->fun->args[$i]->kind] << ${(i + 1) * 3}');
				line("switch( chk ) {");
				funByArgs.get(nargs).iter((k, _) -> {
					var kk = kinds(k);
					var chk = chkOf(kk.args, kk.t);
					expr('case $chk: return wrap_${makeWrapName(kk.args, kk.t)}');
				});
				line("}");
				expr("break");
			}
			unblock(ctx);
		}
		line("}");
		expr("return NULL");
		unblock(ctx);
		line("}");
		line("");
	}

	// port: Printf "%-<n>s"-style helpers are inlined where used
	static function generateFunction(gctx:GlobalContext, ctx:FileContext, f:Fundecl):Void {
		function line(s:String) linec(ctx, s);
		function expr(s:String) exprc(ctx, s);
		function define(s:String) Hl2c.define(ctx, s);
		function block() Hl2c.block(ctx);
		function unblock() Hl2c.unblock(ctx);
		function typeValue(ctx:FileContext, t:Ttype) return Hl2c.typeValue(gctx, ctx, t);
		var code = gctx.hlcode;

		var rid = -1;
		var clId = 0;
		function reg(id:Int) return "r" + id;

		function labelName(p:Int) return 'label$$${ctx.filePrefix}${ctx.funIndex}_$p';
		ctx.funIndex = ctx.funIndex + 1;
		ctx.definedFuns.set(f.findex, true);
		for (r in f.regs) defineType(gctx, ctx, r);
		defineType(gctx, ctx, f.ftype);

		function rtype(r:Int) return f.regs[r];

		function funname(fid:Int) return defineFunction(gctx, ctx, fid);

		function rcast(r:Int, t:Ttype):String {
			var rt = rtype(r);
			return if (tsame(rt, t)) reg(r) else switch [t, rt] {
				case [HPacked(_), HStruct(_)]:
					'(*(${ctype(t)}*)${reg(r)})';
				case _:
					'((${ctype(t)})${reg(r)})';
			}
		}

		function rfun(r:Int, args:Array<Ttype>, t:Ttype) return castFun(reg(r) + "->fun", args, t);

		function rassign(r:Int, t:Ttype):String {
			var rt = rtype(r);
			if (tEq(t, HVoid)) return "";
			var assign = reg(r) + " = ";
			if (tsame(t, rt)) return assign;
			if (!safeCast(t, rt)) return core.Globals.die("", "hl2c.ml") else {
				var cst = assign + "(" + ctype(rt) + ")";
				return switch t {
					case HPacked(_): cst + "&";
					case _: cst;
				}
			}
		}

		function rcasts(a:Array<Int>, b:Array<Ttype>):Array<String> {
			if (a.length != b.length) throw new core.ds.InvalidArgument("List.map2");
			return [for (i in 0...a.length) rcast(a[i], b[i])];
		}

		function ocall(r:Int, fid:Int, args:Array<Int>):Void {
			var ft = gctx.ftable[fid];
			var rstr = rassign(r, ft.feRet);
			var sargs = rcasts(args, ft.feArgs).join(",");
			expr('$rstr${funname(fid)}($sargs)');
		}

		function dynPrefix(t:Ttype) return typeKindInfo(t).dyn;

		function typeValueOpt(t:Ttype):String {
			return switch t {
				case HF32 | HF64 | HI64 | HGUID: "";
				case _: "," + typeValue(ctx, t);
			}
		}

		function dynCall(r:Int, f:Int, pl:Array<Int>):Void {
			line("{");
			block();
			if (pl.length != 0) expr('vdynamic *args[] = {${[for (p in pl) switch rtype(p) {
					case HDyn:
						reg(p);
					case t:
						if (isDynamic(t)) '(vdynamic*)${reg(p)}' else 'hl_make_dyn(&${reg(p)},${typeValue(ctx, t)})';
				}].join(",")}}');
			var rt = rtype(r);
			var ret = if (tEq(rt, HVoid)) "" else if (isDynamic(rt)) '${reg(r)} = (${ctype(rt)})' else "vdynamic *ret = ";
			expr('${ret}hl_dyn_call((vclosure*)${reg(f)},${if (pl.length == 0) "NULL" else "args"},${pl.length})');
			if (!tEq(rt, HVoid) && !isDynamic(rt)) {
				var tvo = typeValueOpt(rt);
				expr('${reg(r)} = (${ctype(rt)})hl_dyn_cast${dynPrefix(rt)}(&ret,&hlt_dyn$tvo)');
			}
			unblock();
			line("}");
		}

		function mcall(r:Int, fid:Int, l:Array<Int>):Void {
			if (l.length == 0) core.Globals.die("", "hl2c.ml");
			var o = l[0], args = l.slice(1);
			switch rtype(o) {
				case HObj(_) | HStruct(_):
					var vfun = castFun('${reg(o)}->$$type->vobj_proto[$fid]', [rtype(o)].concat([for (a in args) rtype(a)]), rtype(r));
					expr('${rassign(r, rtype(r))}$vfun(${[for (x in l) reg(x)].join(",")})');
				case HVirtual(vp):
					var rt = rtype(r);
					var meth = 'hl_vfields(${reg(o)})[$fid]';
					var meth = castFun(meth, [HDyn].concat([for (a in args) rtype(a)]), rt);
					line('if( hl_vfields(${reg(o)})[$fid] ) ${rassign(r, rt)}$meth(${[reg(o) + "->value"].concat([for (a in args) reg(a)]).join(",")}); else {');
					block();
					if (args.length != 0) expr('void *args[] = {${[for (p in args) { var t = rtype(p); if (isPtr(t)) reg(p) else '&${reg(p)}'; }].join(",")}}');
					var rt = rtype(r);
					var ret = if (tEq(rt, HVoid)) "" else if (isPtr(rt)) '${reg(r)} = (${ctype(rt)})' else {
						expr("vdynamic ret");
						"";
					}
					var vf = vp.vfields[fid];
					var fname = vf.name, nid = vf.nid, ft = vf.t;
					var h = hash(gctx, nid);
					var tv = typeValue(ctx, ft);
					expr('${ret}hl_dyn_call_obj(${reg(o)}->value,$tv,$h/*$fname*/,${if (args.length == 0) "NULL" else "args"},${if (isPtr(rt) || rt == HVoid) "NULL" else "&ret"})');
					if (!tEq(rt, HVoid) && !isPtr(rt)) expr('${reg(r)} = (${ctype(rt)})ret.v.${dynPrefix(rt)}');
					unblock();
					line("}");
				case _:
					core.Globals.die("", "hl2c.ml");
			}
		}

		function setField(obj:Int, fid:Int, v:Int):Void {
			switch rtype(obj) {
				case HObj(o) | HStruct(o):
					var nt = resolveField(o, fid);
					expr('${reg(obj)}->${objField(fid, nt.name)} = ${rcast(v, nt.t)}');
				case HVirtual(vp):
					var vf = vp.vfields[fid];
					var name = vf.name, nid = vf.nid, t = vf.t;
					var tvo = typeValueOpt(rtype(v));
					var h = hash(gctx, nid);
					var dset = 'hl_dyn_set${dynPrefix(t)}(${reg(obj)}->value,$h/*$name*/$tvo,${reg(v)})';
					expr('if( hl_vfields(${reg(obj)})[$fid] ) *(${ctype(t)}*)(hl_vfields(${reg(obj)})[$fid]) = (${ctype(t)})${reg(v)}; else $dset');
				case _:
					core.Globals.die("", "hl2c.ml");
			}
		}

		function getField(r:Int, obj:Int, fid:Int):Void {
			switch rtype(obj) {
				case HObj(o) | HStruct(o):
					var nt = resolveField(o, fid);
					expr('${rassign(r, nt.t)}${reg(obj)}->${objField(fid, nt.name)}');
				case HVirtual(v):
					var vf = v.vfields[fid];
					var name = vf.name, nid = vf.nid, t = vf.t;
					var tvo = typeValueOpt(t);
					var h = hash(gctx, nid);
					var dget = '(${ctype(t)})hl_dyn_get${dynPrefix(t)}(${reg(obj)}->value,$h/*$name*/$tvo)';
					expr('${rassign(r, t)}hl_vfields(${reg(obj)})[$fid] ? (*(${ctype(t)}*)(hl_vfields(${reg(obj)})[$fid])) : $dget');
				case _:
					core.Globals.die("", "hl2c.ml");
			}
		}

		var fret = switch f.ftype {
			case HFun(args, t):
				var sargs = [
					for (t in args) {
						rid++;
						varType(reg(rid), t);
					}
				].join(",");
				line('${ctype(t)} ${funname(f.findex)}($sargs) {');
				t;
			case _:
				core.Globals.die("", "hl2c.ml");
		}
		block();
		var varMap = new OcamlHashtbl<{s:String, n:Int}, Array<String>>(k -> OcamlHash.hash(OBlock(0, [OString(k.s), OInt(k.n)])),
			(a, b) -> a.s == b.s && a.n == b.n);
		for (i in 0...f.regs.length) {
			var t = f.regs[i];
			if (i <= rid || tEq(t, HVoid)) continue;
			var key = ctypeNoPtr(t);
			var old = varMap.findOpt(key);
			varMap.replace(key, if (old == null) [reg(i)] else [reg(i)].concat(old));
		}
		varMap.iter((k, il) -> {
			var prefix = stars(k.n);
			var il = [for (s in il) prefix + s];
			il.reverse();
			expr('${k.s} ${il.join(", ")}');
		});
		var outputOptions = VectorTools.init(f.code.length + 1, _ -> ([] : Array<OutputOptions>));
		function outputAt(i:Int, oo:OutputOptions) outputOptions[i].unshift(oo);
		function outputAt2(i:Int, ool:Array<OutputOptions>) for (o in ool) outputAt(i, o);
		function hasLabel(i:Int) return core.ds.ArrayTools.exists(outputOptions[i], o -> o == OOLabel);

		var trapDepth = 0;
		var maxTrapDepth = 0;
		for (op in f.code) {
			switch op {
				case OTrap(_):
					trapDepth++;
					if (trapDepth > maxTrapDepth) maxTrapDepth = trapDepth;
				case OEndTrap(true):
					trapDepth--;
				case OStaticClosure(_, fid):
					var ft = gctx.ftable[fid];
					var fn = funname(fid);
					var tv = typeValue(ctx, HFun(ft.feArgs, ft.feRet));
					expr('static vclosure cl$$$clId = { $tv, $fn, 0 }');
					clId++;
				case _:
			}
		}
		for (i in 0...maxTrapDepth) expr('hl_trap_ctx trap$$$i');
		clId = 0;

		function flushOptions(i:Int):Void {
			switch outputOptions[i] {
				case []:
				case opts:
					/* put label after } */
					var opts = if (hasLabel(i) && opts.indexOf(OOEndBlock) >= 0) [OOLabel].concat([for (o in opts) if (o != OOLabel) o]) else opts;
					var opts = opts.copy();
					opts.reverse();
					for (o in opts) {
						switch o {
							case OOLabel: line('${labelName(i)}:');
							case OOCase(i): line('case $i:');
							case OODefault: line("default:");
							case OOBreak: line("break;");
							case OOIncreaseIndent: block();
							case OODecreaseIndent: unblock();
							case OOBeginBlock: line("{");
							case OOEndBlock: line("}");
						}
					}
			}
		}

		for (i in 0...f.code.length) {
			var op = f.code[i];
			flushOptions(i);
			function label(delta:Int):String {
				var addr = delta + i + 1;
				var l = labelName(addr);
				if (!hasLabel(addr)) outputAt(addr, OOLabel);
				return l;
			}
			function todo() expr('hl_fatal("${ostr(id -> "f" + id, op)}")');
			function compareOp(op:Comparison, a:Int, b:Int, d:Int):Void {
				function physCompare() {
					var l = label(d);
					expr('if( ${reg(a)} ${sComp(op)} ${rcast(b, rtype(a))} ) goto $l');
				}
				/*
					safe_cast is already checked
					two ways (same type) for eq
					one way for comparisons
				 */
				var ta = rtype(a);
				var tb = rtype(b);
				switch [getGroup(ta), getGroup(tb), ta, tb] {
					case [GInt | GFloat | GBool, GInt | GFloat | GBool, _, _] | [_, _, HBytes, HBytes] | [_, _, HArray(_), HArray(_)]:
						physCompare();
					case [_, _, HType, HType]:
						var l = label(d);
						expr('if( hl_same_type(${reg(a)},${reg(b)}) ${sComp(op)} 0 ) {} else goto $l');
					case [_, _, HNull(t), HNull(_)]:
						var field = dynValueField(t);
						var pcompare = '(${reg(a)}->$field ${sComp(op)} ${reg(b)}->$field)';
						var l = label(d);
						if (op == CEq) expr('if( ${reg(a)} == ${reg(b)} || (${reg(a)} && ${reg(b)} && $pcompare) ) goto $l') else if (op == CNeq)
							expr('if( ${reg(a)} != ${reg(b)} && (!${reg(a)} || !${reg(b)} || $pcompare) ) goto $l') else
							expr('if( ${reg(a)} && ${reg(b)} && $pcompare ) goto $l');
					case [_, _, HDyn | HFun(_), _] | [_, _, _, HDyn | HFun(_)]:
						var inv = if (op == CGt || op == CGte) "&& i != hl_invalid_comparison " else "";
						var l = label(d);
						expr('{ int i = hl_dyn_compare((vdynamic*)${reg(a)},(vdynamic*)${reg(b)}); if( i ${sComp(op)} 0 $inv) goto $l; }');
					case [_, _, HObj(oa), HObj(_)]:
						var fid = oa.pfunctions.get("__compare");
						if (fid != null) {
							var l = label(d);
							var fn = funname(fid);
							if (op == CEq) expr('if( ${reg(a)} == ${reg(b)} || (${reg(a)} && ${reg(b)} && $fn(${reg(a)},(vdynamic*)${reg(b)}) == 0) ) goto $l') else if (op == CNeq)
								expr('if( ${reg(a)} != ${reg(b)} && (!${reg(a)} || !${reg(b)} || $fn(${reg(a)},(vdynamic*)${reg(b)}) != 0) ) goto $l') else
								expr('if( ${reg(a)} && ${reg(b)} && $fn(${reg(a)},(vdynamic*)${reg(b)}) ${sComp(op)} 0 ) goto $l');
						} else
							physCompare();
					case [_, _, HStruct(_), HStruct(_)]:
						physCompare();
					case [_, _, HVirtual(_), HVirtual(_)]:
						if (op == CEq) {
							var l = label(d);
							expr('if( ${reg(a)} == ${reg(b)} || (${reg(a)} && ${reg(b)} && ${reg(a)}->value && ${reg(b)}->value && ${reg(a)}->value == ${reg(b)}->value) ) goto $l');
						} else if (op == CNeq) {
							var l = label(d);
							expr('if( ${reg(a)} != ${reg(b)} && (!${reg(a)} || !${reg(b)} || !${reg(a)}->value || !${reg(b)}->value || ${reg(a)}->value != ${reg(b)}->value) ) goto $l');
						} else
							core.Globals.die("", "hl2c.ml");
					case [_, _, HEnum(_), HEnum(_)] | [_, _, HDynObj, HDynObj] | [_, _, HAbstract(_), HAbstract(_)]:
						physCompare();
					case [_, _, HVirtual(_), HObj(_)]:
						if (op == CEq) {
							var l = label(d);
							expr('if( ${reg(a)} ? (${reg(b)} && ${reg(a)}->value == (vdynamic*)${reg(b)}) : (${reg(b)} == NULL) ) goto $l');
						} else if (op == CNeq) {
							var l = label(d);
							expr('if( ${reg(a)} ? (${reg(b)} == NULL || ${reg(a)}->value != (vdynamic*)${reg(b)}) : (${reg(b)} != NULL) ) goto $l');
						} else
							core.Globals.die("", "hl2c.ml");
					case [_, _, HObj(_), HVirtual(_)]:
						compareOp(op, b, a, d);
					case _:
						throw new Failure("Don't know how to compare " + tstr(ta) + " and " + tstr(tb) + " (hlc)");
				}
			}
			switch op {
				case OMov(r, v):
					if (!tEq(rtype(r), HVoid)) expr('${reg(r)} = ${rcast(v, rtype(r))}');
				case OInt(r, idx):
					if (code.ints[idx] == 0x80000000) expr('${reg(r)} = 0x80000000') else expr('${reg(r)} = ${code.ints[idx]}');
				case OFloat(r, idx):
					var fstr = core.ds.OcamlPrintf.formatG(19, code.floats[idx]);
					var fstr = (if (fstr.indexOf(".") >= 0 || fstr.indexOf("e") >= 0) fstr else fstr + ".");
					switch rtype(r) {
						case HF32: expr('${reg(r)} = ${fstr}f');
						case _: expr('${reg(r)} = $fstr');
					}
				case OBool(r, b):
					expr('${reg(r)} = ${b ? "true" : "false"}');
				case OBytes(r, idx):
					define('extern vbyte ${gctx.bytesNames[idx]}[];');
					expr('${reg(r)} = ${gctx.bytesNames[idx]}');
				case OString(r, idx):
					expr('${reg(r)} = (vbyte*)${string(gctx, ctx, idx)}');
				case ONull(r):
					expr('${reg(r)} = NULL');
				case OAdd(r, a, b):
					expr('${reg(r)} = ${reg(a)} + ${reg(b)}');
				case OSub(r, a, b):
					expr('${reg(r)} = ${reg(a)} - ${reg(b)}');
				case OMul(r, a, b):
					expr('${reg(r)} = ${reg(a)} * ${reg(b)}');
				case OSDiv(r, a, b):
					switch getGroup(rtype(r)) {
						case GInt:
							expr('${reg(r)} = (${reg(b)} == 0 || ${reg(b)} == -1) ? ${reg(a)} * ${reg(b)} : ${reg(a)} / ${reg(b)}');
						case _:
							expr('${reg(r)} = ${reg(a)} / ${reg(b)}');
					}
				case OUDiv(r, a, b):
					expr('${reg(r)} = ${reg(b)} == 0 ? 0 : ((unsigned)${reg(a)}) / ((unsigned)${reg(b)})');
				case OSMod(r, a, b):
					var rt = rtype(r);
					switch getGroup(rt) {
						case GInt:
							expr('${reg(r)} = (${reg(b)} == 0 || ${reg(b)} == -1) ? 0 : ${reg(a)} % ${reg(b)}');
						case GFloat:
							if (typeSizeBits(rt) <= 2) expr('${reg(r)} = fmodf(${reg(a)},${reg(b)})') else expr('${reg(r)} = fmod(${reg(a)},${reg(b)})');
						case _:
							core.Globals.die("", "hl2c.ml");
					}
				case OUMod(r, a, b):
					expr('${reg(r)} = ${reg(b)} == 0 ? 0 : ((unsigned)${reg(a)}) % ((unsigned)${reg(b)})');
				case OShl(r, a, b):
					var t = rtype(r);
					var size = switch getGroup(t) {
						case GInt: 8 << typeSizeBits(t);
						case _: core.Globals.die("", "hl2c.ml");
					}
					expr('${reg(r)} = ${reg(a)} << (${reg(b)} % $size)');
				case OSShr(r, a, b):
					var t = rtype(r);
					var size = switch getGroup(t) {
						case GInt: 8 << typeSizeBits(t);
						case _: core.Globals.die("", "hl2c.ml");
					}
					expr('${reg(r)} = ${reg(a)} >> (${reg(b)} % $size)');
				case OUShr(r, a, b):
					var t = rtype(r);
					var size = switch getGroup(t) {
						case GInt: 8 << typeSizeBits(t);
						case _: core.Globals.die("", "hl2c.ml");
					}
					var prefix = (switch typeSizeBits(t) {
						case 3: "uint64";
						case _: "unsigned";
					});
					expr('${reg(r)} = (($prefix)${reg(a)}) >> (${reg(b)} % $size)');
				case OAnd(r, a, b):
					expr('${reg(r)} = ${reg(a)} & ${reg(b)}');
				case OOr(r, a, b):
					expr('${reg(r)} = ${reg(a)} | ${reg(b)}');
				case OXor(r, a, b):
					expr('${reg(r)} = ${reg(a)} ^ ${reg(b)}');
				case ONeg(r, v):
					expr('${reg(r)} = -${reg(v)}');
				case ONot(r, v):
					expr('${reg(r)} = !${reg(v)}');
				case OIncr(r):
					expr('++${reg(r)}');
				case ODecr(r):
					expr('--${reg(r)}');
				case OCall0(r, fid):
					ocall(r, fid, []);
				case OCall1(r, fid, a):
					ocall(r, fid, [a]);
				case OCall2(r, fid, a, b):
					ocall(r, fid, [a, b]);
				case OCall3(r, fid, a, b, c):
					ocall(r, fid, [a, b, c]);
				case OCall4(r, fid, a, b, c, d):
					ocall(r, fid, [a, b, c, d]);
				case OCallN(r, fid, rl):
					ocall(r, fid, rl);
				case OCallMethod(r, fid, pl):
					mcall(r, fid, pl);
				case OCallThis(r, fid, pl):
					mcall(r, fid, [0].concat(pl));
				case OCallClosure(r, cl, pl):
					switch rtype(cl) {
						case HDyn:
							dynCall(r, cl, pl);
						case HFun(args, ret):
							var sargs = rcasts(pl, args).join(",");
							expr('${rassign(r, ret)}${reg(cl)}->hasValue ? ${rfun(cl, [HDyn].concat(args), ret)}((vdynamic*)${reg(cl)}->value${if (sargs == "") "" else "," + sargs}) : ${rfun(cl, args, ret)}($sargs)');
						case _:
							core.Globals.die("", "hl2c.ml");
					}
				case OStaticClosure(r, fid):
					expr('${reg(r)} = &cl$$$clId');
					clId++;
				case OInstanceClosure(r, fid, ptr):
					var ft = gctx.ftable[fid];
					var fn = funname(fid);
					var tv = typeValue(ctx, HFun(ft.feArgs, ft.feRet));
					expr('${reg(r)} = hl_alloc_closure_ptr($tv,$fn,${reg(ptr)})');
				case OVirtualClosure(r, o, m):
					switch rtype(o) {
						case HObj(p):
							var ft = gctx.ftable[p.pvirtuals[m]];
							var s = '${reg(o)}->$$type->vobj_proto[$m]';
							expr('${reg(r)} = hl_alloc_closure_ptr(${typeValue(ctx, HFun(ft.feArgs, ft.feRet))},$s,${reg(o)})');
						case _:
							todo();
					}
				case OGetGlobal(r, g):
					defineGlobal(gctx, ctx, g);
					expr('${reg(r)} = (${ctype(rtype(r))})${gctx.gnames[g]}');
				case OSetGlobal(g, r):
					defineGlobal(gctx, ctx, g);
					expr('${gctx.gnames[g]} = (${ctype(code.globals[g])})${reg(r)}');
				case ORet(r):
					if (tEq(rtype(r), HVoid)) expr("return") else expr('return ${rcast(r, fret)}');
				case OJTrue(r, d) | OJNotNull(r, d):
					expr('if( ${reg(r)} ) goto ${label(d)}');
				case OJFalse(r, d) | OJNull(r, d):
					expr('if( !${reg(r)} ) goto ${label(d)}');
				case OJSLt(a, b, d):
					compareOp(CLt, a, b, d);
				case OJSGte(a, b, d):
					compareOp(CGte, a, b, d);
				case OJSGt(a, b, d):
					compareOp(CGt, a, b, d);
				case OJSLte(a, b, d):
					compareOp(CLte, a, b, d);
				case OJULt(a, b, d):
					expr('if( ((unsigned)${reg(a)}) < ((unsigned)${reg(b)}) ) goto ${label(d)}');
				case OJUGte(a, b, d):
					expr('if( ((unsigned)${reg(a)}) >= ((unsigned)${reg(b)}) ) goto ${label(d)}');
				case OJNotLt(a, b, d):
					expr('if( !(${reg(a)} < ${reg(b)}) ) goto ${label(d)}');
				case OJNotGte(a, b, d):
					expr('if( !(${reg(a)} >= ${reg(b)}) ) goto ${label(d)}');
				case OJEq(a, b, d):
					compareOp(CEq, a, b, d);
				case OJNotEq(a, b, d):
					compareOp(CNeq, a, b, d);
				case OJAlways(d):
					expr('goto ${label(d)}');
				case OLabel(_):
					if (!hasLabel(i)) line('${label(-1)}:');
				case OToDyn(r, v) if (tEq(rtype(v), HBool)):
					expr('${reg(r)} = hl_alloc_dynbool(${reg(v)})');
				case OToDyn(r, v):
					if (isPtr(rtype(v))) {
						line('if( ${reg(v)} == NULL ) ${reg(r)} = NULL; else {');
						block();
					}
					expr('${reg(r)} = hl_alloc_dynamic(${typeValue(ctx, rtype(v))})');
					expr('${reg(r)}->${dynValueField(rtype(v))} = ${reg(v)}');
					if (isPtr(rtype(v))) {
						unblock();
						line("}");
					}
				case OToSFloat(r, v):
					expr('${reg(r)} = (${ctype(rtype(r))})${reg(v)}');
				case OToUFloat(r, v):
					expr('${reg(r)} = (${ctype(rtype(r))})(unsigned)${reg(v)}');
				case OToInt(r, v):
					var rt = rtype(r);
					if (typeSizeBits(rt) <= 2) expr('${reg(r)} = (int)${reg(v)}') else expr('${reg(r)} = (int64)${reg(v)}');
				case ONew(r):
					switch rtype(r) {
						case HObj(o) | HStruct(o): expr('${reg(r)} = (${tname(o.pname)})hl_alloc_obj(${typeValue(ctx, rtype(r))})');
						case HDynObj: expr('${reg(r)} = hl_alloc_dynobj()');
						case t = HVirtual(_): expr('${reg(r)} = hl_alloc_virtual(${typeValue(ctx, t)})');
						case _: core.Globals.die("", "hl2c.ml");
					}
				case OField(r, obj, fid):
					getField(r, obj, fid);
				case OSetField(obj, fid, v):
					setField(obj, fid, v);
				case OGetThis(r, fid):
					getField(r, 0, fid);
				case OSetThis(fid, r):
					setField(0, fid, r);
				case OThrow(r):
					expr('hl_throw((vdynamic*)${reg(r)})');
				case ORethrow(r):
					expr('hl_rethrow((vdynamic*)${reg(r)})');
				case OGetUI8(r, b, idx):
					expr('${reg(r)} = *(unsigned char*)(${reg(b)} + ${reg(idx)})');
				case OGetUI16(r, b, idx):
					expr('{ unsigned short _v; memcpy(&_v, ${reg(b)} + ${reg(idx)}, sizeof(_v)); ${reg(r)} = _v; }');
				case OGetMem(r, b, idx):
					expr('memcpy(&${reg(r)}, ${reg(b)} + ${reg(idx)}, sizeof(${reg(r)}))');
				case OGetArray(r, arr, idx):
					switch rtype(arr) {
						case HAbstract(_):
							switch rtype(r) {
								case HStruct(_) | HObj(_):
									expr('${reg(r)} = ((${ctype(rtype(r))})${reg(arr)}) + ${reg(idx)}');
								case _:
									expr('${reg(r)} = ((${ctype(rtype(r))}*)${reg(arr)})[${reg(idx)}]');
							}
						case _:
							expr('${reg(r)} = ((${ctype(rtype(r))}*)(${reg(arr)} + 1))[${reg(idx)}]');
					}
				case OSetUI8(b, idx, r):
					expr('*(unsigned char*)(${reg(b)} + ${reg(idx)}) = (unsigned char)${reg(r)}');
				case OSetUI16(b, idx, r):
					expr('{ unsigned short _v = (unsigned short)${reg(r)}; memcpy(${reg(b)} + ${reg(idx)}, &_v, sizeof(_v)); }');
				case OSetMem(b, idx, r):
					expr('memcpy(${reg(b)} + ${reg(idx)}, &${reg(r)}, sizeof(${reg(r)}))');
				case OSetArray(arr, idx, v):
					switch rtype(arr) {
						case HAbstract(_):
							expr('((${ctype(rtype(v))})${reg(arr)})[${reg(idx)}] = *${reg(v)}');
						case _:
							expr('((${ctype(rtype(v))}*)(${reg(arr)} + 1))[${reg(idx)}] = ${reg(v)}');
					}
				case OSafeCast(r, v):
					var tsrc = rtype(v);
					var t = rtype(r);
					if (tEq(tsrc, HNull(t))) expr('${reg(r)} = ${reg(v)} ? ${reg(v)}->${dynValueField(t)} : 0') else {
						var tvo = typeValueOpt(t);
						var tv = typeValue(ctx, rtype(v));
						expr('${reg(r)} = (${ctype(t)})hl_dyn_cast${dynPrefix(t)}(&${reg(v)},$tv$tvo)');
					}
				case OUnsafeCast(r, v):
					expr('${reg(r)} = (${ctype(rtype(r))})${reg(v)}');
				case OArraySize(r, a):
					expr('${reg(r)} = ${reg(a)}->size');
				case OType(r, t):
					expr('${reg(r)} = ${typeValue(ctx, t)}');
				case OGetType(r, v):
					expr('${reg(r)} = ${reg(v)} ? ((vdynamic*)${reg(v)})->t : &hlt_void');
				case OGetTID(r, v):
					expr('${reg(r)} = ${reg(v)}->kind');
				case ORef(r, v):
					expr('${reg(r)} = &${reg(v)}');
				case OUnref(r, v):
					expr('${reg(r)} = *${reg(v)}');
				case OSetref(r, v):
					expr('*${reg(r)} = ${reg(v)}');
				case OToVirtual(r, v):
					expr('${reg(r)} = hl_to_virtual(${typeValue(ctx, rtype(r))},(vdynamic*)${reg(v)})');
				case ODynGet(r, o, sid):
					var t = rtype(r);
					var h = hash(gctx, sid);
					expr('${reg(r)} = (${ctype(t)})hl_dyn_get${dynPrefix(t)}((vdynamic*)${reg(o)},$h/*${code.strings[sid]}*/${typeValueOpt(t)})');
				case ODynSet(o, sid, v):
					var h = hash(gctx, sid);
					expr('hl_dyn_set${dynPrefix(rtype(v))}((vdynamic*)${reg(o)},$h/*${code.strings[sid]}*/${typeValueOpt(rtype(v))},${reg(v)})');
				case OMakeEnum(r, cid, rl):
					var e, et;
					switch rtype(r) {
						case HEnum(e1):
							et = enumConstrType(gctx, ctx, e1, cid);
							e = e1;
						case _:
							et = null;
							e = core.Globals.die("", "hl2c.ml");
					}
					var needTmp = rl.indexOf(r) >= 0;
					var tmp = if (!needTmp) reg(r) else {
						expr("{ venum *tmp");
						"tmp";
					}
					expr('$tmp = hl_alloc_enum(${typeValue(ctx, rtype(r))},$cid)');
					var tl = e.efields[cid].args;
					for (i in 0...rl.length) expr('(($et*)$tmp)->p$i = ${rcast(rl[i], tl[i])}');
					if (needTmp) expr('${reg(r)} = tmp; }');
				case OEnumAlloc(r, cid):
					expr('${reg(r)} = hl_alloc_enum(${typeValue(ctx, rtype(r))},$cid)');
				case OEnumIndex(r, v):
					expr('${reg(r)} = HL__ENUM_INDEX__(${reg(v)})');
				case OEnumField(r, e, cid, pid):
					var tn, tl;
					switch rtype(e) {
						case HEnum(e):
							tn = enumConstrType(gctx, ctx, e, cid);
							tl = e.efields[cid].args;
						case _:
							tn = core.Globals.die("", "hl2c.ml");
							tl = null;
					}
					expr('${rassign(r, tl[pid])}(($tn*)${reg(e)})->p$pid');
				case OSetEnumField(e, pid, r):
					var tn, tl;
					switch rtype(e) {
						case HEnum(e):
							tn = enumConstrType(gctx, ctx, e, 0);
							tl = e.efields[0].args;
						case _:
							tn = core.Globals.die("", "hl2c.ml");
							tl = null;
					}
					expr('(($tn*)${reg(e)})->p$pid = (${ctype(tl[pid])})${reg(r)}');
				case OSwitch(r, idx, eend):
					line('switch(${reg(r)}) {');
					block();
					var pend = i + 1 + eend;
					/* insert at end if we have another switch case here */
					var old = outputOptions[pend];
					outputOptions[pend] = [];
					/* insert cases */
					outputAt2(i + 1, [OODefault, OOIncreaseIndent]);
					for (k in 0...idx.length) {
						var delta = idx[k];
						outputAt2(delta + i + 1, [OODecreaseIndent, OOCase(k), OOIncreaseIndent]);
						if (delta == eend) outputAt(pend, OOBreak);
					}
					/* insert end switch */
					var rold = old.copy();
					rold.reverse();
					outputAt2(pend, [OODecreaseIndent, OODecreaseIndent, OOEndBlock].concat(rold));
				case ONullCheck(r):
					expr('if( ${reg(r)} == NULL ) hl_null_access()');
				case OTrap(r, d):
					var l = label(d);
					expr('hl_trap(trap$$$trapDepth,${reg(r)},$l)');
					trapDepth++;
				case OEndTrap(b):
					expr('hl_endtrap(trap$$${trapDepth - 1})');
					if (b) trapDepth--;
				case OAssert(_):
					expr("hl_assert()");
				case ORefData(r, d):
					switch rtype(d) {
						case HArray(_):
							expr('${reg(r)} = (${ctype(rtype(r))})hl_aptr(${reg(d)},void*)');
						case _:
							core.Globals.die("", "hl2c.ml");
					}
				case ORefOffset(r, r2, off):
					expr('${reg(r)} = ${reg(r2)} + ${reg(off)}');
				case ONop(_):
				case OPrefetch(r, fid, mode):
					var e = (if (fid == 0) reg(r) else (switch rtype(r) {
						case HObj(o) | HStruct(o):
							var nt = resolveField(o, fid - 1);
							'&${reg(r)}->${nt.name}';
						case _:
							core.Globals.die("", "hl2c.ml");
					}));
					expr('__hl_prefetch_m$mode($e)');
				case OAsm(_):
					expr("UNSUPPORTED ASM OPCODE");
				case OCatch(_):
			}
		}
		flushOptions(f.code.length);
		unblock();
		line("}");
		line("");
	}

	// port: Str.global_replace (Str.regexp "[^A-Za-z0-9_]+") "_"
	static function validIdent(str:String):String {
		var buf = new StringBuf();
		var inRun = false;
		for (i in 0...str.length) {
			var c = StringTools.fastCodeAt(str, i);
			var ok = (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;
			if (ok) {
				buf.addChar(c);
				inRun = false;
			} else if (!inRun) {
				buf.add("_");
				inRun = true;
			}
		}
		return buf.toString();
	}

	static function nativeName(str:String):String return if (str.charAt(0) == "?") str.substr(1) else str;

	static function makeTypesIdents(htypes:TtypeMap<Int>):TtypeMap<String> {
		var typesDescs = new TtypeMap<TypeDesc>(); // port: keyed by HVirtual vp (structural, as the vp PMap)
		function makeDesc(t:Ttype):TypeDesc {
			return switch t {
				case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HBytes | HDyn | HArray(_) | HType | HRef(_) | HDynObj | HNull(_) | HGUID:
					DSimple(t);
				case HFun(tl, t):
					var args = [for (x in tl) makeDesc(x)];
					DFun(args, makeDesc(t), true);
				case HMethod(tl, t):
					var args = [for (x in tl) makeDesc(x)];
					DFun(args, makeDesc(t), false);
				case HObj(p) | HStruct(p):
					DNamed(p.pname, p);
				case HPacked(t):
					switch makeDesc(t) {
						case DNamed(n, _): DNamed("packed_" + n, null);
						case _: core.Globals.die("", "hl2c.ml");
					}
				case HAbstract(n, _, ident):
					DNamed(n, ident);
				case HEnum(e) if (e.ename == ""):
					var tl = e.efields[0].args;
					DContext(tl.map(x -> makeDesc(x)));
				case HEnum(e):
					DNamed(e.ename, e);
				case HVirtual(vp):
					var d = typesDescs.get(t);
					if (d != null) return d;
					var arr = new Vector(vp.vfields.length, new VDescField("", null, DSimple(HVoid)));
					var td = DVirtual(arr);
					typesDescs.set(t, td);
					for (i in 0...vp.vfields.length) {
						var f = vp.vfields[i];
						arr[i] = new VDescField(f.name, if (core.ds.StrTools.hasIdentity) f.name else f, makeDesc(f.t));
					}
					td;
			}
		}
		var hashes = new StringMap<Bool>();
		function makeSign(d:TypeDesc):String {
			var m = new OcamlExtern();
			m.desc(d);
			var dig = md5hex(m.getBytes());
			var h = dig.substr(0, 7);
			var h = if (hashes.exists(h)) dig else h;
			hashes.set(h, true);
			return h;
		}
		function descString(d:TypeDesc):String {
			return switch d {
				case DSimple(HNull(t)):
					"t$nul_" + tstr(t);
				case DSimple(HRef(t)):
					"t$ref_" + (switch makeDesc(t) {
						case DSimple(_): tstr(t);
						case d: descString(d);
					});
				case DSimple(HArray(t)):
					"t$array_" + (descString(makeDesc(t)));
				case DSimple(t):
					"t$_" + tstr(t);
				case DFun(_):
					"t$fun_" + makeSign(d);
				case DNamed(n, _):
					"t$" + nsplit(n, ".").join("_");
				case DVirtual(_):
					"t$vrt_" + (makeSign(d));
				case DContext(_):
					"t$ctx_" + makeSign(d);
			}
		}
		// port: extlib's PMap.mapi visits the tree in post-order (`let l = loop l in
		// let r = loop r in Node (l, k, f k v, r, h)`), which make_sign's
		// first-come short names reflect; the tree is the one gather_types built
		// by PMap.add, with the keys in their insertion order.
		var tree:Null<PMapNode<Ttype>> = null;
		for (t in htypes.keys) tree = PMapNode.add(tCompare, t, tree);
		var out = new TtypeMap<String>();
		function loop(n:Null<PMapNode<Ttype>>) {
			if (n == null) return;
			loop(n.l);
			loop(n.r);
			out.set(n.k, descString(makeDesc(n.k)));
		}
		loop(tree);
		return out;
	}

	static function makeGlobalNames(code:Code, gnames:Vector<String>):Vector<String> {
		var hstrings = new StringMap<Bool>();
		var isCstr = new IntMap<Bool>();
		for (c in code.constants) {
			switch code.globals[c.g] {
				case HObj({pname: "String"}):
					var str = code.strings[c.fields[0]];
					var v = validIdent(str);
					hstrings.set(v, hstrings.exists(v));
					isCstr.set(c.g, true);
					gnames[c.g] = str;
				case _:
			}
		}
		var gids = [for (i in 0...gnames.length) {n: gnames[i], g: i}];
		ocamlArraySort((a:{n:String, g:Int}, b:{n:String, g:Int}) -> {
			var d = strCompare(a.n, b.n);
			if (d == 0) a.g < b.g ? -1 : (a.g > b.g ? 1 : 0) else d;
		}, gids);
		var gnamesUsed = new StringMap<Bool>();
		var gnames2 = new IntMap<String>();
		for (e in gids) {
			var str = e.n, g = e.g;
			var id = (if (isCstr.exists(g)) "s$" else "g$") + (if (utf8Length(str) > 32) shortDigest(str) else {
				var i = validIdent(str);
				if (i == "_" || hstrings.get(i) == true) shortDigest(str) else i;
			});
			var k = 0;
			var rid = id;
			while (gnamesUsed.exists(rid)) {
				k++;
				rid = id + "_" + k;
			}
			gnamesUsed.set(rid, true);
			gnames2.set(g, rid);
		}
		return VectorTools.init(code.globals.length, i -> gnames2.get(i));
	}

	static function makeFunctionTable(code:Code):Vector<FunctionEntry> {
		var ftable = VectorTools.init(code.functions.length + code.natives.length, i -> new FunctionEntry(i));
		for (n in code.natives) {
			var fname = {
				var lib = code.strings[n.lib];
				var lib = if (lib.charAt(0) == "?") lib.substr(1) else lib;
				var lib = if (lib == "std") "hl" else lib;
				var str = lib + "_" + code.strings[n.name];
				/* create wrappers defines for invalid definitions */
				if (str == "hl_tls_get") str + "_w" else str;
			}
			switch n.t {
				case HFun(args, t):
					var ft = ftable[n.findex];
					ft.feName = fname;
					ft.feArgs = args;
					ft.feRet = t;
				case _:
					core.Globals.die("", "hl2c.ml");
			}
		}
		for (f in code.functions) {
			var fname = nsplit(fundeclName(f), ".").join("_");
			var ft = ftable[f.findex];
			ft.feName = fname;
			switch f.ftype {
				case HFun(args, t):
					ft.feArgs = args;
					ft.feRet = t;
				case _:
					core.Globals.die("", "hl2c.ml");
			}
			ft.feDecl = f;
			for (op in f.code) {
				switch op {
					case OCall0(_, fid) | OCall1(_, fid, _) | OCall2(_, fid, _, _) | OCall3(_, fid, _, _, _) | OCall4(_, fid, _, _, _, _) | OCallN(_, fid, _) |
						OStaticClosure(_, fid) | OInstanceClosure(_, fid, _):
						var ft2 = ftable[fid];
						if (ft2.feCalledBy.indexOf(ft) < 0) {
							ft2.feCalledBy.unshift(ft);
							ft.feCalling.unshift(ft2);
						}
					case _:
				}
			}
		}
		return ftable;
	}

	static function makeModules(ctx:GlobalContext, allTypes:Vector<Ttype>):Array<CodeModule> {
		var modules = new StringMap<CodeModule>();
		var allModules:Array<CodeModule> = []; // port: list, head first
		function getModule(name:String):CodeModule {
			var m = modules.get(name);
			if (m != null) return m;
			var m = new CodeModule(name);
			modules.set(name, m);
			allModules.unshift(m);
			return m;
		}
		function add(m:CodeModule, fid:Int):Void {
			var f = ctx.ftable[fid];
			if (f.feModule != null) core.Globals.die("", "hl2c.ml");
			f.feModule = m;
			m.mFunctions.unshift(f);
		}
		function addType(m:CodeModule, t:Ttype):Void {
			m.mTypes.unshift(t);
			ctx.typeModule.set(t, m);
		}
		function mkName(path:String):String {
			var parts = nsplit(path, ".");
			var baseName, path;
			if (parts.length == 0) {
				baseName = "enums";
				path = ["hl"];
			} else {
				var name = parts[parts.length - 1];
				baseName = if (name.charAt(0) == "$") name.substr(1) else name;
				path = parts.slice(0, parts.length - 1);
			}
			var path = path.concat([baseName]);
			var path = [for (n in path) if (utf8Length(n) > 128) md5hex(haxe.io.Bytes.ofString(n)) else n];
			var path = if (path.length == 1) ["_std", path[0]] else path;
			return path.join("/");
		}
		var allContexts:Array<Ttype> = []; // port: list, head first
		for (t in allTypes) {
			switch t {
				case HObj(o) | HStruct(o):
					var m = getModule(mkName(o.pname));
					for (p in o.pproto) add(m, p.fmethod);
					for (b in o.pbindings) add(m, b.fidx);
					addType(m, t);
				case HEnum(e) if (e.ename == ""):
					allContexts.unshift(t);
				case HEnum(e):
					var m = getModule(mkName(e.ename));
					addType(m, t);
				case _:
			}
		}
		var ep = ctx.hlcode.entrypoint;
		if (ep >= 0) {
			var m = getModule("hl/init");
			add(m, ep);
			ctx.ftable[ep].feName = "fun$init";
		}
		for (m in allModules.copy()) {
			function getDeps(acc:Array<FunctionEntry>, l:Array<FunctionEntry>, i:Int):Array<FunctionEntry> {
				if (i == l.length) return acc;
				var fm = l[i];
				var counter = 1;
				var loop:(Array<FunctionEntry>, Array<FunctionEntry>, Int) -> Array<FunctionEntry> = null;
				function append(f:FunctionEntry, acc:Array<FunctionEntry>):Array<FunctionEntry> {
					var calling = f.feCalling.copy();
					calling.reverse();
					return loop([f].concat(acc), calling, 0);
				}
				loop = function(acc, l, i) {
					while (i < l.length) {
						var f = l[i];
						if (f.feModule == null && f.feCalledBy.length == 1 && f.feDecl != null) {
							f.feName = fm.feName + "__$" + counter;
							counter++;
							f.feModule = m;
							acc = append(f, acc);
						}
						i++;
					}
					return acc;
				}
				return getDeps(append(fm, acc), l, i + 1);
			}
			m.mFunctions = getDeps([], m.mFunctions, 0);
		}
		var contexts = new TtypeMap<{m:Null<CodeModule>}>();
		for (f in ctx.ftable) {
			if (f.feModule == null && StringTools.startsWith(f.feName, "fun$"))
				f.feName = "wrap" + typeName(ctx, if (f.feDecl == null) core.Globals.die("", "hl2c.ml") else f.feDecl.ftype);
			/* assign context to function module */
			if (f.feArgs.length > 0) switch f.feArgs[0] {
				case t = HEnum(e) if (e.ename == ""):
					var r = contexts.get(t);
					if (r != null) {
						if (r.m == null) {} else if (f.feModule != null && r.m == f.feModule) {} else contexts.set(t, {m: null}); /* multiple contexts */
					} else
						contexts.set(t, {m: f.feModule});
				case _:
			}
		}
		var ctxs = allContexts.copy();
		ctxs.reverse();
		for (t in ctxs) {
			var r = contexts.get(t);
			var m = if (r == null) null else r.m;
			var m = if (m == null) {
				var tname = ctx.htypes.get(t);
				if (tname == null) throw core.ds.NotFound.raise();
				getModule("hl/ctx/" + haxe.io.Bytes.ofString(tname).sub(8, utf8Length(tname) - 8).toString());
			} else m;
			addType(m, t);
		}
		return allModules;
	}

	static function generateModuleTypes(gctx:GlobalContext, ctx:FileContext, m:CodeModule):Void {
		var defName = "INC_" + nsplit(m.mName, "/").join("__");
		function line(s:String) linec(ctx, s);
		function expr(s:String) exprc(ctx, s);
		function typeName(t:Ttype):String {
			return switch t {
				case HObj(o) | HStruct(o): o.pname;
				case HEnum(e): e.ename;
				case _: "";
			}
		}
		var types = listSort((t1:Ttype, t2:Ttype) -> strCompare(typeName(t1), typeName(t2)), m.mTypes);
		define(ctx, '#ifndef $defName');
		define(ctx, '#define $defName');
		for (t in types) {
			switch t {
				case HObj(o) | HStruct(o):
					var name = tname(o.pname);
					var tdName = tname("_" + o.pname);
					ctx.definedTypes.set(t, true);
					define(ctx, 'typedef struct $tdName *$name;');
				case _:
			}
		}
		line("");
		for (t in types) {
			switch t {
				case HObj(op) | HStruct(op):
					var name = tname("_" + op.pname);
					line("struct " + name + " {");
					block(ctx);
					function loop(o:ClassProto):Void {
						switch o.psuper {
							case null:
								if (!isStruct(t)) expr("hl_type *$type");
							case c:
								defineType(gctx, ctx, if (isStruct(t)) HStruct(c) else HObj(c));
								loop(c);
						}
						for (i in 0...o.pfields.length) {
							var f = o.pfields[i];
							function absIndex(p:Null<ClassProto>, v:Int):Int return if (p == null) v else absIndex(p.psuper, p.pfields.length + v);
							defineType(gctx, ctx, f.t);
							expr(varType(if (f.name == "") unamedField(absIndex(o.psuper, i)) else f.name, f.t));
						}
					}
					loop(op);
					unblock(ctx);
					expr("}");
				case HEnum(e):
					for (i in 0...e.efields.length) {
						var pl = e.efields[i].args;
						if (pl.length != 0) {
							line("typedef struct {");
							block(ctx);
							line("HL__ENUM_CONSTRUCT__");
							for (j in 0...pl.length) {
								defineType(gctx, ctx, pl[j]);
								expr(varType("p" + j, pl[j]));
							}
							unblock(ctx);
							expr('} ${enumConstrType(gctx, ctx, e, i)}');
						}
					}
				case _:
			}
		}
		line("#endif");
		line("");
	}

	public static function writeC(com:Gctx, file:String, code:Code, gnames:Vector<String>, numDomains:Int):Void {
		var gt = gatherTypes(code);
		var allTypes = gt.all, htypes = gt.types;
		var typesIds = makeTypesIdents(htypes);
		var gnames = makeGlobalNames(code, gnames);
		var bnames = code.bytes.map(b -> "bytes$" + shortDigest(md5hex(b)));
		var gctx = new GlobalContext();
		gctx.version = com.version.version;
		gctx.hlcode = code;
		gctx.dir = switch core.OcamlFilename.dirname(file) {
			case "": ".";
			case dir: dir.split("\\").join("/");
		}
		gctx.ftable = makeFunctionTable(code);
		gctx.htypes = typesIds;
		gctx.gnames = gnames;
		gctx.bytesNames = bnames;
		gctx.gcon = com;
		var modules = makeModules(gctx, allTypes);
		var nativeLibs = new OcamlHashtbl<String, Bool>(OcamlHash.hashString, (a, b) -> a == b);

		core.Path.mkdirRecursive("", nsplit(gctx.dir + "/hl", "/"));

		{
			var ctx = openFile(gctx, "hl/natives.h");
			function line(s:String) linec(ctx, s);
			define(ctx, "#ifndef HL_NATIVES_H");
			define(ctx, "#define HL_NATIVES_H");
			define(ctx, "// Abstract decls");
			var abstracts = [
				for (t in allTypes) switch t {
					case HAbstract("hl_tls" | "hl_mutex" | "hl_thread", _, _): continue; /* ignore / defined in hl.h already */
					case HAbstract(name, _, _): name;
					case _: continue;
				}
			];
			var abstracts = listSort(strCompare, abstracts);
			for (name in abstracts) define(ctx, 'typedef struct _$name $name;');
			define(ctx, "");
			line("// Natives functions");
			var sortedNatives:Vector<Native> = code.natives.copy();
			ocamlVectorSort((n1:Native, n2:Native) -> {
				var c = strCompare(code.strings[n1.lib], code.strings[n2.lib]);
				if (c != 0) c else strCompare(code.strings[n1.name], code.strings[n2.name]);
			}, sortedNatives);
			for (n in sortedNatives) {
				var name = code.strings[n.lib];
				var name = if (name.charAt(0) == "?") name.substr(1) else name;
				nativeLibs.replace(name, true);
				var ft = gctx.ftable[n.findex];
				defineType(gctx, ctx, HFun(ft.feArgs, ft.feRet));
				switch ft.feName {
					case "hl_tls_get_w":
						define(ctx, "#define hl_tls_get_w(tls) ((vdynamic*)hl_tls_get(tls))");
					case "hl_tls_set":
						/* don't redefine */
					case _:
						exprc(ctx, 'HL_API ${ctype(ft.feRet)} ${ft.feName}(${argsRepr(ft.feArgs)})');
				}
			}
			line("#endif");
			line("");
			closeFile(ctx);
		}

		{
			var ctx = openFile(gctx, "hl/globals.c");
			function line(s:String) linec(ctx, s);
			function expr(s:String) exprc(ctx, s);
			define(ctx, "#define HLC_BOOT");
			define(ctx, "#include <hlc.h>");
			line("// Globals");
			for (i in 0...code.globals.length) {
				var t = code.globals[i];
				var name = gnames[i];
				defineType(gctx, ctx, t);
				expr('${varType(name, t)} = 0');
			}
			for (c in code.constants) {
				var t = code.globals[c.g];
				var name = "const_" + gnames[c.g];
				function fieldValue(t:Ttype, idx:Int):String {
					return switch t {
						case HI32:
							Std.string(code.ints[idx]);
						case HBytes:
							"(vbyte*)" + string(gctx, ctx, idx);
						case _:
							core.Globals.die("", "hl2c.ml");
					}
				}
				var fields = switch t {
					case HObj(o) | HStruct(o):
						if (o.pfields.length != c.fields.length) throw new core.ds.InvalidArgument("List.map2");
						var fields = [for (i in 0...o.pfields.length) fieldValue(o.pfields[i].t, c.fields[i])];
						if (isStruct(t)) fields else [typeValue(gctx, ctx, t)].concat(fields);
					case _:
						core.Globals.die("", "hl2c.ml");
				}
				expr('static struct _${ctype(t)} $name = {${fields.join(",")}}');
			}
			line("");
			line("void hl_init_roots_constants() {");
			block(ctx);
			var isConst = new IntMap<Bool>();
			for (c in code.constants) {
				expr('${gnames[c.g]} = &const_${gnames[c.g]}');
				isConst.set(c.g, true);
			}
			unblock(ctx);
			line("}");
			line("void hl_init_roots_globals() {");
			block(ctx);
			for (i in 0...code.globals.length) if (isPtr(code.globals[i]) && !isConst.exists(i)) expr('hl_add_root((void**)&${gnames[i]})');
			unblock(ctx);
			line("}");
			line("void hl_init_roots() {");
			block(ctx);
			expr("hl_init_roots_constants()");
			expr("hl_init_roots_globals()");
			unblock(ctx);
			line("}");

			// port: the string holds one byte per char (bytes > 0x7F are not UTF-8 encoded)
			function outputBytes(f:String->Void, str:String) {
				for (i in 0...str.length) {
					if ((i + 1) % 0x80 == 0) f("\\\n\t");
					if (i > 0) f(",");
					f(Std.string(StringTools.fastCodeAt(str, i)));
				}
			}
			for (i in 0...code.strings.length) {
				var str = code.strings[i];
				var b = haxe.io.Bytes.ofString(str);
				if (b.length >= stringDataLimit) {
					var s = core.StringHelper.utf8ToUtf16(str, true);
					var sub = b.sub(0, stringDataLimit - 4);
					line('// ${ocamlEscapedBytes(sub)}...');
					output(ctx, 'vbyte string$$${shortDigest(str)}[] = {');
					outputBytes(s -> output(ctx, s), s);
					expr("}");
				}
			}
			for (i in 0...code.bytes.length) {
				var bytes = code.bytes[i];
				var bstr = bytesToLatin1(bytes);
				if (bytes.length > 1000) {
					var bytesFile = "hl/bytes_" + md5hex(bytes) + ".h";
					var absFile = ctx.dir + "/" + bytesFile;
					if (!sys.FileSystem.exists(absFile)) {
						var buf = new StringBuf();
						outputBytes(s -> buf.add(s), bstr);
						sys.io.File.saveContent(absFile, buf.toString());
					}
					line('vbyte ${gctx.bytesNames[i]}[] = {');
					output(ctx, '#${ctx.tabs}  include "$bytesFile"\n');
					expr("}");
				} else {
					output(ctx, 'vbyte ${gctx.bytesNames[i]}[] = {');
					outputBytes(s -> output(ctx, s), bstr);
					expr("}");
				}
			}
			closeFile(ctx);
			saveCfile(gctx, ctx.curfile);
		}

		{
			var ctx = openFile(gctx, "hl/types.c");
			function line(s:String) linec(ctx, s);
			function expr(s:String) exprc(ctx, s);
			function typeValue(ctx:GlobalContext, t:Ttype) return "&" + typeName(ctx, t); /* no auto import */
			define(ctx, "#define HLC_BOOT");
			define(ctx, "#include <hlc.h>");
			line("// Types values");
			for (t in allTypes) {
				switch t {
					case HMethod(_) | HFun(_) | HVirtual(_):
						expr('hl_type ${typeName(gctx, t)} = { ${typeId(t)} } /* ${tstr(t)} */');
					case _:
						expr('hl_type ${typeName(gctx, t)} = { ${typeId(t)} }');
				}
			}

			line("");
			line("// Types values data");
			for (t in allTypes) {
				function fieldValue(f:HField):String {
					var s = string(gctx, ctx, f.nid);
					return '{(const uchar*)$s, ${typeValue(gctx, f.t)}, ${hash(gctx, f.nid)}}';
				}
				switch t {
					case HObj(o) | HStruct(o):
						var name = typeName(gctx, t);
						function protoValue(p:FieldProto):String {
							var h = hash(gctx, p.fid);
							var s = string(gctx, ctx, p.fid);
							return '{(const uchar*)$s, ${p.fmethod}, ${p.fvirtual == null ? -1 : p.fvirtual}, $h}';
						}
						var fields = if (o.pfields.length == 0) "NULL" else {
							var name = 'fields$name';
							expr('static hl_obj_field $name[] = {${[for (f in o.pfields) fieldValue(f)].join(",")}}');
							name;
						}
						var proto = if (o.pproto.length == 0) "NULL" else {
							var name = 'proto$name';
							expr('static hl_obj_proto $name[] = {${[for (p in o.pproto) protoValue(p)].join(",")}}');
							name;
						}
						var bindings = if (o.pbindings.length == 0) "NULL" else {
							var name = 'bindings$name';
							expr('static int $name[] = {${[for (b in o.pbindings) b.fid + "," + b.fidx].join(",")}}');
							name;
						}
						var sup = switch o.psuper {
							case null: "NULL";
							case c: typeValue(gctx, switch t {
									case HObj(_): HObj(c);
									case _: HStruct(c);
								});
						}
						var ofields = [
							Std.string(o.pfields.length),
							Std.string(o.pproto.length),
							Std.string(o.pbindings.length),
							'(const uchar*)${string(gctx, ctx, o.pid)}',
							sup,
							fields,
							proto,
							bindings
						];
						expr('static hl_type_obj obj$name = {${ofields.join(",")}}');
					case HEnum(e):
						var ename = typeName(gctx, t);
						function constrValue(cid:Int, f:EField):String {
							var tl = f.args;
							var tval = if (tl.length == 0) "NULL" else {
								var name = 'econstruct${ename}_$cid';
								expr('static hl_type *$name[] = {${[for (t in tl) typeValue(gctx, t)].join(",")}}');
								name;
							}
							var size = if (tl.length == 0) "0" else 'sizeof(${enumConstrType(gctx, ctx, e, cid)})';
							var offsets = if (tl.length == 0) "NULL" else {
								var name = 'eoffsets${ename}_$cid';
								expr('static int $name[] = {${[for (_ in tl) "0"].join(",")}}');
								name;
							}
							var hasPtr = core.ds.ArrayTools.exists(tl, isGcPtr);
							return '{(const uchar*)${string(gctx, ctx, f.nid)}, ${tl.length}, $tval, $size, ${if (hasPtr) "true" else "false"}, $offsets}';
						}
						var constrName = if (e.efields.length == 0) "NULL" else {
							var name = 'econstruct$ename';
							var cv = [for (i in 0...e.efields.length) constrValue(i, e.efields[i])];
							expr('static hl_enum_construct $name[] = {${cv.join(",")}}');
							name;
						}
						var efields = [
							if (e.eid == 0) "NULL" else '(const uchar*)${string(gctx, ctx, e.eid)}',
							Std.string(e.efields.length),
							constrName
						];
						expr('static hl_type_enum enum$ename = {${efields.join(",")}}');
					case HVirtual(v):
						var vname = typeName(gctx, t);
						var fieldsName = if (v.vfields.length == 0) "NULL" else {
							var name = 'vfields$vname';
							expr('static hl_obj_field $name[] = {${[for (f in v.vfields) fieldValue(f)].join(",")}}');
							name;
						}
						var vfields = [fieldsName, Std.string(v.vfields.length)];
						expr('static hl_type_virtual virt$vname = {${vfields.join(",")}}');
					case HFun(args, ret) | HMethod(args, ret):
						var fname = typeName(gctx, t);
						var aname = if (args.length == 0) "NULL" else {
							var name = 'fargs$fname';
							expr('static hl_type *$name[] = {${[for (a in args) typeValue(gctx, a)].join(",")}}');
							name;
						}
						expr('static hl_type_fun tfun$fname = {$aname,${typeValue(gctx, ret)},${args.length}}');
					case _:
				}
			}

			line("");
			line("#ifndef HL_DUMP_TYPES");
			line("HL_API void hl_sys_print(vbyte*);");
			line("#endif");

			line("");
			line("static void dump_types( void (*fdump)( void *, int) ) {");
			block(ctx);
			line("#ifdef HL_DUMP_TYPES");
			expr("hl_type *t");
			expr('int ntypes = ${allTypes.length}');
			expr("fdump(&ntypes,4)");
			var fcount = 0;
			for (t in allTypes) {
				expr('t = &${typeName(gctx, t)}; fdump(&t, sizeof(void*))');
				switch t {
					case HFun(_): fcount++;
					case _:
				}
			}
			expr('int fcount = $fcount');
			expr("fdump(&fcount, 4)");
			for (t in allTypes) {
				switch t {
					case HFun(_):
						expr('t = (hl_type*)&${typeName(gctx, t)}.fun->closure_type; fdump(&t, sizeof(void*))');
					case _:
				}
			}
			line("#else");
			expr("hl_sys_print((vbyte*)USTR(\"dump_types not available, please compile with HL_DUMP_TYPES defined\\n\"))");
			line("#endif");
			unblock(ctx);
			line("}");

			line("");
			line("void hl_init_types( hl_module_context *ctx ) {");
			block(ctx);
			for (t in allTypes) {
				switch t {
					case HObj(o) | HStruct(o):
						var name = typeName(gctx, t);
						expr('obj$name.m = ctx');
						switch o.pclassglobal {
							case null:
							case g:
								defineGlobal(gctx, ctx, g);
								expr('obj$name.global_value = (void**)&${gnames[g]}');
						}
						expr('$name.obj = &obj$name');
					case HNull(r) | HRef(r) | HPacked(r):
						expr('${typeName(gctx, t)}.tparam = ${typeValue(gctx, r)}');
					case HEnum(e):
						var name = typeName(gctx, t);
						expr('$name.tenum = &enum$name');
						switch e.eglobal {
							case null:
							case g:
								defineGlobal(gctx, ctx, g);
								expr('enum$name.global_value = (void**)&${gnames[g]}');
						}
						expr('hl_init_enum(&$name,ctx)');
					case HVirtual(_):
						var name = typeName(gctx, t);
						expr('$name.virt = &virt$name');
						expr('hl_init_virtual(&$name,ctx)');
					case HFun(_) | HMethod(_):
						var name = typeName(gctx, t);
						expr('$name.fun = &tfun$name');
					case _:
				}
			}
			expr("hl_gc_set_dump_types(dump_types)");
			unblock(ctx);
			line("}");
			closeFile(ctx);
			saveCfile(gctx, ctx.curfile);
		}

		{
			var ctx = openFile(gctx, "hl/reflect.c");
			define(ctx, "#define HLC_BOOT");
			define(ctx, "#include <hlc.h>");
			linec(ctx, "// Reflection helpers");
			generateReflection(gctx, ctx);
			closeFile(ctx);
			saveCfile(gctx, ctx.curfile);
		}

		{
			var modules = modules.copy();
			for (m in modules) {
				var path = core.OcamlFilename.dirname(m.mName);
				if (!sys.FileSystem.exists(gctx.dir + "/" + path)) core.Path.mkdirRecursive(gctx.dir, nsplit(path, "/"));
				/* add cfiles in deterministic order */
				if (m.mFunctions.length != 0) saveCfile(gctx, m.mName + ".c");
			}
			// port: upstream generates the modules in parallel; the hash cache they share
			// would then make hashes.c depend on scheduling. Sequential, as with
			// -D disable-parallelism.
			for (idx in 0...modules.length) {
				var m = modules[idx];
				var definedTypes = new TtypeMap<Bool>();
				if (m.mTypes.length != 0) {
					var ctx = openFile(gctx, m.mName + ".h");
					generateModuleTypes(gctx, ctx, m);
					definedTypes = ctx.definedTypes;
					closeFile(ctx);
				}
				if (m.mFunctions.length != 0) {
					var ctx = openFile(gctx, m.mName + ".c");
					ctx.definedTypes = definedTypes;
					define(ctx, "#define HLC_BOOT");
					define(ctx, "#include <hlc.h>");
					if (m.mTypes.length != 0) define(ctx, '#include <${m.mName}.h>');
					function filePos(f:FunctionEntry):{s:String, p:Int} {
						return switch f.feDecl {
							case f if (f != null && f.debug.length > 0):
								var d = f.debug[f.debug.length - 1];
								{s: code.strings[d.file], p: d.line};
							case _:
								{s: "", p: 0};
						}
					}
					var funcs = listSort((f1:FunctionEntry, f2:FunctionEntry) -> {
						var a = filePos(f1), b = filePos(f2);
						var c = strCompare(a.s, b.s);
						if (c != 0) c else (a.p < b.p ? -1 : (a.p > b.p ? 1 : 0));
					}, m.mFunctions);
					for (fe in funcs) if (fe.feDecl != null) generateFunction(gctx, ctx, fe.feDecl);
					closeFile(ctx);
				}
			}
		}

		{
			var ctx = openFile(gctx, "hl/functions.c");
			function line(s:String) linec(ctx, s);
			define(ctx, "#define HLC_BOOT");
			define(ctx, "#include <hlc.h>");
			var ptrs = [
				for (f in gctx.ftable) {
					var name = defineFunction(gctx, ctx, f.feIndex);
					if (name == "hl_tls_get_w") "hl_tls_get" else name;
				}
			];
			exprc(ctx, 'void *hl_functions_ptrs[] = {${ptrs.join(",\\\n\t")}}');
			var types = [
				for (ft in gctx.ftable) {
					var n = typeName(gctx, HFun(ft.feArgs, ft.feRet));
					define(ctx, 'extern hl_type $n;');
					"&" + n;
				}
			];
			exprc(ctx, 'hl_type *hl_functions_types[] = {${types.join(",\\\n\t")}}');
			line("");
			for (f in gctx.ftable) {
				if (f.feModule == null && f.feDecl != null) generateFunction(gctx, ctx, f.feDecl);
			}
			closeFile(ctx);
			saveCfile(gctx, ctx.curfile);
		}

		{
			var ctx = openFile(gctx, "hl/hashes.c");
			function line(s:String) linec(ctx, s);
			define(ctx, "#define HLC_BOOT");
			define(ctx, "#include <hlc.h>");
			line("");
			line("void hl_init_hashes() {");
			block(ctx);
			var l = gctx.hashCacheList.copy();
			l.reverse();
			for (i in l) exprc(ctx, 'hl_hash((vbyte*)${string(gctx, ctx, i)})');
			unblock(ctx);
			line("}");
			closeFile(ctx);
			saveCfile(gctx, ctx.curfile);
		}

		{
			var ctx = openFile(gctx, core.OcamlFilename.basename(file));
			function line(s:String) linec(ctx, s);
			function expr(s:String) exprc(ctx, s);
			define(ctx, "#define HLC_BOOT");
			define(ctx, "#include <hlc.h>");
			line("");
			line("#ifndef HL_MAKE");
			for (f in gctx.cfiles) line('#  include <$f>');
			line("#endif");
			line("");
			line("#include <hlc_main.c>");
			line("");
			expr("void hl_init_hashes()");
			expr("void hl_init_roots()");
			expr("void hl_init_types( hl_module_context *ctx )");
			expr("extern void *hl_functions_ptrs[]");
			expr("extern hl_type *hl_functions_types[]");
			line("");
			line("// Entry point");
			line("void hl_entry_point() {");
			block(ctx);
			expr("hl_module_context ctx");
			expr("hl_alloc_init(&ctx.alloc)");
			expr("ctx.functions_ptrs = hl_functions_ptrs");
			expr("ctx.functions_types = hl_functions_types");
			expr("hl_init_types(&ctx)");
			expr("hl_init_hashes()");
			expr("hl_init_roots()");
			if (code.entrypoint >= 0) expr('${defineFunction(gctx, ctx, code.entrypoint)}()');
			unblock(ctx);
			line("}");
			line("");
			closeFile(ctx);
			saveCfile(gctx, ctx.curfile);
		}

		{
			var ctx = openFile(gctx, "hlc.json");
			function line(s:String) linec(ctx, s);
			line("{");
			block(ctx);
			line('"version" : ${gctx.version},');
			var libs = nativeLibs.fold((k, _, acc:Array<String>) -> {
				acc.unshift('"$k"');
				acc;
			}, []);
			line('"libs" : [${libs.join(",")}],');
			var defines = new StringBuf();
			var keys = [for (k in com.defines.values.keys()) k];
			haxe.ds.ArraySort.sort(keys, strCompare);
			for (key in keys) defines.add('\n\t\t"${ocamlEscaped(key)}" : "${ocamlEscaped(com.defines.values.get(key))}",');
			var defines = defines.toString();
			var defines = defines.substr(0, defines.length - 1);
			line('"defines" : {$defines\n\t},');
			line('"files" : [${[for (f in gctx.cfiles) '\n\t\t"$f"'].join(",")}\n\t]');
			unblock(ctx);
			line("}");
			closeFile(ctx);
		}
	}

	// port: OCaml String.escaped on raw bytes
	static function ocamlEscapedBytes(b:haxe.io.Bytes):String {
		var buf = new StringBuf();
		for (i in 0...b.length) {
			var c = b.get(i);
			switch c {
				case '"'.code: buf.add("\\\"");
				case '\\'.code: buf.add("\\\\");
				case '\n'.code: buf.add("\\n");
				case '\t'.code: buf.add("\\t");
				case '\r'.code: buf.add("\\r");
				case 8: buf.add("\\b");
				case _ if (c >= 32 && c <= 126): buf.addChar(c);
				case _:
					var d = Std.string(c);
					while (d.length < 3) d = "0" + d;
					buf.add("\\" + d);
			}
		}
		return buf.toString();
	}

	static function bytesToLatin1(b:haxe.io.Bytes):String {
		var buf = new StringBuf();
		for (i in 0...b.length) buf.addChar(b.get(i));
		return buf.toString();
	}
}
