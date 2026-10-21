/*
 *  This file is part of SwfLib
 *  Copyright (c)2004-2008 Nicolas Cannasse
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

import haxe.ds.Vector;
import libs.swflib.As3;
import libs.swflib.As3hl;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// port: haxe/libs/swflib/as3hlparse.ml; MultiArray.t and DynArray.t are Arrays.
class As3hlparse {
	static function assertFalse():Dynamic throw new core.ds.Failure("assert false");

	public static function stack_delta(op:HlOpcode):Int return switch op {
		case HBreakPoint: 0;
		case HNop: 0;
		case HThrow: -1;
		case HGetSuper(_): 0;
		case HSetSuper(_): -2;
		case HDxNs(_): 0;
		case HDxNsLate: -1;
		case HRegKill(_): 0;
		case HLabel: 0;
		case HJump(cond, _):
			(switch cond {
				case J3Always: 0;
				case J3True | J3False: -1;
				case _: -2;
			});
		case HSwitch(_): -1;
		case HPushWith: -1;
		case HPopScope: 0;
		case HForIn: -1;
		case HHasNext: -1;
		case HNull | HUndefined: 1;
		case HForEach: -1;
		case HSmallInt(_) | HInt(_) | HTrue | HFalse | HString(_) | HIntRef(_) | HUIntRef(_) | HFunction(_) | HFloat(_) | HNaN: 1;
		case HPop: -1;
		case HDup: 1;
		case HSwap: 0;
		case HScope: -1;
		case HNamespace(_): 1;
		case HNext(_): 1;
		case HCallStack(n): -(n + 1);
		case HConstruct(n): -n;
		case HCallMethod(_, n): -n;
		case HCallStatic(_, n): -n;
		case HCallSuper(_, n): -n;
		case HCallProperty(_, n): -n;
		case HRetVoid: 0;
		case HRet: -1;
		case HConstructSuper(n): -(n + 1);
		case HConstructProperty(_, n): -n;
		case HCallPropLex(_, n): -n;
		case HCallSuperVoid(_, n): -(n + 1);
		case HCallPropVoid(_, n): -(n + 1);
		case HApplyType(n): -n;
		case HObject(n): -(n * 2) + 1;
		case HArray(n): -n + 1;
		case HNewBlock: 1;
		case HClassDef(_): 0;
		case HGetDescendants(_): 0;
		case HCatch(_): 1;
		case HFindPropStrict(_): 1;
		case HFindProp(_): 1;
		case HFindDefinition(_): 1;
		case HGetLex(_): 1;
		case HSetProp(_): -2;
		case HReg(_): 1;
		case HSetReg(_) | HSetThis: -1;
		case HGetGlobalScope | HGetScope(_): 1;
		case HGetProp(_): 0;
		case HInitProp(_): -2;
		case HDeleteProp(_): -1; /* true/false */
		case HGetSlot(_): 0;
		case HSetSlot(_): -2;
		case HToString | HToXml | HToXmlAttr | HToInt | HToUInt | HToNumber | HToObject | HAsAny | HAsType(_) | HIsType(_) | HAsObject | HAsString | HToBool: 0;
		case HCheckIsXml: 0;
		case HCast(_): 0;
		case HTypeof: 0;
		case HInstanceOf: -1;
		case HIncrReg(_) | HDecrReg(_) | HIncrIReg(_) | HDecrIReg(_): 0;
		case HThis: 1;
		case HDebugReg(_) | HDebugLine(_) | HBreakPointLine(_) | HTimestamp | HDebugFile(_): 0;
		case HOp(op):
			(switch op {
				case A3ONeg | A3OINeg | A3OIncr | A3ODecr | A3ONot | A3OBitNot | A3OIIncr | A3OIDecr: 0;
				case A3OMemGet8 | A3OMemGet16 | A3OMemGet32 | A3OMemGetFloat | A3OMemGetDouble | A3OSign1 | A3OSign8 | A3OSign16: 0;
				case A3OMemSet8 | A3OMemSet16 | A3OMemSet32 | A3OMemSetFloat | A3OMemSetDouble: -2;
				case _: -1;
			});
		case HUnk(_): assertFalse();
	}

	// port: ExtString.String.nsplit; an empty string has no parts.
	static function nsplit(s:String, sep:String):Array<String> return s == "" ? [] : s.split(sep);

	static inline function get<T>(t:Vector<T>, i:Index):T return As3parse.iget(t, i);

	static inline function no_nz(i:IndexNz):Index return As3parse.no_nz(i);

	static inline function idx(n:Index):Int return n - 1;

	static function ident(ctx:ParseCtx, i:Index):HlIdent return get(ctx.as3.as3_idents, i);

	static function name(ctx:ParseCtx, n:Index):HlName return ctx.names[idx(n)];

	static function method_type(ctx:ParseCtx, n:IndexNz):HlMethod return ctx.methods[idx(no_nz(n))];

	static function getclass(ctx:ParseCtx, n:IndexNz):HlClass return ctx.classes[idx(no_nz(n))];

	static function parse_opcode(ctx:ParseCtx, i:Int, op:As3Opcode):HlOpcode return switch op {
		case A3BreakPoint: HBreakPoint;
		case A3Nop: HNop;
		case A3Throw: HThrow;
		case A3GetSuper(n): HGetSuper(name(ctx, n));
		case A3SetSuper(n): HSetSuper(name(ctx, n));
		case A3DxNs(s): HDxNs(ident(ctx, s));
		case A3DxNsLate: HDxNsLate;
		case A3RegKill(r): HRegKill(r);
		case A3Label: HLabel;
		case A3Jump(j, n):
			ctx.jumps.unshift({i: i, pos: ctx.pos});
			HJump(j, n);
		case A3Switch(n, infos):
			ctx.jumps.unshift({i: i, pos: ctx.pos - As3code.length(op)});
			HSwitch(n, infos);
		case A3PushWith: HPushWith;
		case A3PopScope: HPopScope;
		case A3ForIn: HForIn;
		case A3HasNext: HHasNext;
		case A3Null: HNull;
		case A3Undefined: HUndefined;
		case A3ForEach: HForEach;
		case A3SmallInt(n): HSmallInt(n);
		case A3Int(n): HInt(n);
		case A3True: HTrue;
		case A3False: HFalse;
		case A3NaN: HNaN;
		case A3Pop: HPop;
		case A3Dup: HDup;
		case A3Swap: HSwap;
		case A3String(i): HString(ident(ctx, i));
		case A3IntRef(i): HIntRef(get(ctx.as3.as3_ints, i));
		case A3UIntRef(i): HUIntRef(get(ctx.as3.as3_uints, i));
		case A3Float(f): HFloat(get(ctx.as3.as3_floats, f));
		case A3Scope: HScope;
		case A3Namespace(n): HNamespace(ctx.namespaces[idx(n)]);
		case A3Next(r1, r2): HNext(r1, r2);
		case A3Function(f): HFunction(method_type(ctx, f));
		case A3CallStack(n): HCallStack(n);
		case A3Construct(n): HConstruct(n);
		case A3CallMethod(s, n): HCallMethod(s, n);
		case A3CallStatic(m, n): HCallStatic(ctx.methods[idx(m)], n);
		case A3CallSuper(p, n): HCallSuper(name(ctx, p), n);
		case A3CallProperty(p, n): HCallProperty(name(ctx, p), n);
		case A3RetVoid: HRetVoid;
		case A3Ret: HRet;
		case A3ConstructSuper(n): HConstructSuper(n);
		case A3ConstructProperty(p, n): HConstructProperty(name(ctx, p), n);
		case A3CallPropLex(p, n): HCallPropLex(name(ctx, p), n);
		case A3CallSuperVoid(p, n): HCallSuperVoid(name(ctx, p), n);
		case A3CallPropVoid(p, n): HCallPropVoid(name(ctx, p), n);
		case A3ApplyType(n): HApplyType(n);
		case A3Object(n): HObject(n);
		case A3Array(n): HArray(n);
		case A3NewBlock: HNewBlock;
		case A3ClassDef(n): HClassDef(getclass(ctx, n));
		case A3GetDescendants(p): HGetDescendants(name(ctx, p));
		case A3Catch(n): HCatch(n);
		case A3FindPropStrict(p): HFindPropStrict(name(ctx, p));
		case A3FindProp(p): HFindProp(name(ctx, p));
		case A3FindDefinition(p): HFindDefinition(name(ctx, p));
		case A3GetLex(p): HGetLex(name(ctx, p));
		case A3SetProp(p): HSetProp(name(ctx, p));
		case A3Reg(r): HReg(r);
		case A3SetReg(r): HSetReg(r);
		case A3GetGlobalScope: HGetGlobalScope;
		case A3GetScope(n): HGetScope(n);
		case A3GetProp(p): HGetProp(name(ctx, p));
		case A3InitProp(p): HInitProp(name(ctx, p));
		case A3DeleteProp(p): HDeleteProp(name(ctx, p));
		case A3GetSlot(n): HGetSlot(n);
		case A3SetSlot(n): HSetSlot(n);
		case A3ToString: HToString;
		case A3ToXml: HToXml;
		case A3ToXmlAttr: HToXmlAttr;
		case A3ToInt: HToInt;
		case A3ToUInt: HToUInt;
		case A3ToNumber: HToNumber;
		case A3ToBool: HToBool;
		case A3ToObject: HToObject;
		case A3CheckIsXml: HCheckIsXml;
		case A3Cast(p): HCast(name(ctx, p));
		case A3AsAny: HAsAny;
		case A3AsString: HAsString;
		case A3AsType(p): HAsType(name(ctx, p));
		case A3AsObject: HAsObject;
		case A3IncrReg(r): HIncrReg(r);
		case A3DecrReg(r): HDecrReg(r);
		case A3Typeof: HTypeof;
		case A3InstanceOf: HInstanceOf;
		case A3IsType(p): HIsType(name(ctx, p));
		case A3IncrIReg(r): HIncrIReg(r);
		case A3DecrIReg(r): HDecrIReg(r);
		case A3This: HThis;
		case A3SetThis: HSetThis;
		case A3DebugReg(id, r, n): HDebugReg(ident(ctx, id), r, n);
		case A3DebugLine(n): HDebugLine(n);
		case A3DebugFile(p): HDebugFile(ident(ctx, p));
		case A3BreakPointLine(n): HBreakPointLine(n);
		case A3Timestamp: HTimestamp;
		case A3Op(op): HOp(op);
		case A3Unk(n): HUnk(n);
	}

	static function parse_code(ctx:ParseCtx, f:As3Function, trys:Vector<HlTryCatch>):Array<HlOpcode> {
		var code = f.fun3_code;
		var old_pos = ctx.pos, old_jumps = ctx.jumps;
		var indexes:Array<Int> = [];
		ctx.pos = 0;
		ctx.jumps = [];
		function codepos(pos:Int, delta:Int):Int {
			// port: MultiArray.get raises outside the array (caught: -1).
			var p = pos + delta;
			var id = (if (p >= 0 && p < indexes.length) indexes[p] else -1);
			if (id == -1) {
				/*Printf.eprintf "MISALIGNED JUMP AT %d %c %d IN #%d\n" pos (if delta < 0 then '-' else '+') (if delta < 0 then -delta else delta) (idx (no_nz f.fun3_id));*/
				if (pos < 0 || pos >= indexes.length) throw new core.ds.InvalidArgument("index out of bounds");
				return indexes[pos]; /* jump 0 */
			} else
				return id;
		}
		var hcode = [];
		for (i in 0...code.length) {
			var op = code[i];
			var len = As3code.length(op);
			indexes.push(i);
			for (k in 2...len + 1) indexes.push(-1);
			ctx.pos = ctx.pos + len;
			hcode.push(parse_opcode(ctx, i, op));
		}
		/* in case we have a dead-jump at the end of code */
		indexes.push(code.length);
		/* patch jumps */
		for (jp in ctx.jumps) {
			var j = jp.i, pos = jp.pos;
			hcode[j] = (switch hcode[j] {
				case HJump(jc, n):
					HJump(jc, codepos(pos, n) - j);
				case HSwitch(n, infos):
					HSwitch(codepos(pos, n) - j, [for (n in infos) codepos(pos, n) - j]);
				case _:
					assertFalse();
			});
		}
		/* patch try/catches */
		for (i in 0...trys.length) {
			var t = trys[i];
			trys[i] = {
				hltc_start: codepos(0, t.hltc_start),
				hltc_end: codepos(0, t.hltc_end),
				hltc_handle: codepos(0, t.hltc_handle),
				hltc_type: t.hltc_type,
				hltc_name: t.hltc_name,
			};
		}
		ctx.pos = old_pos;
		ctx.jumps = old_jumps;
		return hcode;
	}

	static function parse_metadata(ctx:ParseCtx, m:As3Metadata):HlMetadata {
		return {
			hlmeta_name: ident(ctx, m.meta3_name),
			hlmeta_data: m.meta3_data.map(d -> {k: d.k == null ? null : ident(ctx, d.k), v: ident(ctx, d.v)}),
		};
	}

	static function parse_method(ctx:ParseCtx, m:As3Method):HlMethodField {
		return {
			hlm_type: method_type(ctx, m.m3_type),
			hlm_final: m.m3_final,
			hlm_override: m.m3_override,
			hlm_kind: m.m3_kind,
		};
	}

	static function parse_value(ctx:ParseCtx, v:As3Value):HlValue return switch v {
		case A3VNone: HVNone;
		case A3VNull: HVNull;
		case A3VBool(b): HVBool(b);
		case A3VString(s): HVString(ident(ctx, s));
		case A3VInt(i): HVInt(get(ctx.as3.as3_ints, i));
		case A3VUInt(i): HVUInt(get(ctx.as3.as3_uints, i));
		case A3VFloat(f): HVFloat(get(ctx.as3.as3_floats, f));
		case A3VNamespace(n, ns): HVNamespace(n, ctx.namespaces[idx(ns)]);
	}

	static function parse_var(ctx:ParseCtx, v:As3Var):HlVarField {
		return {
			hlv_type: v.v3_type == null ? null : name(ctx, v.v3_type),
			hlv_value: parse_value(ctx, v.v3_value),
			hlv_const: v.v3_const,
		};
	}

	static function parse_field_kind(ctx:ParseCtx, k:As3FieldKind):HlFieldKind return switch k {
		case A3FMethod(m): HFMethod(parse_method(ctx, m));
		case A3FVar(v): HFVar(parse_var(ctx, v));
		case A3FFunction(f): HFFunction(method_type(ctx, f));
		case A3FClass(c): HFClass(getclass(ctx, c));
	}

	static function parse_field(ctx:ParseCtx, f:As3Field):HlField {
		return {
			hlf_name: name(ctx, f.f3_name),
			hlf_slot: f.f3_slot,
			hlf_kind: parse_field_kind(ctx, f.f3_kind),
			hlf_metas: switch f.f3_metas {
				case null: null;
				case a: a.map(i -> parse_metadata(ctx, get(ctx.as3.as3_metadatas, no_nz(i))));
			},
		};
	}

	static function parse_namespace(ctx:ParseCtx, ns:As3Namespace):HlNamespace return switch ns {
		case A3NPrivate(id): HNPrivate(id == null ? null : ident(ctx, id));
		case A3NPublic(id): HNPublic(id == null ? null : ident(ctx, id));
		case A3NInternal(id): HNInternal(id == null ? null : ident(ctx, id));
		case A3NProtected(id): HNProtected(ident(ctx, id));
		case A3NNamespace(id): HNNamespace(ident(ctx, id));
		case A3NExplicit(id): HNExplicit(ident(ctx, id));
		case A3NStaticProtected(id): HNStaticProtected(id == null ? null : ident(ctx, id));
	}

	static function parse_nset(ctx:ParseCtx, l:As3NsSet):HlNsSet return [for (n in l) ctx.namespaces[idx(n)]];

	static function parse_name(names:Vector<As3MultiName>, ctx:ParseCtx, n:As3MultiName):HlName return switch n {
		case A3MName(id, ns):
			switch ctx.namespaces[idx(ns)] {
				case HNPublic(p):
					var pack = (switch p {
						case null: [];
						case i: nsplit(i, ".");
					});
					HMPath(pack, ident(ctx, id));
				case ns:
					HMName(ident(ctx, id), ns);
			}
		case A3MNSAny(id): HMNSAny(ident(ctx, id));
		case A3MAny: HMAny;
		case A3MMultiName(id, ns): HMMultiName(id == null ? null : ident(ctx, id), ctx.nsets[idx(ns)]);
		case A3MRuntimeName(id): HMRuntimeName(ident(ctx, id));
		case A3MRuntimeNameLate: HMRuntimeNameLate;
		case A3MMultiNameLate(ns): HMMultiNameLate(ctx.nsets[idx(ns)]);
		case A3MAttrib(multi): HMAttrib(parse_name(names, ctx, multi));
		case A3MParams(id, pl):
			// port: OCaml evaluates the constructor arguments right to left.
			var params = [for (id in pl) if (idx(id) == -1) HMAny else parse_name(names, ctx, names[idx(id)])];
			HMParams(parse_name(names, ctx, names[idx(id)]), params);
	}

	static function parse_try_catch(ctx:ParseCtx, t:As3TryCatch):HlTryCatch {
		return {
			hltc_start: t.tc3_start,
			hltc_end: t.tc3_end,
			hltc_handle: t.tc3_handle,
			hltc_type: t.tc3_type == null ? null : name(ctx, t.tc3_type),
			hltc_name: t.tc3_name == null ? null : name(ctx, t.tc3_name),
		};
	}

	static function parse_function(ctx:ParseCtx, f:As3Function):HlFunction {
		return {
			hlf_stack_size: f.fun3_stack_size,
			hlf_nregs: f.fun3_nregs,
			hlf_init_scope: f.fun3_init_scope,
			hlf_max_scope: f.fun3_max_scope,
			hlf_code: [], /* keep for later */
			hlf_trys: f.fun3_trys.map(t -> parse_try_catch(ctx, t)),
			hlf_locals: f.fun3_locals.map(f -> {
				if (f.f3_metas != null) assertFalse();
				switch f.f3_kind {
					case A3FVar(v):
						/* v3_value can be <> None if it's a fun parameter with a default value
							- which looks like a bug of the AS3 compiler */
						({
							name: name(ctx, f.f3_name),
							type: v.v3_type == null ? null : name(ctx, v.v3_type),
							slot: f.f3_slot,
							const: v.v3_const
						} : HlLocal);
					case _:
						assertFalse();
				}
			}),
		};
	}

	static function parse_method_type(ctx:ParseCtx, idx:Int, f:Null<As3Function>):HlMethod {
		var m = ctx.as3.as3_method_types[idx];
		var r = new HlMethod();
		r.hlmt_index = idx + ctx.delta_mt;
		r.hlmt_ret = m.mt3_ret == null ? null : name(ctx, m.mt3_ret);
		r.hlmt_args = [for (a in m.mt3_args) a == null ? null : name(ctx, a)];
		r.hlmt_native = m.mt3_native;
		r.hlmt_var_args = m.mt3_var_args;
		r.hlmt_arguments_defined = m.mt3_arguments_defined;
		r.hlmt_uses_dxns = m.mt3_uses_dxns;
		r.hlmt_new_block = m.mt3_new_block;
		r.hlmt_unused_flag = m.mt3_unused_flag;
		r.hlmt_debug_name = m.mt3_debug_name == null ? null : ident(ctx, m.mt3_debug_name);
		r.hlmt_dparams = m.mt3_dparams == null ? null : [for (v in m.mt3_dparams) parse_value(ctx, v)];
		r.hlmt_pnames = m.mt3_pnames == null ? null : [for (i in m.mt3_pnames) i == null ? null : ident(ctx, i)];
		r.hlmt_function = f == null ? null : parse_function(ctx, f);
		return r;
	}

	static function parse_class(ctx:ParseCtx, c:As3Class, s:As3Static, index:Int):HlClass {
		var r = new HlClass();
		r.hlc_index = index + ctx.delta_cl;
		r.hlc_name = name(ctx, c.cl3_name);
		r.hlc_super = c.cl3_super == null ? null : name(ctx, c.cl3_super);
		r.hlc_sealed = c.cl3_sealed;
		r.hlc_final = c.cl3_final;
		r.hlc_interface = c.cl3_interface;
		r.hlc_namespace = c.cl3_namespace == null ? null : ctx.namespaces[idx(c.cl3_namespace)];
		r.hlc_implements = c.cl3_implements.map(n -> name(ctx, n));
		r.hlc_construct = method_type(ctx, c.cl3_construct);
		r.hlc_fields = c.cl3_fields.map(f -> parse_field(ctx, f));
		r.hlc_static_construct = method_type(ctx, s.st3_method);
		r.hlc_static_fields = s.st3_fields.map(f -> parse_field(ctx, f));
		return r;
	}

	static function parse_static(ctx:ParseCtx, s:As3Static):HlStatic {
		return {
			hls_method: method_type(ctx, s.st3_method),
			hls_fields: s.st3_fields.map(f -> parse_field(ctx, f)),
		};
	}

	public static function parse(?delta_mt:Int = 0, ?delta_cl:Int = 0, t:As3Tag):HlTag {
		var ctx = new ParseCtx(t, delta_mt, delta_cl);
		ctx.namespaces = t.as3_namespaces.map(ns -> parse_namespace(ctx, ns));
		ctx.nsets = t.as3_nsets.map(l -> parse_nset(ctx, l));
		ctx.names = t.as3_names.map(n -> parse_name(t.as3_names, ctx, n));
		// port: Hashtbl.add/find: the latest function of a method index wins.
		var hfunctions = new Map<Int, As3Function>();
		for (f in t.as3_functions) hfunctions.set(idx(no_nz(f.fun3_id)), f);
		ctx.methods = t.as3_method_types.mapi((i, _) -> parse_method_type(ctx, i, hfunctions.get(i)));
		ctx.classes = t.as3_classes.mapi((i, c) -> parse_class(ctx, c, t.as3_statics[i], i));
		var inits = [for (s in t.as3_inits) parse_static(ctx, s)];
		for (f in t.as3_functions) {
			switch (method_type(ctx, f.fun3_id)).hlmt_function {
				case null:
					assertFalse();
				case fl:
					fl.hlf_code = parse_code(ctx, f, fl.hlf_trys);
			}
		}
		return inits;
	}

	/* ************************************************************************ */
	/*			FLATTEN															*/
	/* ************************************************************************ */
	static function new_lookup<H, I>(f:FlattenCtx->H->I, key:H->String):Lookup<H, I> return new Lookup(f, key);

	static function new_index_lookup<H, I>(l:Array<H>, f:FlattenCtx->H->I):IndexLookup<H, I> {
		var a:Array<Null<I>> = [];
		for (_ in l) a.push(null);
		return new IndexLookup(l, a, f);
	}

	static inline function lookup_array<H, I>(l:Lookup<H, I>):Vector<I> {
		var r = new Vector<I>(l.a.length);
		for (i in 0...r.length) r[i] = l.a[i];
		return r;
	}

	static inline function lookup_index_array<H, I>(l:IndexLookup<H, I>):Vector<I> {
		var r = new Vector<I>(l.ordered_array.length);
		for (i in 0...r.length) {
			var x = l.ordered_array[i];
			if (x == null) assertFalse();
			r[i] = x;
		}
		return r;
	}

	static function lookup<H, I>(ctx:FlattenCtx, l:Lookup<H, I>, item:H):Index {
		var k = l.key(item);
		var idx = l.h.get(k);
		if (idx == null) {
			var i = l.a.length;
			/* set dummy value for recursion */
			l.a.push(null);
			l.h.set(k, i + 1);
			l.a[i] = l.f(ctx, item);
			idx = i + 1;
		}
		return idx;
	}

	static function lookup_index_nz<H, I>(ctx:FlattenCtx, l:IndexLookup<H, I>, item:H):IndexNz {
		var idx = -1;
		for (n in 0...l.ordered_list.length) if (l.ordered_list[n] == item) {
			idx = n;
			break;
		}
		if (idx < 0) assertFalse();
		if (l.ordered_array[idx] == null) {
			/* set dummy value for recursion */
			l.ordered_array[idx] = cast l.dummy;
			l.ordered_array[idx] = l.map_f(ctx, item);
		}
		return idx;
	}

	static function lookup_nz<H, I>(ctx:FlattenCtx, l:Lookup<H, I>, item:H):IndexNz return lookup(ctx, l, item) - 1;

	static function lookup_ident(ctx:FlattenCtx, i:HlIdent):Index return lookup(ctx, ctx.fidents, i);

	static function lookup_name(ctx:FlattenCtx, n:HlName):Index return lookup(ctx, ctx.fnames, n);

	static function lookup_method(ctx:FlattenCtx, m:HlMethod):IndexNz return lookup_index_nz(ctx, ctx.fmethods, m);

	static function lookup_class(ctx:FlattenCtx, c:HlClass):IndexNz return lookup_index_nz(ctx, ctx.fclasses, c);

	static inline function opt<A, B>(f:FlattenCtx->A->B, ctx:FlattenCtx, x:Null<A>):Null<B> return x == null ? null : f(ctx, x);

	// port: OCaml evaluates constructor arguments, tuples and record fields
	// (in declaration order) right to left; the lookups in this section keep
	// that order, which decides the pool indices.
	static function flatten_namespace(ctx:FlattenCtx, ns:HlNamespace):As3Namespace return switch ns {
		case HNPrivate(i): A3NPrivate(opt(lookup_ident, ctx, i));
		case HNPublic(i): A3NPublic(opt(lookup_ident, ctx, i));
		case HNInternal(i): A3NInternal(opt(lookup_ident, ctx, i));
		case HNProtected(i): A3NProtected(lookup_ident(ctx, i));
		case HNNamespace(i): A3NNamespace(lookup_ident(ctx, i));
		case HNExplicit(i): A3NExplicit(lookup_ident(ctx, i));
		case HNStaticProtected(i): A3NStaticProtected(opt(lookup_ident, ctx, i));
	}

	static function flatten_ns_set(ctx:FlattenCtx, n:HlNsSet):As3NsSet return [for (ns in n) lookup(ctx, ctx.fnamespaces, ns)];

	static function flatten_name(ctx:FlattenCtx, n:HlName):As3MultiName return switch n {
		case HMPath(pack, i):
			var ns = HNPublic(switch pack {
				case []: null;
				case l: l.join(".");
			});
			var nsi = lookup(ctx, ctx.fnamespaces, ns);
			A3MName(lookup_ident(ctx, i), nsi);
		case HMName(i, n):
			var nsi = lookup(ctx, ctx.fnamespaces, n);
			A3MName(lookup_ident(ctx, i), nsi);
		case HMNSAny(i): A3MNSAny(lookup_ident(ctx, i));
		case HMAny: A3MAny;
		case HMMultiName(i, ns):
			var nsi = lookup(ctx, ctx.fnsets, ns);
			A3MMultiName(opt(lookup_ident, ctx, i), nsi);
		case HMRuntimeName(i): A3MRuntimeName(lookup_ident(ctx, i));
		case HMRuntimeNameLate: A3MRuntimeNameLate;
		case HMMultiNameLate(ns): A3MMultiNameLate(lookup(ctx, ctx.fnsets, ns));
		case HMAttrib(n): A3MAttrib(flatten_name(ctx, n));
		case HMParams(i, nl):
			var pl = [for (n in nl) lookup_name(ctx, n)];
			A3MParams(lookup_name(ctx, i), pl);
	}

	static function flatten_meta(ctx:FlattenCtx, m:HlMetadata):As3Metadata {
		var data = m.hlmeta_data.map(d -> {
			var v = lookup_ident(ctx, d.v);
			{k: opt(lookup_ident, ctx, d.k), v: v};
		});
		return {
			meta3_name: lookup_ident(ctx, m.hlmeta_name),
			meta3_data: data,
		};
	}

	static function flatten_value(ctx:FlattenCtx, v:HlValue):As3Value return switch v {
		case HVNone: A3VNone;
		case HVNull: A3VNull;
		case HVBool(b): A3VBool(b);
		case HVString(s): A3VString(lookup_ident(ctx, s));
		case HVInt(i): A3VInt(lookup(ctx, ctx.fints, i));
		case HVUInt(i): A3VUInt(lookup(ctx, ctx.fuints, i));
		case HVFloat(f): A3VFloat(lookup(ctx, ctx.ffloats, f));
		case HVNamespace(n, ns): A3VNamespace(n, lookup(ctx, ctx.fnamespaces, ns));
	}

	static function flatten_field(ctx:FlattenCtx, f:HlField):As3Field {
		var metas = switch f.hlf_metas {
			case null: null;
			case a: a.map(m -> lookup_nz(ctx, ctx.fmetas, m));
		};
		var kind = switch f.hlf_kind {
			case HFMethod(m):
				A3FMethod({
					m3_type: lookup_method(ctx, m.hlm_type),
					m3_final: m.hlm_final,
					m3_override: m.hlm_override,
					m3_kind: m.hlm_kind,
				});
			case HFVar(v):
				var value = flatten_value(ctx, v.hlv_value);
				var t = opt(lookup_name, ctx, v.hlv_type);
				A3FVar({
					v3_type: t,
					v3_value: value,
					v3_const: v.hlv_const,
				});
			case HFFunction(f):
				A3FFunction(lookup_method(ctx, f));
			case HFClass(c):
				A3FClass(lookup_class(ctx, c));
		};
		var name = lookup_name(ctx, f.hlf_name);
		return {
			f3_name: name,
			f3_slot: f.hlf_slot,
			f3_kind: kind,
			f3_metas: metas,
		};
	}

	static function flatten_class(ctx:FlattenCtx, c:HlClass):{cl:As3Class, st:As3Static} {
		var st_fields = c.hlc_static_fields.map(f -> flatten_field(ctx, f));
		var st_method = lookup_method(ctx, c.hlc_static_construct);
		var st:As3Static = {
			st3_method: st_method,
			st3_fields: st_fields,
		};
		var fields = c.hlc_fields.map(f -> flatten_field(ctx, f));
		var construct = lookup_method(ctx, c.hlc_construct);
		var impls = c.hlc_implements.map(n -> lookup_name(ctx, n));
		var namespace = opt((ctx, ns) -> lookup(ctx, ctx.fnamespaces, ns), ctx, c.hlc_namespace);
		var sup = opt(lookup_name, ctx, c.hlc_super);
		var name = lookup_name(ctx, c.hlc_name);
		var cl:As3Class = {
			cl3_name: name,
			cl3_super: sup,
			cl3_sealed: c.hlc_sealed,
			cl3_final: c.hlc_final,
			cl3_interface: c.hlc_interface,
			cl3_namespace: namespace,
			cl3_implements: impls,
			cl3_construct: construct,
			cl3_fields: fields,
		};
		return {cl: cl, st: st};
	}

	static function flatten_opcode(ctx:FlattenCtx, i:Int, op:HlOpcode):As3Opcode return switch op {
		case HBreakPoint: A3BreakPoint;
		case HNop: A3Nop;
		case HThrow: A3Throw;
		case HGetSuper(n): A3GetSuper(lookup_name(ctx, n));
		case HSetSuper(n): A3SetSuper(lookup_name(ctx, n));
		case HDxNs(s): A3DxNs(lookup_ident(ctx, s));
		case HDxNsLate: A3DxNsLate;
		case HRegKill(r): A3RegKill(r);
		case HLabel: A3Label;
		case HJump(j, n):
			ctx.fjumps.unshift(i);
			A3Jump(j, n);
		case HSwitch(n, l):
			ctx.fjumps.unshift(i);
			A3Switch(n, l);
		case HPushWith: A3PushWith;
		case HPopScope: A3PopScope;
		case HForIn: A3ForIn;
		case HHasNext: A3HasNext;
		case HNull: A3Null;
		case HUndefined: A3Undefined;
		case HForEach: A3ForEach;
		case HSmallInt(n): A3SmallInt(n);
		case HInt(n): A3Int(n);
		case HTrue: A3True;
		case HFalse: A3False;
		case HNaN: A3NaN;
		case HPop: A3Pop;
		case HDup: A3Dup;
		case HSwap: A3Swap;
		case HString(s): A3String(lookup_ident(ctx, s));
		case HIntRef(i): A3IntRef(lookup(ctx, ctx.fints, i));
		case HUIntRef(i): A3UIntRef(lookup(ctx, ctx.fuints, i));
		case HFloat(f): A3Float(lookup(ctx, ctx.ffloats, f));
		case HScope: A3Scope;
		case HNamespace(n): A3Namespace(lookup(ctx, ctx.fnamespaces, n));
		case HNext(r1, r2): A3Next(r1, r2);
		case HFunction(m): A3Function(lookup_method(ctx, m));
		case HCallStack(n): A3CallStack(n);
		case HConstruct(n): A3Construct(n);
		case HCallMethod(s, n): A3CallMethod(s, n);
		case HCallStatic(m, n): A3CallStatic(lookup_method(ctx, m) + 1, n);
		case HCallSuper(i, n): A3CallSuper(lookup_name(ctx, i), n);
		case HCallProperty(i, n): A3CallProperty(lookup_name(ctx, i), n);
		case HRetVoid: A3RetVoid;
		case HRet: A3Ret;
		case HConstructSuper(n): A3ConstructSuper(n);
		case HConstructProperty(i, n): A3ConstructProperty(lookup_name(ctx, i), n);
		case HCallPropLex(i, n): A3CallPropLex(lookup_name(ctx, i), n);
		case HCallSuperVoid(i, n): A3CallSuperVoid(lookup_name(ctx, i), n);
		case HCallPropVoid(i, n): A3CallPropVoid(lookup_name(ctx, i), n);
		case HApplyType(n): A3ApplyType(n);
		case HObject(n): A3Object(n);
		case HArray(n): A3Array(n);
		case HNewBlock: A3NewBlock;
		case HClassDef(c): A3ClassDef(lookup_class(ctx, c));
		case HGetDescendants(i): A3GetDescendants(lookup_name(ctx, i));
		case HCatch(n): A3Catch(n);
		case HFindPropStrict(i): A3FindPropStrict(lookup_name(ctx, i));
		case HFindProp(i): A3FindProp(lookup_name(ctx, i));
		case HFindDefinition(i): A3FindDefinition(lookup_name(ctx, i));
		case HGetLex(i): A3GetLex(lookup_name(ctx, i));
		case HSetProp(i): A3SetProp(lookup_name(ctx, i));
		case HReg(r): A3Reg(r);
		case HSetReg(r): A3SetReg(r);
		case HGetGlobalScope: A3GetGlobalScope;
		case HGetScope(n): A3GetScope(n);
		case HGetProp(n): A3GetProp(lookup_name(ctx, n));
		case HInitProp(n): A3InitProp(lookup_name(ctx, n));
		case HDeleteProp(n): A3DeleteProp(lookup_name(ctx, n));
		case HGetSlot(s): A3GetSlot(s);
		case HSetSlot(s): A3SetSlot(s);
		case HToString: A3ToString;
		case HToXml: A3ToXml;
		case HToXmlAttr: A3ToXmlAttr;
		case HToInt: A3ToInt;
		case HToUInt: A3ToUInt;
		case HToNumber: A3ToNumber;
		case HToBool: A3ToBool;
		case HToObject: A3ToObject;
		case HCheckIsXml: A3CheckIsXml;
		case HCast(n): A3Cast(lookup_name(ctx, n));
		case HAsAny: A3AsAny;
		case HAsString: A3AsString;
		case HAsType(n): A3AsType(lookup_name(ctx, n));
		case HAsObject: A3AsObject;
		case HIncrReg(r): A3IncrReg(r);
		case HDecrReg(r): A3DecrReg(r);
		case HTypeof: A3Typeof;
		case HInstanceOf: A3InstanceOf;
		case HIsType(t): A3IsType(lookup_name(ctx, t));
		case HIncrIReg(r): A3IncrIReg(r);
		case HDecrIReg(r): A3DecrIReg(r);
		case HThis: A3This;
		case HSetThis: A3SetThis;
		case HDebugReg(i, r, l): A3DebugReg(lookup_ident(ctx, i), r, l);
		case HDebugLine(l): A3DebugLine(l);
		case HDebugFile(f): A3DebugFile(lookup_ident(ctx, f));
		case HBreakPointLine(n): A3BreakPointLine(n);
		case HTimestamp: A3Timestamp;
		case HOp(op): A3Op(op);
		case HUnk(c): A3Unk(c);
	}

	static function flatten_code(ctx:FlattenCtx, hcode:Array<HlOpcode>, trys:Vector<HlTryCatch>):{code:Array<As3Opcode>, trys:Vector<As3TryCatch>} {
		var positions = [for (_ in 0...hcode.length + 1) 0];
		var pos = 0;
		var old = ctx.fjumps;
		ctx.fjumps = [];
		var code = [];
		for (i in 0...hcode.length) {
			var op = flatten_opcode(ctx, i, hcode[i]);
			pos = pos + As3code.length(op);
			positions[i + 1] = pos;
			code.push(op);
		}
		/* patch jumps */
		for (j in ctx.fjumps) {
			code[j] = switch code[j] {
				case A3Jump(jc, n):
					A3Jump(jc, positions[j + n] - positions[j + 1]);
				case A3Switch(n, infos):
					A3Switch(positions[j + n] - positions[j], [for (n in infos) positions[j + n] - positions[j]]);
				case _: assertFalse();
			}
		}
		/* patch trys */
		var trys = trys.map(t -> {
			// port: right-to-left record field evaluation (tc3_name first).
			var name = opt(lookup_name, ctx, t.hltc_name);
			var type = opt(lookup_name, ctx, t.hltc_type);
			({
				tc3_start: positions[t.hltc_start],
				tc3_end: positions[t.hltc_end],
				tc3_handle: positions[t.hltc_handle],
				tc3_type: type,
				tc3_name: name,
			} : As3TryCatch);
		});
		ctx.fjumps = old;
		return {code: code, trys: trys};
	}

	static function flatten_function(ctx:FlattenCtx, f:HlFunction, mid:IndexNz):As3Function {
		var r = flatten_code(ctx, f.hlf_code, f.hlf_trys);
		// port: right-to-left record field evaluation: fun3_locals, the last field, after the code (a let).
		var locals = f.hlf_locals.map(l -> {
			var t = opt(lookup_name, ctx, l.type);
			var name = lookup_name(ctx, l.name);
			({
				f3_name: name,
				f3_slot: l.slot,
				f3_kind: A3FVar({v3_type: t, v3_value: A3VNone, v3_const: l.const}),
				f3_metas: null,
			} : As3Field);
		});
		return {
			fun3_id: mid,
			fun3_stack_size: f.hlf_stack_size,
			fun3_nregs: f.hlf_nregs,
			fun3_init_scope: f.hlf_init_scope,
			fun3_max_scope: f.hlf_max_scope,
			fun3_code: r.code,
			fun3_trys: r.trys,
			fun3_locals: locals,
		};
	}

	static function flatten_method(ctx:FlattenCtx, m:HlMethod):As3MethodType {
		var mid = lookup_method(ctx, m);
		switch m.hlmt_function {
			case null:
			case f:
				var x = flatten_function(ctx, f, mid);
				ctx.ffunctions.unshift(x);
		}
		// port: right-to-left record field evaluation.
		var pnames = opt((ctx, l:Array<Null<HlIdent>>) -> [for (i in l) opt(lookup_ident, ctx, i)], ctx, m.hlmt_pnames);
		var dparams = opt((ctx, l:Array<HlValue>) -> [for (v in l) flatten_value(ctx, v)], ctx, m.hlmt_dparams);
		var debug_name = opt(lookup_ident, ctx, m.hlmt_debug_name);
		var args = [for (a in m.hlmt_args) opt(lookup_name, ctx, a)];
		var ret = opt(lookup_name, ctx, m.hlmt_ret);
		return {
			mt3_ret: ret,
			mt3_args: args,
			mt3_native: m.hlmt_native,
			mt3_var_args: m.hlmt_var_args,
			mt3_arguments_defined: m.hlmt_arguments_defined,
			mt3_uses_dxns: m.hlmt_uses_dxns,
			mt3_new_block: m.hlmt_new_block,
			mt3_unused_flag: m.hlmt_unused_flag,
			mt3_debug_name: debug_name,
			mt3_dparams: dparams,
			mt3_pnames: pnames,
		};
	}

	static function flatten_static(ctx:FlattenCtx, s:HlStatic):As3Static {
		// port: right-to-left record field evaluation.
		var fields = s.hls_fields.map(f -> flatten_field(ctx, f));
		var method = lookup_method(ctx, s.hls_method);
		return {
			st3_method: method,
			st3_fields: fields,
		};
	}

	static function browse_method(ctx:BrowseCtx, m:HlMethod):Void {
		if (ctx.ml.indexOf(m) < 0) {
			ctx.ml.unshift(m);
			switch m.hlmt_function {
				case null:
				case f:
					for (op in f.hlf_code) switch op {
						case HFunction(f) | HCallStatic(f, _): browse_method(ctx, f);
						case HClassDef(_): /* ignore, should be in fields list anyway */
						case _:
					}
			}
		}
	}

	static function browse_class(ctx:BrowseCtx, c:HlClass):Void {
		if (ctx.cl.indexOf(c) < 0) {
			ctx.cl.unshift(c);
			browse_method(ctx, c.hlc_construct);
			browse_method(ctx, c.hlc_static_construct);
			for (f in c.hlc_fields) browse_field(ctx, f);
			for (f in c.hlc_static_fields) browse_field(ctx, f);
		}
	}

	static function browse_field(ctx:BrowseCtx, f:HlField):Void {
		switch f.hlf_kind {
			case HFMethod(m): browse_method(ctx, m.hlm_type);
			case HFVar(_):
			case HFFunction(m): browse_method(ctx, m);
			case HFClass(c): browse_class(ctx, c);
		}
	}

	public static function flatten(t:HlTag):As3Tag {
		/* collect methods and classes, sort by index and force evaluation in order to keep order */
		var bctx:BrowseCtx = {ml: [], cl: []};
		for (s in t) {
			for (f in s.hls_fields) browse_field(bctx, f);
			browse_method(bctx, s.hls_method);
		}
		var classes = bctx.cl.copy();
		classes.reverse();
		haxe.ds.ArraySort.sort(classes, (c1, c2) -> c1.hlc_index - c2.hlc_index);
		var methods = bctx.ml.copy();
		methods.reverse();
		haxe.ds.ArraySort.sort(methods, (m1, m2) -> m1.hlmt_index - m2.hlmt_index);
		/* done */
		var ctx = new FlattenCtx();
		ctx.fints = new_lookup((_, x:HlInt) -> x, (i:HlInt) -> Std.string(i));
		ctx.fuints = new_lookup((_, x:HlUint) -> x, (i:HlUint) -> Std.string(i));
		ctx.ffloats = new_lookup((_, x:HlFloat) -> x, floatKey);
		ctx.fidents = new_lookup((_, x:HlIdent) -> x, (s:HlIdent) -> s);
		ctx.fnamespaces = new_lookup(flatten_namespace, nsKey);
		ctx.fnsets = new_lookup(flatten_ns_set, nsSetKey);
		ctx.fnames = new_lookup(flatten_name, nameKey);
		ctx.fmetas = new_lookup(flatten_meta, metaKey);
		ctx.fmethods = new_index_lookup(methods, flatten_method);
		ctx.fclasses = new_index_lookup(classes, flatten_class);
		ctx.fjumps = [];
		ctx.ffunctions = [];
		lookup_ident(ctx, "");
		var inits = t.mapToVector(s -> flatten_static(ctx, s));
		var classes = lookup_index_array(ctx.fclasses);
		return {
			as3_ints: lookup_array(ctx.fints),
			as3_uints: lookup_array(ctx.fuints),
			as3_floats: lookup_array(ctx.ffloats),
			as3_idents: lookup_array(ctx.fidents),
			as3_namespaces: lookup_array(ctx.fnamespaces),
			as3_nsets: lookup_array(ctx.fnsets),
			as3_names: lookup_array(ctx.fnames),
			as3_metadatas: lookup_array(ctx.fmetas),
			as3_method_types: lookup_index_array(ctx.fmethods),
			as3_classes: classes.map(c -> c.cl),
			as3_statics: classes.map(c -> c.st),
			as3_functions: VectorTools.ofArrayReversed(ctx.ffunctions),
			as3_inits: inits,
			as3_unknown: "",
		};
	}

	// port: the structural Hashtbl keys of the flatten lookups, as strings that
	// are equal exactly when OCaml's `compare` returns 0 (floats: every NaN is
	// one key, as is 0.0 with -0.0).
	static function floatKey(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (f == 0) return "0";
		var i = haxe.io.FPHelper.doubleToI64(f);
		return i.high + ":" + i.low;
	}

	static function optKey(s:Null<String>):String return s == null ? "N" : "S" + s.length + ":" + s;

	static function nsKey(ns:HlNamespace):String return switch ns {
		case HNPrivate(i): "a" + optKey(i);
		case HNPublic(i): "b" + optKey(i);
		case HNInternal(i): "c" + optKey(i);
		case HNProtected(i): "d" + optKey(i);
		case HNNamespace(i): "e" + optKey(i);
		case HNExplicit(i): "f" + optKey(i);
		case HNStaticProtected(i): "g" + optKey(i);
	}

	static function nsSetKey(l:HlNsSet):String return l.length + "[" + [for (ns in l) nsKey(ns)].join(",") + "]";

	public static function nameKey(n:HlName):String return switch n {
		case HMPath(pack, name): "P" + pack.length + "(" + [for (p in pack) optKey(p)].join("") + ")" + optKey(name);
		case HMName(i, ns): "N" + optKey(i) + nsKey(ns);
		case HMMultiName(i, ns): "M" + optKey(i) + nsSetKey(ns);
		case HMRuntimeName(i): "R" + optKey(i);
		case HMRuntimeNameLate: "L";
		case HMMultiNameLate(ns): "T" + nsSetKey(ns);
		case HMAttrib(n): "A(" + nameKey(n) + ")";
		case HMParams(n, pl): "X(" + nameKey(n) + ")" + pl.length + "[" + [for (p in pl) nameKey(p)].join(",") + "]";
		case HMNSAny(i): "Y" + optKey(i);
		case HMAny: "Z";
	}

	static function metaKey(m:HlMetadata):String
		return optKey(m.hlmeta_name) + m.hlmeta_data.length + "[" + [for (d in m.hlmeta_data) optKey(d.k) + optKey(d.v)].join(",") + "]";
}

private typedef BrowseCtx = {
	var ml:Array<HlMethod>;
	var cl:Array<HlClass>;
}

private class Lookup<H, I> {
	public final h:Map<String, Int> = new Map();
	public final a:Array<Null<I>> = [];
	public final f:FlattenCtx->H->I;
	public final key:H->String;

	public function new(f, key) {
		this.f = f;
		this.key = key;
	}
}

private class IndexLookup<H, I> {
	public final ordered_list:Array<H>;
	public final ordered_array:Array<Null<I>>;
	public final map_f:FlattenCtx->H->I;
	// port: `Obj.magic 0`, the placeholder that marks an entry as being flattened.
	public final dummy:Dynamic = {};

	public function new(l, a, f) {
		ordered_list = l;
		ordered_array = a;
		map_f = f;
	}
}

@:allow(libs.swflib.As3hlparse)
private class FlattenCtx {
	var fints:Lookup<HlInt, As3Int>;
	var fuints:Lookup<HlUint, As3Uint>;
	var ffloats:Lookup<HlFloat, As3Float>;
	var fidents:Lookup<HlIdent, As3Ident>;
	var fnamespaces:Lookup<HlNamespace, As3Namespace>;
	var fnsets:Lookup<HlNsSet, As3NsSet>;
	var fnames:Lookup<HlName, As3MultiName>;
	var fmetas:Lookup<HlMetadata, As3Metadata>;
	var fmethods:IndexLookup<HlMethod, As3MethodType>;
	var fclasses:IndexLookup<HlClass, {cl:As3Class, st:As3Static}>;
	var ffunctions:Array<As3Function>;
	var fjumps:Array<Int>;

	public function new() {}
}

@:allow(libs.swflib.As3hlparse)
private class ParseCtx {
	final as3:As3Tag;
	var namespaces:Vector<HlNamespace> = vector();
	var nsets:Vector<HlNsSet> = vector();
	var names:Vector<HlName> = vector();
	var methods:Vector<HlMethod> = vector();
	var classes:Vector<HlClass> = vector();
	var jumps:Array<{i:Int, pos:Int}> = [];
	var pos = 0;
	final delta_mt:Int;
	final delta_cl:Int;

	public function new(as3, delta_mt, delta_cl) {
		this.as3 = as3;
		this.delta_mt = delta_mt;
		this.delta_cl = delta_cl;
	}
}
