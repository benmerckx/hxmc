/*
 *  This file is part of SwfLib
 *  Copyright (c)2004-2006 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
 */

package libs.swflib;

import haxe.io.Bytes;
import haxe.ds.Vector;
import libs.extlib.IO;
import libs.extlib.IO.Output;
import libs.extlib.IO.Input;
import libs.swflib.As3;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// port: haxe/libs/swflib/as3parse.ml (the parse_* switches are all true);
// indexes are plain Ints, so magic_index/index_int are the identity.
class As3parse {
	static function assertFalse():Dynamic throw new core.ds.Failure("assert false");

	static inline function index<T>(t:Vector<T>, i:Int):Index {
		if (i <= 0 || i - 1 >= t.length) assertFalse();
		return i;
	}

	static inline function index_opt<T>(t:Vector<T>, i:Int):Null<Index> {
		if (i == 0)
			return null
		else
			return index(t, i);
	}

	static inline function index_nz<T>(t:Vector<T>, i:Int):IndexNz {
		if (i < 0 || i >= t.length) assertFalse();
		return i;
	}

	public static inline function iget<T>(t:Vector<T>, i:Index):T return t[i - 1];

	public static inline function no_nz(i:IndexNz):Index return i + 1;

	/* ************************************************************************ */
	/* LENGTH */
	static function as3_empty_index(ctx:As3Tag):Index {
		for (i in 0...ctx.as3_idents.length) if (ctx.as3_idents[i] == "") return i + 1;
		return assertFalse();
	}

	// port: the int32 shifts of as3_int_length on a 32-bit Int.
	public static function as3_int_length(i:Int):Int {
		if ((i >>> 28) > 0)
			return 5
		else if ((i >> 21) > 0)
			return 4
		else if ((i >> 14) > 0)
			return 3
		else if ((i >> 7) > 0)
			return 2
		else
			return 1;
	}

	static function as3_uint_length(i:Int):Int return as3_int_length(i);

	static function sum<T>(f:T->Int, l:Array<T>):Int {
		var acc = 0;
		for (n in l) acc += f(n);
		return acc;
	}

	// port: Int32.of_int truncates; Ints are 32-bit already.
	public static function int_length(i:Int):Int return as3_int_length(i);

	static function idx_length(i:Index):Int return int_length(i);

	static function idx_length_nz(i:IndexNz):Int return int_length(i);

	static function idx_opt_length(i:Null<Index>):Int return i == null ? int_length(0) : idx_length(i);

	// port: OCaml strings are bytes: the length is that of the UTF-8 encoding.
	static function as3_ident_length(s:String):Int {
		var n = Bytes.ofString(s).length;
		return n + int_length(n);
	}

	static function as3_namespace_length(ei:Index, ns:As3Namespace):Int return switch ns {
		case A3NStaticProtected(o) | A3NPrivate(o):
			1 + (o == null ? int_length(0) : idx_length(o));
		case A3NPublic(o) | A3NInternal(o):
			1 + idx_length(o == null ? ei : o);
		case A3NExplicit(n) | A3NNamespace(n) | A3NProtected(n):
			1 + idx_length(n);
	}

	static function as3_ns_set_length(l:As3NsSet):Int return int_length(l.length) + sum(idx_length, l);

	static function as3_name_length(t:As3MultiName):Int return 1 + switch t {
		case A3MMultiName(id, r):
			idx_opt_length(id) + idx_length(r);
		case A3MName(id, r):
			idx_length(r) + idx_length(id);
		case A3MNSAny(id):
			int_length(0) + idx_length(id);
		case A3MAny:
			int_length(0) + int_length(0);
		case A3MRuntimeName(i):
			idx_length(i);
		case A3MRuntimeNameLate:
			0;
		case A3MMultiNameLate(idx):
			idx_length(idx);
		case A3MAttrib(n):
			as3_name_length(n) - 1;
		case A3MParams(id, pl):
			idx_length(id) + 1 + (sum(idx_length, pl));
	}

	static function as3_value_length(extra:Bool, v:As3Value):Int return switch v {
		case A3VNone: if (extra) 2 else 1;
		case A3VNull | A3VBool(_): 2;
		case A3VString(s): 1 + idx_length(s);
		case A3VInt(s): 1 + idx_length(s);
		case A3VUInt(s): 1 + idx_length(s);
		case A3VFloat(s): 1 + idx_length(s);
		case A3VNamespace(_, s): 1 + idx_length(s);
	}

	static function as3_method_type_length(m:As3MethodType):Int {
		return 1
			+ idx_opt_length(m.mt3_ret)
			+ sum(idx_opt_length, m.mt3_args)
			+ idx_opt_length(m.mt3_debug_name)
			+ 1
			+ (m.mt3_dparams == null ? 0 : 1 + sum(as3_value_length.bind(true), m.mt3_dparams))
			+ (m.mt3_pnames == null ? 0 : sum(idx_opt_length, m.mt3_pnames));
	}

	static inline function list_length<T>(f:T->Int, l:Vector<T>):Int {
		return switch l.length {
			case 0: int_length(0);
			case n:
				var acc = int_length(n + 1);
				for (x in l) acc += f(x);
				acc;
		}
	}

	static inline function list2_length<T>(f:T->Int, l:Vector<T>):Int {
		var acc = int_length(l.length);
		for (x in l) acc += f(x);
		return acc;
	}

	static function as3_field_length(f:As3Field):Int {
		return idx_length(f.f3_name)
			+ 1
			+ int_length(f.f3_slot)
			+ (switch f.f3_kind {
				case A3FMethod(m):
					idx_length_nz(m.m3_type);
				case A3FClass(c):
					idx_length_nz(c);
				case A3FFunction(id):
					idx_length_nz(id);
				case A3FVar(v):
					idx_opt_length(v.v3_type) + as3_value_length(false, v.v3_value);
			})
			+ (switch f.f3_metas {
				case null: 0;
				case l: list2_length(idx_length_nz, l);
			});
	}

	static function as3_class_length(c:As3Class):Int {
		return idx_length(c.cl3_name)
			+ idx_opt_length(c.cl3_super)
			+ 1
			+ (c.cl3_namespace == null ? 0 : idx_length(c.cl3_namespace))
			+ list2_length(idx_length, c.cl3_implements)
			+ idx_length_nz(c.cl3_construct)
			+ list2_length(as3_field_length, c.cl3_fields);
	}

	static function as3_static_length(s:As3Static):Int {
		return idx_length_nz(s.st3_method) + list2_length(as3_field_length, s.st3_fields);
	}

	static function as3_metadata_length(m:As3Metadata):Int {
		return idx_length(m.meta3_name) + list2_length(d -> idx_opt_length(d.k) + idx_length(d.v), m.meta3_data);
	}

	static function as3_try_catch_length(t:As3TryCatch):Int {
		return int_length(t.tc3_start)
			+ int_length(t.tc3_end)
			+ int_length(t.tc3_handle)
			+ idx_opt_length(t.tc3_type)
			+ idx_opt_length(t.tc3_name);
	}

	static function as3_function_length(f:As3Function):Int {
		var clen = 0;
		for (op in f.fun3_code) clen += As3code.length(op);
		return idx_length_nz(f.fun3_id)
			+ int_length(f.fun3_stack_size)
			+ int_length(f.fun3_nregs)
			+ int_length(f.fun3_init_scope)
			+ int_length(f.fun3_max_scope)
			+ int_length(clen)
			+ clen
			+ list2_length(as3_try_catch_length, f.fun3_trys)
			+ list2_length(as3_field_length, f.fun3_locals);
	}

	public static function as3_length(ctx:As3Tag):Int {
		var ei = as3_empty_index(ctx);
		var statics = 0;
		for (x in ctx.as3_statics) statics += as3_static_length(x);
		return Bytes.ofString(ctx.as3_unknown).length
			+ 4
			+ list_length(as3_int_length, ctx.as3_ints)
			+ list_length(as3_uint_length, ctx.as3_uints)
			+ list_length(_ -> 8, ctx.as3_floats)
			+ list_length(as3_ident_length, ctx.as3_idents)
			+ list_length(as3_namespace_length.bind(ei), ctx.as3_namespaces)
			+ list_length(as3_ns_set_length, ctx.as3_nsets)
			+ list_length(as3_name_length, ctx.as3_names)
			+ list2_length(as3_method_type_length, ctx.as3_method_types)
			+ list2_length(as3_metadata_length, ctx.as3_metadatas)
			+ list2_length(as3_class_length, ctx.as3_classes)
			+ statics
			+ list2_length(as3_static_length, ctx.as3_inits)
			+ list2_length(as3_function_length, ctx.as3_functions);
	}

	/* ************************************************************************ */
	/* PARSING */
	static function read_as3_int(ch:Input):Int {
		var a = IO.readByte(ch);
		if (a < 128) return a;
		var a = a & 127;
		var b = IO.readByte(ch);
		if (b < 128) return (b << 7) | a;
		var b = b & 127;
		var c = IO.readByte(ch);
		if (c < 128) return (c << 14) | (b << 7) | a;
		var c = c & 127;
		var d = IO.readByte(ch);
		if (d < 128) return (d << 21) | (c << 14) | (b << 7) | a;
		var d = d & 127;
		var e = IO.readByte(ch);
		if (e > 15) assertFalse();
		var small = (d << 21) | (c << 14) | (b << 7) | a;
		var big = e << 28;
		return big | small;
	}

	static function read_as3_uint(ch:Input):Int return read_as3_int(ch);

	public static function read_int(ch:Input):Int return read_as3_int(ch);

	static function read_ident(ch:Input):String return IO.nreadString(ch, read_int(ch));

	static function read_namespace(idents:Vector<As3Ident>, ch:Input):As3Namespace {
		var k = IO.readByte(ch);
		var p = index_opt(idents, read_int(ch));
		return switch k {
			case 0x05:
				A3NPrivate(p);
			case 0x08:
				switch p {
					case null: assertFalse();
					case idx: A3NNamespace(idx);
				}
			case 0x16:
				switch p {
					case null: assertFalse();
					case p if (iget(idents, p) == ""): A3NPublic(null);
					case _: A3NPublic(p);
				}
			case 0x17:
				switch p {
					case null: assertFalse();
					case p if (iget(idents, p) == ""): A3NInternal(null);
					case _: A3NInternal(p);
				}
			case 0x18:
				switch p {
					case null: assertFalse();
					case idx: A3NProtected(idx);
				}
			case 0x19:
				switch p {
					case null: assertFalse();
					case idx: A3NExplicit(idx);
				}
			case 0x1A:
				A3NStaticProtected(p);
			case _:
				assertFalse();
		}
	}

	static function read_ns_set(namespaces:Vector<As3Namespace>, ch:Input):As3NsSet {
		var n = IO.readByte(ch);
		var l = [];
		for (_ in 0...n) l.push(index(namespaces, read_int(ch)));
		return l;
	}

	static function read_name(ctx:As3Tag, k:Null<Int>, ch:Input):As3MultiName {
		var k = (switch k {
			case null: IO.readByte(ch);
			case k: k;
		});
		return switch k {
			case 0x07:
				var i = read_int(ch);
				var j = read_int(ch);
				if (i == 0 && j == 0)
					A3MAny
				else if (i == 0 && j != 0) {
					var id = index(ctx.as3_idents, j);
					A3MNSAny(id);
				} else {
					var ns = index(ctx.as3_namespaces, i);
					var id = index(ctx.as3_idents, j);
					/* both ns and id can be 0 <=> '*' */
					A3MName(id, ns);
				}
			case 0x09:
				var id = index_opt(ctx.as3_idents, read_int(ch));
				var ns = index(ctx.as3_nsets, read_int(ch));
				A3MMultiName(id, ns);
			case 0x0D:
				A3MAttrib(read_name(ctx, 0x07, ch));
			case 0x0E:
				A3MAttrib(read_name(ctx, 0x09, ch));
			case 0x0F:
				var id = index(ctx.as3_idents, read_int(ch));
				A3MRuntimeName(id);
			case 0x10:
				A3MAttrib(read_name(ctx, 0x0F, ch));
			case 0x11:
				A3MRuntimeNameLate;
			case 0x12:
				A3MAttrib(read_name(ctx, 0x11, ch));
			case 0x1B:
				var ns = index(ctx.as3_nsets, read_int(ch));
				A3MMultiNameLate(ns);
			case 0x1C:
				A3MAttrib(read_name(ctx, 0x1B, ch));
			case 0x1D:
				var id = read_int(ch);
				var n = IO.readByte(ch);
				var l = [];
				for (_ in 0...n) l.push(read_int(ch));
				A3MParams(id, l);
			case n:
				Sys.stderr().writeString(Std.string(n) + "\n");
				assertFalse();
		}
	}

	static function read_value(ctx:As3Tag, ch:Input, extra:Bool):As3Value {
		var idx = read_int(ch);
		if (idx == 0) {
			if (extra && IO.readByte(ch) != 0) assertFalse();
			return A3VNone;
		} else
			return switch (IO.readByte(ch) : Int) {
				case 0x01:
					A3VString(index(ctx.as3_idents, idx));
				case 0x03:
					A3VInt(index(ctx.as3_ints, idx));
				case 0x04:
					A3VUInt(index(ctx.as3_uints, idx));
				case 0x06:
					A3VFloat(index(ctx.as3_floats, idx));
				case n if (n == 0x08 || n == 0x16 || n == 0x17 || n == 0x18 || n == 0x19 || n == 0x1A || n == 0x05):
					A3VNamespace(n, index(ctx.as3_namespaces, idx));
				case 0x0A:
					if (idx != 0x0A) assertFalse();
					A3VBool(false);
				case 0x0B:
					if (idx != 0x0B) assertFalse();
					A3VBool(true);
				case 0x0C:
					if (idx != 0x0C) assertFalse();
					A3VNull;
				case _:
					assertFalse();
			}
	}

	static function read_method_type(ctx:As3Tag, ch:Input):As3MethodType {
		var nargs = IO.readByte(ch);
		var tret = index_opt(ctx.as3_names, read_int(ch));
		var targs = [for (_ in 0...nargs) index_opt(ctx.as3_names, read_int(ch))];
		var dname = index_opt(ctx.as3_idents, read_int(ch));
		var flags = IO.readByte(ch);
		var dparams = (if (flags & 0x08 != 0) {
			var n = IO.readByte(ch);
			[for (_ in 0...n) read_value(ctx, ch, true)];
		} else null);
		var pnames = (if (flags & 0x80 != 0) [for (_ in 0...nargs) index_opt(ctx.as3_idents, read_int(ch))] else null);
		return {
			mt3_ret: tret,
			mt3_args: targs,
			mt3_var_args: flags & 0x04 != 0,
			mt3_native: flags & 0x20 != 0,
			mt3_new_block: flags & 0x02 != 0,
			mt3_debug_name: dname,
			mt3_dparams: dparams,
			mt3_pnames: pnames,
			mt3_arguments_defined: flags & 0x01 != 0,
			mt3_uses_dxns: flags & 0x40 != 0,
			mt3_unused_flag: flags & 0x10 != 0,
		};
	}

	static inline function read_list<T>(ch:Input, f:Input->T):Vector<T> {
		var n = read_int(ch);
		// port: Array.init raises on a negative length.
		if (n < 0) throw new core.ds.InvalidArgument("Array.init");
		var a = new Vector<T>(n == 0 ? 0 : n - 1);
		for (i in 0...a.length) a[i] = f(ch);
		return a;
	}

	static inline function read_list2<T>(ch:Input, f:Input->T):Vector<T> {
		var n = read_int(ch);
		if (n < 0) throw new core.ds.InvalidArgument("Array.init");
		var a = new Vector<T>(n);
		for (i in 0...a.length) a[i] = f(ch);
		return a;
	}

	static function read_field(ctx:As3Tag, ch:Input):As3Field {
		var name = index(ctx.as3_names, read_int(ch));
		var kind = IO.readByte(ch);
		var has_meta = kind & 0x40 != 0;
		var slot = read_int(ch);
		var fkind = (switch kind & 0xF {
			case k if (k == 0x00 || k == 0x06):
				var t = index_opt(ctx.as3_names, read_int(ch));
				var value = read_value(ctx, ch, false);
				A3FVar({
					v3_type: t,
					v3_value: value,
					v3_const: k == 0x06,
				});
			case 0x02 | 0x03 | 0x01:
				var meth = index_nz(ctx.as3_method_types, read_int(ch));
				var final_ = kind & 0x10 != 0;
				var override_ = kind & 0x20 != 0;
				A3FMethod({
					m3_type: meth,
					m3_final: final_,
					m3_override: override_,
					m3_kind: (switch kind & 0xF {
						case 0x01: MK3Normal;
						case 0x02: MK3Getter;
						case 0x03: MK3Setter;
						case _: assertFalse();
					}),
				});
			case 0x04:
				var c = index_nz(ctx.as3_classes, read_int(ch));
				A3FClass(c);
			case 0x05:
				var f = index_nz(ctx.as3_method_types, read_int(ch));
				A3FFunction(f);
			case _:
				assertFalse();
		});
		var metas = (if (has_meta) read_list2(ch, _ -> index_nz(ctx.as3_metadatas, read_int(ch))) else null);
		return {
			f3_name: name,
			f3_slot: slot,
			f3_kind: fkind,
			f3_metas: metas,
		};
	}

	static function read_class(ctx:As3Tag, ch:Input):As3Class {
		var name = index(ctx.as3_names, read_int(ch));
		var csuper = index_opt(ctx.as3_names, read_int(ch));
		var flags = IO.readByte(ch);
		var namespace:Null<Index> = if (flags & 8 != 0) {
			var r = index(ctx.as3_namespaces, read_int(ch));
			r;
		} else null;
		var impls = read_list2(ch, _ -> index(ctx.as3_names, read_int(ch)));
		var construct = index_nz(ctx.as3_method_types, read_int(ch));
		var fields = read_list2(ch, read_field.bind(ctx));
		return {
			cl3_name: name,
			cl3_super: csuper,
			cl3_sealed: (flags & 1) != 0,
			cl3_final: (flags & 2) != 0,
			cl3_interface: (flags & 4) != 0,
			cl3_namespace: namespace,
			cl3_implements: impls,
			cl3_construct: construct,
			cl3_fields: fields,
		};
	}

	static function read_static(ctx:As3Tag, ch:Input):As3Static {
		var meth = index_nz(ctx.as3_method_types, read_int(ch));
		var fields = read_list2(ch, read_field.bind(ctx));
		return {
			st3_method: meth,
			st3_fields: fields,
		};
	}

	static function read_metadata(ctx:As3Tag, ch:Input):As3Metadata {
		var name = index(ctx.as3_idents, read_int(ch));
		var data = read_list2(ch, _ -> index_opt(ctx.as3_idents, read_int(ch)));
		var data = data.map(i1 -> {k: i1, v: index(ctx.as3_idents, read_int(ch))});
		return {
			meta3_name: name,
			meta3_data: data,
		};
	}

	static function read_try_catch(ctx:As3Tag, ch:Input):As3TryCatch {
		var start = read_int(ch);
		var pend = read_int(ch);
		var handle = read_int(ch);
		var t = index_opt(ctx.as3_names, read_int(ch));
		var name = index_opt(ctx.as3_names, read_int(ch));
		return {
			tc3_start: start,
			tc3_end: pend,
			tc3_handle: handle,
			tc3_type: t,
			tc3_name: name,
		};
	}

	static function read_function(ctx:As3Tag, ch:Input):As3Function {
		var id = index_nz(ctx.as3_method_types, read_int(ch));
		var ss = read_int(ch);
		var nregs = read_int(ch);
		var init_scope = read_int(ch);
		var max_scope = read_int(ch);
		var size = read_int(ch);
		var code = As3code.parse(ch, size);
		var trys = read_list2(ch, read_try_catch.bind(ctx));
		var local_funs = read_list2(ch, read_field.bind(ctx));
		return {
			fun3_id: id,
			fun3_stack_size: ss,
			fun3_nregs: nregs,
			fun3_init_scope: init_scope,
			fun3_max_scope: max_scope,
			fun3_code: code,
			fun3_trys: trys,
			fun3_locals: local_funs,
		};
	}

	public static function parse(ch:Input, len:Int):As3Tag {
		var pi = IO.posIn(ch);
		var ch = pi.ch, get_pos = pi.pos;
		if (IO.readI32(ch) != header_magic) assertFalse();
		var ints = read_list(ch, read_as3_int);
		var uints = read_list(ch, read_as3_uint);
		var floats = read_list(ch, IO.readDouble);
		var idents = read_list(ch, read_ident);
		var idents = (if (idents.has("")) idents else idents.snoc(""));
		var namespaces = read_list(ch, read_namespace.bind(idents));
		var nsets = read_list(ch, read_ns_set.bind(namespaces));
		var ctx:As3Tag = {
			as3_ints: ints,
			as3_uints: uints,
			as3_floats: floats,
			as3_idents: idents,
			as3_namespaces: namespaces,
			as3_nsets: nsets,
			as3_names: vector(),
			as3_method_types: vector(),
			as3_metadatas: vector(),
			as3_classes: vector(),
			as3_statics: vector(),
			as3_inits: vector(),
			as3_functions: vector(),
			as3_unknown: "",
		};
		ctx.as3_names = read_list(ch, ch -> read_name(ctx, null, ch));
		ctx.as3_method_types = read_list2(ch, read_method_type.bind(ctx));
		ctx.as3_metadatas = read_list2(ch, read_metadata.bind(ctx));
		ctx.as3_classes = read_list2(ch, read_class.bind(ctx));
		ctx.as3_statics = ctx.as3_classes.map(_ -> read_static(ctx, ch));
		ctx.as3_inits = read_list2(ch, read_static.bind(ctx));
		ctx.as3_functions = read_list2(ch, read_function.bind(ctx));
		ctx.as3_unknown = IO.reallyNread(ch, len - (get_pos())).toString();
		if (ctx.as3_unknown.length != 0) assertFalse();
		/*	let len2 = as3_length ctx in
			if len2 <> len then begin Printf.printf "%d != %d" len len2; assert false; end;
		 */
		return ctx;
	}

	/* ************************************************************************ */
	/* WRITING */
	static final header_magic = 0x002E0010;

	static function write_as3_int(ch:Output, i:Int):Void {
		var e = i >>> 28;
		var d = (i >> 21) & 0x7F;
		var c = (i >> 14) & 0x7F;
		var b = (i >> 7) & 0x7F;
		var a = i & 0x7F;
		if (b != 0 || c != 0 || d != 0 || e != 0) {
			IO.writeByte(ch, a | 0x80);
			if (c != 0 || d != 0 || e != 0) {
				IO.writeByte(ch, b | 0x80);
				if (d != 0 || e != 0) {
					IO.writeByte(ch, c | 0x80);
					if (e != 0) {
						IO.writeByte(ch, d | 0x80);
						IO.writeByte(ch, e);
					} else
						IO.writeByte(ch, d);
				} else
					IO.writeByte(ch, c);
			} else
				IO.writeByte(ch, b);
		} else
			IO.writeByte(ch, a);
	}

	static function write_as3_uint(ch:Output, i:Int):Void write_as3_int(ch, i);

	public static function write_int(ch:Output, i:Int):Void write_as3_int(ch, i);

	static function write_index(ch:Output, n:Index):Void write_int(ch, n);

	static function write_index_nz(ch:Output, n:IndexNz):Void write_int(ch, n);

	static function write_index_opt(ch:Output, n:Null<Index>):Void {
		if (n == null) write_int(ch, 0) else write_index(ch, n);
	}

	static function write_as3_ident(ch:Output, id:String):Void {
		var b = Bytes.ofString(id);
		write_int(ch, b.length);
		IO.nwrite(ch, b);
	}

	static function write_namespace(empty_index:Index, ch:Output, ns:As3Namespace):Void {
		switch ns {
			case A3NPrivate(n):
				IO.writeByte(ch, 0x05);
				if (n == null) write_int(ch, 0) else write_index(ch, n);
			case A3NPublic(n):
				IO.writeByte(ch, 0x16);
				if (n == null) write_index(ch, empty_index) else write_index(ch, n);
			case A3NInternal(n):
				IO.writeByte(ch, 0x17);
				if (n == null) write_index(ch, empty_index) else write_index(ch, n);
			case A3NProtected(n):
				IO.writeByte(ch, 0x18);
				write_index(ch, n);
			case A3NNamespace(n):
				IO.writeByte(ch, 0x08);
				write_index(ch, n);
			case A3NExplicit(n):
				IO.writeByte(ch, 0x19);
				write_index(ch, n);
			case A3NStaticProtected(n):
				IO.writeByte(ch, 0x1A);
				if (n == null) write_int(ch, 0) else write_index(ch, n);
		}
	}

	static function write_rights(ch:Output, l:As3NsSet):Void {
		IO.writeByte(ch, l.length);
		for (i in l) write_index(ch, i);
	}

	static function write_name(ch:Output, k:Null<Int>, x:As3MultiName):Void {
		inline function b(n:Int):Int return k == null ? n : k;
		switch x {
			case A3MMultiName(id, r):
				IO.writeByte(ch, b(0x09));
				write_index_opt(ch, id);
				write_index(ch, r);
			case A3MName(id, r):
				IO.writeByte(ch, b(0x07));
				write_index(ch, r);
				write_index(ch, id);
			case A3MNSAny(id):
				IO.writeByte(ch, b(0x07));
				write_int(ch, 0);
				write_index(ch, id);
			case A3MAny:
				IO.writeByte(ch, b(0x07));
				write_int(ch, 0);
				write_int(ch, 0);
			case A3MRuntimeName(i):
				IO.writeByte(ch, b(0x0F));
				write_index(ch, i);
			case A3MRuntimeNameLate:
				IO.writeByte(ch, b(0x11));
			case A3MMultiNameLate(id):
				IO.writeByte(ch, b(0x1B));
				write_index(ch, id);
			case A3MAttrib(n):
				write_name(ch, switch n {
					case A3MName(_) | A3MNSAny(_) | A3MAny: 0x0D;
					case A3MMultiName(_): 0x0E;
					case A3MRuntimeName(_): 0x10;
					case A3MRuntimeNameLate: 0x12;
					case A3MMultiNameLate(_): 0x1C;
					case A3MAttrib(_) | A3MParams(_): assertFalse();
				}, n);
			case A3MParams(id, pl):
				IO.writeByte(ch, b(0x1D));
				write_index(ch, id);
				IO.writeByte(ch, pl.length);
				for (i in pl) write_index(ch, i);
		}
	}

	static function write_value(ch:Output, extra:Bool, v:As3Value):Void {
		switch v {
			case A3VNone:
				IO.writeByte(ch, 0x00);
				if (extra) IO.writeByte(ch, 0x00);
			case A3VNull:
				IO.writeByte(ch, 0x0C);
				IO.writeByte(ch, 0x0C);
			case A3VBool(b):
				IO.writeByte(ch, if (b) 0x0B else 0x0A);
				IO.writeByte(ch, if (b) 0x0B else 0x0A);
			case A3VString(s):
				write_index(ch, s);
				IO.writeByte(ch, 0x01);
			case A3VInt(s):
				write_index(ch, s);
				IO.writeByte(ch, 0x03);
			case A3VUInt(s):
				write_index(ch, s);
				IO.writeByte(ch, 0x04);
			case A3VFloat(s):
				write_index(ch, s);
				IO.writeByte(ch, 0x06);
			case A3VNamespace(n, s):
				write_index(ch, s);
				IO.writeByte(ch, n);
		}
	}

	static function write_method_type(ch:Output, m:As3MethodType):Void {
		var nargs = m.mt3_args.length;
		IO.writeByte(ch, nargs);
		write_index_opt(ch, m.mt3_ret);
		for (a in m.mt3_args) write_index_opt(ch, a);
		write_index_opt(ch, m.mt3_debug_name);
		var flags = (if (m.mt3_arguments_defined) 0x01 else 0) | (if (m.mt3_new_block) 0x02 else 0) | (if (m.mt3_var_args) 0x04 else 0) | (if (m.mt3_dparams != null) 0x08 else
			0) | (if (m.mt3_unused_flag) 0x10 else 0) | (if (m.mt3_native) 0x20 else 0) | (if (m.mt3_uses_dxns) 0x40 else 0) | (if (m.mt3_pnames != null) 0x80 else 0);
		IO.writeByte(ch, flags);
		switch m.mt3_dparams {
			case null:
			case l:
				IO.writeByte(ch, l.length);
				for (v in l) write_value(ch, true, v);
		}
		switch m.mt3_pnames {
			case null:
			case l:
				if (l.length != nargs) assertFalse();
				for (n in l) write_index_opt(ch, n);
		}
	}

	static inline function write_list<T>(ch:Output, f:Output->T->Void, l:Vector<T>):Void {
		switch l.length {
			case 0: IO.writeByte(ch, 0);
			case n:
				write_int(ch, n + 1);
				for (x in l) f(ch, x);
		}
	}

	static inline function write_list2<T>(ch:Output, f:Output->T->Void, l:Vector<T>):Void {
		write_int(ch, l.length);
		for (x in l) f(ch, x);
	}

	static function write_field(ch:Output, f:As3Field):Void {
		write_index(ch, f.f3_name);
		var flags = (if (f.f3_metas != null) 0x40 else 0);
		switch f.f3_kind {
			case A3FMethod(m):
				var base = (switch m.m3_kind {
					case MK3Normal: 0x01;
					case MK3Getter: 0x02;
					case MK3Setter: 0x03;
				});
				var flags = flags | (if (m.m3_final) 0x10 else 0) | (if (m.m3_override) 0x20 else 0);
				IO.writeByte(ch, base | flags);
				write_int(ch, f.f3_slot);
				write_index_nz(ch, m.m3_type);
			case A3FClass(c):
				IO.writeByte(ch, 0x04 | flags);
				write_int(ch, f.f3_slot);
				write_index_nz(ch, c);
			case A3FFunction(i):
				IO.writeByte(ch, 0x05 | flags);
				write_int(ch, f.f3_slot);
				write_index_nz(ch, i);
			case A3FVar(v):
				IO.writeByte(ch, flags | (if (v.v3_const) 0x06 else 0x00));
				write_int(ch, f.f3_slot);
				write_index_opt(ch, v.v3_type);
				write_value(ch, false, v.v3_value);
		}
		switch f.f3_metas {
			case null:
			case l:
				write_list2(ch, write_index_nz, l);
		}
	}

	static function write_class(ch:Output, c:As3Class):Void {
		write_index(ch, c.cl3_name);
		write_index_opt(ch, c.cl3_super);
		var flags = (if (c.cl3_sealed) 1 else 0) | (if (c.cl3_final) 2 else 0) | (if (c.cl3_interface) 4 else 0) | (if (c.cl3_namespace != null) 8 else 0);
		IO.writeByte(ch, flags);
		switch c.cl3_namespace {
			case null:
			case r: write_index(ch, r);
		}
		write_list2(ch, write_index, c.cl3_implements);
		write_index_nz(ch, c.cl3_construct);
		write_list2(ch, write_field, c.cl3_fields);
	}

	static function write_static(ch:Output, s:As3Static):Void {
		write_index_nz(ch, s.st3_method);
		write_list2(ch, write_field, s.st3_fields);
	}

	static function write_metadata(ch:Output, m:As3Metadata):Void {
		write_index(ch, m.meta3_name);
		write_list2(ch, (_, d) -> write_index_opt(ch, d.k), m.meta3_data);
		for (d in m.meta3_data) write_index(ch, d.v);
	}

	static function write_try_catch(ch:Output, t:As3TryCatch):Void {
		write_int(ch, t.tc3_start);
		write_int(ch, t.tc3_end);
		write_int(ch, t.tc3_handle);
		write_index_opt(ch, t.tc3_type);
		write_index_opt(ch, t.tc3_name);
	}

	static function write_function(ch:Output, f:As3Function):Void {
		write_index_nz(ch, f.fun3_id);
		write_int(ch, f.fun3_stack_size);
		write_int(ch, f.fun3_nregs);
		write_int(ch, f.fun3_init_scope);
		write_int(ch, f.fun3_max_scope);
		var clen = 0;
		for (op in f.fun3_code) clen += As3code.length(op);
		write_int(ch, clen);
		for (op in f.fun3_code) As3code.write(ch, op);
		write_list2(ch, write_try_catch, f.fun3_trys);
		write_list2(ch, write_field, f.fun3_locals);
	}

	public static function write(ch1:Output, ctx:As3Tag):Void {
		var buf = new haxe.io.BytesBuffer();
		var ch = IO.outputBytes(buf);
		var empty_index = as3_empty_index(ctx);
		IO.writeI32(ch, header_magic);
		write_list(ch, write_as3_int, ctx.as3_ints);
		write_list(ch, write_as3_uint, ctx.as3_uints);
		write_list(ch, IO.writeDouble, ctx.as3_floats);
		write_list(ch, write_as3_ident, ctx.as3_idents);
		write_list(ch, write_namespace.bind(empty_index), ctx.as3_namespaces);
		write_list(ch, write_rights, ctx.as3_nsets);
		write_list(ch, (ch, n:As3MultiName) -> write_name(ch, null, n), ctx.as3_names);
		write_list2(ch, write_method_type, ctx.as3_method_types);
		write_list2(ch, write_metadata, ctx.as3_metadatas);
		write_list2(ch, write_class, ctx.as3_classes);
		for (s in ctx.as3_statics) write_static(ch, s);
		write_list2(ch, write_static, ctx.as3_inits);
		write_list2(ch, write_function, ctx.as3_functions);
		IO.nwriteString(ch, ctx.as3_unknown);
		IO.nwrite(ch1, buf.getBytes());
	}
}
