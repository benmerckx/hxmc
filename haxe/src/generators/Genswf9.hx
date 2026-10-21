/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package generators;

import haxe.ds.IntMap;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.Error;
import core.Meta;
import core.Define;
import core.Texpr;
import core.TOther.ExtType;
import core.TOther.TClassTools;
import core.ds.Exit;
import core.ds.NotFound;
import libs.swflib.As3;
import libs.swflib.As3hl;
import generators.FlashProps.*;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

enum TKind {
	KInt;
	KUInt;
	KFloat;
	KBool;
	KType(n:HlName);
	KDynamic;
	KNone;
}

class Register {
	public final rid:Int;
	public final rtype:TKind;
	public var rused:Bool;
	public var rinit:Bool;
	public var rcond:Bool;

	public function new(rid, rtype, rused, rinit, rcond) {
		this.rid = rid;
		this.rtype = rtype;
		this.rused = rused;
		this.rinit = rinit;
		this.rcond = rcond;
	}
}

// port: `'a access`; the read/write phantom type is the `forset` Bool of
// gen_access.
enum Access {
	VReg(r:Register);
	VId(n:HlName);
	VCast(n:HlName, k:TKind);
	VGlobal(n:HlName);
	VArray;
	VScope(s:HlSlot);
	VVolatile(n:HlName, k:Null<TKind>);
	VSuper(n:HlName);
}

enum Local {
	LReg(r:Register);
	LScope(s:HlSlot);
	LGlobal(n:HlName);
}

class CodeInfos {
	public var iregs:Array<Register>;
	public var ipos:Int;
	public var istack:Int;
	public var imax:Int;
	public var iscopes:Int;
	public var imaxscopes:Int;
	public var iloop:Int;
	public var icond:Bool;

	public function new() {}
}

typedef TryInfos = {
	var tr_pos:Int;
	var tr_end:Int;
	var tr_catch_pos:Int;
	var tr_type:T;
}

typedef BlockVar = {
	var slot:HlSlot;
	var name:String;
	var t:Null<HlName>;
}

class Context {
	/* globals */
	public var com:Gctx;
	public var debugger:Bool;
	public var swc:Bool;
	public var boot:GlobalTypePath;
	public var swf_protected:Bool;
	public var need_ctor_skip:Bool;
	/*
		Takes an argument list of `call(arg1, arg2, ...)` and if there is a trailing argument `...rest` then returns
		```
		if(rest.length == 0) call(arg1, arg2)
		else if(rest.length == 1) call(arg1, arg2, rest[0])
		else if(rest.length == 2) call(arg1, arg2, rest[0], rest[1])
		<... up to 20 rest args ...>
		else throw "Too many rest arguments"
		```
		otherwise returns `None`
	*/
	public var handle_spread_args:BasicTypes->Vector<TExpr>->T->(Vector<TExpr>->TExpr)->Null<TExpr>;
	public var cur_class:TClass;
	public var debug:Bool;
	public var last_line:Int;
	public var last_file:String;
	/* per-function */
	public var locals:IntMap<{v:TVar, l:Local}>;
	public var code:Array<HlOpcode>;
	public var infos:CodeInfos;
	public var trys:Array<TryInfos>; // port: chronological order (the OCaml list reversed)
	public var breaks:Array<Void->Void>;
	public var continues:Array<Int->Void>;
	public var in_static:Bool;
	public var block_vars:Array<BlockVar>; // port: most recent first, as the OCaml list
	public var try_scope_reg:Null<Register>;
	public var for_call:Bool;

	public function new() {}
}

class Genswf9 {
	static function die(msg:String = "", ?p:Pos):Dynamic return Globals.die(msg, "genswf9.ml", p);

	static function follow(t:T):T return switch TFunctions.follow(t) {
		case TAbstract(a, tl) if (!Meta.has(Meta.CoreType, a.aMeta)):
			follow(core.Abstract.getUnderlyingType(a, tl));
		case t:
			t;
	}

	static function invalid_expr(p:Pos):Dynamic return Error.abort("Invalid expression", p);

	static function stack_error(p:Pos):Dynamic return Error.abort("Stack error", p);

	// port: built on first use: hxmc initialises statics before the monomorph allocator.
	static var ethis_cache:Null<TExpr> = null;

	static var ethis(get, never):TExpr;

	static function get_ethis():TExpr {
		if (ethis_cache == null) ethis_cache = mk(TConst(TThis), mkMono(), nullPos);
		return ethis_cache;
	}
	static final dynamic_prop = HMMultiNameLate([HNPublic("")]);

	// port: OCaml's structural `=` on tkind (and the hl_name inside KType).
	static function kindEq(a:TKind, b:TKind):Bool return switch [a, b] {
		case [KInt, KInt] | [KUInt, KUInt] | [KFloat, KFloat] | [KBool, KBool] | [KDynamic, KDynamic] | [KNone, KNone]: true;
		case [KType(n1), KType(n2)]: nameEq(n1, n2);
		case _: false;
	}

	static function optEq(a:Null<String>, b:Null<String>):Bool return a == b;

	static function nsEq(a:HlNamespace, b:HlNamespace):Bool return switch [a, b] {
		case [HNPrivate(x), HNPrivate(y)] | [HNPublic(x), HNPublic(y)] | [HNInternal(x), HNInternal(y)] | [HNStaticProtected(x), HNStaticProtected(y)]:
			optEq(x, y);
		case [HNProtected(x), HNProtected(y)] | [HNNamespace(x), HNNamespace(y)] | [HNExplicit(x), HNExplicit(y)]: x == y;
		case _: false;
	}

	static function arrEq<A>(f:A->A->Bool, a:Array<A>, b:Array<A>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (!f(a[i], b[i])) return false;
		return true;
	}

	static function nameEq(a:HlName, b:HlName):Bool return switch [a, b] {
		case [HMPath(p1, n1), HMPath(p2, n2)]: arrEq((x, y) -> x == y, p1, p2) && n1 == n2;
		case [HMName(i1, ns1), HMName(i2, ns2)]: i1 == i2 && nsEq(ns1, ns2);
		case [HMMultiName(i1, ns1), HMMultiName(i2, ns2)]: optEq(i1, i2) && arrEq(nsEq, ns1, ns2);
		case [HMRuntimeName(i1), HMRuntimeName(i2)]: i1 == i2;
		case [HMRuntimeNameLate, HMRuntimeNameLate]: true;
		case [HMMultiNameLate(ns1), HMMultiNameLate(ns2)]: arrEq(nsEq, ns1, ns2);
		case [HMAttrib(n1), HMAttrib(n2)]: nameEq(n1, n2);
		case [HMParams(n1, l1), HMParams(n2, l2)]: nameEq(n1, n2) && arrEq(nameEq, l1, l2);
		case [HMNSAny(i1), HMNSAny(i2)]: i1 == i2;
		case [HMAny, HMAny]: true;
		case _: false;
	}

	static function isSpecialCompare(e1:TExpr, e2:TExpr):Null<TClass> {
		switch [e1.eexpr, e2.eexpr] {
			case [TConst(TNull), _] | [_, TConst(TNull)]: return null;
			case _:
		}
		return switch [follow(e1.etype), follow(e2.etype)] {
			case [TInst(c = {clPath: {pack: ["flash"], name: "NativeXml"}}, _), _] | [_, TInst(c = {clPath: {pack: ["flash"], name: "NativeXml"}}, _)]: c;
			case _: null;
		}
	}

	static function write(ctx:Context, op:HlOpcode):Void {
		ctx.code.push(op);
		ctx.infos.ipos = ctx.infos.ipos + 1;
		var s = ctx.infos.istack + libs.swflib.As3hlparse.stack_delta(op);
		ctx.infos.istack = s;
		if (s > ctx.infos.imax) ctx.infos.imax = s;
		switch op {
			case HScope:
				var n = ctx.infos.iscopes + 1;
				ctx.infos.iscopes = n;
				if (n > ctx.infos.imaxscopes) ctx.infos.imaxscopes = n;
			case HPopScope:
				ctx.infos.iscopes = ctx.infos.iscopes - 1;
			case _:
		}
	}

	static function jump(ctx:Context, cond:HlJump):Void->Void {
		var op = ctx.code.length;
		var p = ctx.infos.ipos;
		write(ctx, HJump(cond, 0));
		return function() {
			var delta = ctx.infos.ipos - p;
			ctx.code[op] = HJump(cond, delta);
		}
	}

	static function jump_back(ctx:Context):HlJump->Void {
		var p = ctx.infos.ipos;
		write(ctx, HLabel);
		return function(cond) {
			var delta = p - ctx.infos.ipos;
			write(ctx, HJump(cond, delta));
		}
	}

	static function path(pack:Array<String>, name:String):GlobalTypePath return {pack: pack, name: name};

	public static function real_path(path:GlobalTypePath):GlobalTypePath {
		return switch [path.pack, path.name] {
			case [[], "Int"]: {pack: [], name: "int"};
			case [[], "UInt"]: {pack: [], name: "uint"};
			case [["haxe"], "UInt32"]: {pack: [], name: "uint"};
			case [[], "Float"]: {pack: [], name: "Number"};
			case [[], "Bool"]: {pack: [], name: "Boolean"};
			case [[], "Enum"]: {pack: [], name: "Class"};
			case [[], "EnumValue"]: {pack: [], name: "Object"};
			case [["flash", "xml"], "XML"]: {pack: [], name: "XML"};
			case [["flash", "xml"], "XMLList"]: {pack: [], name: "XMLList"};
			case [["flash", "utils"], "QName"]: {pack: [], name: "QName"};
			case [["flash", "utils"], "Namespace"]: {pack: [], name: "Namespace"};
			case [["flash", "utils"], "Object"]: {pack: [], name: "Object"};
			case [["flash", "utils"], "Function"]: {pack: [], name: "Function"};
			case [["flash"], "FlashXml__"]: {pack: [], name: "Xml"};
			case [["flash", "errors"], "Error"]: {pack: [], name: "Error"};
			case [["flash"], "Vector"]: {pack: ["__AS3__", "vec"], name: "Vector"};
			case _: path;
		}
	}

	static function type_path(ctx:Context, path:GlobalTypePath):HlName {
		var p = real_path(path);
		return HMPath(p.pack, p.name);
	}

	static function follow_basic(t:T):T {
		return switch t {
			case TMono(r):
				(switch r.tmType {
					case null: t;
					case t: follow_basic(t);
				});
			case TLazy(f):
				follow_basic(lazyType(f));
			case TAbstract({aPath: {pack: [], name: "Null"}}, [tp]):
				(switch follow_basic(tp) {
					case TMono(_) | TFun(_) | TAbstract({aPath: {pack: [], name: "Int"}}, []) | TAbstract({aPath: {pack: [], name: "Float"}}, []) |
						TAbstract({aPath: {pack: ["haxe"], name: "UInt32"}}, []) | TAbstract({aPath: {pack: [], name: "Bool"}}, []) |
						TInst({clPath: {pack: ["haxe"], name: "Int32"}}, []): t;
					case t: t;
				});
			case TType({tPath: {pack: ["flash", "utils"], name: "Function"}}, []):
				t;
			case TType(t, tl):
				follow_basic(applyTypedef(t, tl));
			case TAbstract(a, pl) if (!Meta.has(Meta.CoreType, a.aMeta)):
				follow_basic(applyParams(a.aParams, pl, a.aThis));
			case _: t;
		}
	}

	static function type_id(ctx:Context, t:T):HlName {
		return switch follow_basic(t) {
			case TInst({clPath: {pack: ["haxe"], name: "Int32"}}, _):
				type_path(ctx, path([], "Int"));
			case TInst(c = {clPath: {pack: ["flash"], name: "Vector"}}, pl):
				function def() return HMParams(type_path(ctx, c.clPath), [for (t in pl) type_id(ctx, t)]);
				(switch pl {
					case [t]: switch follow(t) {
							case TInst({clKind: KTypeParameter(_)}, _): type_path(ctx, path([], "Object"));
							case _: def();
						}
					case _: def();
				});
			case TInst(c, _):
				(switch c.clKind {
					case KTypeParameter(ttp):
						(switch getConstraints(ttp) {
							case [t]: type_id(ctx, t);
							case _: type_path(ctx, path([], "Object"));
						});
					case _:
						type_path(ctx, c.clPath);
				});
			case TAbstract({aPath: {pack: [], name: "Null"}}, _):
				HMPath([], "Object");
			case TAbstract({aPath: {pack: ["flash"], name: "AnyType"}}, _):
				HMAny;
			case TAbstract(a, _) if (Meta.has(Meta.CoreType, a.aMeta)):
				type_path(ctx, a.aPath);
			case TFun(_) | TType({tPath: {pack: ["flash", "utils"], name: "Function"}}, []):
				type_path(ctx, path([], "Function"));
			case TAbstract({aPath: path = {pack: ["haxe"], name: "UInt32"}}, _):
				type_path(ctx, path);
			case TEnum(e = {ePath: {pack: ["flash"], name: "XmlType"}}, _) if (hasEnumFlag(e, EnExtern)):
				HMPath([], "String");
			case TEnum(e, _):
				type_path(ctx, e.ePath);
			case _:
				HMPath([], "Object");
		}
	}

	static function type_opt(ctx:Context, t:T):Null<HlName> {
		return switch follow_basic(t) {
			case TDynamic(_) | TMono(_) | TAbstract({aPath: {pack: [], name: "Void"}}, _): null;
			case _: type_id(ctx, t);
		}
	}

	static function type_void(ctx:Context, t:T):Null<HlName> {
		return switch follow(t) {
			case TEnum({ePath: {pack: [], name: "Void"}}, _) | TAbstract({aPath: {pack: [], name: "Void"}}, _): HMPath([], "void");
			case _: type_opt(ctx, t);
		}
	}

	static function classify(ctx:Context, t:T):TKind {
		return switch follow_basic(t) {
			case TAbstract({aPath: {pack: [], name: "Int"}}, _) | TInst({clPath: {pack: [], name: "Int"}}, _) | TInst({clPath: {pack: ["haxe"], name: "Int32"}}, _):
				KInt;
			case TAbstract({aPath: {pack: [], name: "Float"}}, _) | TInst({clPath: {pack: [], name: "Float"}}, _):
				KFloat;
			case TAbstract({aPath: {pack: [], name: "Bool"}}, _) | TEnum({ePath: {pack: [], name: "Bool"}}, _):
				KBool;
			case TAbstract({aPath: {pack: [], name: "Void"}}, _) | TEnum({ePath: {pack: [], name: "Void"}}, _):
				KDynamic;
			case TAbstract({aPath: {pack: ["flash"], name: "AnyType"}}, _):
				KDynamic;
			case TEnum(e = {ePath: {pack: ["flash"], name: "XmlType"}}, _) if (hasEnumFlag(e, EnExtern)):
				KType(HMPath([], "String"));
			case TEnum(e, _):
				KType(type_id(ctx, t));
			case TAbstract({aPath: {pack: ["haxe"], name: "UInt32"}}, _) | TType({tPath: {pack: [], name: "UInt"}}, _):
				KUInt;
			case TFun(_) | TType({tPath: {pack: ["flash", "utils"], name: "Function"}}, []):
				KType(HMPath([], "Function"));
			case TAnon(a):
				(switch a.aStatus {
					case ClassStatics(_): KNone;
					case _: KDynamic;
				});
			case TAbstract({aPath: {pack: ["flash", "utils"], name: "Object"}}, []):
				KType(HMPath([], "Object"));
			case TInst(_) | TAbstract(_):
				KType(type_id(ctx, t));
			case TMono(_) | TType(_) | TDynamic(_):
				KDynamic;
			case TLazy(_):
				die();
		}
	}

	/* some field identifiers might cause issues with SWC */
	static function reserved(i:String):String {
		return switch i {
			case "int": "_" + i;
			case _: i;
		}
	}

	static function ident(i:String):HlName return HMPath([], reserved(i));

	static function as3(p:String):HlName return HMName(p, HNNamespace("http://adobe.com/AS3/2006/builtin"));

	static function make_class_ns(c:TClass):String {
		return switch c.clPath {
			case {pack: [], name: n}: n;
			case {pack: p, name: n}: p.join(".") + ":" + n;
		}
	}

	static function is_cf_protected(cf:TClassField):Bool return Meta.has(Meta.Protected, cf.cfMeta);

	static function ns_access(cf:TClassField):Null<HlName> {
		var m = Meta.getOpt(Meta.Ns, cf.cfMeta);
		if (m == null) return null;
		return switch m.exprs {
			case [{expr: EConst(String(ns, _))}]:
				HMName(cf.cfName, HNNamespace(ns));
			case [{expr: EConst(String(ns, _))}, {expr: EConst(Ident("internal"))}]:
				HMName(cf.cfName, HNInternal(ns));
			case _: die();
		}
	}

	static function property(ctx:Context, fa:TFieldAccess, t:T):{id:HlName, k:Null<TKind>, closure:Bool} {
		var f = extractField(fa);
		var n = f == null ? null : ns_access(f);
		if (n != null) return {id: n, k: null, closure: false};
		switch fa {
			case FStatic(c, cf) if (is_cf_protected(cf)):
				return {id: HMName(reserved(cf.cfName), HNStaticProtected(make_class_ns(c))), k: null, closure: false};
			case _:
		}
		var p = fieldName(fa);
		inline function r(id:HlName, k:Null<TKind>, closure:Bool) return {id: id, k: k, closure: closure};
		return switch follow(t) {
			case TInst({clPath: {pack: [], name: "Array"}}, _):
				(switch p {
					case "length": r(ident(p), KInt, false); /* UInt in the spec */
					case "map" | "filter" if (Gctx.defined(ctx.com, Define.NoFlashOverride)): r(ident(p + "HX"), null, true);
					case "copy" | "insert" | "contains" | "remove" | "iterator" | "keyValueIterator" | "toString" | "map" | "filter" | "resize": r(ident(p), null, true);
					case _: r(as3(p), null, false);
				});
			case TInst({clPath: {pack: ["flash"], name: "Vector"}}, _):
				(switch p {
					case "length": r(ident(p), KInt, false); /* UInt in the spec */
					case "fixed" | "toString": r(ident(p), null, false);
					case "iterator": r(ident(p), null, true);
					case _: r(as3(p), null, false);
				});
			case TInst({clPath: {pack: [], name: "String"}}, _):
				(switch p {
					case "length" /* Int in AS3/Haxe */: r(ident(p), null, false);
					case "charCodeAt" if (Gctx.defined(ctx.com, Define.NoFlashOverride)): r(ident(p + "HX"), null, true);
					case "charCodeAt" /* use Haxe version */: r(ident(p), null, true);
					case "cca": r(as3("charCodeAt"), null, false);
					case "substr" if (Gctx.defined(ctx.com, Define.NoFlashOverride)): r(ident(p + "HX"), null, true);
					case "substr" /* use Haxe version */: r(ident(p), null, true);
					case "__substr__": r(as3("substr"), null, false);
					case _: r(as3(p), null, false);
				});
			case TInst({clPath: {pack: [], name: "Date"}}, _):
				(switch p {
					case "toString" if (Gctx.defined(ctx.com, Define.NoFlashOverride)): r(ident(p + "HX"), null, true);
					case _: r(ident(p), null, false);
				});
			case TAnon(a):
				(switch a.aStatus {
					case ClassStatics({clPath: {pack: [], name: "Math"}}):
						(switch p {
							case "POSITIVE_INFINITY" | "NEGATIVE_INFINITY" | "NaN": r(ident(p), KFloat, false);
							case "floor" | "ceil" | "round" if (ctx.for_call): r(ident(p), KInt, false);
							case "ffloor" | "fceil" | "fround": r(ident(p.substr(1, p.length - 1)), null, false);
							case _: r(ident(p), null, false);
						});
					case _: r(ident(p), null, false);
				});
			case TInst(c, _) if (hasClassFlag(c, CInterface)):
				/* lookup the interface in which the field was actually declared */
				function loop(c:TClass):TClass {
					var f = c.clFields.get(p);
					if (f != null) {
						return switch f {
							case {cfKind: Var(_) | Method(MethDynamic)}: throw Exit.raise(); /* no vars in interfaces in swf9 */
							case _: c;
						}
					}
					function loop2(l:Array<ClassAndParams>, i:Int):TClass {
						if (i >= l.length) throw NotFound.raise();
						return try loop(l[i].cls) catch (_:NotFound) loop2(l, i + 1);
					}
					return loop2(c.clImplements, 0);
				}
				try {
					var c = loop(c);
					var ns = HMName(reserved(p), HNNamespace(make_class_ns(c)));
					r(ns, null, false);
				} catch (_:NotFound) {
					r(ident(p), null, false);
				} catch (_:Exit) {
					r(ident(p), null, false);
				}
			case _:
				r(ident(p), null, false);
		}
	}

	static function this_property(fa:TFieldAccess):HlName {
		return switch fa {
			case FInstance(c, _, cf) | FClosure({cls: c}, cf):
				if (is_cf_protected(cf))
					HMName(reserved(cf.cfName), HNProtected(make_class_ns(c)))
				else {
					switch ns_access(cf) {
						case null: ident(fieldName(fa));
						case n: n;
					}
				}
			case _:
				ident(fieldName(fa));
		}
	}

	static function default_infos():CodeInfos {
		var i = new CodeInfos();
		i.ipos = 0;
		i.istack = 0;
		i.imax = 0;
		i.iregs = [];
		i.iscopes = 0;
		i.imaxscopes = 0;
		i.iloop = -1;
		i.icond = false;
		return i;
	}

	static function alloc_reg(ctx:Context, k:TKind):Register {
		var regs = ctx.infos.iregs;
		for (r in regs) if (!r.rused && kindEq(k, r.rtype)) {
			r.rused = true;
			r.rinit = false;
			return r;
		}
		var r = new Register(regs.length + 1, k, true, false, false);
		regs.push(r);
		return r;
	}

	static function coerce(ctx:Context, t:TKind):Void {
		/* it would be useful to know if we don't already have
		   this type on the stack (as detected by the bytecode verifier)...
		   maybe this get removed at JIT, so it's only useful to reduce codesize
		*/
		if (!kindEq(t, KNone)) write(ctx, switch t {
			case KInt: HToInt;
			case KUInt: HToUInt;
			case KFloat: HToNumber;
			case KBool: HToBool;
			case KType(t): HCast(t);
			case KDynamic: HAsAny;
			case KNone: die();
		});
	}

	static function set_reg(ctx:Context, r:Register):Void {
		if (!r.rinit) {
			r.rinit = true;
			if (ctx.infos.icond) r.rcond = true;
		}
		coerce(ctx, r.rtype);
		write(ctx, HSetReg(r.rid));
	}

	static function set_reg_dup(ctx:Context, r:Register):Void {
		if (!r.rinit) {
			r.rinit = true;
			if (ctx.infos.icond) r.rcond = true;
		}
		coerce(ctx, r.rtype);
		write(ctx, HDup);
		write(ctx, HSetReg(r.rid));
	}

	static function free_reg(ctx:Context, r:Register):Void {
		r.rused = false;
	}

	static function pop(ctx:Context, n:Int):Void {
		function loop(n:Int) {
			if (n > 0) {
				write(ctx, HPop);
				loop(n - 1);
			}
		}
		if (n < 0) die();
		var old = ctx.infos.istack;
		loop(n);
		ctx.infos.istack = old;
	}

	static function is_member(ctx:Context, name:String):Bool {
		function loop(c:TClass):Bool {
			return c.clFields.exists(name) || (switch c.clSuper {
				case null: false;
				case {cls: c}: loop(c);
			});
		}
		return loop(ctx.cur_class);
	}

	static function block_var_exists(ctx:Context, name:String):Bool {
		for (b in ctx.block_vars) if (b.name == name) return true;
		return false;
	}

	static function rename_block_var(ctx:Context, v:TVar):Void {
		/* we need to rename it since slots are accessed on a by-name basis */
		function loop(i:Int) {
			var name = v.vName + Std.string(i);
			if (block_var_exists(ctx, name) || is_member(ctx, name))
				loop(i + 1)
			else
				v.vName = name;
		}
		loop(1);
	}

	static function define_local(ctx:Context, ?init:Bool = false, v:TVar, p:Pos):Void {
		var name = v.vName;
		var t = v.vType;
		var l = (if (hasVarFlag(v, VCaptured)) {
			var topt = type_opt(ctx, t);
			if (block_var_exists(ctx, name) || is_member(ctx, name)) rename_block_var(ctx, v);
			var pos = ctx.block_vars.length + 1;
			ctx.block_vars.unshift({slot: pos, name: v.vName, t: topt});
			LScope(pos);
		} else {
			var r = alloc_reg(ctx, classify(ctx, t));
			if (ctx.debug) write(ctx, HDebugReg(name, r.rid, ctx.last_line));
			r.rinit = init;
			LReg(r);
		});
		// port: PMap.add on a persistent map: blocks restore the previous map.
		var m = ctx.locals.copy();
		m.set(v.vId, {v: v, l: l});
		ctx.locals = m;
	}

	static function gen_local_access(ctx:Context, v:TVar, p:Pos, forset:Bool):Access {
		var e = ctx.locals.get(v.vId);
		if (e == null) Error.abort("Unbound variable " + v.vName, p);
		return switch e.l {
			case LReg(r):
				VReg(r);
			case LScope(n):
				write(ctx, HGetScope(1));
				VScope(n);
			case LGlobal(p):
				if (forset) write(ctx, HFindProp(p));
				VGlobal(p);
		}
	}

	static function get_local_register(ctx:Context, v:TVar):Null<Register> {
		var e = ctx.locals.get(v.vId);
		return switch (e == null ? LScope(0) : e.l) {
			case LReg(r): r;
			case _: null;
		}
	}

	static function setvar(ctx:Context, acc:Access, kret:Null<TKind>):Void {
		switch acc {
			case VReg(r):
				if (kret != null)
					set_reg_dup(ctx, r)
				else
					set_reg(ctx, r);
			case VGlobal(_) | VId(_) | VCast(_) | VArray | VScope(_) | VSuper(_) if (kret != null):
				var r = alloc_reg(ctx, kret);
				set_reg_dup(ctx, r);
				setvar(ctx, acc, null);
				write(ctx, HReg(r.rid));
				free_reg(ctx, r);
			case VGlobal(g):
				write(ctx, HSetProp(g));
			case VId(id) | VCast(id, _):
				write(ctx, HInitProp(id));
			case VVolatile(id, _):
				write(ctx, HArray(1));
				write(ctx, HInitProp(id));
			case VArray:
				write(ctx, HSetProp(dynamic_prop));
				ctx.infos.istack = ctx.infos.istack - 1;
			case VScope(n):
				write(ctx, HSetSlot(n));
			case VSuper(id):
				write(ctx, HSetSuper(id));
		}
	}

	static function getvar(ctx:Context, acc:Access):Void {
		switch acc {
			case VReg(r):
				if (!r.rinit) {
					r.rinit = true;
					r.rcond = true;
				}
				write(ctx, HReg(r.rid));
			case VId(id):
				write(ctx, HGetProp(id));
			case VVolatile(id, t):
				write(ctx, HGetProp(id));
				write(ctx, HSmallInt(0));
				write(ctx, HGetProp(dynamic_prop));
				ctx.infos.istack = ctx.infos.istack - 1;
				switch t {
					case null:
					case t: coerce(ctx, t);
				}
			case VCast(id, t):
				write(ctx, HGetProp(id));
				coerce(ctx, t);
			case VGlobal(g):
				write(ctx, HGetLex(g));
			case VArray:
				write(ctx, HGetProp(dynamic_prop));
				ctx.infos.istack = ctx.infos.istack - 1;
			case VScope(n):
				write(ctx, HGetSlot(n));
			case VSuper(id):
				write(ctx, HGetSuper(id));
		}
	}

	static function open_block(ctx:Context, retval:Bool):Void->Void {
		var old_stack = ctx.infos.istack;
		var old_regs = [for (r in ctx.infos.iregs) r.rused];
		var old_locals = ctx.locals;
		return function() {
			if (ctx.infos.istack != old_stack + (if (retval) 1 else 0)) die();
			var rcount = old_regs.length + 1;
			for (r in ctx.infos.iregs) {
				if (r.rid < rcount)
					r.rused = old_regs[r.rid - 1]
				else
					r.rused = false;
			}
			ctx.locals = old_locals;
		}
	}

	static function begin_branch(ctx:Context):Void->Void {
		if (ctx.infos.icond)
			return function() {}
		else {
			ctx.infos.icond = true;
			return function() ctx.infos.icond = false;
		}
	}

	static function begin_switch(ctx:Context):{fend:Void->Void, ftag:Int->Void} {
		var branch = begin_branch(ctx);
		var switch_index = ctx.code.length;
		var switch_pos = ctx.infos.ipos;
		write(ctx, HSwitch(0, []));
		var constructs:Array<{tag:Int, pos:Int}> = [];
		var max = 0;
		function ftag(tag:Int) {
			if (tag > max) max = tag;
			constructs.unshift({tag: tag, pos: ctx.infos.ipos});
		}
		function fend() {
			var cases = [for (_ in 0...max + 1) 1];
			for (c in constructs) cases[c.tag] = c.pos - switch_pos;
			ctx.code[switch_index] = HSwitch(1, cases);
			branch();
		}
		return {fend: fend, ftag: ftag};
	}

	static function debug_infos(ctx:Context, ?is_min:Bool = true, p:Pos):Void {
		if (ctx.debug) {
			var line = syntax.Lexer.getErrorLine(if (is_min) p else ({pfile: p.pfile, pmin: p.pmax, pmax: p.pmax} : Pos));
			if (ctx.last_file != p.pfile) {
				write(ctx, HDebugFile(if (ctx.debugger) core.Path.getFullPath(p.pfile) else p.pfile));
				ctx.last_file = p.pfile;
				ctx.last_line = -1;
			}
			if (ctx.last_line != line) {
				write(ctx, HDebugLine(line));
				ctx.last_line = line;
			}
		}
	}

	// port: UTF8.validate cannot fail: the port's strings are always valid
	// Unicode, so the Latin-1 fallback of to_utf8 is unreachable.
	static function to_utf8(str:String):String return str;

	static function gen_constant(ctx:Context, c:TConstant, t:T, p:Pos):Void {
		switch c {
			case TInt(i):
				var unsigned = kindEq(classify(ctx, t), KUInt);
				if (i > -128 && i < 128) {
					write(ctx, HSmallInt(i));
					if (unsigned) write(ctx, HToUInt);
				} else
					write(ctx, if (unsigned) HUIntRef(i) else HIntRef(i));
			case TFloat(f):
				var f = core.ds.OcamlFloat.ofString(f);
				write(ctx, HFloat(f));
			case TString(s):
				write(ctx, HString(to_utf8(s)));
			case TBool(b):
				write(ctx, if (b) HTrue else HFalse);
			case TNull:
				write(ctx, HNull);
				coerce(ctx, classify(ctx, t));
			case TThis:
				write(ctx, HThis);
			case TSuper:
				die();
		}
	}

	static function end_fun(ctx:Context, args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>, dparams:Null<Array<HlValue>>, tret:T):HlMethod {
		var m = new HlMethod();
		m.hlmt_index = 0;
		m.hlmt_ret = type_void(ctx, tret);
		m.hlmt_args = [for (a in args) type_opt(ctx, a.variable.vType)];
		m.hlmt_native = false;
		m.hlmt_var_args = false;
		m.hlmt_debug_name = null;
		m.hlmt_dparams = dparams;
		m.hlmt_pnames = if (ctx.swc || ctx.debugger) [for (a in args) (a.variable.vName : Null<String>)] else null;
		m.hlmt_new_block = false;
		m.hlmt_unused_flag = false;
		m.hlmt_arguments_defined = false;
		m.hlmt_uses_dxns = false;
		m.hlmt_function = null;
		return m;
	}

	static function begin_fun(ctx:Context, args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>, tret:T, el:Array<TExpr>, stat:Bool, p:Pos):Void->HlMethod {
		var old_locals = ctx.locals;
		var old_code = ctx.code;
		var old_infos = ctx.infos;
		var old_trys = ctx.trys;
		var old_bvars = ctx.block_vars;
		var old_static = ctx.in_static;
		var last_line = ctx.last_line;
		var old_treg = ctx.try_scope_reg;
		ctx.infos = default_infos();
		ctx.code = [];
		ctx.trys = [];
		ctx.block_vars = [];
		ctx.in_static = stat;
		ctx.last_line = -1;
		ctx.last_file = "";
		debug_infos(ctx, p);
		function find_this(e:TExpr) {
			switch e.eexpr {
				case TFunction(_):
				case TConst(TThis | TSuper): throw Exit.raise();
				case _: Texpr.iter(find_this, e);
			}
		}
		var this_reg = try {
			for (e in el) find_this(e);
			false;
		} catch (_:Exit) true;
		// port: PMap.foldi visits the ids in increasing order; the result is a map.
		var nlocals = new IntMap();
		for (id => vl in ctx.locals) switch vl.l {
			case LReg(_):
			case LScope(_): nlocals.set(vl.v.vId, {v: vl.v, l: LGlobal(ident(vl.v.vName))});
			case LGlobal(_): nlocals.set(vl.v.vId, vl);
		}
		ctx.locals = nlocals;

		var dparams:Null<Array<HlValue>> = null; // port: the OCaml list in reverse
		function make_constant_value(r:Register, c:Null<TExpr>, t:T) {
			var v = (switch [classify(ctx, t), c] {
				case [_, null]: HVNone;
				case [kind = (KInt | KFloat | KUInt | KBool), c]:
					(switch c.eexpr {
						case TConst(TInt(i)): if (kindEq(kind, KUInt)) HVUInt(i) else HVInt(i);
						case TConst(TFloat(s)): HVFloat(core.ds.OcamlFloat.ofString(s));
						case TConst(TBool(b)): HVBool(b);
						case TConst(TNull): Error.abort("In Flash9, null can't be used as basic type " + core.TPrinting.sType(core.TPrinting.printContext(), t), p);
						case _: Error.abort("Non-constant default argument values are not supported on the flash target for basic type "
								+ core.TPrinting.sType(core.TPrinting.printContext(), t), p);
					});
				case [_, {eexpr: TConst(TNull)}]: HVNone;
				case [k, c]:
					write(ctx, HReg(r.rid));
					write(ctx, HNull);
					var j = jump(ctx, J3Neq);
					gen_expr(ctx, true, c);
					coerce(ctx, k);
					write(ctx, HSetReg(r.rid));
					j();
					HVNone;
			});
			switch dparams {
				case null: if (c != null) dparams = [v];
				case l: l.unshift(v);
			}
		}
		var varargs:Null<{v:TVar, isArray:Bool}> = null;
		{
			var rev = args.copy();
			rev.reverse();
			if (rev.length > 0 && rev[0].variable.vName == "__arguments__") {
				var v = rev[0].variable;
				var l = args.slice(0, args.length - 1);
				switch follow(v.vType) {
					case TInst({clPath: {pack: [], name: "Array"}}, _):
						args = l;
						varargs = {v: v, isArray: true};
					case _:
						args = l;
						varargs = {v: v, isArray: false};
				}
			} else if (rev.length > 0 && ExtType.isRest(TFunctions.follow(rev[0].variable.vType))) {
				args = args.slice(0, args.length - 1);
				varargs = {v: rev[0].variable, isArray: true};
			}
		}

		for (a in args) {
			var v = a.variable, c = a.defaultValue;
			var t = v.vType;
			define_local(ctx, true, v, p);
			switch gen_local_access(ctx, v, nullPos, true) {
				case VReg(r):
					make_constant_value(r, c, t);
				case acc:
					var r = alloc_reg(ctx, classify(ctx, t));
					make_constant_value(r, c, t);
					write(ctx, HReg(r.rid));
					setvar(ctx, acc, null);
			}
		}

		switch varargs {
			case null:
			case {v: v}:
				define_local(ctx, true, v, p);
				alloc_reg(ctx, classify(ctx, v.vType));
		}

		if (dparams != null) dparams.reverse();
		var dparams = dparams;
		function is_not_rethrow(c:{variable:TVar, expr:TExpr}):Bool {
			return switch c.expr.eexpr {
				case TBlock([{eexpr: TThrow({eexpr: TNew(_, _, [])})}]): false;
				case _: true;
			}
		}
		function loop_try(e:TExpr) {
			switch e.eexpr {
				case TFunction(_):
				case TTry(_, catches) if (catches.exists(is_not_rethrow)): throw Exit.raise();
				case _: Texpr.iter(loop_try, e);
			}
		}
		ctx.try_scope_reg = (try {
			for (e in el) loop_try(e);
			null;
		} catch (_:Exit) alloc_reg(ctx, KDynamic));
		var args = args;
		var varargs = varargs;
		return function() {
			var hasblock = ctx.block_vars.length != 0 || ctx.try_scope_reg != null;
			var code = ctx.code;
			var extra = (if (hasblock) {
				var scope = (switch ctx.try_scope_reg {
					case null: [HScope];
					case r: [HDup, HSetReg(r.rid), HScope];
				});
				[HThis, HScope, HNewBlock].concat(scope);
			} else if (this_reg)
				[HThis, HScope]
			else
				[]);
			/* add dummy registers initialization */
			for (r in ctx.infos.iregs) {
				if (!r.rcond) continue;
				var s = [HSetReg(r.rid)];
				extra = extra.concat(switch r.rtype {
					case KInt: [HSmallInt(0)].concat(s);
					case KUInt: [HSmallInt(0), HToUInt].concat(s);
					case KFloat: [HNaN].concat(s);
					case KBool: [HFalse].concat(s);
					case KType(t): [HNull, HAsType(t)].concat(s);
					case KDynamic: [HNull, HAsAny].concat(s);
					case KNone: [HNull, HAsType(HMPath([], "Class"))].concat(s);
				});
			}
			var delta = extra.length;
			var f:HlFunction = {
				hlf_stack_size: (if (ctx.infos.imax == 0 && (hasblock || this_reg)) 1 else ctx.infos.imax),
				hlf_nregs: ctx.infos.iregs.length + 1,
				hlf_init_scope: 1,
				hlf_max_scope: ctx.infos.imaxscopes + 1 + (if (hasblock) 2 else if (this_reg) 1 else 0),
				hlf_code: extra.concat(code),
				hlf_trys: ctx.trys.mapToVector(t -> ({
					hltc_start: t.tr_pos + delta,
					hltc_end: t.tr_end + delta,
					hltc_handle: t.tr_catch_pos + delta,
					hltc_type: type_opt(ctx, t.tr_type),
					hltc_name: null,
				} : HlTryCatch)),
				hlf_locals: ctx.block_vars.mapToVector(b -> ({name: ident(b.name), type: b.t, slot: b.slot, const: false} : HlLocal)),
			};
			var mt = end_fun(ctx, args, dparams, tret);
			mt.hlmt_var_args = (switch varargs {
				case {isArray: true}: true;
				case _: false;
			});
			mt.hlmt_arguments_defined = (switch varargs {
				case {isArray: false}: true;
				case _: false;
			});
			mt.hlmt_new_block = hasblock;
			mt.hlmt_function = f;
			ctx.locals = old_locals;
			ctx.code = old_code;
			ctx.infos = old_infos;
			ctx.trys = old_trys;
			ctx.block_vars = old_bvars;
			ctx.in_static = old_static;
			ctx.last_line = last_line;
			ctx.try_scope_reg = old_treg;
			return mt;
		}
	}

	static function empty_method(ctx:Context, p:Pos):HlMethod {
		var f = begin_fun(ctx, vector(), ctx.com.basic.tvoid, [], true, p);
		write(ctx, HRetVoid);
		return f();
	}

	static function begin_loop(ctx:Context):Int->Void {
		var old_loop = ctx.infos.iloop;
		var old_breaks = ctx.breaks;
		var old_conts = ctx.continues;
		ctx.infos.iloop = ctx.infos.istack;
		ctx.breaks = [];
		ctx.continues = [];
		return function(cont_pos:Int) {
			if (ctx.infos.istack != ctx.infos.iloop) die();
			for (j in ctx.breaks) j();
			for (j in ctx.continues) j(cont_pos);
			ctx.infos.iloop = old_loop;
			ctx.breaks = old_breaks;
			ctx.continues = old_conts;
		}
	}

	static function no_value(ctx:Context, retval:Bool):Void {
		/* does not push a null but still increment the stack like if
		   a real value was pushed */
		if (retval) ctx.infos.istack = ctx.infos.istack + 1;
	}

	static function pop_value(ctx:Context, retval:Bool):Void {
		/* if we have multiple branches, make sure to forget about previous
		   branch value */
		if (retval) ctx.infos.istack = ctx.infos.istack - 1;
	}

	static function gen_access(ctx:Context, e:TExpr, forset:Bool):Access {
		switch e.eexpr {
			case TLocal(v):
				return gen_local_access(ctx, v, e.epos, forset);
			case TField({eexpr: TConst(TSuper)}, f):
				write(ctx, HThis);
				return VSuper(this_property(f));
			case TEnumParameter(e1, _, i):
				gen_expr(ctx, true, e1);
				write(ctx, HGetProp(ident("params")));
				write(ctx, HSmallInt(i));
				return VArray;
			case TEnumIndex(e1):
				gen_expr(ctx, true, e1);
				return VId(ident("index"));
			case TField(e1, fa):
				var r = switch e1.eexpr {
					case TConst(TThis | TSuper) if (!ctx.in_static):
						var id = this_property(fa);
						write(ctx, HFindProp(id));
						{id: id, k: (null : Null<TKind>), closure: false};
					case _:
						gen_expr(ctx, true, e1);
						property(ctx, fa, e1.etype);
				}
				var id = r.id, k = r.k, closure = r.closure;
				if (closure && !ctx.for_call) Error.abort("In Flash9, this method cannot be accessed this way : please define a local function", e1.epos);
				return switch k {
					case null:
						switch [follow(e1.etype), follow(e.etype)] {
							case [_, TFun(_)] if (!ctx.for_call): VCast(id, classify(ctx, e.etype));
							case [TEnum(_), _]: VId(id);
							case [TInst(_, tl), et]:
								var requires_cast = switch fa {
									case FInstance(c, _, {cfKind: Var(_)}) if (hasClassFlag(c, CInterface)):
										/* we have to cast var access on interfaces */
										true;
									case FInstance(_, _, cf):
										/* if the return type is one of the type-parameters, then we need to cast it */
										(switch follow(cf.cfType) {
											case TInst({clKind: KTypeParameter(_)}, _): true;
											case _: false;
										});
									case _:
										tl.exists(t -> follow(t) == et);
								}
								if (requires_cast)
									VCast(id, classify(ctx, e.etype))
								else if (codegen.Codegen.isVolatile(e.etype))
									VVolatile(id, null)
								else
									VId(id);
							case [TAnon(a), _] if (switch a.aStatus {
									case ClassStatics(_) | EnumStatics(_): true;
									case _: false;
								}):
								if (codegen.Codegen.isVolatile(e.etype))
									VVolatile(id, null)
								else
									VId(id);
							case _:
								if (codegen.Codegen.isVolatile(e.etype))
									VVolatile(id, classify(ctx, e.etype))
								else
									VCast(id, classify(ctx, e.etype));
						}
					case t: VCast(id, t);
				}
			case TArray({eexpr: TIdent("__global__")}, {eexpr: TConst(TString(s))}):
				var path = Ast.parsePath(s);
				var id = type_path(ctx, {pack: path.pack, name: path.name});
				if (forset) write(ctx, HGetGlobalScope);
				return VGlobal(id);
			case TArray(e, eindex):
				gen_expr(ctx, true, e);
				gen_expr(ctx, true, eindex);
				return VArray;
			case TTypeExpr(t):
				var id = type_path(ctx, tPath(t));
				if (forset) write(ctx, HGetGlobalScope);
				return VGlobal(id);
			case _:
				return invalid_expr(e.epos);
		}
	}

	static function gen_expr_twice(ctx:Context, e:TExpr):Void {
		switch e.eexpr {
			case TLocal(v):
				switch get_local_register(ctx, v) {
					case null:
						gen_expr(ctx, true, e);
						write(ctx, HDup);
					case r:
						write(ctx, HReg(r.rid));
						write(ctx, HReg(r.rid));
				}
			case TConst(_):
				gen_expr(ctx, true, e);
				gen_expr(ctx, true, e);
			case _:
				gen_expr(ctx, true, e);
				write(ctx, HDup);
		}
	}

	static function gen_access_rw(ctx:Context, e:TExpr):{r:Access, w:Access} {
		switch e.eexpr {
			case TArray({eexpr: TLocal(_)}, {eexpr: TConst(_)}) | TArray({eexpr: TLocal(_)}, {eexpr: TLocal(_)}) | TField({eexpr: TLocal(_)}, _) | TField({eexpr: TConst(_)}, _):
				var w = gen_access(ctx, e, true);
				var r = gen_access(ctx, e, false);
				return {r: r, w: w};
			case TArray(e, eindex):
				var r = (switch e.eexpr {
					case TLocal(v): get_local_register(ctx, v);
					case _: null;
				});
				switch r {
					case null:
						var r = alloc_reg(ctx, classify(ctx, e.etype));
						gen_expr(ctx, true, e);
						set_reg(ctx, r);
						write(ctx, HReg(r.rid));
						gen_expr_twice(ctx, eindex);
						write(ctx, HReg(r.rid));
						write(ctx, HSwap);
						free_reg(ctx, r);
					case r:
						write(ctx, HReg(r.rid));
						gen_expr_twice(ctx, eindex);
						write(ctx, HReg(r.rid));
						write(ctx, HSwap);
				}
				return {r: VArray, w: VArray};
			case TField(_):
				var w = gen_access(ctx, e, true);
				write(ctx, HDup);
				return {r: w, w: w};
			case _:
				var w = gen_access(ctx, e, true);
				var r = gen_access(ctx, e, false);
				return {r: r, w: w};
		}
	}

	static function gen_type(ctx:Context, t:HlName):Void {
		switch t {
			case HMParams(t, tl):
				write(ctx, HGetLex(t));
				for (t in tl) gen_type(ctx, t);
				write(ctx, HApplyType(tl.length));
			case HMAny:
				write(ctx, (HNull));
			case _:
				write(ctx, HGetLex(t));
		}
	}

	static function gen_expr_content(ctx:Context, retval:Bool, e:TExpr):Void {
		switch e.eexpr {
			case TConst(c):
				gen_constant(ctx, c, e.etype, e.epos);
			case TThrow(e):
				ctx.infos.icond = true;
				if (Gctx.hasFeature(ctx.com, "haxe.CallStack.exceptionStack") && !filters.exception.ExceptionFunctions.isHaxeException(e.etype)) {
					getvar(ctx, VGlobal(type_path(ctx, path(["flash"], "Boot"))));
					var id = type_path(ctx, path(["flash", "errors"], "Error"));
					write(ctx, HFindPropStrict(id));
					write(ctx, HConstructProperty(id, 0));
					setvar(ctx, VId(ident("lastError")), null);
				}
				gen_expr(ctx, true, e);
				write(ctx, HThrow);
				no_value(ctx, retval);
			case TParenthesis(e) | TMeta(_, e):
				gen_expr(ctx, retval, e);
			case TObjectDecl(fl):
				for (f in fl) {
					write(ctx, HString(reserved(f.key.name)));
					gen_expr(ctx, true, f.expr);
				}
				write(ctx, HObject(fl.length));
			case TArrayDecl(el):
				for (e in el) gen_expr(ctx, true, e);
				write(ctx, HArray(el.length));
			case TBlock(el):
				function loop(i:Int) {
					if (i >= el.length) {
						if (retval) write(ctx, HNull);
					} else if (i == el.length - 1) {
						gen_expr(ctx, retval, el[i]);
					} else {
						gen_expr(ctx, false, el[i]);
						loop(i + 1);
					}
				}
				var b = open_block(ctx, retval);
				loop(0);
				b();
			case TVar(v, ei):
				define_local(ctx, v, e.epos);
				switch ei {
					case null:
					case e:
						var acc = gen_local_access(ctx, v, e.epos, true);
						gen_expr(ctx, true, e);
						setvar(ctx, acc, null);
				}
			case TReturn(null):
				write(ctx, HRetVoid);
				ctx.infos.icond = true;
				no_value(ctx, retval);
			case TReturn(e):
				gen_expr(ctx, true, e);
				write(ctx, HRet);
				ctx.infos.icond = true;
				no_value(ctx, retval);
			case TField(_) | TLocal(_) | TEnumIndex(_) | TTypeExpr(_):
				getvar(ctx, gen_access(ctx, e, false));
			/* both accesses return dynamic so let's cast them to the real type */
			case TEnumParameter(_) | TArray(_):
				getvar(ctx, gen_access(ctx, e, false));
				coerce(ctx, classify(ctx, e.etype));
			case TBinop(op, e1, e2):
				gen_binop(ctx, retval, op, e1, e2, e.etype, e.epos);
			case TCall(f, el):
				switch ctx.handle_spread_args(ctx.com.basic, el, e.etype, el -> ({eexpr: TCall(f, el), etype: e.etype, epos: e.epos} : TExpr)) {
					case null:
						gen_call(ctx, retval, f, el, e.etype);
					case e:
						gen_expr(ctx, retval, e);
				}
			case TNew({clPath: {pack: [], name: "Array"}}, _, []):
				/* it seems that [] is 4 time faster than new Array() */
				write(ctx, HArray(0));
			case TNew({clPath: {pack: ["flash"], name: "Vector"}}, [t], _) if (switch follow(t) {
					case TInst({clKind: KTypeParameter(_)}, _): true;
					case _: false;
				}):
				write(ctx, HString("Cannot create Vector without knowing runtime type"));
				write(ctx, HThrow);
				no_value(ctx, retval);
			case TNew(c, tl, pl):
				switch ctx.handle_spread_args(ctx.com.basic, pl, e.etype, pl -> ({eexpr: TNew(c, tl, pl), etype: e.etype, epos: e.epos} : TExpr)) {
					case null:
						var id = type_id(ctx, TInst(c, tl));
						switch id {
							case HMParams(_):
								gen_type(ctx, id);
								for (e in pl) gen_expr(ctx, true, e);
								write(ctx, HConstruct(pl.length));
							case _:
								write(ctx, HFindPropStrict(id));
								for (e in pl) gen_expr(ctx, true, e);
								write(ctx, HConstructProperty(id, pl.length));
						}
					case e:
						gen_expr(ctx, retval, e);
				}
			case TFunction(f):
				write(ctx, HFunction(generate_function(ctx, f, true)));
			case TIf(e0, e1, e2):
				var j = jump_expr(ctx, e0, false);
				var branch = begin_branch(ctx);
				gen_expr(ctx, retval, e1);
				var t = classify(ctx, e.etype);
				if (retval && !kindEq(classify(ctx, e1.etype), t)) coerce(ctx, t);
				switch e2 {
					case null: j();
					case e:
						/* two expresssions, but one per branch */
						pop_value(ctx, retval);
						var jend = jump(ctx, J3Always);
						j();
						gen_expr(ctx, retval, e);
						if (retval && !kindEq(classify(ctx, e.etype), t)) coerce(ctx, t);
						jend();
				}
				branch();
			case TWhile(econd, e, flag):
				var jstart = jump(ctx, J3Always);
				var end_loop = begin_loop(ctx);
				var branch = begin_branch(ctx);
				var loop = jump_back(ctx);
				if (flag.match(DoWhile)) jstart();
				gen_expr(ctx, false, e);
				if (flag.match(NormalWhile)) jstart();
				var continue_pos = ctx.infos.ipos;
				var _j = jump_expr_gen(ctx, econd, true, j -> {
					loop(j);
					function() {};
				});
				branch();
				end_loop(continue_pos);
				if (retval) write(ctx, HNull);
			case TUnop(op, flag, e):
				gen_unop(ctx, retval, op, flag, e);
			case TTry(e2, cases):
				if (ctx.infos.istack != 0) Error.abort("Cannot compile try/catch as a right-side expression in Flash9", e.epos);
				var branch = begin_branch(ctx);
				var p = ctx.infos.ipos;
				gen_expr(ctx, retval, e2);
				var pend = ctx.infos.ipos;
				var jend = jump(ctx, J3Always);
				function loop(ncases:Int, i:Int):Array<Void->Void> {
					if (i >= cases.length) return [];
					var v = cases[i].variable, e = cases[i].expr;
					var b = open_block(ctx, retval);
					var t = v.vType;
					ctx.trys.push({
						tr_pos: p,
						tr_end: pend,
						tr_catch_pos: ctx.infos.ipos,
						tr_type: t,
					});
					ctx.infos.istack = ctx.infos.istack + 1;
					if (ctx.infos.imax < ctx.infos.istack) ctx.infos.imax = ctx.infos.istack;
					write(ctx, HThis);
					write(ctx, HScope);
					switch ctx.try_scope_reg {
						case null:
						case r:
							write(ctx, HReg(r.rid));
							write(ctx, HScope);
					}
					/* store the exception into local var, using a tmp register if needed */
					define_local(ctx, v, e.epos);
					var r = (switch (switch ctx.locals.get(v.vId) {
						case null: die();
						case x: x;
					}).l {
						case LReg(_): null;
						case _:
							var r = alloc_reg(ctx, classify(ctx, t));
							set_reg(ctx, r);
							r;
					});
					var acc = gen_local_access(ctx, v, e.epos, true);
					switch r {
						case null:
						case r: write(ctx, HReg(r.rid));
					}
					setvar(ctx, acc, null);
					/* ----- */
					function call_loop(e:TExpr) {
						switch e.eexpr {
							case TCall(_) | TNew(_): throw Exit.raise();
							case TFunction(_):
							case _: Texpr.iter(call_loop, e);
						}
					}
					var has_call = (try {
						call_loop(e);
						false;
					} catch (_:Exit) true);
					if (has_call && Gctx.hasFeature(ctx.com, "haxe.CallStack.exceptionStack") && !filters.exception.ExceptionFunctions.isHaxeException(v.vType)) {
						getvar(ctx, gen_local_access(ctx, v, e.epos, false));
						write(ctx, HAsType(type_path(ctx, path(["flash", "errors"], "Error"))));
						var j = jump(ctx, J3False);
						getvar(ctx, VGlobal(type_path(ctx, path(["flash"], "Boot"))));
						getvar(ctx, gen_local_access(ctx, v, e.epos, false));
						setvar(ctx, VId(ident("lastError")), null);
						j();
					}
					gen_expr(ctx, retval, e);
					b();
					if (retval) ctx.infos.istack = ctx.infos.istack - 1;
					if (i + 1 >= cases.length) return [];
					var j = jump(ctx, J3Always);
					var rest = loop(ncases + 1, i + 1);
					rest.unshift(j);
					return rest;
				}
				var loops = loop(ctx.trys.length, 0);
				for (j in loops) j();
				branch();
				jend();
			case TBreak:
				pop(ctx, ctx.infos.istack - ctx.infos.iloop);
				ctx.breaks.unshift(jump(ctx, J3Always));
				no_value(ctx, retval);
			case TContinue:
				pop(ctx, ctx.infos.istack - ctx.infos.iloop);
				var op = ctx.code.length;
				var p = ctx.infos.ipos;
				write(ctx, HJump(J3Always, 0));
				ctx.continues.unshift(target -> ctx.code[op] = HJump(J3Always, target - p));
				no_value(ctx, retval);
			case TSwitch({switchSubject: e0, switchCases: cases, switchDefault: eo}):
				var t = classify(ctx, e.etype);
				try {
					var t0 = classify(ctx, e0.etype);
					/* generate optimized int switch */
					if (!kindEq(t0, KInt) && !kindEq(t0, KUInt)) throw Exit.raise();
					function get_int(e:TExpr):Int {
						return switch e.eexpr {
							case TConst(TInt(n)):
								if (n < 0 || n > 512) throw Exit.raise();
								n;
							case TParenthesis(e) | TBlock([e]) | TMeta(_, e): get_int(e);
							case _: throw NotFound.raise();
						}
					}
					for (c in cases) for (v in c.casePatterns) {
						try get_int(v) catch (_:Dynamic) throw Exit.raise();
					}
					gen_expr(ctx, true, e0);
					if (!kindEq(t0, KInt)) write(ctx, HToInt);
					var s = begin_switch(ctx);
					var switch_ = s.fend, case_ = s.ftag;
					switch eo {
						case null:
							if (retval) {
								write(ctx, HNull);
								coerce(ctx, t);
							}
						case e:
							gen_expr(ctx, retval, e);
							if (retval && !kindEq(classify(ctx, e.etype), t)) coerce(ctx, t);
					}
					var jends = [
						for (c in cases) {
							var vl = c.casePatterns, e = c.caseExpr;
							var j = jump(ctx, J3Always);
							for (v in vl) case_(get_int(v));
							pop_value(ctx, retval);
							gen_expr(ctx, retval, e);
							if (retval && !kindEq(classify(ctx, e.etype), t)) coerce(ctx, t);
							j;
						}
					];
					for (j in jends) j();
					switch_();
				} catch (_:Exit) {
					var r = alloc_reg(ctx, classify(ctx, e0.etype));
					gen_expr(ctx, true, e0);
					set_reg(ctx, r);
					var branch = begin_branch(ctx);
					var prev = function() {};
					var jend = [
						for (c in cases) {
							var vl = c.casePatterns, e = c.caseExpr;
							prev();
							function loop(i:Int) {
								if (i >= vl.length) die();
								var v = vl[i];
								if (i == vl.length - 1) {
									write(ctx, HReg(r.rid));
									gen_expr(ctx, true, v);
									prev = jump(ctx, J3Neq);
								} else {
									write(ctx, HReg(r.rid));
									gen_expr(ctx, true, v);
									var j = jump(ctx, J3Eq);
									loop(i + 1);
									j();
								}
							}
							loop(0);
							gen_expr(ctx, retval, e);
							pop_value(ctx, retval);
							if (retval && !kindEq(classify(ctx, e.etype), t)) coerce(ctx, t);
							jump(ctx, J3Always);
						}
					];
					prev();
					free_reg(ctx, r);
					switch eo {
						case null:
							if (retval) {
								write(ctx, HNull);
								coerce(ctx, t);
							}
						case e:
							gen_expr(ctx, retval, e);
							if (retval && !kindEq(classify(ctx, e.etype), t)) coerce(ctx, t);
					}
					for (j in jend) j();
					branch();
				}
			case TCast(e1, t) if (t != null && !retval):
				var p = e.epos;
				var e2 = mk(TTypeExpr(t), tDynamic, p);
				var eis = mk(TIdent("__is__"), tDynamic, p);
				var ecall = mk(TCall(eis, vector(e1, e2)), ctx.com.basic.tbool, p);
				var enot:TExpr = {eexpr: TUnop(Not, Prefix, ecall), etype: ecall.etype, epos: ecall.epos};
				var exc = mk(TThrow(mk(TConst(TString("Class cast error")), ctx.com.basic.tstring, p)), ctx.com.basic.tvoid, p);
				var eif = mk(TIf(enot, exc, null), ctx.com.basic.tvoid, p);
				gen_expr(ctx, retval, eif);
			case TCast(e1, t):
				gen_expr(ctx, retval, e1);
				if (retval) {
					switch t {
						case null:
							/* no error if cast failure */
							var t1 = classify(ctx, e1.etype);
							var t = classify(ctx, e.etype);
							if (!kindEq(t1, t)) coerce(ctx, t);
						case t:
							/* manual cast */
							var tid = (switch gen_access(ctx, mk(TTypeExpr(t), tDynamic, e.epos), false) {
								case VGlobal(id): id;
								case _: die();
							});
							switch classify(ctx, e.etype) {
								case KType(n) if (switch n {
										case HMPath([], "String"): false;
										case _: true;
									}):
									/* for normal classes, we can use native cast */
									write(ctx, HCast(tid));
								case KInt | KUInt:
									/* allow any number to be cast to int (will coerce) */
									write(ctx, HDup);
									write(ctx, HIsType(HMPath([], "Number")));
									var j = jump(ctx, J3True);
									write(ctx, HString("Class cast error"));
									write(ctx, HThrow);
									j();
									write(ctx, HCast(tid));
								case _:
									/* we need to check with "is" first, to prevent convertion */
									write(ctx, HDup);
									write(ctx, HIsType(tid));
									var j = jump(ctx, J3True);
									write(ctx, HString("Class cast error"));
									write(ctx, HThrow);
									j();
									write(ctx, HCast(tid));
							}
					}
				}
			case TIdent(s):
				Error.abort("Unbound variable " + s, e.epos);
		}
	}

	static function args_as_array(ctx:Context, mandatory_args:Vector<TExpr>, spread_arg:TExpr, p:Pos):TExpr {
		return switch mandatory_args {
			case []:
				spread_arg;
			case _:
				var p = Texpr.punionEl(p, mandatory_args);
				var array = mk(TArrayDecl(mandatory_args), ctx.com.basic.tarray(tDynamic), p);
				var concat = mk(TField(array, FDynamic("concat")), tDynamic, spread_arg.epos);
				mk(TCall(concat, vector(spread_arg)), ctx.com.basic.tarray(tDynamic), Ast.punion(p, spread_arg.epos));
		}
	}

	static function gen_call(ctx:Context, retval:Bool, e:TExpr, el:Vector<TExpr>, r:T):Void {
		switch (el.length > 0 ? el[el.length - 1].eexpr : null) {
			/* generate a call with `...rest` as `callee.apply(null, [param1, param2].concat(rest))` */
			case TUnop(Spread, Prefix, rest):
				var el_rev = el.slice(0, el.length - 1);
				var t_array_dyn = ctx.com.basic.tarray(tDynamic);
				var nul = mk(TConst(TNull), tDynamic, nullPos);
				var t = TFun({args: vector({name: "thisArg", optional: false, type: tDynamic}, {name: "argArray", optional: false, type: t_array_dyn}), ret: r});
				var apply = mk(TField(e, FDynamic("apply")), t, e.epos);
				gen_call(ctx, retval, apply, vector(nul, args_as_array(ctx, el_rev, rest, e.epos)), r);
				return;
			/* normal call without `...rest` */
			case _:
		}
		switch [e.eexpr, el] {
			case [TIdent("__is__"), [e, t]]:
				gen_expr(ctx, true, e);
				gen_expr(ctx, true, t);
				write(ctx, HOp(A3OIs));
			case [TField(_, FStatic({clPath: {pack: [], name: "Std"}}, {cfName: "is" | "isOfType"})), [e, t = {eexpr: TTypeExpr(TClassDecl(_))}]]:
				/* fast inlining of Std.is with known values */
				gen_expr(ctx, true, e);
				gen_expr(ctx, true, t);
				write(ctx, HOp(A3OIs));
			case [TIdent("__as__"), [e, t]]:
				gen_expr(ctx, true, e);
				gen_expr(ctx, true, t);
				write(ctx, HOp(A3OAs));
			case [TIdent("__int__"), [e]]:
				gen_expr(ctx, true, e);
				write(ctx, HToInt);
			case [TIdent("__float__"), [e]]:
				gen_expr(ctx, true, e);
				write(ctx, HToNumber);
			case [TIdent("__foreach__"), [obj, counter]]:
				gen_expr(ctx, true, obj);
				gen_expr(ctx, true, counter);
				write(ctx, HForEach);
			case [TIdent("__forin__"), [obj, counter]]:
				gen_expr(ctx, true, obj);
				gen_expr(ctx, true, counter);
				write(ctx, HForIn);
			case [TIdent("__has_next__"), [obj, counter]]:
				var oreg = switch gen_access(ctx, obj, false) {
					case VReg(r): r;
					case _: Error.abort("Must be a local variable", obj.epos);
				}
				var creg = switch gen_access(ctx, counter, false) {
					case VReg(r): r;
					case _: Error.abort("Must be a local variable", obj.epos);
				}
				write(ctx, HNext(oreg.rid, creg.rid));
			case [TIdent("__hkeys__"), [e2]] | [TIdent("__foreach__"), [e2]] | [TIdent("__keys__"), [e2]]:
				var racc = alloc_reg(ctx, KType(type_path(ctx, path([], "Array"))));
				var rcounter = alloc_reg(ctx, KInt);
				var rtmp = alloc_reg(ctx, KDynamic);
				write(ctx, HSmallInt(0));
				set_reg(ctx, rcounter);
				write(ctx, HArray(0));
				set_reg(ctx, racc);
				gen_expr(ctx, true, e2);
				set_reg(ctx, rtmp);
				var start = jump(ctx, J3Always);
				var loop = jump_back(ctx);
				write(ctx, HReg(racc.rid));
				write(ctx, HReg(rtmp.rid));
				write(ctx, HReg(rcounter.rid));
				switch e.eexpr {
					case TIdent("__foreach__"):
						write(ctx, HForEach);
					case TIdent("__hkeys__"):
						write(ctx, HForIn);
						write(ctx, HSmallInt(1));
						write(ctx, HCallProperty(as3("substr"), 1));
					case _:
						write(ctx, HForIn);
				}
				write(ctx, HCallPropVoid(as3("push"), 1));
				start();
				write(ctx, HNext(rtmp.rid, rcounter.rid));
				loop(J3True);
				write(ctx, HReg(racc.rid));
				free_reg(ctx, rtmp);
				free_reg(ctx, rcounter);
				free_reg(ctx, racc);
			case [TIdent("__new__"), _] if (el.length > 0):
				var e = el[0];
				var el = el.slice(1);
				gen_expr(ctx, true, e);
				for (e in el) gen_expr(ctx, true, e);
				write(ctx, HConstruct(el.length));
			case [TIdent("__delete__"), [o, f]]:
				gen_expr(ctx, true, o);
				gen_expr(ctx, true, f);
				write(ctx, HDeleteProp(dynamic_prop));
			case [TIdent("__unprotect__"), [e]]:
				write(ctx, HGetLex(type_path(ctx, path(["flash"], "Boot"))));
				gen_expr(ctx, true, e);
				write(ctx, HCallProperty(ident("__unprotect__"), 1));
			case [TIdent("__typeof__"), [e]]:
				gen_expr(ctx, true, e);
				write(ctx, HTypeof);
			case [TIdent("__in__"), [e, f]]:
				gen_expr(ctx, true, e);
				gen_expr(ctx, true, f);
				write(ctx, HOp(A3OIn));
			case [TIdent("__resources__"), []]:
				var count = 0;
				for (name in resource_names(ctx.com)) {
					count++;
					write(ctx, HString("name"));
					write(ctx, HString(name));
					write(ctx, HObject(1));
				}
				write(ctx, HArray(count));
			case [TIdent("__vmem_set__"), [{eexpr: TConst(TInt(code))}, e1, e2]]:
				gen_expr(ctx, true, e2);
				gen_expr(ctx, true, e1);
				write(ctx, HOp(switch code {
					case 0: A3OMemSet8;
					case 1: A3OMemSet16;
					case 2: A3OMemSet32;
					case 3: A3OMemSetFloat;
					case 4: A3OMemSetDouble;
					case _: die();
				}));
			case [TIdent("__vmem_get__"), [{eexpr: TConst(TInt(code))}, e]]:
				gen_expr(ctx, true, e);
				write(ctx, HOp(switch code {
					case 0: A3OMemGet8;
					case 1: A3OMemGet16;
					case 2: A3OMemGet32;
					case 3: A3OMemGetFloat;
					case 4: A3OMemGetDouble;
					case _: die();
				}));
			case [TIdent("__vmem_sign__"), [{eexpr: TConst(TInt(code))}, e]]:
				gen_expr(ctx, true, e);
				write(ctx, HOp(switch code {
					case 0: A3OSign1;
					case 1: A3OSign8;
					case 2: A3OSign16;
					case _: die();
				}));
			case [TIdent("__vector__"), []]:
				var t = switch r {
					case TAbstract({aPath: {pack: [], name: "Class"}}, [vt]): vt;
					case _: die();
				}
				gen_type(ctx, type_id(ctx, t));
			case [TIdent("__vector__"), [ep]]:
				gen_type(ctx, type_id(ctx, r));
				write(ctx, HGetGlobalScope);
				gen_expr(ctx, true, ep);
				write(ctx, HCallStack(1));
			case [TArray({eexpr: TIdent("__global__")}, {eexpr: TConst(TString(s))}), _]:
				switch gen_access(ctx, e, false) {
					case VGlobal(id):
						write(ctx, HFindPropStrict(id));
						for (e in el) gen_expr(ctx, true, e);
						write(ctx, HCallProperty(id, el.length));
					case _: die();
				}
			case [TConst(TSuper), _]:
				write(ctx, HThis);
				for (e in el) gen_expr(ctx, true, e);
				write(ctx, HConstructSuper(el.length));
			case [TField(e1, f), _]:
				function default_() gen_field_call(ctx, retval, e1, f, el, r);
				function mk_prop_acccess(prop_cl, prop_tl, prop_cf:TClassField) return mk(TField(e1, FInstance(prop_cl, prop_tl, prop_cf)), prop_cf.cfType, e.epos);
				function mk_static_acccess(cl, prop_cf:TClassField) return mk(TField(e1, FStatic(cl, prop_cf)), prop_cf.cfType, e.epos);
				switch [f, el] {
					case [FInstance(cl, tl, cf), []]:
						switch isExternInstanceAccessor(true, cl, tl, cf) {
							case null:
								default_();
							case p:
								var efield = mk_prop_acccess(p.cls, p.params, p.field);
								getvar(ctx, gen_access(ctx, efield, false));
						}
					case [FInstance(cl, tl, cf), [evalue]]:
						switch isExternInstanceAccessor(false, cl, tl, cf) {
							case null:
								default_();
							case p:
								var efield = mk_prop_acccess(p.cls, p.params, p.field);
								gen_assign(ctx, efield, evalue, retval);
						}
					case [FStatic(cl, cf), []]:
						switch isExternStaticAccessor(true, cl, cf) {
							case null:
								default_();
							case prop_cf:
								var efield = mk_static_acccess(cl, prop_cf);
								getvar(ctx, gen_access(ctx, efield, false));
						}
					case [FStatic(cl, cf), [evalue]]:
						switch isExternStaticAccessor(false, cl, cf) {
							case null:
								default_();
							case prop_cf:
								var efield = mk_static_acccess(cl, prop_cf);
								gen_assign(ctx, efield, evalue, retval);
						}
					case _:
						default_();
				}
			case _:
				gen_expr(ctx, true, e);
				write(ctx, HGetGlobalScope);
				for (e in el) gen_expr(ctx, true, e);
				write(ctx, HCallStack(el.length));
				coerce(ctx, classify(ctx, r));
		}
	}

	static function gen_field_call(ctx:Context, retval:Bool, eobj:TExpr, f:TFieldAccess, el:Vector<TExpr>, r:T):Void {
		switch eobj {
			case {eexpr: TConst(TSuper)}:
				var id = this_property(f);
				write(ctx, HFindPropStrict(id));
				for (e in el) gen_expr(ctx, true, e);
				if (retval) {
					write(ctx, HCallSuper(id, el.length));
					coerce(ctx, classify(ctx, r));
				} else
					write(ctx, HCallSuperVoid(id, el.length));
			case {eexpr: TConst(TThis)} if (!ctx.in_static):
				var id = this_property(f);
				write(ctx, HFindProp(id)); /* not sure why we don't use HFindPropStrict here too */
				for (e in el) gen_expr(ctx, true, e);
				if (retval) {
					write(ctx, HCallProperty(id, el.length));
					coerce(ctx, classify(ctx, r));
				} else
					write(ctx, HCallPropVoid(id, el.length));
			case _:
				var old = ctx.for_call;
				ctx.for_call = true;
				gen_expr(ctx, true, eobj);
				var id = property(ctx, f, eobj.etype).id;
				ctx.for_call = old;
				for (e in el) gen_expr(ctx, true, e);
				if (retval) {
					write(ctx, HCallProperty(id, el.length));
					coerce(ctx, classify(ctx, r));
				} else
					write(ctx, HCallPropVoid(id, el.length));
		}
	}

	static function gen_unop(ctx:Context, retval:Bool, op:Unop, flag:UnopFlag, e:TExpr):Void {
		var k = classify(ctx, e.etype);
		switch op {
			case Not:
				gen_expr(ctx, true, e);
				write(ctx, HOp(A3ONot));
			case Neg:
				gen_expr(ctx, true, e);
				write(ctx, HOp(if (kindEq(k, KInt)) A3OINeg else A3ONeg));
			case NegBits:
				gen_expr(ctx, true, e);
				write(ctx, HOp(A3OBitNot));
			case Spread:
				Globals.die("Unhandled spread operator", "genswf9.ml", e.epos);
			case Increment | Decrement:
				var incr = op.match(Increment);
				var r = (switch e.eexpr {
					case TLocal(v): get_local_register(ctx, v);
					case _: null;
				});
				switch r {
					case r if (r != null && kindEq(r.rtype, KInt)):
						if (!r.rinit) r.rcond = true;
						if (retval && flag.match(Postfix)) getvar(ctx, VReg(r));
						write(ctx, if (incr) HIncrIReg(r.rid) else HDecrIReg(r.rid));
						if (retval && flag.match(Prefix)) getvar(ctx, VReg(r));
					case _:
						var rw = gen_access_rw(ctx, e);
						var acc_read = rw.r, acc_write = rw.w;
						var op = (switch [k, incr] {
							case [KInt, true]: A3OIIncr;
							case [KInt, false]: A3OIDecr;
							case [_, true]: A3OIncr;
							case [_, false]: A3ODecr;
						});
						getvar(ctx, acc_read);
						switch flag {
							case Postfix if (retval):
								var r = alloc_reg(ctx, k);
								write(ctx, HDup);
								set_reg(ctx, r);
								write(ctx, HOp(op));
								setvar(ctx, acc_write, null);
								write(ctx, HReg(r.rid));
								free_reg(ctx, r);
							case Postfix | Prefix:
								write(ctx, HOp(op));
								setvar(ctx, acc_write, if (retval) k else null);
						}
				}
		}
	}

	static function check_binop(ctx:Context, e1:TExpr, e2:TExpr):Void {
		var invalid = (switch [classify(ctx, e1.etype), classify(ctx, e2.etype)] {
			case [KInt, KUInt] | [KUInt, KInt]:
				(switch [e1.eexpr, e2.eexpr] {
					case [TConst(TInt(i)), _] | [_, TConst(TInt(i))]: i < 0;
					case _: true;
				});
			case _: false;
		});
		if (invalid) Error.abort("Comparison of Int and UInt might lead to unexpected results", Ast.punion(e1.epos, e2.epos));
	}

	static function gen_assign(ctx:Context, lhs:TExpr, rhs:TExpr, retval:Bool):Void {
		var acc = gen_access(ctx, lhs, true);
		gen_expr(ctx, true, rhs);
		setvar(ctx, acc, if (retval) classify(ctx, lhs.etype) else null);
	}

	static function gen_binop(ctx:Context, retval:Bool, op:Binop, e1:TExpr, e2:TExpr, t:T, p:Pos):Void {
		function write_op(op:Binop) {
			var iop = (switch op {
				case OpAdd: A3OIAdd;
				case OpSub: A3OISub;
				case OpMult: A3OIMul;
				case _: null;
			});
			var op = (switch op {
				case OpAdd: A3OAdd;
				case OpSub: A3OSub;
				case OpMult: A3OMul;
				case OpDiv: A3ODiv;
				case OpAnd: A3OAnd;
				case OpOr: A3OOr;
				case OpXor: A3OXor;
				case OpShl: A3OShl;
				case OpShr: A3OShr;
				case OpUShr: A3OUShr;
				case OpMod: A3OMod;
				case _: die();
			});
			switch iop {
				case null:
					write(ctx, HOp(op));
					if (op.match(A3OMod) && kindEq(classify(ctx, e1.etype), KInt) && kindEq(classify(ctx, e2.etype), KInt)) coerce(ctx, classify(ctx, t));
				case iop:
					var k1 = classify(ctx, e1.etype);
					var k2 = classify(ctx, e2.etype);
					switch [k1, k2] {
						case [KInt, KInt] | [KUInt, KUInt] | [KInt, KUInt] | [KUInt, KInt]:
							write(ctx, HOp(iop));
							var ret = classify(ctx, t);
							if (!kindEq(ret, KInt)) coerce(ctx, ret);
						case _:
							write(ctx, HOp(op));
							/* add is a generic operation, so let's make sure we don't loose our type in the process */
							if (op.match(A3OAdd)) coerce(ctx, classify(ctx, t));
					}
			}
		}
		function gen_op(o:As3Op) {
			check_binop(ctx, e1, e2);
			gen_expr(ctx, true, e1);
			gen_expr(ctx, true, e2);
			write(ctx, HOp(o));
		}
		function gen_eq() {
			switch isSpecialCompare(e1, e2) {
				case null:
					gen_op(A3OEq);
				case c:
					var cf = c.clStatics.get("compare");
					if (cf == null) die();
					var f = FStatic(c, cf);
					gen_expr(ctx, true, mk(TCall(mk(TField(mk(TTypeExpr(TClassDecl(c)), tDynamic, p), f), tDynamic, p), vector(e1, e2)), ctx.com.basic.tbool, p));
			}
		}
		switch op {
			case OpAssign:
				gen_assign(ctx, e1, e2, retval);
			case OpBoolAnd:
				write(ctx, HFalse);
				var j = jump_expr(ctx, e1, false);
				var b = begin_branch(ctx);
				write(ctx, HPop);
				gen_expr(ctx, true, e2);
				coerce(ctx, KBool);
				j();
				b();
			case OpBoolOr:
				write(ctx, HTrue);
				var j = jump_expr(ctx, e1, true);
				var b = begin_branch(ctx);
				write(ctx, HPop);
				gen_expr(ctx, true, e2);
				coerce(ctx, KBool);
				j();
				b();
			case OpAssignOp(op):
				var rw = gen_access_rw(ctx, e1);
				getvar(ctx, rw.r);
				gen_expr(ctx, true, e2);
				write_op(op);
				setvar(ctx, rw.w, if (retval) classify(ctx, e1.etype) else null);
			case OpAdd | OpMult | OpDiv | OpSub | OpAnd | OpOr | OpXor | OpMod:
				gen_expr(ctx, true, e1);
				gen_expr(ctx, true, e2);
				write_op(op);
			case OpShl | OpShr | OpUShr:
				gen_expr(ctx, true, e1);
				gen_expr(ctx, true, e2);
				write_op(op);
				coerce(ctx, classify(ctx, e1.etype));
			case OpEq:
				gen_eq();
			case OpNotEq:
				gen_eq();
				write(ctx, HOp(A3ONot));
			case OpGt:
				gen_op(A3OGt);
			case OpGte:
				gen_op(A3OGte);
			case OpLt:
				gen_op(A3OLt);
			case OpLte:
				gen_op(A3OLte);
			case OpInterval | OpArrow | OpIn | OpNullCoal:
				die();
		}
	}

	static function gen_expr(ctx:Context, retval:Bool, e:TExpr):Void {
		var old = ctx.infos.istack;
		debug_infos(ctx, e.epos);
		gen_expr_content(ctx, retval, e);
		if (old != ctx.infos.istack) {
			if (old + 1 != ctx.infos.istack) stack_error(e.epos);
			if (!retval) write(ctx, HPop);
		} else if (retval) stack_error(e.epos);
	}

	static function generate_function(ctx:Context, fdata:TFunc, stat:Bool):HlMethod {
		var f = begin_fun(ctx, fdata.tfArgs, fdata.tfType, [fdata.tfExpr], stat, fdata.tfExpr.epos);
		gen_expr(ctx, false, fdata.tfExpr);
		switch follow(fdata.tfType) {
			case TEnum({ePath: {pack: [], name: "Void"}}, []) | TAbstract({aPath: {pack: [], name: "Void"}}, []):
				debug_infos(ctx, false, fdata.tfExpr.epos);
				write(ctx, HRetVoid);
			case _:
				/* check that we have a return that can be accepted by Flash9 VM */
				function loop(e:TExpr):Bool {
					return switch e.eexpr {
						case TBlock([]): false;
						case TBlock(l): loop(l[l.length - 1]);
						case TReturn(null): true;
						case TReturn(e):
							function inner_loop(e:TExpr):Bool {
								return switch e.eexpr {
									case TSwitch(_) | TWhile(_) | TTry(_): false;
									case TIf(_): loop(e);
									case TParenthesis(e) | TMeta(_, e): inner_loop(e);
									case _: true;
								}
							}
							inner_loop(e);
						case TIf(_, e1, e2) if (e2 != null): loop(e1) && loop(e2);
						case TParenthesis(e) | TMeta(_, e): loop(e);
						case _: false;
					}
				}
				if (!loop(fdata.tfExpr)) write(ctx, HRetVoid);
		}
		return f();
	}

	static function jump_expr_gen<A>(ctx:Context, e:TExpr, jif:Bool, jfun:HlJump->A):A {
		switch e.eexpr {
			case TParenthesis(e) | TMeta(_, e):
				return jump_expr_gen(ctx, e, jif, jfun);
			case TBinop(op, e1, e2):
				function j(t:HlJump, f:HlJump) {
					check_binop(ctx, e1, e2);
					gen_expr(ctx, true, e1);
					gen_expr(ctx, true, e2);
					return jfun(if (jif) t else f);
				}
				return switch op {
					case OpEq if (isSpecialCompare(e1, e2) == null): j(J3Eq, J3Neq);
					case OpNotEq if (isSpecialCompare(e1, e2) == null): j(J3Neq, J3Eq);
					case OpGt: j(J3Gt, J3NotGt);
					case OpGte: j(J3Gte, J3NotGte);
					case OpLt: j(J3Lt, J3NotLt);
					case OpLte: j(J3Lte, J3NotLte);
					case _:
						gen_expr(ctx, true, e);
						jfun(if (jif) J3True else J3False);
				}
			case _:
				gen_expr(ctx, true, e);
				return jfun(if (jif) J3True else J3False);
		}
	}

	static function jump_expr(ctx:Context, e:TExpr, jif:Bool):Void->Void return jump_expr_gen(ctx, e, jif, jump.bind(ctx));

	static function do_debug(ctx:Context, meta:Metadata):Void->Void {
		var old = ctx.debug;
		ctx.debug = (old || Meta.has(Meta.Debug, meta)) && !Meta.has(Meta.NoDebug, meta);
		return function() ctx.debug = old;
	}

	static function generate_method(ctx:Context, fdata:TFunc, stat:Bool, fmeta:Metadata):HlMethod {
		var old = do_debug(ctx, fmeta);
		var m = generate_function(ctx, fdata, stat);
		old();
		return m;
	}

	static function generate_construct(ctx:Context, fdata:TFunc, c:TClass):{m:HlMethod, nargs:Int} {
		/* make all args optional to allow no-param constructor */
		var cargs = if (!ctx.need_ctor_skip) fdata.tfArgs else fdata.tfArgs.map(a -> {
				var v = a.variable, c = a.defaultValue;
				var c = (switch c {
					case null:
						(switch classify(ctx, v.vType) {
							case KInt | KUInt: mk(TConst(TInt(0)), ctx.com.basic.tint, v.vPos);
							case KFloat: mk(TConst(TFloat("0")), ctx.com.basic.tfloat, v.vPos);
							case KBool: mk(TConst(TBool(false)), ctx.com.basic.tbool, v.vPos);
							case KType(_) | KDynamic | KNone: mk(TConst(TNull), tDynamic, v.vPos);
						});
					case _: c;
				});
				({variable: v, defaultValue: c} : {variable:TVar, defaultValue:Null<TExpr>});
			});
		var f = begin_fun(ctx, cargs, fdata.tfType, [ethis, fdata.tfExpr], false, fdata.tfExpr.epos);
		/* if skip_constructor, then returns immediatly */
		if (ctx.need_ctor_skip) switch c.clKind {
			case KGenericInstance(_):
			case _ if (!Texpr.constructorSideEffects(fdata.tfExpr)):
			case _:
				var id = ident("skip_constructor");
				getvar(ctx, VGlobal(type_path(ctx, path(["flash"], "Boot"))));
				getvar(ctx, VId(id));
				var j = jump(ctx, J3False);
				write(ctx, HRetVoid);
				j();
		}
		/* --- */
		for (name in sortedKeys(c.clFields)) {
			var f = c.clFields.get(name);
			switch [f.cfExpr, f.cfKind] {
				case [null, _]:
				case [{eexpr: TFunction(fdata)}, Method(MethDynamic)]:
					var id = ident(f.cfName);
					write(ctx, HFindProp(id));
					write(ctx, HGetProp(id));
					var j = jump(ctx, J3True);
					write(ctx, HFindProp(id));
					write(ctx, HFunction(generate_method(ctx, fdata, false, [])));
					write(ctx, HInitProp(id));
					j();
				case _:
			}
		}
		gen_expr(ctx, false, fdata.tfExpr);
		debug_infos(ctx, false, fdata.tfExpr.epos);
		write(ctx, HRetVoid);
		var m = f();
		return {m: m, nargs: fdata.tfArgs.length};
	}

	// port: PMap iteration order: ascending keys under OCaml's string compare.
	static function sortedKeys<V>(m:haxe.ds.StringMap<V>):Array<String> return compiler.hxb.HxbWriter.sortedKeys(m);

	static function is_const(e:TExpr):Bool {
		return switch e.eexpr {
			case TConst(_): true;
			case TArrayDecl(el) | TBlock(el): el.foreach(is_const);
			case TObjectDecl(fl): fl.foreach(f -> is_const(f.expr));
			case TParenthesis(e) | TMeta(_, e): is_const(e);
			case TFunction(_): true;
			case _: false;
		}
	}

	static function generate_class_statics(ctx:Context, c:TClass, const_:Bool):Void {
		for (f in c.clOrderedStatics) {
			switch f.cfExpr {
				case null:
				case {eexpr: TFunction(_)} if (switch f.cfKind {
						case Method(MethNormal | MethInline): true;
						case _: false;
					}):
				case e if (is_const(e) == const_):
					write(ctx, HGetLex(type_path(ctx, c.clPath)));
					gen_expr(ctx, true, e);
					if (codegen.Codegen.isVolatile(f.cfType)) write(ctx, HArray(1));
					write(ctx, HInitProp(ident(f.cfName)));
				case _:
			}
		}
	}

	static function need_init(ctx:Context, c:TClass):Bool {
		return !ctx.swc && !hasClassFlag(c, CExtern) && Lambda.exists(c.clOrderedStatics, f -> switch f.cfExpr {
			case null: false;
			case e: !is_const(e);
		});
	}

	static function generate_extern_inits(ctx:Context):Void {
		for (t in ctx.com.types) {
			switch t {
				case TClassDecl(c) if (hasClassFlag(c, CExtern)):
					switch TClassTools.getClInit(c) {
						case null:
						case e: gen_expr(ctx, false, e);
					}
				case _:
			}
		}
	}

	static function generate_inits(ctx:Context):HlMethod {
		var finit = begin_fun(ctx, vector(), ctx.com.basic.tvoid, [], true, nullPos);
		if (!ctx.swc) generate_extern_inits(ctx);
		for (t in ctx.com.types) {
			switch t {
				case TClassDecl(c) if (need_init(ctx, c)):
					var id = ident("init__");
					getvar(ctx, VGlobal(type_path(ctx, c.clPath)));
					getvar(ctx, VId(id));
					var j = jump(ctx, J3True);
					getvar(ctx, VGlobal(type_path(ctx, c.clPath)));
					write(ctx, HTrue);
					setvar(ctx, VId(id), null);
					var branch = begin_branch(ctx);
					generate_class_statics(ctx, c, false);
					branch();
					j();
				case _:
			}
		}
		switch ctx.com.main.mainExpr {
			case null:
			case e: gen_expr(ctx, false, e);
		}
		write(ctx, HRetVoid);
		return finit();
	}

	static function generate_class_init(ctx:Context, c:TClass, hc:HlClass):Void {
		write(ctx, HGetGlobalScope);
		if (hasClassFlag(c, CInterface))
			write(ctx, HNull)
		else {
			var sup_path = (switch c.clSuper {
				case null: path([], "Object");
				case {cls: sup}: sup.clPath;
			});
			write(ctx, HGetLex(type_path(ctx, sup_path)));
			write(ctx, HScope);
			write(ctx, HGetLex(type_path(ctx, sup_path)));
		}
		write(ctx, HClassDef(hc));
		for (f in c.clOrderedStatics) {
			switch [f.cfExpr, f.cfKind] {
				case [null, _]:
				case [{eexpr: TFunction(fdata)}, Method(MethDynamic)]:
					write(ctx, HDup);
					write(ctx, HFunction(generate_method(ctx, fdata, true, f.cfMeta)));
					write(ctx, HInitProp(ident(f.cfName)));
				case _:
			}
		}
		if (!hasClassFlag(c, CInterface)) write(ctx, HPopScope);
		write(ctx, HInitProp(type_path(ctx, c.clPath)));
		if (ctx.swc && pathEq(c.clPath, ctx.boot)) generate_extern_inits(ctx);
		switch TClassTools.getClInit(c) {
			case null:
			case e:
				gen_expr(ctx, false, e);
				if (ctx.block_vars.length != 0) Error.abort("You can't have a local variable referenced from a closure inside __init__ (FP 10.1.53 crash)", e.epos);
		}
		generate_class_statics(ctx, c, true);
		if (ctx.swc) {
			generate_class_statics(ctx, c, false);
			if (ctx.block_vars.length != 0) Error.abort("You can't have a local variable referenced from a closure inside a static (FP 10.1.53 crash)", c.clPos);
		}
	}

	static function pathEq(a:GlobalTypePath, b:GlobalTypePath):Bool return a.name == b.name && arrEq((x, y) -> x == y, a.pack, b.pack);

	static function generate_enum_init(ctx:Context, e:TEnum, hc:HlClass, meta:Null<TExpr>):Void {
		var opath = path([], "Object");
		var name_id = type_path(ctx, e.ePath);
		write(ctx, HGetGlobalScope);
		write(ctx, HGetLex(type_path(ctx, opath)));
		write(ctx, HScope);
		write(ctx, HGetLex(type_path(ctx, opath)));
		write(ctx, HClassDef(hc));
		write(ctx, HPopScope);
		write(ctx, HInitProp(name_id));
		for (name in sortedKeys(e.eConstrs)) {
			var f = e.eConstrs.get(name);
			switch f.efType {
				case TFun(_):
				case _:
					write(ctx, HGetLex(name_id));
					write(ctx, HFindPropStrict(name_id));
					write(ctx, HString(f.efName));
					write(ctx, HInt(f.efIndex));
					write(ctx, HNull);
					write(ctx, HConstructProperty(name_id, 3));
					write(ctx, HInitProp(ident(f.efName)));
			}
		}
		write(ctx, HGetLex(name_id));
		for (n in e.eNames) write(ctx, HString(n));
		write(ctx, HArray(e.eNames.length));
		write(ctx, HInitProp(ident("__constructs__")));
		switch meta {
			case null:
			case e:
				write(ctx, HGetLex(name_id));
				gen_expr(ctx, true, e);
				write(ctx, HInitProp(ident("__meta__")));
		}
	}

	static function extract_meta(meta:Metadata):Null<Vector<HlMetadata>> {
		// port: `x :: loop l` evaluates `loop l` first: the entries are built from the
		// last one (which decides which invalid definition is reported).
		var l = [];
		var i = meta.length;
		while (i-- > 0) {
			var m = meta[i];
			if (Meta.metaEq(Meta.Meta, m.meta)) switch m.exprs {
				case [{expr: ECall({expr: EConst(Ident(n))}, args)}]:
					function mk_arg(a:Expr) {
						return switch a.expr {
							case EConst(String(s, _)): {k: (null : Null<String>), v: s};
							case EBinop(OpAssign, {expr: EConst(Ident(n))}, {expr: EConst(String(s, _))}): {k: (n : Null<String>), v: s};
							case _: Error.abort("Invalid meta definition", a.pos);
						}
					}
					l.unshift(({hlmeta_name: n, hlmeta_data: args.map(mk_arg)} : HlMetadata));
				case _:
			}
		}
		return switch l {
			case []: null;
			case l: Vector.fromArrayCopy(l);
		}
	}

	static function generate_field_kind(ctx:Context, f:TClassField, c:TClass, stat:Bool):Null<HlFieldKind> {
		function method_kind():{name:String, kind:HlMethodKind} {
			for (m in f.cfMeta) {
				switch m.exprs {
					case [{expr: EConst(Ident(f))}] if (Meta.metaEq(Meta.Getter, m.meta)): return {name: f, kind: MK3Getter};
					case [{expr: EConst(Ident(f))}] if (Meta.metaEq(Meta.Setter, m.meta)): return {name: f, kind: MK3Setter};
					case _:
				}
			}
			return {name: f.cfName, kind: MK3Normal};
		}
		if (!isPhysicalField(f)) return null;
		var fdata = switch f.cfExpr {
			case null: null;
			case {eexpr: TFunction(fdata)}: fdata;
			case _: null;
		}
		if (fdata != null) {
			function loop(c:TClass, name:String):Bool {
				return switch c.clSuper {
					case null: false;
					case {cls: c}:
						c.clFields.exists(name) || loop(c, name);
				}
			}
			return switch f.cfKind {
				case Method(MethDynamic) if (hasClassFieldFlag(f, CfOverride)):
					null;
				case Var(_) | Method(MethDynamic):
					HFVar({
						hlv_type: type_path(ctx, path([], "Function")),
						hlv_value: HVNone,
						hlv_const: false,
					});
				case _:
					var mk = method_kind();
					var name = mk.name, kind = mk.kind;
					var m = generate_method(ctx, fdata, stat, f.cfMeta);
					var is_override = !stat && (if (kind.match(MK3Normal)) hasClassFieldFlag(f, CfOverride) else (loop(c, name) || loop(c, f.cfName)));
					HFMethod({
						hlm_type: m,
						hlm_final: stat || (hasClassFieldFlag(f, CfFinal)),
						hlm_override: is_override,
						hlm_kind: kind,
					});
			}
		} else if ((hasClassFlag(c, CInterface) || hasClassFieldFlag(f, CfAbstract)) && !stat) {
			return switch [follow(f.cfType), f.cfKind] {
				case [TFun({args: args, ret: tret}), Method(MethNormal | MethInline)]:
					var dparams:Null<Array<HlValue>> = null;
					for (a in args) {
						switch dparams {
							case null: if (a.optional) dparams = [HVNone];
							case l: l.unshift(HVNone);
						}
					}
					if (dparams != null) dparams.reverse();
					// port: List.map evaluates the allocations left to right.
					var margs = args.map(a -> ({
						variable: allocVar(VUser(TVOArgument), a.name, a.type, f.cfPos),
						defaultValue: if (a.optional) mk(TConst(TNull), tDynamic, nullPos) else null
					} : {variable:TVar, defaultValue:Null<TExpr>}));
					HFMethod({
						hlm_type: end_fun(ctx, margs, dparams, tret),
						hlm_final: false,
						hlm_override: false,
						hlm_kind: method_kind().kind,
					});
				case _:
					null;
			}
		} else {
			return HFVar({
				hlv_type: if (codegen.Codegen.isVolatile(f.cfType)) type_path(ctx, path([], "Array")) else type_opt(ctx, f.cfType),
				hlv_value: HVNone,
				hlv_const: false,
			});
		}
	}

	static function check_constructor(ctx:Context, c:TClass, f:TFunc):Void {
		/*
			check that we don't assign a super Float var before we call super() : will result in NaN
		*/
		function loop(e:TExpr) {
			Texpr.iter(loop, e);
			switch e.eexpr {
				case TCall({eexpr: TConst(TSuper)}, _): throw Exit.raise();
				case TBinop(OpAssign, {eexpr: TField({eexpr: TConst(TThis)}, FInstance(cc, _, cf))}, _) if (c != cc && (switch classify(ctx, cf.cfType) {
						case KFloat | KDynamic: true;
						case _: false;
					})):
					Error.abort("You cannot assign some super class vars before calling super() in flash, this will reset them to default value", e.epos);
				case _:
			}
		}
		/* only do so if we have a call to super() */
		function has_super(e:TExpr) {
			Texpr.iter(has_super, e);
			switch e.eexpr {
				case TCall({eexpr: TConst(TSuper)}, _): throw Exit.raise();
				case _:
			}
		}
		try {
			has_super(f.tfExpr);
		} catch (_:Exit) {
			try {
				loop(f.tfExpr);
			} catch (_:Exit) {}
		}
	}

	static final has_protected_meta = Meta.Custom(":has_protected");

	static function mark_has_protected(c:TClass):Void c.clMeta.unshift(({meta: has_protected_meta, exprs: vector(), pos: nullPos} : MetadataEntry));

	static function find_first_nonextern_accessor_implementor(cl:TClass, name:String):TClass {
		function loop(cl:TClass, cl_found:TClass):TClass {
			return switch cl.clSuper {
				case null: cl_found;
				case {cls: c} if (hasClassFlag(c, CExtern)): cl_found;
				case {cls: cl_super}:
					var has_field = cl_super.clFields.exists(name);
					var cl_found = if (has_field) cl_super else cl_found;
					loop(cl_super, cl_found);
			}
		}
		return loop(cl, cl);
	}

	static function maybe_gen_instance_accessor(ctx:Context, cl:TClass, tl:TParams, accessor_cf:TClassField, acc:Array<HlField>, alloc_slot:Void->Int,
			kind:HlMethodKind, f_impl:TClassField->TFunc, f_iface:TClassField->{args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>, tret:T}):Array<HlField> {
		switch findPropertyForAccessor(kind.match(MK3Getter), cl, tl, accessor_cf.cfName) {
			case null:
				return acc;
			case {field: prop_cf}:
				var accessor_cl = find_first_nonextern_accessor_implementor(cl, accessor_cf.cfName);
				if (accessor_cl == cl) {
					var was_override = hasClassFieldFlag(accessor_cf, CfOverride);
					if (was_override) removeClassFieldFlag(accessor_cf, CfOverride);
					var name, mtype;
					if (hasClassFlag(cl, CInterface)) {
						var ia = f_iface(prop_cf);
						var mt = end_fun(ctx, ia.args, null, ia.tret);
						name = HMName(reserved(prop_cf.cfName), HNNamespace(make_class_ns(cl)));
						mtype = mt;
					} else {
						var func = f_impl(prop_cf);
						var mt = generate_method(ctx, func, false, accessor_cf.cfMeta);
						name = ident(prop_cf.cfName);
						mtype = mt;
					}

					var getter:HlField = {
						hlf_name: name,
						hlf_slot: alloc_slot(),
						hlf_kind: HFMethod({
							hlm_type: mtype,
							hlm_final: hasClassFieldFlag(accessor_cf, CfFinal),
							hlm_override: was_override,
							hlm_kind: kind,
						}),
						hlf_metas: null,
					};
					acc.unshift(getter);
					return acc;
				} else
					return acc;
		}
	}

	static function mk_instance_getter_func(c:TClass, tl:TParams, accessor_cl:TClass, accessor_tl:TParams, accessor_cf:TClassField, prop_cf:TClassField):TFunc {
		return {
			tfArgs: vector(),
			tfType: prop_cf.cfType,
			tfExpr: {
				var ethis = mk(TConst(TThis), TInst(c, tl), nullPos);
				var efield = mk(TField(ethis, FInstance(accessor_cl, accessor_tl, accessor_cf)), accessor_cf.cfType, nullPos);
				var ecall = mk(TCall(efield, vector()), prop_cf.cfType, nullPos);
				mk(TReturn(ecall), tDynamic, nullPos);
			}
		};
	}

	static function maybe_gen_instance_getter(ctx:Context, c:TClass, f:TClassField, acc:Array<HlField>, alloc_slot:Void->Int):Array<HlField> {
		var tl = extractParamTypes(c.clParams);
		return maybe_gen_instance_accessor(ctx, c, tl, f, acc, alloc_slot, MK3Getter, mk_instance_getter_func.bind(c, tl, c, tl, f),
			prop_cf -> {args: vector(), tret: prop_cf.cfType});
	}

	static function mk_varg(t:T):TVar return allocVar(VUser(TVOArgument), "value", t, nullPos);

	static function mk_instance_setter_func(com:Gctx, c:TClass, tl:TParams, accessor_cl:TClass, accessor_tl:TParams, accessor_cf:TClassField,
			prop_cf:TClassField):TFunc {
		var varg = mk_varg(prop_cf.cfType);
		return {
			tfArgs: vector({variable: varg, defaultValue: null}),
			tfType: com.basic.tvoid,
			tfExpr: {
				var ethis = mk(TConst(TThis), TInst(c, tl), nullPos);
				var efield = mk(TField(ethis, FInstance(accessor_cl, accessor_tl, accessor_cf)), accessor_cf.cfType, nullPos);
				var earg = mk(TLocal(varg), prop_cf.cfType, nullPos);
				mk(TCall(efield, vector(earg)), prop_cf.cfType, nullPos);
			}
		};
	}

	static function maybe_gen_instance_setter(ctx:Context, c:TClass, f:TClassField, acc:Array<HlField>, alloc_slot:Void->Int):Array<HlField> {
		var tl = extractParamTypes(c.clParams);
		return maybe_gen_instance_accessor(ctx, c, tl, f, acc, alloc_slot, MK3Setter, mk_instance_setter_func.bind(ctx.com, c, tl, c, tl, f),
			prop_cf -> {args: vector(({variable: mk_varg(prop_cf.cfType), defaultValue: null} : {variable:TVar, defaultValue:Null<TExpr>})), tret: ctx.com.basic.tvoid});
	}

	static function maybe_gen_static_accessor(ctx:Context, cl:TClass, accessor_cf:TClassField, acc:Array<HlField>, alloc_slot:Void->Int, kind:HlMethodKind,
			f_impl:TClassField->TFunc):Array<HlField> {
		switch findStaticPropertyForAccessor(kind.match(MK3Getter), cl, accessor_cf.cfName) {
			case null:
				return acc;
			case prop_cf:
				var func = f_impl(prop_cf);
				// port: right-to-left record field evaluation: the method before the slot.
				var m = generate_method(ctx, func, true, accessor_cf.cfMeta);
				var getter:HlField = {
					hlf_name: ident(prop_cf.cfName),
					hlf_slot: alloc_slot(),
					hlf_kind: HFMethod({
						hlm_type: m,
						hlm_final: true,
						hlm_override: false,
						hlm_kind: kind,
					}),
					hlf_metas: null,
				};
				acc.unshift(getter);
				return acc;
		}
	}

	static function maybe_gen_static_getter(ctx:Context, c:TClass, f:TClassField, acc:Array<HlField>, alloc_slot:Void->Int):Array<HlField> {
		return maybe_gen_static_accessor(ctx, c, f, acc, alloc_slot, MK3Getter, prop_cf -> ({
			tfArgs: vector(),
			tfType: prop_cf.cfType,
			tfExpr: {
				var ethis = Builder.makeStaticThis(c, nullPos);
				var efield = mk(TField(ethis, FStatic(c, f)), f.cfType, nullPos);
				var ecall = mk(TCall(efield, vector()), prop_cf.cfType, nullPos);
				mk(TReturn(ecall), tDynamic, nullPos);
			}
		} : TFunc));
	}

	static function maybe_gen_static_setter(ctx:Context, c:TClass, f:TClassField, acc:Array<HlField>, alloc_slot:Void->Int):Array<HlField> {
		return maybe_gen_static_accessor(ctx, c, f, acc, alloc_slot, MK3Setter, prop_cf -> {
			var varg = allocVar(VUser(TVOArgument), "value", prop_cf.cfType, nullPos);
			({
				tfArgs: vector({variable: varg, defaultValue: null}),
				tfType: ctx.com.basic.tvoid,
				tfExpr: {
					var ethis = Builder.makeStaticThis(c, nullPos);
					var efield = mk(TField(ethis, FStatic(c, f)), f.cfType, nullPos);
					var earg = mk(TLocal(varg), prop_cf.cfType, nullPos);
					mk(TCall(efield, vector(earg)), prop_cf.cfType, nullPos);
				}
			} : TFunc);
		});
	}

	static function realize_required_accessors(ctx:Context, cl:TClass):Array<HlField> {
		function is_implemented_by_super(ci:TClass):Bool {
			return switch cl.clSuper {
				case null: false;
				case {cls: csup}:
					/* heavily stripped-down version from Type.unify */
					function loop(c:TClass):Bool {
						return c == ci || (switch c.clSuper {
							case null: false;
							case {cls: cs}: loop(cs);
						}) || Lambda.exists(c.clImplements, i -> loop(i.cls));
					}
					loop(csup);
			}
		}
		var interface_props = {
			var h = new core.ds.OcamlHashtbl<String, {read:Bool, write:Bool, native:Null<TClass>}>(core.ds.OcamlHash.hashString, (a, b) -> a == b);
			function collect(cl:TClass) {
				function loop(ci:TClass) {
					if (!is_implemented_by_super(ci)) {
						for (cf in ci.clOrderedFields) {
							switch cf.cfKind {
								case Var({vRead: read = (AccCall | AccPrivateCall | AccNever), vWrite: write = (AccCall | AccPrivateCall | AccNever)}):
									switch h.findOpt(cf.cfName) {
										case null:
											h.add(cf.cfName, {read: read.match(AccCall), write: write.match(AccCall), native: if (isFlashProperty(cf)) ci else null});
										case x:
											var read = if (read.match(AccNever)) x.read else true;
											var write = if (write.match(AccNever)) x.write else true;
											h.replace(cf.cfName, {read: read, write: write, native: x.native});
									}
								case _:
							}
						}
						collect(ci);
					}
				}
				for (i in cl.clImplements) loop(i.cls);
			}
			collect(cl);
			h;
		}

		function has_nonextern_field(cl:TClass, name:String):Bool {
			if (cl.clFields.exists(name))
				return true
			else
				return switch cl.clSuper {
					case {cls: csup} if (!hasClassFlag(csup, CExtern)): has_nonextern_field(csup, name);
					case _: false;
				}
		}

		var tl = extractParamTypes(cl.clParams);
		var fields:Array<HlField> = [];
		interface_props.iter(function(name, x) {
			var read = x.read, write = x.write, native = x.native;
			var r = classField(cl, tl, name);
			switch r.owner {
				case {cls: actual_cl, params: actual_tl}:
					var cf = r.field;
					switch native {
						case null:
						case iface:
							if (!isFlashProperty(cf))
								Error.abort('Interface ${sTypePath(iface.clPath)} requires property ${cf.cfName} to be marked with @:flash.property', cf.cfPos);
					}
					if (hasClassFlag(actual_cl, CExtern)) {
						function mk_field_access() {
							var ethis = mk(TConst(TThis), TInst(cl, tl), nullPos);
							return mk(TField(ethis, FInstance(actual_cl, actual_tl, cf)), cf.cfType, nullPos);
						}
						if (read) {
							var getter_name = "get_" + name;
							if (!has_nonextern_field(cl, getter_name)) {
								var getter_func:TFunc = {
									tfArgs: vector(),
									tfType: cf.cfType,
									tfExpr: mk(TReturn(mk_field_access()), tDynamic, nullPos),
								};
								var getter:HlField = {
									hlf_name: ident(getter_name),
									hlf_slot: 0,
									hlf_kind: HFMethod({
										hlm_type: generate_method(ctx, getter_func, false, []),
										hlm_final: false,
										hlm_override: false,
										hlm_kind: MK3Normal,
									}),
									hlf_metas: null,
								};
								fields.unshift(getter);
							}
						}
						if (write) {
							var setter_name = "set_" + name;
							if (!has_nonextern_field(cl, setter_name)) {
								var varg = allocVar(VUser(TVOArgument), "value", cf.cfType, nullPos);
								var setter_func:TFunc = {
									tfArgs: vector({variable: varg, defaultValue: null}),
									tfType: cf.cfType,
									tfExpr: {
										var efield = mk_field_access();
										var earg = mk(TLocal(varg), varg.vType, nullPos);
										var eassign = mk(TBinop(OpAssign, efield, earg), cf.cfType, nullPos);
										mk(TReturn(eassign), tDynamic, nullPos);
									},
								};
								var setter:HlField = {
									hlf_name: ident(setter_name),
									hlf_slot: 0,
									hlf_kind: HFMethod({
										hlm_type: generate_method(ctx, setter_func, false, []),
										hlm_final: false,
										hlm_override: false,
										hlm_kind: MK3Normal,
									}),
									hlf_metas: null,
								};
								fields.unshift(setter);
							}
						}
					}
				case _: die();
			}
		});
		return fields;
	}

	static function generate_class(ctx:Context, c:TClass):HlClass {
		var name = type_path(ctx, c.clPath);
		ctx.cur_class = c;
		var cid:HlMethod = null, cnargs = 0;
		switch c.clConstructor {
			case null:
				if (hasClassFlag(c, CInterface)) {
					var m = empty_method(ctx, nullPos).copy();
					m.hlmt_function = null;
					cid = m;
					cnargs = 0;
				} else {
					var r = generate_construct(ctx, {
						tfArgs: vector(),
						tfType: ctx.com.basic.tvoid,
						tfExpr: {
							eexpr: TBlock(vector()),
							etype: ctx.com.basic.tvoid,
							epos: nullPos,
						}
					}, c);
					cid = r.m;
					cnargs = r.nargs;
				}
			case f:
				switch f.cfExpr {
					case null: die();
					case {eexpr: TFunction(fdata)}:
						var old = do_debug(ctx, f.cfMeta);
						var m = generate_construct(ctx, fdata, c);
						check_constructor(ctx, c, fdata);
						old();
						cid = m.m;
						cnargs = m.nargs;
					case _: die();
				}
		}
		var has_protected:Null<String> = null;
		function make_name(f:TClassField, stat:Bool):HlName {
			function find_meta(c:TClass):Metadata {
				var f2 = (if (stat) c.clStatics else c.clFields).get(f.cfName);
				if (f2 != null && !hasClassFieldFlag(f2, CfOverride)) return f2.cfMeta;
				return switch c.clSuper {
					case null: [];
					case _ if (stat): [];
					case {cls: c}: find_meta(c);
				}
			}
			function protect() {
				var p = make_class_ns(c);
				has_protected = p;
				return HMName(f.cfName, HNProtected(p));
			}
			function loop_meta(l:Metadata, i:Int):HlName {
				if (i >= l.length) {
					if (!hasClassFieldFlag(f, CfPublic) && ctx.swf_protected)
						return protect()
					else
						return ident(f.cfName);
				}
				var x = l[i];
				return switch x.exprs {
					case [{expr: EConst(Ident(f))}] if (Meta.metaEq(Meta.Getter, x.meta) || Meta.metaEq(Meta.Setter, x.meta)): ident(f);
					case [{expr: EConst(String(ns, _))}] if (Meta.metaEq(Meta.Ns, x.meta)): HMName(f.cfName, HNNamespace(ns));
					case [] if (Meta.metaEq(Meta.Protected, x.meta)): protect();
					case _: loop_meta(l, i + 1);
				}
			}
			if (hasClassFlag(c, CInterface))
				return HMName(reserved(f.cfName), HNNamespace(make_class_ns(c)))
			else
				return loop_meta(find_meta(c), 0);
		}
		function generate_prop(stat:Bool, f:TClassField, acc:Array<HlField>, alloc_slot:Void->Int):Array<HlField> {
			return switch f.cfKind {
				case Method(_) if (isGetterName(f.cfName)):
					if (!stat)
						maybe_gen_instance_getter(ctx, c, f, acc, alloc_slot)
					else
						maybe_gen_static_getter(ctx, c, f, acc, alloc_slot);
				case Method(_) if (isSetterName(f.cfName)):
					if (!stat)
						maybe_gen_instance_setter(ctx, c, f, acc, alloc_slot)
					else
						maybe_gen_static_setter(ctx, c, f, acc, alloc_slot);
				case Var({vRead: read = (AccCall | AccPrivateCall | AccNever), vWrite: write = (AccCall | AccPrivateCall | AccNever)}) if (!hasClassFlag(c, CInterface)
						&& !Meta.has(Meta.IsVar, f.cfMeta)):
					/* if the accessor methods were defined in super classes, we still need to generate native getter/setter */
					var acc = if (read.match(AccCall | AccPrivateCall)) {
						try {
							var tl = extractParamTypes(c.clParams);
							var r = classField(c, tl, "get_" + f.cfName);
							switch r.owner {
								case {cls: actual_cl, params: actual_tl} if (actual_cl != c):
									var getter_cf = r.field;
									var func = mk_instance_getter_func(c, tl, actual_cl, actual_tl, getter_cf, f);
									// port: right-to-left record field evaluation: the method before the slot.
									var m = generate_method(ctx, func, false, []);
									acc.unshift({
										hlf_name: ident(f.cfName),
										hlf_slot: alloc_slot(),
										hlf_kind: HFMethod({
											hlm_type: m,
											hlm_final: false,
											hlm_override: false,
											hlm_kind: MK3Getter,
										}),
										hlf_metas: null,
									});
									acc;
								case _:
									acc;
							}
						} catch (_:NotFound) acc;
					} else acc;
					if (write.match(AccCall | AccPrivateCall)) {
						try {
							var tl = extractParamTypes(c.clParams);
							var r = classField(c, tl, "set_" + f.cfName);
							switch r.owner {
								case {cls: actual_cl, params: actual_tl} if (actual_cl != c):
									var setter_cf = r.field;
									var func = mk_instance_setter_func(ctx.com, c, tl, actual_cl, actual_tl, setter_cf, f);
									// port: right-to-left record field evaluation: the method before the slot.
									var m = generate_method(ctx, func, false, []);
									acc.unshift({
										hlf_name: ident(f.cfName),
										hlf_slot: alloc_slot(),
										hlf_kind: HFMethod({
											hlm_type: m,
											hlm_final: false,
											hlm_override: false,
											hlm_kind: MK3Setter,
										}),
										hlf_metas: null,
									});
									acc;
								case _:
									acc;
							}
						} catch (_:NotFound) acc;
					} else acc;
				case Method(_) | Var(_): acc;
			}
		}
		// port: PMap.fold visits the fields in ascending key order; the list is
		// built by prepending (`acc` here is that list, most recent first).
		var fields:Array<HlField> = [];
		for (key in sortedKeys(c.clFields)) {
			var f = c.clFields.get(key);
			fields = generate_prop(false, f, fields, () -> 0);
			switch generate_field_kind(ctx, f, c, false) {
				case null:
				case k:
					var metas = extract_meta(f.cfMeta);
					fields.unshift({
						hlf_name: make_name(f, false),
						hlf_slot: 0,
						hlf_kind: k,
						hlf_metas: metas,
					});
			}
		}
		if (pathEq(c.clPath, ctx.boot)) {
			var cf = mkField("init", TFun({args: vector(), ret: tDynamic}), c.clPos, nullPos, ctx.swc && ctx.swf_protected);
			cf.cfKind = Method(MethNormal);
			// port: right-to-left record field evaluation: the init method before the name.
			var m = generate_inits(ctx);
			fields.unshift({
				hlf_name: make_name(cf, false),
				hlf_slot: 0,
				hlf_kind: (HFMethod({
					hlm_type: m,
					hlm_final: false,
					hlm_override: true,
					hlm_kind: MK3Normal,
				})),
				hlf_metas: null,
			});
		}
		if (!hasClassFlag(c, CInterface)) fields = fields.concat(realize_required_accessors(ctx, c));
		var st_field_count = 0;
		var st_meth_count = 0;
		var statics:Array<HlField> = [];
		for (f in c.clOrderedStatics) {
			statics = generate_prop(true, f, statics, () -> {
				st_meth_count++;
				st_meth_count;
			});
			switch generate_field_kind(ctx, f, c, true) {
				case null:
				case k:
					var count = (switch k {
						case HFMethod(_):
							st_meth_count++;
							st_meth_count;
						case HFVar(_):
							st_field_count++;
							st_field_count;
						case _: die();
					});
					var metas = extract_meta(f.cfMeta);
					statics.unshift({
						hlf_name: make_name(f, true),
						hlf_slot: count,
						hlf_kind: k,
						hlf_metas: metas,
					});
			}
		}
		statics.reverse();
		if (need_init(ctx, c)) {
			st_field_count++;
			statics.unshift({
				hlf_name: ident("init__"),
				hlf_slot: st_field_count,
				hlf_kind: HFVar({hlv_type: (type_id(ctx, ctx.com.basic.tbool)), hlv_value: HVNone, hlv_const: false}),
				hlf_metas: null,
			});
		}
		function is_dynamic(c:TClass):Bool {
			if (c.clArrayAccess != null)
				return true
			else
				return switch c.clSuper {
					case null: false;
					case {cls: c}: is_dynamic(c);
				}
		}
		if (has_protected != null)
			mark_has_protected(c) /* class has its own protected methods - add meta for the child classes */
		else switch c.clSuper {
			case null:
			case {cls: csup}: /* child has no own protected methods, check whether parent was marked with the meta */
				if (Meta.has(has_protected_meta, csup.clMeta)) {
					has_protected = make_class_ns(c);
					mark_has_protected(c); /* also mark this class with the meta for further child classes */
				} else if (hasClassFlag(csup, CExtern)) {
					function loop(csup:TClass) {
						if (Lambda.exists(csup.clOrderedFields, is_cf_protected)) {
							has_protected = make_class_ns(c);
							mark_has_protected(c); /* also mark this class with the meta for further child classes */
							mark_has_protected(csup); /* ALSO mark the extern class for faster future checks */
						} else switch csup.clSuper {
							case null:
							case {cls: csup}: loop(csup);
						}
					}
					loop(csup);
				}
		}
		// port: right-to-left record field evaluation: the static constructor
		// first, then the implements check.
		var static_construct = empty_method(ctx, c.clPos);
		var impls = c.clImplements.mapToVector(i -> {
			var c = i.cls;
			if (!hasClassFlag(c, CInterface)) Error.abort("Can't implement class in Flash9", c.clPos);
			var p = real_path(c.clPath);
			HMMultiName(p.name, [HNPublic(p.pack.join("."))]);
		});
		var hc = new HlClass();
		hc.hlc_index = 0;
		hc.hlc_name = name;
		hc.hlc_super = (if (hasClassFlag(c, CInterface)) null else type_path(ctx, switch c.clSuper {
			case null: path([], "Object");
			case {cls: c}: c.clPath;
		}));
		hc.hlc_sealed = !is_dynamic(c);
		hc.hlc_final = hasClassFlag(c, CFinal);
		hc.hlc_interface = (hasClassFlag(c, CInterface));
		hc.hlc_namespace = (switch has_protected {
			case null: null;
			case p: HNProtected(p);
		});
		hc.hlc_implements = impls;
		hc.hlc_construct = cid;
		hc.hlc_fields = Vector.fromArrayCopy(fields);
		hc.hlc_static_construct = static_construct;
		hc.hlc_static_fields = Vector.fromArrayCopy(statics);
		return hc;
	}

	static function generate_enum(ctx:Context, e:TEnum, meta:Null<TExpr>):HlClass {
		var name_id = type_path(ctx, e.ePath);
		var api = ctx.com.basic;
		// port: the list elements are evaluated right to left.
		var vparams = allocVar(VGenerated, "params", api.tarray(mkMono()), e.ePos);
		var vindex = allocVar(VGenerated, "index", api.tint, e.ePos);
		var vtag = allocVar(VGenerated, "tag", api.tstring, e.ePos);
		var f = begin_fun(ctx, vector(
			{variable: vtag, defaultValue: null},
			{variable: vindex, defaultValue: null},
			{variable: vparams, defaultValue: null}
		), api.tvoid, [ethis], false, e.ePos);
		var tag_id = ident("tag");
		var index_id = ident("index");
		var params_id = ident("params");
		write(ctx, HFindProp(tag_id));
		write(ctx, HReg(1));
		write(ctx, HInitProp(tag_id));
		write(ctx, HFindProp(index_id));
		write(ctx, HReg(2));
		write(ctx, HInitProp(index_id));
		write(ctx, HFindProp(params_id));
		write(ctx, HReg(3));
		write(ctx, HInitProp(params_id));
		write(ctx, HRetVoid);
		var construct = f();
		var f = begin_fun(ctx, vector(), api.tstring, [], true, e.ePos);
		write(ctx, HGetLex(type_path(ctx, path(["flash"], "Boot"))));
		write(ctx, HThis);
		write(ctx, HCallProperty(ident("enum_to_string"), 1));
		write(ctx, HRet);
		var tostring = f();
		var st_field_count = 0;
		var st_meth_count = 0;
		// port: PMap.fold in ascending key order, prepending.
		var constrs:Array<HlField> = [];
		for (key in sortedKeys(e.eConstrs)) {
			var f = e.eConstrs.get(key);
			var isFun = f.efType.match(TFun(_));
			var st_count = if (isFun) {
				st_meth_count++;
				st_meth_count;
			} else {
				st_field_count++;
				st_field_count;
			};
			var kind = switch f.efType {
				case TFun({args: args}):
					// port: List.map evaluates the allocations left to right.
					var fargs = args.map(a -> ({
						variable: allocVar(VGenerated, a.name, a.type, e.ePos),
						defaultValue: if (a.optional) mk(TConst(TNull), tDynamic, nullPos) else null
					} : {variable:TVar, defaultValue:Null<TExpr>}));
					var fdata = begin_fun(ctx, fargs, TEnum(e, vector()), [], true, f.efPos);
					write(ctx, HFindPropStrict(name_id));
					write(ctx, HString(f.efName));
					write(ctx, HInt(f.efIndex));
					var n = 0;
					for (_ in args) {
						n++;
						write(ctx, HReg(n));
					}
					write(ctx, HArray((n)));
					write(ctx, HConstructProperty(name_id, 3));
					write(ctx, HRet);
					var fid = fdata();
					HFMethod({
						hlm_type: fid,
						hlm_final: true,
						hlm_override: false,
						hlm_kind: MK3Normal,
					});
				case _:
					HFVar({hlv_type: (name_id), hlv_value: HVNone, hlv_const: false});
			};
			constrs.unshift({
				hlf_name: ident(f.efName),
				hlf_slot: st_count,
				hlf_kind: kind,
				hlf_metas: null,
			});
		}
		switch meta {
			case null:
			case _:
				st_field_count++;
				constrs.unshift({
					hlf_name: ident("__meta__"),
					hlf_slot: st_field_count,
					hlf_kind: HFVar({hlv_type: null, hlv_value: HVNone, hlv_const: false}),
					hlf_metas: null,
				});
		}
		var static_construct = empty_method(ctx, e.ePos);
		var hc = new HlClass();
		hc.hlc_index = 0;
		hc.hlc_name = name_id;
		hc.hlc_super = type_path(ctx, path([], "Object"));
		hc.hlc_sealed = true;
		hc.hlc_final = true;
		hc.hlc_interface = false;
		hc.hlc_namespace = null;
		hc.hlc_implements = vector();
		hc.hlc_construct = construct;
		hc.hlc_fields = vector(
			{hlf_name: tag_id, hlf_slot: 0, hlf_kind: HFVar({hlv_type: HMPath([], "String"), hlv_value: HVNone, hlv_const: false}), hlf_metas: null},
			{hlf_name: index_id, hlf_slot: 0, hlf_kind: HFVar({hlv_type: HMPath([], "int"), hlv_value: HVNone, hlv_const: false}), hlf_metas: null},
			{hlf_name: params_id, hlf_slot: 0, hlf_kind: HFVar({hlv_type: HMPath([], "Array"), hlv_value: HVNone, hlv_const: false}), hlf_metas: null},
			{hlf_name: ident("__enum__"), hlf_slot: 0, hlf_kind: HFVar({hlv_type: HMPath([], "Boolean"), hlv_value: HVBool(true), hlv_const: true}), hlf_metas: null},
			{
				hlf_name: ident("toString"),
				hlf_slot: 0,
				hlf_kind: HFMethod({
					hlm_type: tostring,
					hlm_final: true,
					hlm_override: false,
					hlm_kind: MK3Normal,
				}),
				hlf_metas: null,
			}
		);
		hc.hlc_static_construct = static_construct;
		var sf:Array<HlField> = [
			{
				hlf_name: ident("__isenum"),
				hlf_slot: st_field_count + 2,
				hlf_kind: HFVar({hlv_type: HMPath([], "Boolean"), hlv_value: HVBool(true), hlv_const: true}),
				hlf_metas: null,
			},
			{
				hlf_name: ident("__constructs__"),
				hlf_slot: st_field_count + 1,
				hlf_kind: HFVar({hlv_type: HMPath([], "Array"), hlv_value: HVNone, hlv_const: false}),
				hlf_metas: null,
			}
		].concat(constrs);
		hc.hlc_static_fields = VectorTools.ofArrayReversed(sf);
		return hc;
	}

	static function generate_type(ctx:Context, t:ModuleType):Null<{m:HlMethod, f:HlField}> {
		switch t {
			case TClassDecl(c):
				if (pathEq(c.clPath, path(["flash", "_Boot"], "RealBoot"))) c.clPath = ctx.boot;
				if (hasClassFlag(c, CExtern) && (!pathEq(c.clPath, path([], "Dynamic")) || Meta.has(Meta.RealPath, c.clMeta)))
					return null
				else {
					var debug = do_debug(ctx, c.clMeta);
					var hlc = generate_class(ctx, c);
					var init = begin_fun(ctx, vector(), ctx.com.basic.tvoid, [ethis], false, c.clPos);
					generate_class_init(ctx, c, hlc);
					write(ctx, HRetVoid);
					debug();
					// port: right-to-left tuple evaluation: the field before init().
					var f:HlField = {
						hlf_name: type_path(ctx, c.clPath),
						hlf_slot: 0,
						hlf_kind: HFClass(hlc),
						hlf_metas: extract_meta(c.clMeta),
					};
					return {m: init(), f: f};
				}
			case TEnumDecl(e):
				if (hasEnumFlag(e, EnExtern))
					return null
				else {
					var meta = Texpr.buildMetadata(ctx.com.basic, t);
					var hlc = generate_enum(ctx, e, meta);
					var init = begin_fun(ctx, vector(), ctx.com.basic.tvoid, [ethis], false, e.ePos);
					generate_enum_init(ctx, e, hlc, meta);
					write(ctx, HRetVoid);
					var f:HlField = {
						hlf_name: type_path(ctx, e.ePath),
						hlf_slot: 0,
						hlf_kind: HFClass(hlc),
						hlf_metas: extract_meta(e.eMeta),
					};
					return {m: init(), f: f};
				}
			case TAbstractDecl(a = {aPath: {pack: [], name: "Dynamic"}}):
				return generate_type(ctx, TClassDecl(mkClass(a.aModule, a.aPath, a.aPos, nullPos)));
			case TTypeDecl(_) | TAbstractDecl(_):
				return null;
		}
	}

	public static function resource_path(name:String):GlobalTypePath return {pack: ["_res"], name: "_" + name.split(".").join("_")};

	// port: the names of com.resources in Hashtbl.iter order.
	public static function resource_names(com:Gctx):Array<String> {
		var names = [];
		com.resources.iter((name, _) -> names.push(name));
		return names;
	}

	static function generate_resource(ctx:Context, name:String):{t:ModuleType, m:HlMethod, f:HlField} {
		var c = mkClass(nullModule, resource_path(name), nullPos, nullPos);
		c.clSuper = {cls: mkClass(nullModule, path(["flash", "utils"], "ByteArray"), nullPos, nullPos), params: vector()};
		var t = TClassDecl(c);
		return switch generate_type(ctx, t) {
			case null: die();
			case r: {t: t, m: r.m, f: r.f};
		}
	}

	public static function generate(com:Gctx, boot_name:String):Array<{t:ModuleType, m:HlMethod, f:HlField}> {
		var ctx = new Context();
		ctx.com = com;
		ctx.need_ctor_skip = Gctx.hasFeature(com, "Type.createEmptyInstance");
		ctx.handle_spread_args = function(basic:BasicTypes, args:Vector<TExpr>, t_result:T, args_to_expr:Vector<TExpr>->TExpr):Null<TExpr> {
			if (args.length == 0) return null;
			switch args[args.length - 1].eexpr {
				case TUnop(Spread, Prefix, rest):
					var args_rev = args.slice(0, args.length - 1);
					args_rev.reverse();
					var t_rest_item = switch TFunctions.follow(rest.etype) {
						case TAbstract(_, [t]): t;
						case _: die();
					}
					var t_array_dyn = basic.tarray(tDynamic);
					var c_array = switch t_array_dyn {
						case TInst(c, _): c;
						case _: die();
					}
					var length = {
						var faccess = switch c_array.clFields.get("length") {
							case null: FDynamic("length");
							case cf: FInstance(c_array, vector(tDynamic), cf);
						}
						mk(TField(rest, faccess), basic.tint, rest.epos);
					}
					function const_(n:Int) return mk(TConst(TInt(n)), basic.tint, rest.epos);
					function check(n:Int) return mk(TBinop(OpEq, length, const_(n)), basic.tbool, rest.epos);
					function nargs(n:Int, acc:Array<TExpr>):Array<TExpr> {
						if (n < 0) return acc else {
							var acc = acc.copy();
							acc.unshift(mk(TArray(rest, const_(n)), t_rest_item, rest.epos));
							return nargs(n - 1, acc);
						}
					}
					function loop(n:Int, e_else:TExpr):TExpr {
						// port: List.rev_append args_rev (nargs (n - 1) []).
						var args = {
							var front = args_rev.copy();
							front.reverse();
							front.concat(VectorTools.ofArray(nargs(n - 1, [])));
						};
						// port: right-to-left constructor argument evaluation.
						var e_then = args_to_expr(args);
						var e = mk(TIf(check(n), e_then, e_else), t_result, rest.epos);
						if (n == 0) return e else return loop(n - 1, e);
					}
					var msg = mk(TConst(TString("Too many rest arguments")), basic.tstring, rest.epos);
					return loop(20, mk(TThrow(msg), tDynamic, rest.epos));
				case _:
					return null;
			}
		};
		ctx.debug = com.debug;
		ctx.cur_class = nullClass;
		ctx.boot = path([], boot_name);
		ctx.debugger = Gctx.defined(com, Define.Fdb);
		ctx.swc = Gctx.defined(com, Define.Swc);
		ctx.swf_protected = Gctx.defined(com, Define.SwfProtected);
		ctx.code = [];
		ctx.locals = new IntMap();
		ctx.infos = default_infos();
		ctx.trys = [];
		ctx.breaks = [];
		ctx.continues = [];
		ctx.block_vars = [];
		ctx.in_static = false;
		ctx.last_line = -1;
		ctx.last_file = "";
		ctx.try_scope_reg = null;
		ctx.for_call = false;
		var types = if (ctx.swc && com.main.mainPath == null) {
			/*
				make sure that both Boot and RealBoot are the first two classes in the SWC
				this way initializing RealBoot will also run externs __init__ blocks before
				another class static is defined
			*/
			var hd = [];
			var types = [];
			for (t in com.types) {
				var p = tPath(t);
				if (pathEq(p, path(["flash", "_Boot"], "RealBoot")))
					hd.push(t)
				else if (pathEq(p, path(["flash"], "Boot")))
					hd.unshift(t)
				else
					types.push(t);
			}
			hd.concat(types);
		} else com.types;
		// port: Hashtbl.fold visits the resources in iteration order, prepending.
		var res = [for (name in resource_names(com)) generate_resource(ctx, name)];
		res.reverse();
		var classes = res;
		classes.reverse();
		for (t in types) {
			switch generate_type(ctx, t) {
				case null:
				case r: classes.push({t: t, m: r.m, f: r.f});
			}
		}
		return classes;
	}
}
