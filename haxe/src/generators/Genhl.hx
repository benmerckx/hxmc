/*
 * Copyright (C)2005-2015 Haxe Foundation
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
import haxe.ds.ObjectMap;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.Error;
import core.Meta;
import core.Define;
import core.ds.NotFound;
import core.ds.Failure;
import generators.Hlcode;
import generators.Hlcode.*;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: OCaml evaluates the arguments of an application or constructor right to
// left; where several of them have effects (register, string, function or op
// allocation), this translation computes them in that order explicitly.

/* compiler */

class Lookup<V> {
	public var arr:Array<V> = [];
	// port: ('a, int) Hashtbl.t, with the key rendered as a string
	public var map:StringMap<Int> = new StringMap();

	public function new() {}
}

/* not mutable, might be be shared */
class MethodCapture {
	public final cMap:IntMap<Int>;
	public final cVars:Vector<TVar>;
	public final cType:Ttype;
	public final cGroup:Bool;

	public function new(cMap:IntMap<Int>, cVars:Vector<TVar>, cType:Ttype, cGroup:Bool) {
		this.cMap = cMap;
		this.cVars = cVars;
		this.cType = cType;
		this.cGroup = cGroup;
	}
}

class Allocator {
	// port: int lists, head first
	public var aAll:Array<Int> = [];
	public var aHold:Array<Int> = [];

	public function new() {}
}

class Lassign {
	public final laName:Int;
	public final laVid:Int;
	public final laPos:Int;
	public var laScopeEnd:Int;

	public function new(laName:Int, laVid:Int, laPos:Int, laScopeEnd:Int) {
		this.laName = laName;
		this.laVid = laVid;
		this.laPos = laPos;
		this.laScopeEnd = laScopeEnd;
	}
}

class MethodContext {
	public final mid:Int;
	public final mregs:Array<Ttype> = []; // port: (int, ttype) lookup; only its array is used
	public final mops:Array<Opcode> = [];
	public final mret:Ttype;
	public final mdebug:Array<Pos> = [];
	public final mvars:IntMap<Int> = new IntMap();
	public final mhasthis:Bool;
	public var mdeclared:Array<Int> = []; // port: int list, head first
	public var mallocs:TtypeMap<Allocator> = new TtypeMap();
	public var mcaptured:MethodCapture;
	public var mcontinues:Array<Int->Void> = []; // port: lists, head first
	public var mbreaks:Array<Int->Void> = [];
	public var mtrys:Int = 0;
	public var mloopTrys:Int = 0;
	public var mcaptreg:Int = 0;
	public var mcurpos:Pos = Globals.nullPos;
	public var massign:Array<Lassign> = []; // port: in chronological order (upstream keeps it reversed)
	/* lookup into massign by variable id, so we can set the scope end when the block closes */
	public final mvarAssigns:IntMap<Array<Lassign>> = new IntMap();

	public function new(mid:Int, mret:Ttype, mcaptured:MethodCapture, mhasthis:Bool) {
		this.mid = mid;
		this.mret = mret;
		this.mcaptured = mcaptured;
		this.mhasthis = mhasthis;
	}
}

typedef ArrayImpl = {
	var aall:TClass;
	var abase:TClass;
	var adyn:TClass;
	var aobj:TClass;
	var aui8:TClass;
	var aui16:TClass;
	var ai32:TClass;
	var af32:TClass;
	var af64:TClass;
	var ai64:Null<TClass>;
	var aguid:Null<TClass>;
}

enum Constval {
	CString(s:String);
}

// port: `ttype option ref`
class TRef {
	public var v:Null<Ttype> = null;

	public function new() {}
}

class HlContext {
	public var com:Gctx;
	public var numDomains:Int;
	public var cglobals:Lookup<Ttype> = new Lookup();
	public var cstrings:Lookup<String> = new Lookup();
	public var cbytes:Lookup<haxe.io.Bytes> = new Lookup();
	public var cfloats:Lookup<Float> = new Lookup();
	public var cints:Lookup<Int> = new Lookup();
	public var cnatives:Lookup<Native> = new Lookup();
	public var cfids:Lookup<Bool> = new Lookup();
	// port: the (string * path) keys of cfids.map, for `check`
	public var cfidsKeys:Array<{name:String, path:GlobalTypePath, id:Int}> = [];
	public var cfunctions:Array<Fundecl> = [];
	public var cconstants:Lookup<{g:Int, fields:Vector<Int>}> = new Lookup();
	public var hlVer:String;
	public var optimize:Bool;
	public var wNullCompare:Bool;
	public var overrides:StringMap<Bool> = new StringMap();
	public var definedFuns:IntMap<Bool> = new IntMap();
	public var cachedTypes:StringMap<Ttype> = new StringMap();
	public var m:MethodContext;
	// port: keyed by physical identity; upstream compares tanon structurally, which
	// only merges anonymous types that convert to structurally equal ttypes.
	public var anonsCache:ObjectMap<TAnon, Ttype> = new ObjectMap();
	public var methodWrappers:TtypeMap<TtypeMap<Int>> = new TtypeMap();
	public var recCache:Array<{t:T, tref:TRef}> = []; // port: list, head = last element
	public var cachedTuples:TtypeMap<Ttype> = new TtypeMap(); // port: keyed by HFun (tl, HVoid)
	public var tstring:Ttype = HVoid;
	public var macroTypedefs:StringMap<Ttype> = new StringMap();
	public var arrayImpl:ArrayImpl;
	public var baseClass:TClass;
	public var baseType:TClass;
	public var baseEnum:TClass;
	public var coreType:TClass;
	public var coreEnum:TClass;
	public var refAbstract:TAbstract;
	public var cdebugFiles:Lookup<String> = new Lookup();
	public var ctDelayed:Array<Void->Void> = []; // port: list, head = last element
	public var ctDepth:Int = 0;

	public function new() {}
}

/* --- */

private enum Access {
	ANone;
	AGlobal(g:Int);
	ALocal(v:TVar, r:Int);
	AStaticVar(g:Int, t:Ttype, fid:Int);
	AStaticFun(f:Int);
	AInstanceFun(e:TExpr, f:Int);
	AInstanceProto(e:TExpr, fid:Int);
	AInstanceField(e:TExpr, fid:Int, packed:Bool);
	AArray(r:Int, at:Ttype, vt:Ttype, idx:Int);
	ACArray(r:Int, t:Ttype, idx:Int);
	AVirtualMethod(e:TExpr, fid:Int);
	ADynamic(e:TExpr, sid:Int);
	AEnum(en:TEnum, fid:Int);
	ACaptured(fid:Int);
}

private class ExitException extends haxe.Exception {
	public function new() super("Exit");
}

class Genhl {
	// port: the HAbstract identity of the "macro_pos" literal
	static final macroPosIdent:Dynamic = {};

	// port: ocamlopt shares identical structured constants of a compilation unit, so
	// these literal types are physically equal wherever genhl.ml writes them (tsame on
	// HArray is physical).
	static final cHArrayDyn = HArray(HDyn);
	static final cHRefI32 = HRef(HI32);
	static final cHRefBool = HRef(HBool);
	static final cHFunBytes = HFun([], HBytes);

	static function makeAssigns(l:Array<Lassign>, sorted:Bool = false):Vector<Assign> {
		var l = if (sorted) listSort((a:Lassign, b:Lassign) -> a.laPos - b.laPos, l) else l;
		return l.mapToVector((a:Lassign) -> ({name: a.laName, pos: a.laPos, scopeEnd: a.laScopeEnd} : Assign));
	}

	public static function compareVersion(v1:String, v2:String):Int
		return syntax.SemVer.SemVerTools.compareVersion(syntax.SemVer.SemVerTools.parseVersion(v1), syntax.SemVer.SemVerTools.parseVersion(v2));

	static inline function isPath(p:GlobalTypePath, pack:Array<String>, name:String):Bool
		return p.name == name && p.pack.join(".") == pack.join(".");

	// port: PMap iteration order over string keys
	static function sortedKeys<V>(m:StringMap<V>):Array<String> {
		var keys = [for (k in m.keys()) k];
		haxe.ds.ArraySort.sort(keys, strCompare);
		return keys;
	}

	static function isToString(t:T):Bool {
		return switch follow(t) {
			case TFun({args: [], ret: r}):
				switch follow(r) {
					case TInst(c, []) if (isPath(c.clPath, [], "String")): true;
					case _: false;
				}
			case _: false;
		}
	}

	static function isString(t:Ttype):Bool {
		return switch t {
			case HObj({pname: "String"}): true;
			case _: false;
		}
	}

	static function isExternField(f:TClassField):Bool {
		return !isPhysicalField(f) || (switch f.cfKind {
			case Method(MethNormal): core.ds.ArrayTools.exists(f.cfMeta, m -> Meta.metaEq(Meta.HlNative, m.meta));
			case _: false;
		}) || hasClassFieldFlag(f, CfExtern);
	}

	public static function isArrayClass(name:String):Bool {
		return switch name {
			case "hl.types.ArrayDyn" | "hl.types.ArrayBytes_Int" | "hl.types.ArrayBytes_Float" | "hl.types.ArrayObj" | "hl.types.ArrayBytes_hl_F32" |
				"hl.types.ArrayBytes_hl_UI16" | "hl.types.ArrayBytes_hl_UI8" | "hl.types.ArrayBytes_hl_I64" | "hl.types.ArrayBytes_hl_GUID":
				true;
			case _: false;
		}
	}

	static function isArrayType(t:Ttype):Bool {
		return switch t {
			case HObj(p): isArrayClass(p.pname);
			case _: false;
		}
	}

	static function maxPos(e:TExpr):Pos {
		var p = e.epos;
		return {pfile: p.pfile, pmin: p.pmax, pmax: p.pmax};
	}

	// port: the result is the UTF-16 length.
	static function toUtf8(str:String, p:Pos):{str:String, len:Int} {
		if (core.StringHelper.malformedUtf8(str)) str = core.StringHelper.isoToUtf8(str);
		var ccount = 0;
		for (c in new haxe.iterators.StringIteratorUnicode(str)) {
			if ((c >= 0xD800 && c <= 0xDFFF) || c >= 0x110000) Error.abort("Invalid unicode char", p);
			ccount++;
			if (c >= 0x10000) ccount++;
		}
		return {str: str, len: ccount};
	}

	static function tupleType(ctx:HlContext, tl:Array<Ttype>):Ttype {
		var key = HFun(tl, HVoid);
		var ct = ctx.cachedTuples.get(key);
		if (ct != null) return ct;
		var ct = HEnum(new EnumProto("", 0, null, vector({name: "", nid: 0, args: Vector.fromArrayCopy(tl)})));
		ctx.cachedTuples.set(key, ct);
		return ct;
	}

	static final nullCapture:MethodCapture = new MethodCapture(new IntMap(), vector(), HVoid, false);

	static function lookup<V>(l:Lookup<V>, v:String, fb:Void->V):Int {
		var id = l.map.get(v);
		if (id != null) return id;
		var id = l.arr.length;
		l.arr.push(null);
		l.map.set(v, id);
		l.arr[id] = fb();
		return id;
	}

	static function lookupAlloc<V>(l:Lookup<V>, v:V):Int {
		var id = l.arr.length;
		l.arr.push(v);
		return id;
	}

	static function methodContext(id:Int, t:Ttype, captured:MethodCapture, hasthis:Bool):MethodContext
		return new MethodContext(id, t, captured, hasthis);

	static function fieldName(c:TClass, f:TClassField):String return sTypePath(c.clPath) + ":" + f.cfName;

	static function efieldName(e:TEnum, f:TEnumField):String return sTypePath(e.ePath) + ":" + f.efName;

	static function globalType(ctx:HlContext, g:Int):Ttype return ctx.cglobals.arr[g];

	static function overrideKey(name:String, path:GlobalTypePath):String return name + "\x00" + sTypePath(path);

	static function isOverridden(ctx:HlContext, c:TClass, f:TClassField):Bool return ctx.overrides.exists(overrideKey(f.cfName, c.clPath));

	// port: compare treats every NaN as equal and 0.0 as equal to -0.0
	static function floatKey(f:Float):String {
		if (Math.isNaN(f)) return "nan";
		if (f == 0) return "0";
		var b = haxe.io.FPHelper.doubleToI64(f);
		return haxe.Int64.getHigh(b) + ":" + haxe.Int64.getLow(b);
	}

	static function allocFloat(ctx:HlContext, f:Float):Int return lookup(ctx.cfloats, floatKey(f), () -> f);

	static function allocI32(ctx:HlContext, i:Int):Int return lookup(ctx.cints, Std.string(i), () -> i);

	static function allocString(ctx:HlContext, s:String):Int return lookup(ctx.cstrings, s, () -> s);

	static function allocBytes(ctx:HlContext, s:haxe.io.Bytes):Int return lookup(ctx.cbytes, s.toHex(), () -> s);

	static function arrayClass(ctx:HlContext, t:Ttype):TClass {
		return switch t {
			case HI32:
				ctx.arrayImpl.ai32;
			case HUI16:
				ctx.arrayImpl.aui16;
			case HUI8:
				ctx.arrayImpl.aui8;
			case HF32:
				ctx.arrayImpl.af32;
			case HF64:
				ctx.arrayImpl.af64;
			case HI64:
				if (ctx.arrayImpl.ai64 == null) die("", "genhl.ml") else ctx.arrayImpl.ai64;
			case HGUID:
				if (ctx.arrayImpl.aguid == null) die("", "genhl.ml") else ctx.arrayImpl.aguid;
			case HDyn:
				ctx.arrayImpl.adyn;
			case _:
				ctx.arrayImpl.aobj;
		}
	}

	static function memberFun(c:TClass, t:T):T {
		return switch follow(t) {
			case TFun(s): TFun({args: VectorTools.cons({name: "this", optional: false, type: TInst(c, vector())}, s.args), ret: s.ret});
			case _: die("", "genhl.ml");
		}
	}

	static function unsigned(t:T):Bool {
		return switch follow(t) {
			case TAbstract(a, _) if (isPath(a.aPath, ["haxe"], "UInt32")): true;
			case TAbstract(a, pl): unsigned(core.Abstract.getUnderlyingType(a, pl));
			case _: false;
		}
	}

	static function unsignedOp(e1:TExpr, e2:TExpr):Bool {
		function isUnsigned(e:TExpr):Bool {
			return switch e.eexpr {
				case TConst(TInt(_)): true;
				case _: unsigned(e.etype);
			}
		}
		return isUnsigned(e1) && isUnsigned(e2);
	}

	static function getConst(e:TExpr):TConstant {
		return switch e.eexpr {
			case TConst(c): c;
			case TParenthesis(e) | TCast(e, _): getConst(e);
			case _: Error.abort("Should be a constant", e.epos);
		}
	}

	static function setCurpos(ctx:HlContext, p:Pos):Void ctx.m.mcurpos = p;

	static function makeDebug(ctx:HlContext, arr:Array<Pos>):Vector<DebugInfo> {
		function getRelativePath(p:Pos):String {
			return if (Gctx.defined(ctx.com, Define.AbsolutePath)) {
				if (core.OcamlFilename.isRelative(p.pfile)) core.OcamlFilename.concat(core.OcamlFilename.sysGetcwd(), p.pfile) else p.pfile;
			} else ctx.com.classPaths.relativePath(p.pfile);
		}
		var pos:DebugInfo = {file: 0, line: 0, pos: Globals.nullPos};
		var curFile = 0;
		var curLine = 0;
		var cur = Globals.nullPos;
		var out = new Vector<DebugInfo>(arr.length);
		for (i in 0...arr.length) {
			var p = arr[i];
			if (p != cur) {
				var file = if (p.pfile == cur.pfile) curFile else lookup(ctx.cdebugFiles, p.pfile, () -> getRelativePath(p));
				var line = syntax.Lexer.getErrorLine(p);
				if (line != curLine || file != curFile) {
					curFile = file;
					curLine = line;
					pos = {file: file, line: line, pos: p};
				}
				cur = p;
			}
			out[i] = pos;
		}
		return out;
	}

	static var fakeTnullCache:Null<TAbstract> = null;

	static function fakeTnull():TAbstract {
		if (fakeTnullCache == null) {
			var a = nullAbstract.clone();
			a.aPath = {pack: [], name: "Null"};
			a.aParams = vector(mkTypeParam(nullClass, TPHType, null, null));
			fakeTnullCache = a;
		}
		return fakeTnullCache;
	}

	static function isExcluded(c:TClass):Bool return hasClassFlag(c, CExcluded) && !hasClassFlag(c, CInterface);

	static function getRecCache(ctx:HlContext, t:T, noneCallback:Void->Ttype, notFoundCallback:TRef->Ttype):Ttype {
		// port: `loop retried l` walks the list from its head (the last element).
		var retried = false;
		var i = ctx.recCache.length - 1;
		while (i >= 0) {
			var e = ctx.recCache[i];
			i--;
			if (!core.TUnification.fastEq(e.t, t)) continue;
			/* Note from Simon: This is unlikely to be the "correct" fix. What this really does is ignore a singular `ref None` lookup
			   and ultimately (once hitting the `| [] -> ` case above) go through the `not_found_callback`, at which point two entries
			   with the same `t` key exists in `ctx.rec_cache`. This is not a robust solution to a recursive data problem, but at the
			   moment it is unclear how to reproduce any actual issue from this. */
			if (e.tref.v != null) return e.tref.v;
			if (retried) return noneCallback();
			retried = true;
		}
		var tref = new TRef();
		ctx.recCache.push({t: t, tref: tref});
		var t = notFoundCallback(tref);
		ctx.recCache.pop();
		return t;
	}

	// port: the name of `TInst ({ cl_path = ["hl"],"Abstract" },[TInst({ cl_kind = KExpr (EConst (String(name,_)),_) },_)])`
	static function hlAbstractName(t:T):Null<{name:String, ident:Dynamic}> {
		return switch t {
			case TInst(c, [TInst({clKind: KExpr(e)}, _)]) if (isPath(c.clPath, ["hl"], "Abstract")):
				switch e.expr {
					case EConst(String(name, _)): {name: name, ident: e};
					case _: null;
				}
			case _: null;
		}
	}

	public static function toType(ctx:HlContext, t:T, ?tref:TRef):Ttype {
		switch t {
			case TMono(r):
				return if (r.tmType == null) HDyn else toType(ctx, r.tmType, tref);
			case TType(td, tl):
				var t = getRecCache(ctx, t, () -> HDyn, tref -> toType(ctx, applyTypedef(td, tl), tref));
				if (td.tPath.pack.length == 2 && td.tPath.pack[0] == "haxe" && td.tPath.pack[1] == "macro") {
					ctx.macroTypedefs.set(td.tPath.name, t);
					return t;
				}
				return t;
			case TLazy(f):
				return toType(ctx, lazyType(f), tref);
			case TFun(s):
				var ret = toType(ctx, s.ret);
				var args = [
					for (a in s.args) {
						var pt = toType(ctx, a.type);
						if (a.optional && !isNullable(pt)) HRef(pt) else pt;
					}
				];
				return HFun(args, ret);
			case TAnon(a) if (a.aStatus.match(ClassStatics(_) | EnumStatics(_))):
				return switch a.aStatus {
					case ClassStatics(c):
						classType(ctx, c, extractParamTypes(c.clParams), true);
					case EnumStatics(e):
						enumClass(ctx, e);
					case _: die("", "genhl.ml");
				}
			case TAnon(a):
				if (!a.aFields.keys().hasNext()) return HDyn;
				/* can't use physical comparison in PMap since addresses might change in GC compact,
					maybe add an uid to tanon if too slow ? */
				var cached = ctx.anonsCache.get(a);
				if (cached != null) return cached;
				var vp = new VirtualProto();
				var t = HVirtual(vp);
				if (tref != null) tref.v = t;
				ctx.anonsCache.set(a, t);
				var fields = [for (k in sortedKeys(a.aFields)) cfieldType(ctx, a.aFields.get(k))];
				fields.reverse();
				var fields = listSort((f1:HField, f2:HField) -> strCompare(f1.name, f2.name), fields);
				vp.vfields = Vector.fromArrayCopy(fields);
				for (i in 0...vp.vfields.length) vp.vindex.set(vp.vfields[i].name, i);
				return t;
			case TDynamic(_):
				return HDyn;
			case TEnum(e, _):
				return enumType(ctx, e, tref);
			case TInst(_, _) if (hlAbstractName(t) != null):
				var a = hlAbstractName(t);
				return HAbstract(a.name, allocString(ctx, a.name), a.ident);
			case TInst(c, pl):
				switch c.clKind {
					case KTypeParameter(ttp):
						for (t in getConstraints(ttp)) {
							var ft = follow(applyParams(c.clParams, pl, t));
							switch ft {
								case TInst(c, _) if (!hasClassFlag(c, CInterface)): return toType(ctx, ft, tref);
								case _:
							}
						}
						return HDyn;
					case _:
						return classType(ctx, c, pl, false, tref);
				}
			case TAbstract(a, [t1]) if (isPath(a.aPath, [], "Null")):
				var t = toType(ctx, t1, tref);
				return if (!isNullable(t) && !tEq(t, HVoid)) HNull(t) else t;
			case TAbstract(a, pl):
				if (Meta.has(Meta.CoreType, a.aMeta)) {
					var pack = a.aPath.pack.join(".");
					return switch [pack, a.aPath.name] {
						case ["", "Void"]: HVoid;
						case ["", "Int"] | ["haxe", "UInt32"]: HI32;
						case ["", "Float"]: HF64;
						case ["", "Single"]: HF32;
						case ["", "Bool"]: HBool;
						case ["", "Dynamic"]: HDyn;
						case ["", "Class"]:
							classType(ctx, ctx.baseClass, vector(), false);
						case ["", "Enum"]:
							classType(ctx, ctx.baseType, vector(), false);
						case ["", "EnumValue"]: HDyn;
						case ["hl", "Ref"]: HRef(toType(ctx, pl[0]));
						case ["hl", "Bytes" | "BytesAccess"]: HBytes;
						case ["hl", "Type"]: HType;
						case ["hl", "UI16"]: HUI16;
						case ["hl", "UI8"]: HUI8;
						case ["hl", "I64"]: HI64;
						case ["hl", "GUID"]: HGUID;
						case ["hl", "NativeArray"]: HArray(toType(ctx, pl[0]));
						case ["haxe.macro", "Position"]: HAbstract("macro_pos", allocString(ctx, "macro_pos"), macroPosIdent);
						case ["haxe.coro", "Coroutine"]:
							switch pl {
								case [TFun(s)]:
									var s = context.Common.expandCoroType(ctx.com.basic, s.args, s.ret);
									toType(ctx, TFun(s));
								case _:
									die("", "genhl.ml");
							}
						case _: throw new Failure("Unknown core type " + sTypePath(a.aPath));
					}
				} else
					return getRecCache(ctx, t, () -> HDyn, tref -> toType(ctx, core.Abstract.getUnderlyingType(a, pl), tref));
		}
	}

	static function resolveClass(ctx:HlContext, c:TClass, pl:TParams, statics:Bool):TClass {
		if (isPath(c.clPath, [], "Array")) {
			switch pl {
				case [t]:
					return if (statics) ctx.arrayImpl.abase else arrayClass(ctx, toType(ctx, t));
				case []:
					return die("", "genhl.ml");
				case _:
			}
		}
		return c;
	}

	static function cfieldType(ctx:HlContext, cf:TClassField):HField {
		var t = toType(ctx, cf.cfType);
		var t = switch [cf.cfKind, t] {
			case [Method(MethNormal | MethInline), HFun(args, ret)]: HMethod(args, ret);
			case _: t;
		}
		return {name: cf.cfName, nid: allocString(ctx, cf.cfName), t: t};
	}

	static function fieldType(ctx:HlContext, f:TFieldAccess, p:Pos):T {
		return switch f {
			case FInstance(c, pl, f):
				instanceFieldType(ctx, c, pl, f, p);
			case FClosure(cl, f) if (cl != null):
				instanceFieldType(ctx, cl.cls, cl.params, f, p);
			case FStatic(_, f) | FAnon(f) | FClosure(_, f): f.cfType;
			case FDynamic(_): tDynamic;
			case FEnum(_, f): f.efType;
		}
	}

	// port: the `FInstance (c,pl,f) | FClosure (Some (c,pl),f)` case of field_type
	static function instanceFieldType(ctx:HlContext, c:TClass, pl:TParams, f:TClassField, p:Pos):T {
		var creal = resolveClass(ctx, c, pl, false);
		function loop(c:TClass):TClassField {
			var cf = c.clFields.get(f.cfName);
			if (cf != null && !(cf.cfKind.match(Method(MethDynamic)) && hasClassFieldFlag(cf, CfOverride))) return cf;
			return if (c.clSuper != null) loop(c.clSuper.cls) else Error.abort(sTypePath(creal.clPath) + " is missing field " + f.cfName, p);
		}
		return loop(creal).cfType;
	}

	static function realType(ctx:HlContext, e:TExpr):Ttype {
		function loop(e:TExpr):T {
			return switch e.eexpr {
				case TField(_, f):
					var ft = fieldType(ctx, f, e.epos);
					switch [ft, e.etype] {
						case [TFun(s), TFun(s2)]:
							if (s.args.length != s2.args.length) throw new core.ds.InvalidArgument("List.map2");
							TFun({
								args: VectorTools.init(s.args.length, i -> {
										var a = s.args[i];
										var a2 = s2.args[i];
										switch [a.type, a2.type] {
											/*
												Handle function variance:
												If we have type parameters which are function types, we need to keep the functions
												because we might need to insert a cast to coerce Void->Bool to Void->Dynamic for instance.
											 */
											case [TInst({clKind: KTypeParameter(_)}, _), TFun(_)]: a2;
											/*
												If we have a number, it is more accurate to cast it to the type parameter before wrapping it as dynamic
												Ignore dynamic method (#7166)
											 */
											case [TInst({clKind: KTypeParameter(_)}, _), t] if (isNumber(toType(ctx, t)) && (switch f {
													case FInstance(_, _, {cfKind: Var(_) | Method(MethDynamic)}): false;
													case _: true;
												})):
												{name: a.name, optional: a.optional, type: TAbstract(fakeTnull(), vector(t))};
											case _:
												a;
										}
									}),
								ret: s.ret
							});
						case _: ft;
					}
				case TLocal(v): v.vType;
				case TParenthesis(e): loop(e);
				case TArray(arr, _):
					function loop(t:T):T {
						return switch follow(t) {
							case TInst(c, [t]) if (isPath(c.clPath, [], "Array")): t;
							case TAbstract(a, pl): loop(core.Abstract.getUnderlyingType(a, pl));
							case _: tDynamic;
						}
					}
					loop(arr.etype);
				case _: e.etype;
			}
		}
		return toType(ctx, loop(e));
	}

	static function classType(ctx:HlContext, c:TClass, pl:TParams, statics:Bool, ?tref:TRef):Ttype {
		var c = if (hasClassFlag(c, CExtern)) resolveClass(ctx, c, pl, statics) else c;
		var keyName = if (statics) "$" + c.clPath.name else c.clPath.name;
		var keyPath = [keyName].concat(c.clPath.pack).join("\x00");
		var cached = ctx.cachedTypes.get(keyPath);
		if (cached != null) return cached;
		if (hasClassFlag(c, CInterface) && !statics) {
			var vp = new VirtualProto();
			var t = HVirtual(vp);
			ctx.cachedTypes.set(keyPath, t);
			function loop(c:TClass):Array<HField> {
				function concatUniq(fields:Array<HField>, pfields:Array<HField>):Array<HField> {
					for (pf in pfields) if (!core.ds.ArrayTools.exists(fields, f -> f.name == pf.name)) fields = [pf].concat(fields);
					return fields;
				}
				var pfields:Array<HField> = [];
				for (i in c.clImplements) pfields = loop(i.cls).concat(pfields);
				var fields = [for (k in sortedKeys(c.clFields)) cfieldType(ctx, c.clFields.get(k))];
				fields.reverse();
				return concatUniq(fields, pfields);
			}
			var fields = loop(c);
			var fields = listSort((f1:HField, f2:HField) -> strCompare(f1.name, f2.name), fields);
			vp.vfields = Vector.fromArrayCopy(fields);
			for (i in 0...vp.vfields.length) vp.vindex.set(vp.vfields[i].name, i);
			return t;
		}
		var pname = sTypePath({pack: c.clPath.pack, name: keyName});
		var p = new ClassProto(pname, allocString(ctx, pname));
		p.pnfields = -1;
		var t = if (Meta.has(Meta.Struct, c.clMeta) && !statics) HStruct(p) else HObj(p);
		if (tref != null) tref.v = t;
		ctx.ctDepth = ctx.ctDepth + 1;
		ctx.cachedTypes.set(keyPath, t);
		if (isPath(c.clPath, [], "Array")) die("", "genhl.ml");
		if (c == ctx.baseClass) {
			if (statics) die("", "genhl.ml");
			p.pnfields = 1;
		}
		var tsup = if (c.clSuper != null && !statics) classType(ctx, c.clSuper.cls, vector(), statics) else if (statics) classType(ctx, ctx.baseClass, vector(), false) else null;
		var startField:Int, virtuals:Vector<Int>;
		switch tsup {
			case null:
				startField = 0;
				virtuals = vector();
			case HObj(psup) | HStruct(psup):
				if (isStruct(t) != isStruct(tsup))
					Error.abort(if (isStruct(t)) "Struct cannot extend a not struct class" else "Class cannot extend a struct", c.clPos);
				if (psup.pnfields < 0) die("", "genhl.ml");
				p.psuper = psup;
				startField = psup.pnfields;
				virtuals = psup.pvirtuals;
			case _:
				startField = 0;
				virtuals = die("", "genhl.ml");
		}
		var fa:Array<HField> = [];
		var pa:Array<FieldProto> = [];
		var virtuals = virtuals.toArray();
		function addField(name:String, getT:Void->Ttype):Int {
			var fid = fa.length + startField;
			var str = allocString(ctx, name);
			p.pindex.set(name, {fid: fid, t: HVoid});
			fa.push({name: name, nid: str, t: HVoid});
			ctx.ctDelayed.push(() -> {
				var t = getT();
				p.pindex.set(name, {fid: fid, t: t});
				p.pfields[fid - startField] = {name: name, nid: str, t: t};
			});
			return fid;
		}
		if (!hasClassFlag(c, CExtern)) for (f in (if (statics) c.clOrderedStatics else c.clOrderedFields)) {
			if (isExternField(f) || (statics && f.cfName == "__meta__")) continue;
			var fid:Null<Int> = switch f.cfKind {
				case Method(m) if (m != MethDynamic && !statics):
					var g = allocFid(ctx, c, f);
					p.pfunctions.set(f.cfName, g);
					var virt:Null<Int> = if (hasClassFieldFlag(f, CfOverride)) {
						var vid = try -(getIndex(f.cfName, p).fid) - 1 catch (_:NotFound) die("", "genhl.ml");
						virtuals[vid] = g;
						vid;
					} else if (isOverridden(ctx, c, f)) {
						var vid = virtuals.length;
						virtuals.push(g);
						p.pindex.set(f.cfName, {fid: -vid - 1, t: HVoid});
						vid;
					} else null;
					pa.push(new FieldProto(f.cfName, allocString(ctx, f.cfName), g, virt));
					null;
				case Method(MethDynamic) if (hasClassFieldFlag(f, CfOverride)):
					try getIndex(f.cfName, p).fid catch (_:NotFound) die("", "genhl.ml");
				case _:
					var fid = addField(f.cfName, () -> {
						var t = toType(ctx, f.cfType);
						if (hasMeta(core.MetaList.StrictMeta.Custom(":packed"), f.cfMeta)) {
							switch t {
								case HStruct(_):
								case _: Error.abort("Packed field should be struct", f.cfPos);
							}
							HPacked(t);
						} else t;
					});
					fid;
			}
			switch [f.cfKind, f.cfExpr, fid] {
				case [Method(_), e, fid] if (e != null && fid != null): p.pbindings.unshift({fid: fid, fidx: allocFunPath(ctx, c.clPath, f.cfName)});
				case _:
			}
		}
		if (!statics) {
			/* add interfaces */
			var seen = new StringMap<Bool>();
			function addInterface(i:TClass, pl:TParams):Void {
				if (!hasClassFlag(i, CExtern) && !seen.exists(sTypePath(i.clPath))) {
					seen.set(sTypePath(i.clPath), true);
					var rid = -1;
					rid = addField("", () -> {
						var t = toType(ctx, TInst(i, pl));
						p.pinterfaces.set(t, rid);
						t;
					});
					for (si in i.clImplements) {
						var spl = si.params.map(t -> applyParams(i.clParams, pl, t));
						addInterface(si.cls, spl);
					}
				}
			}
			for (i in c.clImplements) addInterface(i.cls, i.params);
			/* check toString */
			var cf = c.clFields.get("toString");
			if (cf != null && !(hasClassFieldFlag(cf, CfOverride) || c.clFields.exists("__string") || !isToString(cf.cfType))) {
				var fmethod = allocFunPath(ctx, c.clPath, "__string");
				pa.push(new FieldProto("__string", allocString(ctx, "__string"), fmethod, null));
			}
		} else {
			switch c.clConstructor {
				case f if (f != null && !isExternField(f)):
					var g = allocFid(ctx, c, f);
					p.pbindings.unshift({fid: (try getIndex("__constructor__", p).fid catch (_:NotFound) die("", "genhl.ml")), fidx: g});
				case _:
			}
		}
		p.pnfields = fa.length + startField;
		p.pfields = Vector.fromArrayCopy(fa);
		p.pproto = Vector.fromArrayCopy(pa);
		p.pvirtuals = Vector.fromArrayCopy(virtuals);
		ctx.ctDepth = ctx.ctDepth - 1;
		if (ctx.ctDepth == 0) {
			var todo = ctx.ctDelayed;
			ctx.ctDelayed = [];
			var i = todo.length;
			while (i-- > 0) todo[i]();
		}
		if (!statics && c != ctx.coreType && c != ctx.coreEnum) p.pclassglobal = classGlobal(ctx, if (statics) ctx.baseClass else c).g;
		return t;
	}

	static function enumType(ctx:HlContext, e:TEnum, ?tref:TRef):Ttype {
		var keyPath = [e.ePath.name].concat(e.ePath.pack).join("\x00");
		var cached = ctx.cachedTypes.get(keyPath);
		if (cached != null) return cached;
		var ename = sTypePath(e.ePath);
		var et = new EnumProto(ename, allocString(ctx, ename), null, vector());
		var t = HEnum(et);
		if (tref != null) tref.v = t;
		ctx.cachedTypes.set(keyPath, t);
		et.efields = e.eNames.mapToVector(n -> {
			var f = e.eConstrs.get(n);
			if (f == null) throw NotFound.raise();
			var args:Vector<Ttype> = switch f.efType {
				case TFun(s): s.args.map(a -> toType(ctx, a.type));
				case _: vector();
			}
			({name: f.efName, nid: allocString(ctx, f.efName), args: args} : EField);
		});
		var ct = enumClass(ctx, e);
		et.eglobal = allocGlobal(ctx, switch ct {
			case HObj(o): o.pname;
			case _: die("", "genhl.ml");
		}, ct);
		return t;
	}

	static function enumClass(ctx:HlContext, e:TEnum):Ttype {
		var keyName = "$" + e.ePath.name;
		var keyPath = [keyName].concat(e.ePath.pack).join("\x00");
		var cached = ctx.cachedTypes.get(keyPath);
		if (cached != null) return cached;
		var pname = sTypePath({pack: e.ePath.pack, name: keyName});
		var p = new ClassProto(pname, allocString(ctx, pname));
		p.pnfields = -1;
		var t = HObj(p);
		ctx.cachedTypes.set(keyPath, t);
		var psuper = switch classType(ctx, ctx.baseEnum, vector(), false) {
			case HObj(o): o;
			case _: die("", "genhl.ml");
		}
		var startField = psuper.pnfields;
		var fa:Array<HField> = [];
		function addField(name:String, t:Ttype):Int {
			var fid = startField + fa.length;
			var str = allocString(ctx, name);
			fa.push({name: name, nid: str, t: t});
			p.pindex.set(name, {fid: fid, t: t});
			return fid;
		}
		for (k in sortedKeys(e.eConstrs)) {
			var ef = e.eConstrs.get(k);
			switch follow(ef.efType) {
				case TEnum(_):
					addField(ef.efName, toType(ctx, ef.efType));
				case TFun(s):
					var fid = addField(ef.efName, toType(ctx, ef.efType));
					var eid = allocEid(ctx, e, ef);
					var fargs = [for (a in s.args) toType(ctx, a.type)];
					var tret = toType(ctx, s.ret);
					var old = ctx.m;
					var ft = toType(ctx, ef.efType);
					ctx.m = methodContext(eid, ft, nullCapture, false);
					setCurpos(ctx, ef.efPos);
					var argRegs = [for (t in fargs) allocFresh(ctx, t)];
					var retReg = allocFresh(ctx, tret);
					op(ctx, OMakeEnum(retReg, ef.efIndex, argRegs));
					op(ctx, ORet(retReg));
					var hlf = new Fundecl({fst: "", snd: ""}, eid, HFun(fargs, tret), Vector.fromArrayCopy(ctx.m.mregs), Vector.fromArrayCopy(ctx.m.mops), makeDebug(ctx, ctx.m.mdebug),
						makeAssigns(ctx.m.massign), false);
					ctx.m = old;
					ctx.definedFuns.set(eid, true);
					ctx.cfunctions.push(hlf);
					p.pbindings.unshift({fid: fid, fidx: eid});
				case t:
					die("", "genhl.ml");
			}
		}
		p.pnfields = fa.length;
		p.pfields = Vector.fromArrayCopy(fa);
		p.psuper = psuper;
		return t;
	}

	static function allocFunPath(ctx:HlContext, path:GlobalTypePath, name:String):Int {
		var n = ctx.cfids.arr.length;
		var id = lookup(ctx.cfids, name + "\x00" + path.pack.join(".") + "\x00" + path.name, () -> true);
		if (id == n) ctx.cfidsKeys.push({name: name, path: path, id: id});
		return id;
	}

	static function allocFid(ctx:HlContext, c:TClass, f:TClassField):Int {
		return switch f.cfKind {
			case Var(_): die("", "genhl.ml");
			case _: allocFunPath(ctx, c.clPath, f.cfName);
		}
	}

	static function allocEid(ctx:HlContext, e:TEnum, f:TEnumField):Int return allocFunPath(ctx, e.ePath, f.efName);

	static function allocFunctionName(ctx:HlContext, f:String):Int return allocFunPath(ctx, {pack: [], name: ""}, f);

	static function allocGlobal(ctx:HlContext, name:String, t:Ttype):Int return lookup(ctx.cglobals, name, () -> t);

	static function classGlobal(ctx:HlContext, c:TClass, resolve:Bool = true):{g:Int, t:Ttype} {
		var isStatic = c != ctx.baseClass;
		var c = if (resolve && isArrayClass(sTypePath(c.clPath))) ctx.arrayImpl.abase else c;
		var c = resolveClass(ctx, c, extractParamTypes(c.clParams), isStatic);
		var t = classType(ctx, c, vector(), isStatic);
		return {g: allocGlobal(ctx, "$" + sTypePath(c.clPath), t), t: t};
	}

	static function resolveClassGlobal(ctx:HlContext, cpath:String):Int return lookup(ctx.cglobals, "$" + cpath, () -> die("", "genhl.ml"));

	static function resolveType(ctx:HlContext, path:Array<String>):Ttype {
		var t = ctx.cachedTypes.get(path.join("\x00"));
		if (t == null) throw NotFound.raise();
		return t;
	}

	static function allocStd(ctx:HlContext, name:String, args:Array<Ttype>, ret:Ttype):Int {
		var lib = "std";
		/* different from :hlNative to prevent mismatch */
		var nid = lookup(ctx.cnatives, "$" + name + "@" + lib + "\x00-1", () -> {
			var fid = allocFunPath(ctx, {pack: [], name: "std"}, name);
			ctx.definedFuns.set(fid, true);
			var n = allocString(ctx, name);
			var l = allocString(ctx, lib);
			({lib: l, name: n, t: HFun(args, ret), findex: fid} : Native);
		});
		return ctx.cnatives.arr[nid].findex;
	}

	static function allocFresh(ctx:HlContext, t:Ttype):Int {
		var rid = ctx.m.mregs.length;
		ctx.m.mregs.push(t);
		return rid;
	}

	static function allocTmp(ctx:HlContext, t:Ttype):Int {
		if (!ctx.optimize) return allocFresh(ctx, t);
		var a = ctx.m.mallocs.get(t);
		if (a == null) {
			a = new Allocator();
			ctx.m.mallocs.set(t, a);
		}
		return if (a.aAll.length == 0) {
			var r = allocFresh(ctx, t);
			a.aAll = [r];
			r;
		} else a.aAll[0];
	}

	static function currentPos(ctx:HlContext):Int return ctx.m.mops.length;

	static function rtype(ctx:HlContext, r:Int):Ttype return ctx.m.mregs[r];

	static function hold(ctx:HlContext, r:Int):Void {
		if (!ctx.optimize) return;
		var t = rtype(ctx, r);
		var a = ctx.m.mallocs.get(t);
		if (a == null) throw NotFound.raise();
		var idx = a.aAll.indexOf(r);
		if (idx >= 0) a.aAll = a.aAll.slice(0, idx).concat(a.aAll.slice(idx + 1)) else if (a.aHold.indexOf(r) < 0) die("", "genhl.ml");
		a.aHold = [r].concat(a.aHold);
	}

	static function free(ctx:HlContext, r:Int):Void {
		if (!ctx.optimize) return;
		var t = rtype(ctx, r);
		var a = ctx.m.mallocs.get(t);
		if (a == null) throw NotFound.raise();
		var idx = a.aHold.indexOf(r);
		if (idx < 0) die("", "genhl.ml");
		var last = a.aHold.indexOf(r, idx + 1) < 0;
		a.aHold = a.aHold.slice(0, idx).concat(a.aHold.slice(idx + 1));
		/* insert sorted */
		if (last) {
			var l = a.aAll;
			var i = 0;
			while (i < l.length && !(l[i] > r)) i++;
			a.aAll = l.slice(0, i).concat([r]).concat(l.slice(i));
		}
	}

	static function declVar(ctx:HlContext, v:TVar):Void ctx.m.mdeclared.unshift(v.vId);

	static function allocVar(ctx:HlContext, v:TVar, newVar:Bool):Int {
		if (newVar) declVar(ctx, v);
		var r = ctx.m.mvars.get(v.vId);
		if (r != null) return r;
		var r = allocTmp(ctx, toType(ctx, v.vType));
		hold(ctx, r);
		ctx.m.mvars.set(v.vId, r);
		return r;
	}

	static function pushOp(ctx:HlContext, o:Opcode):Void {
		ctx.m.mdebug.push(ctx.m.mcurpos);
		ctx.m.mops.push(o);
	}

	static function op(ctx:HlContext, o:Opcode):Void {
		switch o {
			case OMov(a, b) if (a == b):
			case _:
				pushOp(ctx, o);
		}
	}

	static function setOp(ctx:HlContext, pos:Int, o:Opcode):Void ctx.m.mops[pos] = o;

	static function allocArray(ctx:HlContext, size:Int, et:Ttype):Int {
		var a = allocTmp(ctx, cHArrayDyn);
		var b = allocTmp(ctx, HArray(et));
		var rt = allocTmp(ctx, HType);
		op(ctx, OType(rt, et));
		op(ctx, OCall2(a, allocStd(ctx, "alloc_array", [HType, HI32], cHArrayDyn), rt, size));
		op(ctx, OUnsafeCast(b, a));
		return b;
	}

	static function jump(ctx:HlContext, f:Int->Opcode):Void->Void {
		var pos = currentPos(ctx);
		op(ctx, OJAlways(-1)); /* loop */
		return () -> setOp(ctx, pos, f(currentPos(ctx) - pos - 1));
	}

	static function jumpBack(ctx:HlContext):Void->Void {
		var pos = currentPos(ctx);
		op(ctx, OLabel(0));
		return () -> op(ctx, OJAlways(pos - currentPos(ctx) - 1));
	}

	static function regInt(ctx:HlContext, v:Int):Int {
		var r = allocTmp(ctx, HI32);
		op(ctx, OInt(r, allocI32(ctx, v)));
		return r;
	}

	static function shl(ctx:HlContext, idx:Int, v:Int):Int {
		if (v == 0) return idx;
		hold(ctx, idx);
		var rv = regInt(ctx, v);
		var idx2 = allocTmp(ctx, HI32);
		op(ctx, OShl(idx2, idx, rv));
		free(ctx, idx);
		return idx2;
	}

	static function setDefault(ctx:HlContext, r:Int):Void {
		var t = rtype(ctx, r);
		switch [getGroup(t), t] {
			case [GInt, _]:
				op(ctx, OInt(r, allocI32(ctx, 0)));
			case [GFloat, _]:
				op(ctx, OFloat(r, allocFloat(ctx, 0.)));
			case [GBool, _]:
				op(ctx, OBool(r, false));
			case [_, HType]:
				op(ctx, OType(r, HVoid));
			case _:
				op(ctx, ONull(r));
		}
	}

	static function readMem(ctx:HlContext, rdst:Int, bytes:Int, index:Int, t:Ttype):Void {
		switch getGroup(t) {
			case GInt | GFloat:
				var nb = typeSizeBits(t);
				if (nb == 0) op(ctx, OGetUI8(rdst, bytes, index)) else if (nb == 1) op(ctx, OGetUI16(rdst, bytes, index)) else
					op(ctx, OGetMem(rdst, bytes, index));
			case _:
				die("", "genhl.ml");
		}
	}

	static function writeMem(ctx:HlContext, bytes:Int, index:Int, t:Ttype, r:Int):Void {
		switch getGroup(t) {
			case GInt | GFloat:
				var nb = typeSizeBits(t);
				if (nb == 0) op(ctx, OSetUI8(bytes, index, r)) else if (nb == 1) op(ctx, OSetUI16(bytes, index, r)) else op(ctx, OSetMem(bytes, index, r));
			case _:
				die("", "genhl.ml");
		}
	}

	static function commonType(ctx:HlContext, e1:TExpr, e2:TExpr, forEq:Bool, p:Pos):Ttype {
		var t1 = toType(ctx, e1.etype);
		var t2 = toType(ctx, e2.etype);
		if (t1 == t2) return t1;
		return switch [getGroup(t1), getGroup(t2), t1, t2] {
			case [GNull, GNull, _, _]:
				var ti1 = getInnerType(t1);
				var ti2 = getInnerType(t2);
				HNull(commonTypeNumber(ti1, ti2));
			case [GNull, GInt | GFloat | GBool, _, _] | [GInt | GFloat | GBool, GNull, _, _]:
				var ti1 = getInnerType(t1);
				var ti2 = getInnerType(t2);
				if (forEq) HNull(commonTypeNumber(ti1, ti2)) else commonTypeNumber(ti1, ti2);
			case [GInt | GFloat, GInt | GFloat, _, _]: commonTypeNumber(t1, t2);
			case [_, GInt | GFloat, HDyn, _]: HF64;
			case [GInt | GFloat, _, _, HDyn]: HF64;
			case [_, _, HDyn, _]: HDyn;
			case [_, _, _, HDyn]: HDyn;
			case _ if (forEq && safeCast(t1, t2)): t2;
			case _ if (forEq && safeCast(t2, t1)): t1;
			case [_, _, HObj(_), HVirtual(_)] | [_, _, HVirtual(_), HObj(_)] | [_, _, HVirtual(_), HVirtual(_)]: HDyn;
			case [_, _, HFun(_), HFun(_)]: HDyn;
			case _:
				Error.abort("Can't find common type " + tstr(t1) + " and " + tstr(t2), p);
		}
	}

	static function capturedIndex(ctx:HlContext, v:TVar):Null<Int> {
		if (!hasVarFlag(v, VCaptured)) return null;
		return ctx.m.mcaptured.cMap.get(v.vId);
	}

	static function realName(v:TVar):String {
		function loop(l:Metadata):String {
			for (m in l) if (Meta.metaEq(Meta.RealPath, m.meta) && m.exprs.length == 1) switch m.exprs[0].expr {
				case EConst(String(name, _)): return name;
				case _:
			}
			return v.vName;
		}
		// port: `loop` stops at the first entry matching the pattern
		return switch loop(v.vMeta) {
			case "_gthis": "this";
			case name: switch v.vKind {
					case VInlinedConstructorVariable(sl): sl.join(".");
					case _: name;
				}
		}
	}

	static function notDebugVar(ctx:HlContext, v:TVar):Bool {
		return switch v.vKind {
			case VUser(_): false;
			case VInlinedConstructorVariable(_): false;
			case _: true;
		}
	}

	static function addAssign(ctx:HlContext, v:TVar, force:Bool = false):Void {
		if (!force && notDebugVar(ctx, v)) return;
		var name = realName(v);
		var a = new Lassign(allocString(ctx, name), v.vId, currentPos(ctx) - 1, -1);
		ctx.m.massign.push(a);
		if (a.laPos >= 0) {
			var l = ctx.m.mvarAssigns.get(v.vId);
			if (l == null) {
				l = [];
				ctx.m.mvarAssigns.set(v.vId, l);
			}
			l.unshift(a);
		}
	}

	static function closeScopes(ctx:HlContext, declared:Array<Int>):Void {
		var pos = currentPos(ctx);
		for (vid in declared) {
			var l = ctx.m.mvarAssigns.get(vid);
			if (l != null) for (a in l) if (a.laScopeEnd < 0) a.laScopeEnd = pos;
		}
	}

	static function addCapture(ctx:HlContext, r:Int):Void {
		for (v in ctx.m.mcaptured.cVars) {
			var name = realName(v);
			ctx.m.massign.push(new Lassign(allocString(ctx, name), -1, -(r + 2), -1));
		}
	}

	static function beforeReturn(ctx:HlContext):Void {
		var i = ctx.m.mtrys;
		while (i > 0) {
			op(ctx, OEndTrap(false));
			i--;
		}
	}

	static function beforeBreakContinue(ctx:HlContext):Void {
		var i = ctx.m.mtrys - ctx.m.mloopTrys;
		while (i > 0) {
			op(ctx, OEndTrap(false));
			i--;
		}
	}

	static function typeGlobal(ctx:HlContext, t:ModuleType, p:Pos):{g:Int, t:Ttype} {
		switch t {
			case TClassDecl(c):
				return classGlobal(ctx, c);
			case TAbstractDecl(a):
				var rt = classType(ctx, ctx.baseType, vector(), false);
				var g = switch [a.aPath.pack.join("."), a.aPath.name] {
					case ["", "Int"]: allocGlobal(ctx, "$Int", rt);
					case ["", "Float"]: allocGlobal(ctx, "$Float", rt);
					case ["", "Bool"]: allocGlobal(ctx, "$Bool", rt);
					case ["", "Class"]: classGlobal(ctx, ctx.baseClass).g;
					case ["", "Enum"]: classGlobal(ctx, ctx.baseEnum).g;
					case ["", "Dynamic"]: allocGlobal(ctx, "$Dynamic", rt);
					case _: Error.abort("Unsupported type value " + sTypePath(tPath(t)), p);
				}
				return {g: g, t: rt};
			case TEnumDecl(e):
				var rt = enumClass(ctx, e);
				var g = allocGlobal(ctx, switch rt {
					case HObj(o): o.pname;
					case _: die("", "genhl.ml");
				}, rt);
				return {g: g, t: rt};
			case TTypeDecl(_):
				return die("", "genhl.ml");
		}
	}

	static function typeValue(ctx:HlContext, t:ModuleType, p:Pos):Int {
		var gt = typeGlobal(ctx, t, p);
		var r = allocTmp(ctx, gt.t);
		op(ctx, OGetGlobal(r, gt.g));
		return r;
	}

	static function evalTo(ctx:HlContext, e:TExpr, t:Ttype):Int {
		switch [e.eexpr, t] {
			case [TConst(TInt(i)), HF64]:
				var r = allocTmp(ctx, t);
				op(ctx, OFloat(r, allocFloat(ctx, i)));
				return r;
			case [TConst(TInt(i)), HF32] if (compareVersion(ctx.hlVer, "1.15.0") >= 0):
				var r = allocTmp(ctx, t);
				op(ctx, OFloat(r, allocFloat(ctx, i)));
				return r;
			case [TConst(TFloat(f)), HF32] if (compareVersion(ctx.hlVer, "1.15.0") >= 0):
				var r = allocTmp(ctx, t);
				op(ctx, OFloat(r, allocFloat(ctx, core.ds.OcamlFloat.ofString(f))));
				return r;
			case _:
				var r = evalExpr(ctx, e);
				return castTo(ctx, r, t, e.epos);
		}
	}

	static function toString(ctx:HlContext, r:Int, p:Pos):Int {
		var rt = rtype(ctx, r);
		if (safeCast(rt, ctx.tstring)) return r;
		switch rt {
			case HUI8 | HUI16 | HI32:
				var len = allocTmp(ctx, HI32);
				hold(ctx, len);
				var lref = allocTmp(ctx, cHRefI32);
				var bytes = allocTmp(ctx, HBytes);
				op(ctx, ORef(lref, len));
				var a = castTo(ctx, r, HI32, p);
				op(ctx, OCall2(bytes, allocStd(ctx, "itos", [HI32, cHRefI32], HBytes), a, lref));
				var out = allocTmp(ctx, ctx.tstring);
				op(ctx, OCall2(out, allocFunPath(ctx, {pack: [], name: "String"}, "__alloc__"), bytes, len));
				free(ctx, len);
				return out;
			case HF32 | HF64:
				var len = allocTmp(ctx, HI32);
				var lref = allocTmp(ctx, cHRefI32);
				var bytes = allocTmp(ctx, HBytes);
				op(ctx, ORef(lref, len));
				var a = castTo(ctx, r, HF64, p);
				op(ctx, OCall2(bytes, allocStd(ctx, "ftos", [HF64, cHRefI32], HBytes), a, lref));
				var out = allocTmp(ctx, ctx.tstring);
				op(ctx, OCall2(out, allocFunPath(ctx, {pack: [], name: "String"}, "__alloc__"), bytes, len));
				return out;
			case _:
				var r = castTo(ctx, r, HDyn, p);
				var out = allocTmp(ctx, ctx.tstring);
				op(ctx, OJNotNull(r, 2));
				op(ctx, ONull(out));
				op(ctx, OJAlways(1));
				op(ctx, OCall1(out, allocFunPath(ctx, {pack: [], name: "Std"}, "string"), r));
				return out;
		}
	}

	static function castTo(ctx:HlContext, r:Int, t:Ttype, p:Pos, force:Bool = false):Int {
		var rt = rtype(ctx, r);
		if (safeCast(rt, t)) return r;
		switch [getGroup(rt), getGroup(t), rt, t] {
			case [_, _, _, HVoid]:
				return allocTmp(ctx, HVoid);
			case [_, _, HVirtual(_), HVirtual(_)]:
				var tmp = allocTmp(ctx, HDyn);
				op(ctx, OMov(tmp, r));
				return castTo(ctx, tmp, t, p);
			case [GInt | GFloat, GFloat, _, _]:
				var tmp = allocTmp(ctx, t);
				op(ctx, OToSFloat(tmp, r));
				return tmp;
			case [GInt | GFloat, GInt, _, _]:
				var tmp = allocTmp(ctx, t);
				op(ctx, OToInt(tmp, r));
				return tmp;
			case [_, _, HObj(o), HVirtual(_)]:
				var out = allocTmp(ctx, t);
				function lookupIntf(o:ClassProto):Null<Int> {
					var v = o.pinterfaces.get(t);
					if (v != null) return v;
					return if (o.psuper == null) null else lookupIntf(o.psuper);
				}
				var fid = lookupIntf(o);
				if (fid != null) {
					/* memoisation */
					function needNullCheck(r:Int):Bool return !(r == 0 && ctx.m.mhasthis);
					var jend = if (needNullCheck(r)) {
						var jnull = jump(ctx, d -> OJNotNull(r, d));
						op(ctx, ONull(out));
						var jend = jump(ctx, d -> OJAlways(d));
						jnull();
						jend;
					} else () -> {};
					op(ctx, OField(out, r, fid));
					var j = jump(ctx, d -> OJNotNull(out, d));
					op(ctx, OToVirtual(out, r));
					op(ctx, OSetField(r, fid, out));
					jend();
					j();
				} else {
					/* not an interface */
					op(ctx, OToVirtual(out, r));
				}
				return out;
			case [_, _, HDynObj | HDyn, HVirtual(_)]:
				var out = allocTmp(ctx, t);
				op(ctx, OToVirtual(out, r));
				return out;
			case [_, _, HDyn, _]:
				var out = allocTmp(ctx, t);
				op(ctx, OSafeCast(out, r));
				return out;
			case [_, _, HNull(rt), _] if (tEq(t, rt)):
				var out = allocTmp(ctx, t);
				op(ctx, OSafeCast(out, r));
				return out;
			case [_, _, HVoid, HDyn]:
				var tmp = allocTmp(ctx, HDyn);
				op(ctx, ONull(tmp));
				return tmp;
			case [_, _, _, HDyn]:
				var tmp = allocTmp(ctx, HDyn);
				op(ctx, OToDyn(tmp, r));
				return tmp;
			case [_, _, _, HNull(ti)] if (tEq(rt, ti)):
				var tmp = allocTmp(ctx, HNull(rt));
				op(ctx, OToDyn(tmp, r));
				return tmp;
			case [_, _, HNull(t1), HNull(_)]:
				var j = jump(ctx, n -> OJNull(r, n));
				var rtmp = allocTmp(ctx, t1);
				op(ctx, OSafeCast(rtmp, r));
				var out = castTo(ctx, rtmp, t, p);
				op(ctx, OJAlways(1));
				j();
				op(ctx, ONull(out));
				return out;
			case [_, _, HRef(t1), HNull(_)]:
				var j = jump(ctx, n -> OJNull(r, n));
				var rtmp = allocTmp(ctx, t1);
				op(ctx, OUnref(rtmp, r));
				var out = castTo(ctx, rtmp, t, p);
				op(ctx, OJAlways(1));
				j();
				op(ctx, ONull(out));
				return out;
			case [GInt | GFloat, GNull, _, HNull(t)] if (getGroup(t) != GBool):
				var tmp = allocTmp(ctx, t);
				switch getGroup(t) {
					case GFloat: op(ctx, OToSFloat(tmp, r));
					case GInt: op(ctx, OToInt(tmp, r));
					case _: die("", "genhl.ml");
				}
				var r = allocTmp(ctx, HNull(t));
				op(ctx, OToDyn(r, tmp));
				return r;
			case [GNull, GFloat, HNull(it), _] if (getGroup(it) != GBool):
				var i = allocTmp(ctx, it);
				op(ctx, OSafeCast(i, r));
				var tmp = allocTmp(ctx, t);
				op(ctx, OToSFloat(tmp, i));
				return tmp;
			case [GNull, GInt, HNull(it), _]:
				switch getGroup(it) {
					case GFloat:
						var i = allocTmp(ctx, it);
						op(ctx, OSafeCast(i, r));
						var tmp = allocTmp(ctx, t);
						op(ctx, OToInt(tmp, i));
						return tmp;
					case GInt:
						var out = allocTmp(ctx, t);
						op(ctx, OSafeCast(out, r));
						return out;
					case _:
						return die("", "genhl.ml");
				}
			case [_, _, HFun(args1, ret1), HFun(args2, ret2)] if (args1.length == args2.length):
				var fid = genMethodWrapper(ctx, rt, t, p);
				var fr = allocTmp(ctx, t);
				op(ctx, OJNotNull(r, 2));
				op(ctx, ONull(fr));
				op(ctx, OJAlways(1));
				op(ctx, OInstanceClosure(fr, fid, r));
				return fr;
			case [_, _, HObj(_), HObj(_)] if (isArrayType(rt) && isArrayType(t)):
				var out = allocTmp(ctx, t);
				op(ctx, OSafeCast(out, r));
				return out;
			case [_, _, HNull(_), HRef(t2)]:
				var out = allocTmp(ctx, t);
				op(ctx, OJNotNull(r, 2));
				op(ctx, ONull(out));
				var j = jump(ctx, n -> OJAlways(n));
				var r = castTo(ctx, r, t2, p);
				var r2 = allocTmp(ctx, t2);
				op(ctx, OMov(r2, r));
				hold(ctx, r2); /* retain */
				op(ctx, ORef(out, r2));
				j();
				return out;
			case [_, _, _, HRef(t2)]:
				var r = castTo(ctx, r, t2, p);
				var r2 = allocTmp(ctx, t2);
				op(ctx, OMov(r2, r));
				hold(ctx, r2); /* retain */
				var out = allocTmp(ctx, t);
				op(ctx, ORef(out, r2));
				return out;
			case _:
				if (force) {
					var out = allocTmp(ctx, t);
					op(ctx, OSafeCast(out, r));
					return out;
				} else
					return Error.abort("Don't know how to cast " + tstr(rt) + " to " + tstr(t), p);
		}
	}

	static function unsafeCastTo(ctx:HlContext, r:Int, t:Ttype, p:Pos, debugchk:Bool = true):Int {
		var rt = rtype(ctx, r);
		if (safeCast(rt, t)) return r;
		return switch rt {
			case HFun(_):
				castTo(ctx, r, t, p);
			case HDyn if (isArrayType(t)):
				castTo(ctx, r, t, p);
			case HDyn | HObj(_) if (t.match(HVirtual(_))):
				castTo(ctx, r, t, p);
			case HObj(_) if (isArrayType(rt) && isArrayType(t)):
				castTo(ctx, r, t, p);
			case HVirtual(_) if (t.match(HObj(_) | HVirtual(_))):
				castTo(ctx, r, t, p, true);
			case _:
				if (isDynamic(rtype(ctx, r)) && isDynamic(t)) {
					var r2 = allocTmp(ctx, t);
					op(ctx, OUnsafeCast(r2, r));
					if (ctx.com.debug && debugchk) {
						hold(ctx, r2);
						var r3 = castTo(ctx, r, t, p, true);
						var j = jump(ctx, n -> OJEq(r2, r3, n));
						op(ctx, OAssert(0));
						j();
						free(ctx, r2);
					}
					r2;
				} else
					castTo(ctx, r, t, p, true);
		}
	}

	static function isMethNormal(f:TClassField):Bool {
		return switch f.cfKind {
			case Method(MethNormal): true;
			case _: false;
		}
	}

	static function objectAccess(ctx:HlContext, eobj:TExpr, t:Ttype, f:TClassField):Access {
		switch t {
			case HObj(p) | HStruct(p):
				var idx = try getIndex(f.cfName, p) catch (_:NotFound) null;
				if (idx == null) return ADynamic(eobj, allocString(ctx, f.cfName));
				return if (isMethNormal(f)) AInstanceProto(eobj, -idx.fid - 1) else {
					var isPacked = idx.t.match(HPacked(_));
					AInstanceField(eobj, idx.fid, isPacked);
				}
			case HVirtual(v):
				var fid = v.vindex.get(f.cfName);
				if (fid == null) return ADynamic(eobj, allocString(ctx, f.cfName));
				return if (isMethNormal(f)) AVirtualMethod(eobj, fid) else AInstanceField(eobj, fid, false);
			case HDyn:
				return ADynamic(eobj, allocString(ctx, f.cfName));
			case _:
				return Error.abort("Unsupported field access " + tstr(t), eobj.epos);
		}
	}

	static function directMethodCall(ctx:HlContext, c:TClass, f:TClassField, ethis:TExpr):Bool {
		return if (switch f.cfKind {
			case Method(m): m == MethDynamic;
			case Var(_): true;
		}) false else if (hasClassFlag(c, CInterface)) false else if (c.clKind.match(KTypeParameter(_))) false else if (isOverridden(ctx, c, f)
			&& !ethis.eexpr.match(TConst(TSuper))) false else true;
	}

	static function getAccess(ctx:HlContext, e:TExpr):Access {
		switch e.eexpr {
			case TField(ethis, a):
				var ft = follow(ethis.etype);
				// port: `FClosure (Some (cdef,pl), f)` / `FInstance (cdef,pl,f)`
				var inst:Null<{cdef:TClass, pl:TParams, f:TClassField}> = switch a {
					case FInstance(cdef, pl, f): {cdef: cdef, pl: pl, f: f};
					case FClosure(cl, f) if (cl != null): {cdef: cl.cls, pl: cl.params, f: f};
					case _: null;
				}
				switch [a, ft] {
					case [FStatic(c, f), _] if (f.cfKind.match(Var(_) | Method(MethDynamic))):
						var gt = classGlobal(ctx, c);
						return AStaticVar(gt.g, gt.t, switch gt.t {
							case HObj(o): try getIndex(f.cfName, o).fid catch (_:NotFound) die("", "genhl.ml", e.epos);
							case _: die("", "genhl.ml", e.epos);
						});
					case [FStatic(c, f), _]:
						return AStaticFun(allocFid(ctx, c, f));
					case [_, TInst(c, _)] if (inst != null && directMethodCall(ctx, c, inst.f, ethis)):
						var cdef = inst.cdef, pl = inst.pl, f = inst.f;
						/* cdef is the original definition, we want the last redefinition */
						function loop(c:TClass):TClass {
							return if (c.clFields.exists(f.cfName)) c else (if (c.clSuper == null) cdef else loop(c.clSuper.cls));
						}
						var lastDef = loop(c);
						return AInstanceFun(ethis, allocFid(ctx, resolveClass(ctx, lastDef, pl, false), f));
					case _ if (inst != null):
						function loop(t:T):{c:TClass, pl:TParams} {
							return switch follow(t) {
								case TInst(c, pl): {c: c, pl: pl};
								case TAbstract(a, pl): loop(core.Abstract.getUnderlyingType(a, pl));
								case _: Error.abort(core.TPrinting.sType(core.TPrinting.printContext(), ethis.etype) + " hl type should be interface",
										ethis.epos);
							}
						}
						var cp = if (hasClassFlag(inst.cdef, CInterface)) loop(ethis.etype) else {c: inst.cdef, pl: inst.pl};
						return objectAccess(ctx, ethis, classType(ctx, cp.c, cp.pl, false), inst.f);
					case [FAnon(f) | FClosure(_, f), _]:
						return objectAccess(ctx, ethis, toType(ctx, ethis.etype), f);
					case [FDynamic(name), _]:
						return ADynamic(ethis, allocString(ctx, name));
					case [FEnum(e, ef), _]:
						return switch follow(ef.efType) {
							case TFun(_): AEnum(e, ef.efIndex);
							case t:
								var ht = toType(ctx, t);
								AGlobal(allocGlobal(ctx, efieldName(e, ef), ht));
						}
					case _:
						return die("", "genhl.ml");
				}
			case TLocal(v):
				var idx = capturedIndex(ctx, v);
				return if (idx == null) ALocal(v, allocVar(ctx, v, false)) else ACaptured(idx);
			case TParenthesis(e):
				return getAccess(ctx, e);
			case TArray(a, i):
				function loop(t:T):Access {
					var ft = follow(t);
					var abstractName = hlAbstractName(ft);
					switch ft {
						case TInst(c, [t]) if (isPath(c.clPath, [], "Array")):
							var a = evalNullCheck(ctx, a);
							hold(ctx, a);
							var i = evalTo(ctx, i, HI32);
							free(ctx, a);
							var t = toType(ctx, t);
							return AArray(a, t, t, i);
						case TInst(_, _) if (abstractName != null && abstractName.name == "hl_carray"):
							var a = evalExpr(ctx, a);
							hold(ctx, a);
							var i = evalTo(ctx, i, HI32);
							free(ctx, a);
							var t = toType(ctx, e.etype);
							return ACArray(a, t, i);
						case TAbstract(a, pl):
							return loop(core.Abstract.getUnderlyingType(a, pl));
						case _:
							var a = evalTo(ctx, a, classType(ctx, ctx.arrayImpl.adyn, vector(), false));
							op(ctx, ONullCheck(a));
							hold(ctx, a);
							var i = evalTo(ctx, i, HI32);
							free(ctx, a);
							return AArray(a, HDyn, toType(ctx, e.etype), i);
					}
				}
				return loop(a.etype);
			case _:
				return ANone;
		}
	}

	static function arrayRead(ctx:HlContext, ra:Int, at:Ttype, vt:Ttype, ridx:Int, p:Pos):Int {
		switch [getGroup(at), at] {
			case [GInt | GFloat, _]:
				var tg = getGroup(at);
				/* check bounds */
				hold(ctx, ridx);
				var length = allocTmp(ctx, HI32);
				free(ctx, ridx);
				op(ctx, OField(length, ra, 0));
				var j = jump(ctx, i -> OJULt(ridx, length, i));
				var r = allocTmp(ctx, switch at {
					case HUI8 | HUI16: HI32;
					case _: at;
				});
				switch tg {
					case GInt:
						op(ctx, OInt(r, allocI32(ctx, 0)));
					case GFloat:
						op(ctx, OFloat(r, allocFloat(ctx, 0.)));
					case _:
						die("", "genhl.ml");
				}
				var jend = jump(ctx, i -> OJAlways(i));
				j();
				var hbytes = allocTmp(ctx, HBytes);
				op(ctx, OField(hbytes, ra, 1));
				readMem(ctx, r, hbytes, shl(ctx, ridx, typeSizeBits(at)), at);
				jend();
				return castTo(ctx, r, vt, p);
			case [_, HDyn]:
				/* call getDyn */
				var r = allocTmp(ctx, HDyn);
				op(ctx, OCallMethod(r, 0, [ra, ridx]));
				return unsafeCastTo(ctx, r, vt, p);
			case _:
				/* check bounds */
				hold(ctx, ridx);
				var length = allocTmp(ctx, HI32);
				free(ctx, ridx);
				op(ctx, OField(length, ra, 0));
				var j = jump(ctx, i -> OJULt(ridx, length, i));
				var r = allocTmp(ctx, vt);
				setDefault(ctx, r);
				var jend = jump(ctx, i -> OJAlways(i));
				j();
				var tmp = allocTmp(ctx, HDyn);
				var harr = allocTmp(ctx, HArray(vt));
				op(ctx, OField(harr, ra, 1));
				op(ctx, OGetArray(tmp, harr, ridx));
				op(ctx, OMov(r, unsafeCastTo(ctx, tmp, vt, p)));
				jend();
				return r;
		}
	}

	static function isNullConst(e:TExpr):Bool return e.eexpr.match(TConst(TNull));

	static function jumpExpr(ctx:HlContext, e:TExpr, jcond:Bool):Void->Void {
		switch e.eexpr {
			case TParenthesis(e):
				return jumpExpr(ctx, e, jcond);
			case TUnop(Not, _, e):
				return jumpExpr(ctx, e, !jcond);
			case TBinop(OpEq | OpGte | OpLte, e1, e2) if (isNullConst(e1) || isNullConst(e2)):
				var e = if (isNullConst(e1)) e2 else e1;
				var r = evalExpr(ctx, e);
				return if (isNullable(rtype(ctx, r))) jump(ctx, i -> if (jcond) OJNull(r, i) else OJNotNull(r, i)) else if (!jcond)
					jump(ctx, i -> OJAlways(i)) else () -> {};
			case TBinop(OpNotEq, e1, e2) if (isNullConst(e1) || isNullConst(e2)):
				var e = if (isNullConst(e1)) e2 else e1;
				var r = evalExpr(ctx, e);
				return if (isNullable(rtype(ctx, r))) jump(ctx, i -> if (jcond) OJNotNull(r, i) else OJNull(r, i)) else if (jcond)
					jump(ctx, i -> OJAlways(i)) else () -> {};
			case TBinop(jop, e1, e2) if (jop.match(OpEq | OpNotEq)):
				function jumpeq(r1:Int, r2:Int):Void->Void return jump(ctx, i -> switch jop {
					case OpEq: if (jcond) OJEq(r1, r2, i) else OJNotEq(r1, r2, i);
					case OpNotEq: if (jcond) OJNotEq(r1, r2, i) else OJEq(r1, r2, i);
					case _: die("", "genhl.ml");
				});
				var nullisfalse = switch jop {
					case OpEq: jcond;
					case OpNotEq: !jcond;
					case _: die("", "genhl.ml");
				}
				var t1 = toType(ctx, e1.etype);
				var t2 = toType(ctx, e2.etype);
				switch [getGroup(t1), getGroup(t2)] {
					case [GNull, GInt | GFloat | GBool] | [GInt | GFloat | GBool, GNull]:
						var ti1 = getInnerType(t1);
						var ti2 = getInnerType(t2);
						var swap = isNullt(t2);
						var oe1 = e1, oe2 = e2;
						var t1 = if (swap) t2 else t1;
						var e1 = if (swap) oe2 else oe1;
						var e2 = if (swap) oe1 else oe2;
						var r1 = evalExpr(ctx, e1);
						hold(ctx, r1);
						var jnull = if (isNullt(t1)) jump(ctx, i -> OJNull(r1, i)) else () -> {};
						var t = commonTypeNumber(ti1, ti2); /* HBool has t==ti1==ti2 */
						var a = castTo(ctx, r1, t, e1.epos);
						hold(ctx, a);
						var b = evalTo(ctx, e2, t);
						free(ctx, a);
						free(ctx, r1);
						var j = jumpeq(a, b);
						if (nullisfalse) jnull();
						return () -> {
							if (!nullisfalse) jnull();
							j();
						};
					case _:
						var t = commonType(ctx, e1, e2, true, e.epos);
						var a = evalTo(ctx, e1, t);
						hold(ctx, a);
						var b = evalTo(ctx, e2, t);
						free(ctx, a);
						var j = jumpeq(a, b);
						return () -> j();
				}
			case TBinop(jop, e1, e2) if (jop.match(OpGt | OpGte | OpLt | OpLte)):
				var t1 = toType(ctx, e1.etype);
				var t2 = toType(ctx, e2.etype);
				var unsigned = unsignedOp(e1, e2);
				function jumpcmp(t:Ttype, r1:Int, r2:Int):Void->Void return jump(ctx, i -> {
					function lt(a, b) return if (unsigned) OJULt(a, b, i) else if (!jcond && isFloat(t)) OJNotGte(a, b, i) else OJSLt(a, b, i);
					function gte(a, b) return if (unsigned) OJUGte(a, b, i) else if (!jcond && isFloat(t)) OJNotLt(a, b, i) else OJSGte(a, b, i);
					switch jop {
						case OpGt: if (jcond) lt(r2, r1) else gte(r2, r1);
						case OpGte: if (jcond) gte(r1, r2) else lt(r1, r2);
						case OpLt: if (jcond) lt(r1, r2) else gte(r1, r2);
						case OpLte: if (jcond) gte(r2, r1) else lt(r2, r1);
						case _: die("", "genhl.ml");
					}
				});
				switch [getGroup(t1), getGroup(t2), t1, t2] {
					case [(GInt | GFloat) | GNull, (GInt | GFloat) | GNull, _, _]:
						var ti1 = getInnerType(t1);
						var ti2 = getInnerType(t2);
						if (ctx.wNullCompare && (isNullt(t1) || isNullt(t2)))
							ctx.com.warning(core.Message.WarningCode.WGenerator, [], "Null compare: " + tstr(t1) + " " + Ast.sBinop(jop) + " " + tstr(t2), e.epos);
						var r1 = evalExpr(ctx, e1);
						hold(ctx, r1);
						var jnull1 = if (isNullt(t1)) jump(ctx, i -> OJNull(r1, i)) else () -> {};
						var r2 = evalExpr(ctx, e2);
						hold(ctx, r2);
						var jnull2 = if (isNullt(t2)) jump(ctx, i -> OJNull(r2, i)) else () -> {};
						var t = commonTypeNumber(ti1, ti2);
						var a = castTo(ctx, r1, t, e1.epos);
						hold(ctx, a);
						var b = castTo(ctx, r2, t, e2.epos);
						free(ctx, a);
						free(ctx, r1);
						free(ctx, r2);
						var j = jumpcmp(t, a, b);
						if (jcond) {
							jnull1();
							jnull2();
						}
						return () -> {
							if (!jcond) {
								jnull1();
								jnull2();
							}
							j();
						};
					case [_, _, HObj({pname: "String"}), HObj({pname: "String"})] | [_, _, HDyn, _] | [_, _, _, HDyn]:
						var t = commonType(ctx, e1, e2, false, e.epos);
						var a = evalTo(ctx, e1, t);
						hold(ctx, a);
						var b = evalTo(ctx, e2, t);
						free(ctx, a);
						var j = jumpcmp(t, a, b);
						return () -> j();
					case _:
						return Error.abort("Don't know how to compare " + tstr(t1) + " and " + tstr(t2), e.epos);
				}
			case TBinop(OpBoolAnd, e1, e2):
				var j = jumpExpr(ctx, e1, false);
				var j2 = jumpExpr(ctx, e2, jcond);
				if (jcond) j();
				return () -> {
					if (!jcond) j();
					j2();
				};
			case TBinop(OpBoolOr, e1, e2):
				var j = jumpExpr(ctx, e1, true);
				var j2 = jumpExpr(ctx, e2, jcond);
				if (!jcond) j();
				return () -> {
					if (jcond) j();
					j2();
				};
			case _:
				var r = evalTo(ctx, e, HBool);
				return jump(ctx, i -> if (jcond) OJTrue(r, i) else OJFalse(r, i));
		}
	}

	static function evalArgs(ctx:HlContext, el:Vector<TExpr>, t:Ttype, p:Pos):Array<Int> {
		var tl = switch t {
			case HFun(args, _): args;
			case HDyn: [for (_ in el) HDyn];
			case _: die("", "genhl.ml");
		}
		if (el.length != tl.length) throw new core.ds.InvalidArgument("List.map2");
		var rl = [
			for (i in 0...el.length) {
				var e = el[i], t = tl[i];
				var r = switch [e.eexpr, t] {
					case [TConst(TNull), HRef(_)]:
						var r = allocTmp(ctx, t);
						op(ctx, ONull(r));
						r;
					case _:
						evalTo(ctx, e, t);
				}
				hold(ctx, r);
				r;
			}
		];
		for (r in rl) free(ctx, r);
		setCurpos(ctx, p);
		return rl;
	}

	static function evalNullCheck(ctx:HlContext, e:TExpr):Int {
		var r = evalExpr(ctx, e);
		switch e.eexpr {
			case TConst(TThis) | TConst(TSuper):
			case _: op(ctx, ONullCheck(r));
		}
		return r;
	}

	static function makeConst(ctx:HlContext, c:Constval, p:Pos):Int {
		var key = switch c {
			case CString(s): "S" + s;
		}
		var cidx = lookup(ctx.cconstants, key, () -> {
			var fields:Vector<Int>, t:Ttype;
			switch c {
				case CString(s):
					var u = toUtf8(s, p);
					var l = allocI32(ctx, u.len);
					fields = vector(allocString(ctx, u.str), l);
					t = ctx.tstring;
			}
			var g = lookupAlloc(ctx.cglobals, t);
			{g: g, fields: fields};
		});
		return ctx.cconstants.arr[cidx].g;
	}

	static function makeString(ctx:HlContext, s:String, p:Pos):Int {
		var r = allocTmp(ctx, ctx.tstring);
		op(ctx, OGetGlobal(r, makeConst(ctx, CString(s), p)));
		return r;
	}

	static function getEnumIndex(ctx:HlContext, v:TExpr):Int {
		var r = allocTmp(ctx, HI32);
		var re = evalExpr(ctx, v);
		op(ctx, ONullCheck(re));
		op(ctx, OEnumIndex(r, re));
		return r;
	}

	static function evalVar(ctx:HlContext, v:TVar):Int {
		var idx = capturedIndex(ctx, v);
		if (idx == null) return allocVar(ctx, v, false);
		var r = allocTmp(ctx, toType(ctx, v.vType));
		op(ctx, OEnumField(r, ctx.m.mcaptreg, 0, idx));
		return r;
	}

	static function constModeInt(e:TExpr, msg:String, p:Pos):Int {
		return switch getConst(e) {
			case TInt(m): m;
			case _: Error.abort(msg, p);
		}
	}

	static function evalExpr(ctx:HlContext, e:TExpr):Int {
		setCurpos(ctx, e.epos);
		switch e.eexpr {
			case TConst(c):
				switch c {
					case TInt(i):
						var r = allocTmp(ctx, HI32);
						op(ctx, OInt(r, allocI32(ctx, i)));
						return r;
					case TFloat(f):
						var r = allocTmp(ctx, HF64);
						op(ctx, OFloat(r, allocFloat(ctx, core.ds.OcamlFloat.ofString(f))));
						return r;
					case TBool(b):
						var r = allocTmp(ctx, HBool);
						op(ctx, OBool(r, b));
						return r;
					case TString(s):
						return makeString(ctx, s, e.epos);
					case TThis | TSuper:
						return 0; /* first reg */
					case TNull:
						var r = allocTmp(ctx, toType(ctx, e.etype));
						setDefault(ctx, r);
						return r;
				}
			case TVar(v, e):
				if (e == null) {
					if (capturedIndex(ctx, v) == null) declVar(ctx, v);
				} else {
					var ri = evalTo(ctx, e, toType(ctx, v.vType));
					var idx = capturedIndex(ctx, v);
					if (idx == null) {
						var r = allocVar(ctx, v, true);
						pushOp(ctx, OMov(r, ri));
						addAssign(ctx, v);
					} else {
						op(ctx, OSetEnumField(ctx.m.mcaptreg, idx, ri));
					}
				}
				return allocTmp(ctx, HVoid);
			case TLocal(v):
				var et = toType(ctx, e.etype);
				var idx = capturedIndex(ctx, v);
				var r = if (idx == null) {
					/* we need to make a copy for cases such as (a - a++) */
					var r = allocVar(ctx, v, false);
					var r2 = allocTmp(ctx, rtype(ctx, r));
					op(ctx, OMov(r2, r));
					r2;
				} else {
					var r = allocTmp(ctx, toType(ctx, v.vType));
					op(ctx, OEnumField(r, ctx.m.mcaptreg, 0, idx));
					r;
				}
				return castTo(ctx, r, et, e.epos);
			case TReturn(null):
				beforeReturn(ctx);
				var r = allocTmp(ctx, ctx.m.mret);
				if (!ctx.m.mret.match(HVoid)) op(ctx, ONull(r));
				op(ctx, ORet(r));
				return allocTmp(ctx, HDyn);
			case TReturn(e):
				var r = evalTo(ctx, e, ctx.m.mret);
				beforeReturn(ctx);
				op(ctx, ORet(r));
				return allocTmp(ctx, HDyn);
			case TParenthesis(e):
				return evalExpr(ctx, e);
			case TBlock(el):
				function loop(el:Vector<TExpr>):Int {
					if (el.length == 0) return allocTmp(ctx, HVoid);
					for (i in 0...el.length - 1) evalExpr(ctx, el[i]);
					return evalExpr(ctx, el[el.length - 1]);
				}
				var old = ctx.m.mdeclared;
				ctx.m.mdeclared = [];
				var r = loop(el);
				closeScopes(ctx, ctx.m.mdeclared);
				for (vid in ctx.m.mdeclared) {
					var r = ctx.m.mvars.get(vid);
					if (r == null) r = -1;
					if (r >= 0) {
						ctx.m.mvars.remove(vid);
						free(ctx, r);
					}
				}
				ctx.m.mdeclared = old;
				return r;
			case TCall(s, el) if (s.eexpr.match(TConst(TSuper))):
				switch follow(s.etype) {
					case TInst(csup, _):
						var f = csup.clConstructor;
						if (f == null) return die("", "genhl.ml");
						var r = allocTmp(ctx, HVoid);
						var el = evalArgs(ctx, el, toType(ctx, f.cfType), e.epos);
						op(ctx, OCallN(r, allocFid(ctx, csup, f), [0].concat(el)));
						return r;
					case _:
						return die("", "genhl.ml");
				}
			case TCall({eexpr: TIdent(s)}, el) if (s.charAt(0) == "$"):
				return evalNativeCall(ctx, e, s, el);
			case TEnumIndex(v):
				return getEnumIndex(ctx, v);
			case TCall({eexpr: TField(_, FStatic(c, {cfName: "enumIndex"}))}, [{eexpr: TCast(v, _)}]) if (isPath(c.clPath, [], "Type")
				&& follow(v.etype).match(TEnum(_))):
				return getEnumIndex(ctx, v);
			case TCall({eexpr: TField(_, FStatic(c, {cfName: "enumIndex"}))}, [v]) if (isPath(c.clPath, [], "Type") && follow(v.etype).match(TEnum(_))):
				return getEnumIndex(ctx, v);
			case TCall(e1, [v]) if (switch e1.eexpr {
					case TField(_, FStatic(c, {cfName: "makeVarArgs"})): isPath(c.clPath, [], "Reflect");
					case _: false;
				}):
				var ef, c;
				switch e1.eexpr {
					case TField(ef1, FStatic(c1, _)):
						ef = ef1;
						c = c1;
					case _:
						throw die("", "genhl.ml");
				}
				var f = c.clStatics.get("_makeVarArgs");
				if (f == null) throw NotFound.raise();
				return evalExpr(ctx, {eexpr: TCall({eexpr: TField(ef, FStatic(c, f)), etype: e1.etype, epos: e1.epos}, vector(v)), etype: e.etype, epos: e.epos});
			case TCall({eexpr: TField(_, FStatic(c, {cfName: "instance" | "downcast"}))}, [v, vt]) if (isPath(c.clPath, [], "Std")):
				var r = evalExpr(ctx, v);
				hold(ctx, r);
				var c = evalTo(ctx, vt, classType(ctx, ctx.baseType, vector(), false));
				hold(ctx, c);
				var rv = allocTmp(ctx, toType(ctx, e.etype));
				var rd = allocTmp(ctx, HDyn);
				op(ctx, OCall2(rd, allocFunPath(ctx, {pack: ["hl"], name: "BaseType"}, "downcast"), c, r));
				var jnext = jump(ctx, n -> OJNull(rd, n));
				var t = toType(ctx, e.etype);
				op(ctx, OMov(rv, unsafeCastTo(ctx, rd, t, e.epos, false)));
				var jend = jump(ctx, n -> OJAlways(n));
				jnext();
				op(ctx, ONull(rv));
				jend();
				free(ctx, r);
				free(ctx, c);
				return rv;
			case TCall(ec, args):
				var tfun = realType(ctx, ec);
				function el() return evalArgs(ctx, args, tfun, e.epos);
				var ret = allocTmp(ctx, switch tfun {
					case HFun(_, r): r;
					case _: HDyn;
				});
				var defRet:Null<Int> = null;
				switch getAccess(ctx, ec) {
					case AStaticFun(f):
						switch el() {
							case []: op(ctx, OCall0(ret, f));
							case [a]: op(ctx, OCall1(ret, f, a));
							case [a, b]: op(ctx, OCall2(ret, f, a, b));
							case [a, b, c]: op(ctx, OCall3(ret, f, a, b, c));
							case [a, b, c, d]: op(ctx, OCall4(ret, f, a, b, c, d));
							case el: op(ctx, OCallN(ret, f, el));
						}
					case AInstanceFun(ethis, f):
						var r = evalNullCheck(ctx, ethis);
						hold(ctx, r);
						var el = [r].concat(el());
						free(ctx, r);
						switch el {
							case [a]: op(ctx, OCall1(ret, f, a));
							case [a, b]: op(ctx, OCall2(ret, f, a, b));
							case [a, b, c]: op(ctx, OCall3(ret, f, a, b, c));
							case [a, b, c, d]: op(ctx, OCall4(ret, f, a, b, c, d));
							case _: op(ctx, OCallN(ret, f, el));
						}
					case AInstanceProto({eexpr: TConst(TThis)}, fid):
						op(ctx, OCallThis(ret, fid, el()));
					case AInstanceProto(ethis, fid) | AVirtualMethod(ethis, fid):
						var r = evalNullCheck(ctx, ethis);
						hold(ctx, r);
						var el = [r].concat(el());
						free(ctx, r);
						op(ctx, OCallMethod(ret, fid, el));
					case AEnum(_, index):
						op(ctx, OMakeEnum(ret, index, el()));
					case AArray(a, at, vt, idx):
						var r = arrayRead(ctx, a, at, vt, idx, ec.epos);
						hold(ctx, r);
						op(ctx, ONullCheck(r));
						op(ctx, OCallClosure(ret, r, el())); /* if it's a value, it's a closure */
						free(ctx, r);
					case _:
						/* don't use real_type here */
						var tfun = toType(ctx, ec.etype);
						var r = evalNullCheck(ctx, ec);
						hold(ctx, r);
						var el = evalArgs(ctx, args, tfun, e.epos);
						free(ctx, r);
						var ret = allocTmp(ctx, switch tfun {
							case HFun(_, r): r;
							case _: HDyn;
						});
						op(ctx, OCallClosure(ret, r, el)); /* if it's a value, it's a closure */
						defRet = castTo(ctx, ret, toType(ctx, e.etype), e.epos, true);
				}
				if (defRet == null) {
					function isMapGetMethod(t:T):Bool {
						return switch follow(t) {
							case TFun(s):
								switch follow(s.ret) {
									case TInst({clKind: KTypeParameter(_), clPath: {pack: ["haxe", "ds", "StringMap" | "ObjectMap" | "IntMap" | "Int64Map"]}},
										_): true;
									case _: false;
								}
							case _:
								false;
						}
					}
					var rt = toType(ctx, e.etype);
					return switch ec.eexpr {
						case TField(_, FInstance(_, _, {cfKind: Method(MethNormal | MethInline), cfType: t})) if (isMapGetMethod(t)):
							/* let's trust the compiler on map.get type */
							unsafeCastTo(ctx, ret, rt, e.epos);
						case _:
							castTo(ctx, ret, rt, e.epos, true);
					}
				} else
					return defRet;
			case TField(ec, FInstance(c, [t], {cfName: "length"})) if (isPath(c.clPath, [], "Array") && tEq(toType(ctx, t), HDyn)):
				var r = allocTmp(ctx, HI32);
				var a = evalTo(ctx, ec, classType(ctx, ctx.arrayImpl.adyn, vector(), false));
				op(ctx, ONullCheck(a));
				op(ctx, OCall1(r, allocFunPath(ctx, {pack: ["hl", "types"], name: "ArrayDyn"}, "get_length"), a));
				return r;
			case TField(ec, a):
				var r = allocTmp(ctx, toType(ctx, fieldType(ctx, a, e.epos)));
				switch getAccess(ctx, e) {
					case AGlobal(g):
						op(ctx, OGetGlobal(r, g));
					case AStaticVar(g, t, fid):
						var o = allocTmp(ctx, t);
						op(ctx, OGetGlobal(o, g));
						op(ctx, OField(r, o, fid));
					case AStaticFun(f):
						op(ctx, OStaticClosure(r, f));
					case AInstanceFun(ethis, f):
						op(ctx, OInstanceClosure(r, f, evalNullCheck(ctx, ethis)));
					case AInstanceField(ethis, fid, _):
						var robj = evalNullCheck(ctx, ethis);
						op(ctx, switch ethis.eexpr {
							case TConst(TThis): OGetThis(r, fid);
							case _: OField(r, robj, fid);
						});
					case AInstanceProto(ethis, fid) | AVirtualMethod(ethis, fid):
						var robj = evalNullCheck(ctx, ethis);
						switch rtype(ctx, robj) {
							case HObj(_):
								op(ctx, OVirtualClosure(r, robj, fid));
							case HVirtual(vp):
								var sid = vp.vfields[fid].nid;
								op(ctx, ODynGet(r, robj, sid));
							case _:
								die("", "genhl.ml");
						}
					case ADynamic(ethis, f):
						var robj = evalNullCheck(ctx, ethis);
						op(ctx, ODynGet(r, robj, f));
					case AEnum(en, index):
						var curFid = ctx.cfids.arr.length;
						var name = en.eNames[index];
						var fid = allocFunPath(ctx, en.ePath, name);
						if (fid == curFid) {
							var ef = en.eConstrs.get(name);
							if (ef == null) throw NotFound.raise();
							var eargs, et;
							switch follow(ef.efType) {
								case TFun(s):
									eargs = s.args;
									et = s.ret;
								case _:
									eargs = die("", "genhl.ml");
									et = null;
							}
							var ct = ctx.com.basic;
							var p = ef.efPos;
							var eargs = eargs.map(a -> ({
								variable: TFunctions.allocVar(VGenerated, a.name, a.type, en.ePos),
								defaultValue: if (a.optional) mk(TConst(TNull), tDynamic, nullPos) else null
							} : {variable:TVar, defaultValue:Null<TExpr>}));
							var ecall = mk(TCall(e, eargs.map(a -> mk(TLocal(a.variable), a.variable.vType, p))), et, p);
							var f:TFunc = {
								tfArgs: eargs,
								tfType: et,
								tfExpr: mk(TReturn(ecall), ct.tvoid, p)
							};
							makeFun(ctx, {fst: "", snd: ""}, fid, f, null, null);
						}
						op(ctx, OStaticClosure(r, fid));
					case ANone | ALocal(_) | AArray(_) | ACaptured(_) | ACArray(_):
						Error.abort("Invalid access", e.epos);
				}
				var toT = toType(ctx, e.etype);
				return switch toT {
					case HFun(_): castTo(ctx, r, toT, e.epos);
					case _: unsafeCastTo(ctx, r, toT, e.epos);
				}
			case TObjectDecl(fl):
				/* We cannot rely on e.etype because it might have optional field etc, see jvm */
				var fields = new StringMap<TClassField>();
				for (f in fl) {
					var cf = mkField(f.key.name, f.expr.etype, f.expr.epos, f.expr.epos);
					fields.set(f.key.name, cf);
				}
				var rt = toType(ctx, mkAnon(Closed, fields));
				switch rt {
					case HVirtual(vp) if (safeCast(rt, toType(ctx, e.etype))
						&& !core.ds.ArrayTools.exists(fl, f -> f.key.name == "toString" && isToString(f.expr.etype))):
						var t = rt;
						var r = allocTmp(ctx, t);
						op(ctx, ONew(r));
						hold(ctx, r);
						for (f in fl) {
							var fidx = vp.vindex.get(f.key.name);
							if (fidx == null) die("", "genhl.ml");
							var ft = vp.vfields[fidx].t;
							var v = evalTo(ctx, f.expr, ft);
							op(ctx, OSetField(r, fidx, v));
						}
						free(ctx, r);
						return r;
					case _:
						var r = allocTmp(ctx, HDynObj);
						op(ctx, ONew(r));
						hold(ctx, r);
						var a = switch follow(e.etype) {
							case TAnon(a): a;
							case t: if (t == tDynamic) null else die("", "genhl.ml");
						}
						for (f in fl) {
							var s = f.key.name, ev = f.expr;
							var ft = {
								var cf = if (a == null) null else a.aFields.get(s);
								if (cf == null) ev.etype else cf.cfType;
							}
							var v = evalTo(ctx, ev, toType(ctx, ft));
							op(ctx, ODynSet(r, allocString(ctx, s), v));
							if (s == "toString" && isToString(ev.etype)) {
								var f = allocTmp(ctx, cHFunBytes);
								op(ctx, OInstanceClosure(f, allocFunPath(ctx, {pack: [], name: "String"}, "call_toString"), r));
								op(ctx, ODynSet(r, allocString(ctx, "__string"), f));
							}
						}
						free(ctx, r);
						return castTo(ctx, r, toType(ctx, e.etype), e.epos);
				}
			case TNew(c, pl, el):
				var c = resolveClass(ctx, c, pl, false);
				var r = allocTmp(ctx, classType(ctx, c, pl, false));
				op(ctx, ONew(r));
				hold(ctx, r);
				switch c.clConstructor {
					case null:
						if (c.clImplements.length != 0) die("", "genhl.ml");
					case {cfExpr: null}:
						Error.abort(sTypePath(c.clPath) + " does not have a constructor", e.epos);
					case constr:
						var cexpr = constr.cfExpr;
						var rl = evalArgs(ctx, el, toType(ctx, cexpr.etype), e.epos);
						var ret = allocTmp(ctx, HVoid);
						var g = allocFid(ctx, c, constr);
						op(ctx, switch rl {
							case []: OCall1(ret, g, r);
							case [a]: OCall2(ret, g, r, a);
							case [a, b]: OCall3(ret, g, r, a, b);
							case [a, b, c]: OCall4(ret, g, r, a, b, c);
							case _: OCallN(ret, g, [r].concat(rl));
						});
				}
				free(ctx, r);
				return r;
			case TIf(cond, eif, eelse):
				var t = toType(ctx, e.etype);
				var out = allocTmp(ctx, t);
				var j = jumpExpr(ctx, cond, false);
				var rif = if (tEq(t, HVoid)) evalExpr(ctx, eif) else evalTo(ctx, eif, t);
				setCurpos(ctx, maxPos(eif));
				if (!tEq(t, HVoid)) op(ctx, OMov(out, rif));
				switch eelse {
					case null:
						j();
					case e:
						var jexit = jump(ctx, i -> OJAlways(i));
						j();
						if (tEq(t, HVoid)) evalExpr(ctx, e) else op(ctx, OMov(out, evalTo(ctx, e, t)));
						jexit();
				}
				return out;
			case TBinop(bop, e1, e2):
				function arithbinop(r:Int, a:Int, b:Int):Void {
					function loop(bop:Binop):Void {
						switch bop {
							case OpAdd:
								var t = rtype(ctx, r);
								switch [getGroup(t), t] {
									case [GInt | GFloat, _]:
										op(ctx, OAdd(r, a, b));
									case [_, HObj({pname: "String"})]:
										var sb = toString(ctx, b, e2.epos);
										var sa = toString(ctx, a, e1.epos);
										op(ctx, OCall2(r, allocFunPath(ctx, {pack: [], name: "String"}, "__add__"), sa, sb));
									case [_, HDyn]:
										op(ctx, OCall2(r, allocFunPath(ctx, {pack: [], name: "Std"}, "__add__"), a, b));
									case _:
										Error.abort("Cannot add " + tstr(t), e.epos);
								}
							case OpSub | OpMult | OpMod | OpDiv:
								var t = rtype(ctx, r);
								switch [getGroup(t), t] {
									case [GInt | GFloat, _]:
										switch bop {
											case OpSub: op(ctx, OSub(r, a, b));
											case OpMult: op(ctx, OMul(r, a, b));
											case OpMod: op(ctx, if (unsigned(e1.etype)) OUMod(r, a, b) else OSMod(r, a, b));
											case OpDiv: op(ctx, OSDiv(r, a, b)); /* don't use UDiv since both operands are float already */
											case _: die("", "genhl.ml");
										}
									case [_, HDyn]:
										var ri = regInt(ctx, switch bop {
											case OpSub: 1;
											case OpMult: 2;
											case OpMod: 3;
											case OpDiv: 4;
											case _: die("", "genhl.ml");
										});
										op(ctx, OCall3(r, allocStd(ctx, "dyn_op", [HI32, HDyn, HDyn], HDyn), ri, a, b));
									case _:
										die("", "genhl.ml");
								}
							case OpShl | OpShr | OpUShr | OpAnd | OpOr | OpXor:
								var t = rtype(ctx, r);
								switch [getGroup(t), t] {
									case [GInt, _]:
										switch bop {
											case OpShl: op(ctx, OShl(r, a, b));
											case OpShr: op(ctx, if (unsigned(e1.etype)) OUShr(r, a, b) else OSShr(r, a, b));
											case OpUShr: op(ctx, OUShr(r, a, b));
											case OpAnd: op(ctx, OAnd(r, a, b));
											case OpOr: op(ctx, OOr(r, a, b));
											case OpXor: op(ctx, OXor(r, a, b));
											case _:
										}
									case [_, HDyn]:
										var ri = regInt(ctx, switch bop {
											case OpShl: 5;
											case OpShr: 6;
											case OpUShr: 7;
											case OpAnd: 8;
											case OpOr: 9;
											case OpXor: 10;
											case _: die("", "genhl.ml");
										});
										op(ctx, OCall3(r, allocStd(ctx, "dyn_op", [HI32, HDyn, HDyn], HDyn), ri, a, b));
									case _:
										die("", "genhl.ml");
								}
							case OpAssignOp(bop):
								loop(bop);
							case _:
								die("", "genhl.ml");
						}
					}
					loop(bop);
				}
				switch bop {
					case OpLte | OpGt | OpGte | OpLt | OpEq | OpNotEq:
						var r = allocTmp(ctx, HBool);
						var j = jumpExpr(ctx, e, false);
						op(ctx, OBool(r, true));
						op(ctx, OJAlways(1));
						j();
						op(ctx, OBool(r, false));
						return r;
					case OpAdd | OpSub | OpMult | OpDiv | OpMod | OpShl | OpShr | OpUShr | OpAnd | OpOr | OpXor:
						var t = switch toType(ctx, e.etype) {
							case HNull(t): t;
							case t: t;
						}
						var convString = bop == OpAdd && isString(t);
						function eval(e:TExpr):Int {
							return if (convString) {
								var r = evalExpr(ctx, e);
								toString(ctx, r, e.epos);
							} else evalTo(ctx, e, t);
						}
						var r = allocTmp(ctx, t);
						var a = eval(e1);
						hold(ctx, a);
						var b = eval(e2);
						free(ctx, a);
						arithbinop(r, a, b);
						return r;
					case OpAssign:
						function value() return evalTo(ctx, e2, realType(ctx, e1));
						switch getAccess(ctx, e1) {
							case AGlobal(g):
								var r = value();
								op(ctx, OSetGlobal(g, r));
								return r;
							case AStaticVar(g, t, fid):
								var r = value();
								hold(ctx, r);
								var o = allocTmp(ctx, t);
								free(ctx, r);
								op(ctx, OGetGlobal(o, g));
								op(ctx, OSetField(o, fid, r));
								return r;
							case AInstanceField({eexpr: TConst(TThis)}, fid, isPacked):
								var r = value();
								if (isPacked) op(ctx, ONullCheck(r));
								op(ctx, OSetThis(fid, r));
								return r;
							case AInstanceField(ethis, fid, isPacked):
								var rthis = evalNullCheck(ctx, ethis);
								hold(ctx, rthis);
								var r = value();
								free(ctx, rthis);
								if (isPacked) op(ctx, ONullCheck(r));
								op(ctx, OSetField(rthis, fid, r));
								return r;
							case ALocal(v, l):
								var r = value();
								pushOp(ctx, OMov(l, r));
								addAssign(ctx, v);
								return r;
							case AArray(ra, at, vt, ridx):
								hold(ctx, ra);
								hold(ctx, ridx);
								var v = castTo(ctx, value(), switch at {
									case HUI16 | HUI8: HI32;
									case _: at;
								}, e.epos);
								hold(ctx, v);
								/* bounds check against length */
								switch at {
									case HDyn:
										/* call setDyn() */
										var cv = castTo(ctx, v, if (isDynamic(at)) at else HDyn, e.epos);
										op(ctx, OCallMethod(allocTmp(ctx, HVoid), 1, [ra, ridx, cv]));
									case _:
										var len = allocTmp(ctx, HI32);
										op(ctx, OField(len, ra, 0)); /* length */
										var j = jump(ctx, i -> OJULt(ridx, len, i));
										var fexpand = allocFunPath(ctx, arrayClass(ctx, at).clPath, "__expand");
										op(ctx, OCall2(allocTmp(ctx, HVoid), fexpand, ra, ridx));
										j();
										switch getGroup(at) {
											case GInt | GFloat:
												var b = allocTmp(ctx, HBytes);
												op(ctx, OField(b, ra, 1));
												writeMem(ctx, b, shl(ctx, ridx, typeSizeBits(at)), at, v);
											case _:
												var arr = allocTmp(ctx, HArray(vt));
												op(ctx, OField(arr, ra, 1));
												op(ctx, OSetArray(arr, ridx, castTo(ctx, v, if (isDynamic(at)) at else HDyn, e.epos)));
										}
								}
								free(ctx, v);
								free(ctx, ra);
								free(ctx, ridx);
								return v;
							case ACArray(ra, t, ridx):
								hold(ctx, ra);
								hold(ctx, ridx);
								var v = evalTo(ctx, e2, t);
								op(ctx, OSetArray(ra, ridx, v));
								free(ctx, ridx);
								free(ctx, ra);
								return v;
							case ADynamic(ethis, f):
								var obj = evalNullCheck(ctx, ethis);
								hold(ctx, obj);
								var r = evalExpr(ctx, e2);
								free(ctx, obj);
								op(ctx, ODynSet(obj, f, r));
								return r;
							case ACaptured(index):
								var r = value();
								op(ctx, OSetEnumField(ctx.m.mcaptreg, index, r));
								return r;
							case AEnum(_) | ANone | AInstanceFun(_) | AInstanceProto(_) | AStaticFun(_) | AVirtualMethod(_):
								return die("", "genhl.ml");
						}
					case OpBoolOr:
						var r = allocTmp(ctx, HBool);
						var j = jumpExpr(ctx, e1, true);
						var j2 = jumpExpr(ctx, e2, true);
						op(ctx, OBool(r, false));
						var jend = jump(ctx, b -> OJAlways(b));
						j();
						j2();
						op(ctx, OBool(r, true));
						jend();
						return r;
					case OpBoolAnd:
						var r = allocTmp(ctx, HBool);
						var j = jumpExpr(ctx, e1, false);
						var j2 = jumpExpr(ctx, e2, false);
						op(ctx, OBool(r, true));
						var jend = jump(ctx, b -> OJAlways(b));
						j();
						j2();
						op(ctx, OBool(r, false));
						jend();
						return r;
					case OpAssignOp(bop):
						switch getAccess(ctx, e1) {
							case ALocal(v, l):
								var r = evalTo(ctx, {eexpr: TBinop(bop, e1, e2), etype: e.etype, epos: e.epos}, toType(ctx, e1.etype));
								pushOp(ctx, OMov(l, r));
								addAssign(ctx, v);
								return r;
							case acc:
								return genAssignOp(ctx, acc, e1, r -> {
									hold(ctx, r);
									var b = if (bop == OpAdd && isString(rtype(ctx, r))) toString(ctx, evalExpr(ctx, e2), e2.epos) else evalTo(ctx, e2, rtype(ctx, r));
									free(ctx, r);
									arithbinop(r, r, b);
									r;
								});
						}
					case OpInterval | OpArrow | OpIn | OpNullCoal:
						return die("", "genhl.ml");
				}
			case TUnop(Not, _, v):
				var tmp = allocTmp(ctx, HBool);
				var r = evalTo(ctx, v, HBool);
				op(ctx, ONot(tmp, r));
				return tmp;
			case TUnop(Neg, _, v):
				var t = toType(ctx, e.etype);
				var tmp = allocTmp(ctx, t);
				var r = evalTo(ctx, v, t);
				op(ctx, ONeg(tmp, r));
				return tmp;
			case TUnop(Spread, _, _):
				return die("Unexpected spread operator", "genhl.ml", e.epos);
			case TUnop(NegBits, _, v):
				var t = toType(ctx, e.etype);
				var tmp = allocTmp(ctx, t);
				var r = evalTo(ctx, v, t);
				var mask = switch t {
					case HUI8: 0xFF;
					case HUI16: 0xFFFF;
					case HI32: -1; // port: 0xFFFFFFFFl
					case _: Error.abort("Unsupported " + tstr(t), e.epos);
				}
				hold(ctx, r);
				var r2 = allocTmp(ctx, t);
				free(ctx, r);
				op(ctx, OInt(r2, allocI32(ctx, mask)));
				op(ctx, OXor(tmp, r, r2));
				return tmp;
			case TUnop(Increment | Decrement, fix, v):
				var uop = switch e.eexpr {
					case TUnop(u, _, _): u;
					case _: die("", "genhl.ml");
				}
				function unop(r:Int):Void {
					var t = rtype(ctx, r);
					switch [getGroup(t), t] {
						case [GInt, _]:
							if (uop == Increment) op(ctx, OIncr(r)) else op(ctx, ODecr(r));
						case [GFloat, _]:
							hold(ctx, r);
							var tmp = allocTmp(ctx, t);
							free(ctx, r);
							op(ctx, OFloat(tmp, allocFloat(ctx, 1.)));
							if (uop == Increment) op(ctx, OAdd(r, r, tmp)) else op(ctx, OSub(r, r, tmp));
						case [GNull, HNull(t)]:
							hold(ctx, r);
							var tmp = allocTmp(ctx, t);
							free(ctx, r);
							op(ctx, OSafeCast(tmp, r));
							unop(tmp);
							op(ctx, OToDyn(r, tmp));
						case [_, HDyn] if (uop == Increment):
							hold(ctx, r);
							var tmp = allocTmp(ctx, HDyn);
							free(ctx, r);
							op(ctx, OToDyn(tmp, regInt(ctx, 1)));
							op(ctx, OCall2(r, allocFunPath(ctx, {pack: [], name: "Std"}, "__add__"), r, tmp));
						case [_, HDyn] if (uop == Decrement):
							var r2 = allocTmp(ctx, HF64);
							hold(ctx, r2);
							var tmp = allocTmp(ctx, HF64);
							free(ctx, r2);
							op(ctx, OSafeCast(r2, r));
							op(ctx, OFloat(tmp, allocFloat(ctx, 1.)));
							op(ctx, OSub(r2, r2, tmp));
							op(ctx, OSafeCast(r, r2));
						case _:
							die("", "genhl.ml");
					}
				}
				switch [getAccess(ctx, v), fix] {
					case [ALocal(v, r), Prefix]:
						unop(r);
						return r;
					case [ALocal(v, r), Postfix]:
						var r2 = allocTmp(ctx, rtype(ctx, r));
						hold(ctx, r2);
						op(ctx, OMov(r2, r));
						unop(r);
						free(ctx, r2);
						return r2;
					case [acc, _]:
						var ret = 0;
						switch acc {
							case AArray(a, _, _, idx):
								hold(ctx, a);
								hold(ctx, idx);
							case _:
						}
						genAssignOp(ctx, acc, v, r -> {
							if (fix == Prefix) ret = r else {
								hold(ctx, r);
								var tmp = allocTmp(ctx, rtype(ctx, r));
								free(ctx, r);
								op(ctx, OMov(tmp, r));
								ret = tmp;
							}
							hold(ctx, ret);
							unop(r);
							r;
						});
						free(ctx, ret);
						switch acc {
							case AArray(a, _, _, idx):
								free(ctx, a);
								free(ctx, idx);
							case _:
						}
						return ret;
				}
			case TFunction(f):
				var fid = allocFunctionName(ctx, "function#" + ctx.cfids.arr.length);
				var capt = makeFun(ctx, {fst: "", snd: ""}, fid, f, null, ctx.m.mcaptured);
				var r = allocTmp(ctx, toType(ctx, e.etype));
				if (capt == ctx.m.mcaptured) op(ctx, OInstanceClosure(r, fid, ctx.m.mcaptreg)) else switch capt.cVars.length {
					case 0:
						op(ctx, OStaticClosure(r, fid));
					case 1 if (!capt.cGroup):
						op(ctx, OInstanceClosure(r, fid, evalVar(ctx, capt.cVars[0])));
					case _:
						var env = allocTmp(ctx, capt.cType);
						op(ctx, OEnumAlloc(env, 0));
						hold(ctx, env);
						for (i in 0...capt.cVars.length) op(ctx, OSetEnumField(env, i, evalVar(ctx, capt.cVars[i])));
						free(ctx, env);
						op(ctx, OInstanceClosure(r, fid, env));
				}
				return r;
			/* throwing a catch var means we want to rethrow an exception */
			case TThrow(e1) if (switch e1.eexpr {
					case TLocal(v): hasVarFlag(v, VCaught);
					case _: false;
				}):
				var r = allocTmp(ctx, HVoid);
				op(ctx, ORethrow(evalTo(ctx, e1, HDyn)));
				return r;
			case TThrow(v):
				op(ctx, OThrow(evalTo(ctx, v, HDyn)));
				return allocTmp(ctx, HDyn);
			case TWhile(cond, eloop, NormalWhile):
				var oldb = ctx.m.mbreaks, oldc = ctx.m.mcontinues, oldtrys = ctx.m.mloopTrys;
				ctx.m.mbreaks = [];
				ctx.m.mcontinues = [];
				ctx.m.mloopTrys = ctx.m.mtrys;
				var continuePos = currentPos(ctx);
				var ret = jumpBack(ctx);
				var j = jumpExpr(ctx, cond, false);
				evalExpr(ctx, eloop);
				setCurpos(ctx, maxPos(e));
				ret();
				j();
				for (f in ctx.m.mbreaks) f(currentPos(ctx));
				for (f in ctx.m.mcontinues) f(continuePos);
				ctx.m.mbreaks = oldb;
				ctx.m.mcontinues = oldc;
				ctx.m.mloopTrys = oldtrys;
				return allocTmp(ctx, HVoid);
			case TWhile(cond, eloop, DoWhile):
				var oldb = ctx.m.mbreaks, oldc = ctx.m.mcontinues, oldtrys = ctx.m.mloopTrys;
				ctx.m.mbreaks = [];
				ctx.m.mcontinues = [];
				ctx.m.mloopTrys = ctx.m.mtrys;
				var continuePos = currentPos(ctx);
				var ret = jumpBack(ctx);
				evalExpr(ctx, eloop);
				var j = jumpExpr(ctx, cond, false);
				ret();
				j();
				for (f in ctx.m.mbreaks) f(currentPos(ctx));
				for (f in ctx.m.mcontinues) f(continuePos);
				ctx.m.mbreaks = oldb;
				ctx.m.mcontinues = oldc;
				ctx.m.mloopTrys = oldtrys;
				return allocTmp(ctx, HVoid);
			case TCast(v, null) if (v.eexpr.match(TConst(TInt(_) | TFloat(_)))):
				var ec = v.eexpr;
				return evalTo(ctx, {eexpr: ec, etype: e.etype, epos: e.epos}, toType(ctx, e.etype));
			case TCast({eexpr: TCast(v, null)}, null) if (!isNumber(toType(ctx, e.etype))):
				/* coalesce double casts into a single runtime check - temp fix for Map accesses */
				return evalExpr(ctx, {eexpr: TCast(v, null), etype: e.etype, epos: e.epos});
			case TCast(v, null):
				var t = toType(ctx, e.etype);
				var rv = evalExpr(ctx, v);
				switch t {
					case HF32 | HF64 if (unsigned(v.etype)):
						var r = allocTmp(ctx, t);
						op(ctx, OToUFloat(r, rv));
						return r;
					case HDyn if (rtype(ctx, rv).match(HFun(_))):
						/* if called, a HDyn method will return HDyn, not its usual return type */
						var r = allocTmp(ctx, t);
						op(ctx, OMov(r, rv));
						return r;
					case _:
						return castTo(ctx, rv, t, e.epos, true);
				}
			case TArrayDecl(el):
				var r = allocTmp(ctx, toType(ctx, e.etype));
				var et = switch follow(e.etype) {
					case TInst(_, [t]): toType(ctx, t);
					case _: die("", "genhl.ml");
				}
				function arrayBytes(bits:Int, t:Ttype, tname:String, getOp:(Int, Int, Int) -> Opcode):Void {
					var b = allocTmp(ctx, HBytes);
					var size = regInt(ctx, el.length << bits);
					op(ctx, OCall1(b, allocStd(ctx, "alloc_bytes", [HI32], HBytes), size));
					var idx = regInt(ctx, 0);
					hold(ctx, idx);
					hold(ctx, b);
					for (e in el) {
						var r = evalTo(ctx, e, t);
						hold(ctx, r);
						op(ctx, getOp(b, shl(ctx, idx, bits), r));
						free(ctx, r);
						op(ctx, OIncr(idx));
					}
					free(ctx, b);
					free(ctx, idx);
					var len = regInt(ctx, el.length);
					op(ctx, OCall2(r, allocFunPath(ctx, {pack: ["hl", "types"], name: "ArrayBase"}, "alloc" + tname), b, len));
				}
				switch et {
					case HI32:
						arrayBytes(2, HI32, "I32", (b, i, r) -> OSetMem(b, i, r));
					case HUI16:
						arrayBytes(1, HI32, "UI16", (b, i, r) -> OSetUI16(b, i, r));
					case HUI8:
						arrayBytes(0, HI32, "UI8", (b, i, r) -> OSetUI8(b, i, r));
					case HF32:
						arrayBytes(2, HF32, "F32", (b, i, r) -> OSetMem(b, i, r));
					case HF64:
						arrayBytes(3, HF64, "F64", (b, i, r) -> OSetMem(b, i, r));
					case HI64:
						arrayBytes(3, HI64, "I64", (b, i, r) -> OSetMem(b, i, r));
					case HGUID:
						arrayBytes(3, HGUID, "GUID", (b, i, r) -> OSetMem(b, i, r));
					case _:
						var at = if (isDynamic(et)) et else HDyn;
						var size = regInt(ctx, el.length);
						var a = allocArray(ctx, size, at);
						hold(ctx, a);
						for (i in 0...el.length) {
							var r = evalTo(ctx, el[i], at);
							op(ctx, OSetArray(a, regInt(ctx, i), r));
						}
						free(ctx, a);
						var tmp = if (tEq(et, HDyn)) allocTmp(ctx, classType(ctx, ctx.arrayImpl.aobj, vector(), false)) else r;
						op(ctx, OCall1(tmp, allocFunPath(ctx, {pack: ["hl", "types"], name: "ArrayObj"}, "alloc"), a));
						if (tmp != r) {
							var re = allocTmp(ctx, HBool);
							op(ctx, OBool(re, true));
							var ren = allocTmp(ctx, cHRefBool);
							op(ctx, ORef(ren, re));
							op(ctx, OCall2(r, allocFunPath(ctx, {pack: ["hl", "types"], name: "ArrayDyn"}, "alloc"), tmp, ren));
						}
				}
				return r;
			case TArray(_):
				switch getAccess(ctx, e) {
					case AArray(a, at, vt, idx):
						return arrayRead(ctx, a, at, vt, idx, e.epos);
					case ACArray(a, t, idx):
						var tmp = allocTmp(ctx, t);
						op(ctx, OGetArray(tmp, a, idx));
						return tmp;
					case _:
						return die("", "genhl.ml");
				}
			case TMeta(_, e):
				return evalExpr(ctx, e);
			case TSwitch({switchSubject: en, switchCases: cases, switchDefault: def}):
				var rt = toType(ctx, e.etype);
				var r = allocTmp(ctx, rt);
				try {
					var max = -1;
					function getInt(e:TExpr):Int {
						return switch e.eexpr {
							case TConst(TInt(i)):
								i;
							case _:
								throw new ExitException();
						}
					}
					for (c in cases) for (v in c.casePatterns) {
						var i = getInt(v);
						if (i < 0) throw new ExitException();
						if (i > max) max = i;
					}
					if (max > 255 || cases.length == 0) throw new ExitException();
					var ridx = evalTo(ctx, en, HI32);
					var indexes = new Vector(max + 1, 0);
					op(ctx, OSwitch(ridx, indexes, 0));
					var switchPos = currentPos(ctx);
					switch def {
						case null:
							if (!tEq(rt, HVoid)) setDefault(ctx, r);
						case e:
							var re = evalTo(ctx, e, rt);
							if (!tEq(rt, HVoid)) op(ctx, OMov(r, re));
					}
					var jends = [jump(ctx, i -> OJAlways(i))];
					for (c in cases) {
						for (v in c.casePatterns) indexes[getInt(v)] = currentPos(ctx) - switchPos;
						var re = evalTo(ctx, c.caseExpr, rt);
						if (!tEq(rt, HVoid)) op(ctx, OMov(r, re));
						jends.unshift(jump(ctx, i -> OJAlways(i)));
					}
					setOp(ctx, switchPos - 1, OSwitch(ridx, indexes, currentPos(ctx) - switchPos));
					for (j in jends) j();
				} catch (_:ExitException) {
					var jends:Array<Void->Void> = [];
					var rvalue = evalExpr(ctx, en);
					function loop(c:TSwitchCase):Void->Void {
						var cases = c.casePatterns, e = c.caseExpr;
						hold(ctx, rvalue);
						var ok = [
							for (c in cases) {
								var ct = commonType(ctx, en, c, true, c.epos);
								switch [c.eexpr, ct] {
									case [TConst(TString(str)), HObj({pname: "String"})]:
										var jnull = jump(ctx, n -> OJNull(rvalue, n));

										/* compare len */
										var rlen = allocTmp(ctx, HI32);
										op(ctx, OField(rlen, rvalue, 1));
										hold(ctx, rlen);
										var u = toUtf8(str, c.epos);
										var str = u.str, len = u.len;
										var rlen2 = regInt(ctx, len);
										var jdiff = jump(ctx, n -> OJNotEq(rlen, rlen2, n));
										free(ctx, rlen);

										/* compare data */
										var rbytes = allocTmp(ctx, HBytes);
										op(ctx, OField(rbytes, rvalue, 0));
										hold(ctx, rbytes);
										var rbytes2 = allocTmp(ctx, HBytes);
										op(ctx, OString(rbytes2, allocString(ctx, str)));
										var result = allocTmp(ctx, HI32);
										op(ctx, OCall3(result, allocStd(ctx, "string_compare", [HBytes, HBytes, HI32], HI32), rbytes, rbytes2, rlen));
										free(ctx, rbytes);

										hold(ctx, result);
										var zero = regInt(ctx, 0);
										var jok = jump(ctx, n -> OJEq(result, zero, n));
										free(ctx, result);

										jnull();
										jdiff();
										jok;

									case _:
										var r = evalTo(ctx, c, ct);
										jump(ctx, n -> OJEq(r, rvalue, n));
								}
							}
						];
						free(ctx, rvalue);
						return () -> {
							for (f in ok) f();
							var re = evalTo(ctx, e, rt);
							if (!tEq(rt, HVoid)) op(ctx, OMov(r, re));
							jends.unshift(jump(ctx, n -> OJAlways(n)));
						};
					}
					var all = [for (c in cases) loop(c)];
					switch def {
						case null:
							if (!tEq(rt, HVoid)) op(ctx, ONull(r));
						case e:
							var rdef = evalTo(ctx, e, rt);
							if (!tEq(rt, HVoid)) op(ctx, OMov(r, rdef));
					}
					jends.unshift(jump(ctx, n -> OJAlways(n)));
					for (f in all) f();
					for (j in jends) j();
				}
				return r;
			case TEnumParameter(ec, f, index):
				var pt:Ttype, isSingle:Bool;
				switch toType(ctx, ec.etype) {
					case HEnum(e):
						var args = e.efields[f.efIndex].args;
						pt = args[index];
						isSingle = e.efields.length == 1;
					case _:
						pt = die("", "genhl.ml");
						isSingle = false;
				}
				var er = evalExpr(ctx, ec);
				if (isSingle) op(ctx, ONullCheck(er)); /* #7560 */
				var r = allocTmp(ctx, pt);
				op(ctx, OEnumField(r, er, f.efIndex, index));
				return castTo(ctx, r, toType(ctx, e.etype), e.epos);
			case TContinue:
				beforeBreakContinue(ctx);
				var pos = currentPos(ctx);
				op(ctx, OJAlways(-1)); /* loop */
				ctx.m.mcontinues.unshift(target -> setOp(ctx, pos, OJAlways(target - (pos + 1))));
				return allocTmp(ctx, HVoid);
			case TBreak:
				beforeBreakContinue(ctx);
				var pos = currentPos(ctx);
				op(ctx, OJAlways(-1)); /* loop */
				ctx.m.mbreaks.unshift(target -> setOp(ctx, pos, OJAlways(target - (pos + 1))));
				return allocTmp(ctx, HVoid);
			case TTry(etry, catches):
				var pos = currentPos(ctx);
				var rtrap = allocTmp(ctx, HDyn);
				op(ctx, OTrap(rtrap, -1)); /* loop */
				ctx.m.mtrys = ctx.m.mtrys + 1;
				if (compareVersion(ctx.hlVer, "1.16.0") >= 0) {
					var catchedTypes:Array<Int> = []; // port: list, head first
					function findMeta(e:TExpr):Void {
						switch e.eexpr {
							/* Std.isOfType(e, t) */
							case TMeta(m, {eexpr: TCall(_, [_, {eexpr: TTypeExpr(mt)}])}) if (Meta.metaEq(Meta.ExceptionTypeCheck, m.meta)):
								catchedTypes.unshift(typeGlobal(ctx, mt, e.epos).g);
							case TMeta(m, {eexpr: TConst(TBool(true))}) if (Meta.metaEq(Meta.ExceptionTypeCheck, m.meta)):
								catchedTypes.unshift(allocGlobal(ctx, "$Dynamic", HDyn));
							case _:
								core.Texpr.iter(findMeta, e);
						}
					}
					for (c in catches) core.Texpr.iter(findMeta, c.expr);
					var l = catchedTypes.copy();
					l.reverse();
					for (gt in l) op(ctx, OCatch(gt));
				}
				var tret = toType(ctx, e.etype);
				var result = allocTmp(ctx, tret);
				var r = evalExpr(ctx, etry);
				if (!tEq(tret, HVoid)) op(ctx, OMov(result, castTo(ctx, r, tret, etry.epos)));
				ctx.m.mtrys = ctx.m.mtrys - 1;
				op(ctx, OEndTrap(true));
				var j = jump(ctx, n -> OJAlways(n));
				setOp(ctx, pos, OTrap(rtrap, currentPos(ctx) - (pos + 1)));
				function loop(l:Vector<{variable:TVar, expr:TExpr}>, i:Int):Array<Void->Void> {
					if (i == l.length) {
						op(ctx, ORethrow(rtrap));
						return [];
					}
					var v = l[i].variable, ec = l[i].expr;
					var rv = allocVar(ctx, v, true);
					var jnext = if (follow(v.vType) == tDynamic) {
						op(ctx, OMov(rv, rtrap));
						() -> {};
					} else {
						var ct = switch follow(v.vType) {
							case TInst(c, _): TClassDecl(c);
							case TAbstract(a, _): TAbstractDecl(a);
							case TEnum(e, _): TEnumDecl(e);
							case _: die("", "genhl.ml");
						}
						hold(ctx, rtrap);
						var r = typeValue(ctx, ct, ec.epos);
						var rd = allocTmp(ctx, HDyn);
						free(ctx, rtrap);
						op(ctx, OCall2(rd, allocFunPath(ctx, {pack: ["hl"], name: "BaseType"}, "downcast"), r, rtrap));
						var jnext = jump(ctx, n -> OJNull(rd, n));
						var vt = toType(ctx, v.vType);
						op(ctx, OMov(rv, unsafeCastTo(ctx, rd, vt, ec.epos, false)));
						addAssign(ctx, v);
						jnext;
					}
					var r = evalExpr(ctx, ec);
					if (!tEq(tret, HVoid)) op(ctx, OMov(result, castTo(ctx, r, tret, ec.epos)));
					if (follow(v.vType) == tDynamic) return [];
					var jend = jump(ctx, n -> OJAlways(n));
					jnext();
					return [jend].concat(loop(l, i + 1));
				}
				for (j in loop(catches, 0)) j();
				j();
				return result;
			case TTypeExpr(t):
				return typeValue(ctx, t, e.epos);
			case TCast(ev, _):
				var t = toType(ctx, e.etype);
				var re = evalExpr(ctx, ev);
				var rt = allocTmp(ctx, t);
				if (safeCast(rtype(ctx, re), t)) op(ctx, OMov(rt, re)) else switch core.Abstract.followWithAbstracts(e.etype) {
					case TInst(c, _) if (hasClassFlag(c, CInterface)):
						hold(ctx, re);
						var c = evalTo(ctx, {eexpr: TTypeExpr(TClassDecl(c)), epos: e.epos, etype: tDynamic}, classType(ctx, ctx.baseType, vector(), false));
						hold(ctx, c);
						var rb = allocTmp(ctx, HBool);
						op(ctx, OCall2(rb, allocFunPath(ctx, {pack: ["hl"], name: "BaseType"}, "check"), c, re));
						var jnext = jump(ctx, n -> OJTrue(rb, n));
						var jnext2 = jump(ctx, n -> OJNull(re, n));
						op(ctx, OThrow(makeString(ctx, "Cast error", e.epos)));
						jnext();
						jnext2();
						var ut = toType(ctx, e.etype);
						op(ctx, OMov(rt, unsafeCastTo(ctx, re, ut, e.epos, false)));
						free(ctx, c);
						free(ctx, re);
					case _:
						op(ctx, OSafeCast(rt, re));
				}
				return rt;
			case TIdent(s):
				return Error.abort("Unbound identifier " + s, e.epos);
		}
	}

	// port: the `TCall ({ eexpr = TIdent s }, el) when s.[0] = '$'` case of eval_expr
	static function evalNativeCall(ctx:HlContext, e:TExpr, s:String, el:Vector<TExpr>):Int {
		function invalid():Dynamic return Error.abort("Invalid native call", e.epos);
		function bytesAccessType(eb:TExpr):Null<T> {
			return switch follow(eb.etype) {
				case TAbstract(a, [t]) if (isPath(a.aPath, ["hl"], "BytesAccess")): t;
				case _: null;
			}
		}
		function nativeArrayType(t:T):Ttype {
			return switch follow(t) {
				case TAbstract(a, [t]) if (isPath(a.aPath, ["hl"], "NativeArray")): toType(ctx, t);
				case _: invalid();
			}
		}
		function bset(b:TExpr, pos:TExpr, v:TExpr, vt:Ttype, mk:(Int, Int, Int) -> Opcode):Int {
			var b = evalTo(ctx, b, HBytes);
			hold(ctx, b);
			var pos = evalTo(ctx, pos, HI32);
			hold(ctx, pos);
			var r = evalTo(ctx, v, vt);
			free(ctx, pos);
			free(ctx, b);
			op(ctx, mk(b, pos, r));
			return r;
		}
		function bget(b:TExpr, pos:TExpr, rt:Ttype, mk:(Int, Int, Int) -> Opcode):Int {
			var b = evalTo(ctx, b, HBytes);
			hold(ctx, b);
			var pos = evalTo(ctx, pos, HI32);
			free(ctx, b);
			var r = allocTmp(ctx, rt);
			op(ctx, mk(r, b, pos));
			return r;
		}
		function localOf(e:TExpr):TVar {
			return switch e.eexpr {
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): localOf(e1);
				case TLocal(v): v;
				case _: invalid();
			}
		}
		switch [s, el] {
			case ["$new", [{eexpr: TTypeExpr(TClassDecl(_))}]]:
				switch follow(e.etype) {
					case TInst(c, pl):
						var r = allocTmp(ctx, classType(ctx, c, pl, false));
						op(ctx, ONew(r));
						return r;
					case _:
						return invalid();
				}
			case ["$int", [{eexpr: TBinop(OpDiv, e1, e2)}]] if (isInt(toType(ctx, e1.etype)) && isInt(toType(ctx, e2.etype))):
				var tmp = allocTmp(ctx, HI32);
				var r1 = evalTo(ctx, e1, HI32);
				hold(ctx, r1);
				var r2 = evalTo(ctx, e2, HI32);
				free(ctx, r1);
				op(ctx, if (unsignedOp(e1, e2)) OUDiv(tmp, r1, r2) else OSDiv(tmp, r1, r2));
				return tmp;
			case ["$int", [e]]:
				var tmp = allocTmp(ctx, HI32);
				op(ctx, OToInt(tmp, evalExpr(ctx, e)));
				return tmp;
			case ["$bsetui8", [b, pos, v]]:
				return bset(b, pos, v, HI32, OSetUI8);
			case ["$bsetui16", [b, pos, v]]:
				return bset(b, pos, v, HI32, OSetUI16);
			case ["$bseti32", [b, pos, v]]:
				return bset(b, pos, v, HI32, OSetMem);
			case ["$bseti64", [b, pos, v]]:
				return bset(b, pos, v, HI64, OSetMem);
			case ["$bsetf32", [b, pos, v]]:
				return bset(b, pos, v, HF32, OSetMem);
			case ["$bsetf64", [b, pos, v]]:
				return bset(b, pos, v, HF64, OSetMem);
			case ["$bytes_sizebits", [eb]]:
				var t = bytesAccessType(eb);
				if (t == null) return Error.abort("Invalid BytesAccess", eb.epos);
				var t = toType(ctx, t);
				return regInt(ctx, switch getGroup(t) {
					case GInt | GFloat: typeSizeBits(t);
					case _: Error.abort("Unsupported basic type " + tstr(t), e.epos);
				});
			case ["$bytes_nullvalue", [eb]]:
				var t = bytesAccessType(eb);
				if (t == null) return Error.abort("Invalid BytesAccess", eb.epos);
				var t = toType(ctx, t);
				var r = allocTmp(ctx, t);
				switch getGroup(t) {
					case GInt:
						op(ctx, OInt(r, allocI32(ctx, 0)));
					case GFloat:
						op(ctx, OFloat(r, allocFloat(ctx, 0.)));
					case _:
						Error.abort("Unsupported basic type " + tstr(t), e.epos);
				}
				return r;
			case ["$bget", [eb, pos]]:
				var t = bytesAccessType(eb);
				if (t == null) return Error.abort("Invalid BytesAccess", eb.epos);
				var b = evalTo(ctx, eb, HBytes);
				hold(ctx, b);
				var pos = evalTo(ctx, pos, HI32);
				free(ctx, b);
				var t = toType(ctx, t);
				switch getGroup(t) {
					case GInt | GFloat:
						var nb = typeSizeBits(t);
						var r = allocTmp(ctx, if (nb <= 1) HI32 else t);
						var ridx = shl(ctx, pos, nb);
						readMem(ctx, r, b, ridx, t);
						return r;
					case _:
						return Error.abort("Unsupported basic type " + tstr(t), e.epos);
				}
			case ["$bset", [eb, pos, value]]:
				var t = bytesAccessType(eb);
				if (t == null) return Error.abort("Invalid BytesAccess", eb.epos);
				var b = evalTo(ctx, eb, HBytes);
				hold(ctx, b);
				var pos = evalTo(ctx, pos, HI32);
				hold(ctx, pos);
				var t = toType(ctx, t);
				var v = switch getGroup(t) {
					case GInt | GFloat:
						var nb = typeSizeBits(t);
						var v = evalTo(ctx, value, if (nb <= 1) HI32 else t);
						hold(ctx, v);
						var ridx = shl(ctx, pos, nb);
						writeMem(ctx, b, ridx, t, v);
						free(ctx, v);
						v;
					case _:
						Error.abort("Unsupported basic type " + tstr(t), e.epos);
				}
				free(ctx, b);
				free(ctx, pos);
				return v;
			case ["$bgetui8", [b, pos]]:
				return bget(b, pos, HI32, OGetUI8);
			case ["$bgetui16", [b, pos]]:
				return bget(b, pos, HI32, OGetUI16);
			case ["$bgeti32", [b, pos]]:
				return bget(b, pos, HI32, OGetMem);
			case ["$bgeti64", [b, pos]]:
				return bget(b, pos, HI64, OGetMem);
			case ["$bgetf32", [b, pos]]:
				return bget(b, pos, HF32, OGetMem);
			case ["$bgetf64", [b, pos]]:
				return bget(b, pos, HF64, OGetMem);
			case ["$asize", [e]]:
				var r = allocTmp(ctx, HI32);
				var ft = follow(e.etype);
				var an = hlAbstractName(ft);
				switch ft {
					case TInst(_, _) if (an != null && an.name == "hl_carray"):
						var arr = evalExpr(ctx, e);
						op(ctx, ONullCheck(arr));
						op(ctx, OArraySize(r, arr));
					case TAbstract(a, [t]) if (isPath(a.aPath, ["hl"], "NativeArray")):
						op(ctx, OArraySize(r, evalTo(ctx, e, HArray(toType(ctx, t)))));
					case _:
						invalid();
				}
				return r;
			case ["$aalloc", [esize]]:
				var et = nativeArrayType(e.etype);
				var size = evalTo(ctx, esize, HI32);
				return allocArray(ctx, size, et);
			case ["$aget", [a, pos]]:
				/*
					read/write on arrays are unsafe : the type of NativeArray needs to be correcly set.
				 */
				var at = nativeArrayType(a.etype);
				var arr = evalTo(ctx, a, HArray(at));
				hold(ctx, arr);
				var pos = evalTo(ctx, pos, HI32);
				free(ctx, arr);
				var r = allocTmp(ctx, at);
				op(ctx, OGetArray(r, arr, pos));
				return castTo(ctx, r, toType(ctx, e.etype), e.epos);
			case ["$aset", [a, pos, value]]:
				var et = nativeArrayType(a.etype);
				var arr = evalTo(ctx, a, HArray(et));
				hold(ctx, arr);
				var pos = evalTo(ctx, pos, HI32);
				hold(ctx, pos);
				var r = evalTo(ctx, value, et);
				free(ctx, pos);
				free(ctx, arr);
				op(ctx, OSetArray(arr, pos, r));
				return r;
			case ["$abytes", [a]]:
				switch follow(a.etype) {
					case TInst(c, [t]) if (isPath(c.clPath, [], "Array") && isNumber(toType(ctx, t))):
						var a = evalExpr(ctx, a);
						var r = allocTmp(ctx, HBytes);
						op(ctx, ONullCheck(a));
						op(ctx, OField(r, a, 1));
						return r;
					case t:
						return Error.abort("Invalid array type " + core.TPrinting.sType(core.TPrinting.printContext(), t), a.epos);
				}
			case ["$ref", [v]]:
				switch v.eexpr {
					case TLocal(v):
						var r = allocTmp(ctx, toType(ctx, e.etype));
						var rv = switch rtype(ctx, r) {
							case HRef(t): allocVar(ctx, v, false);
							case _: invalid();
						}
						hold(ctx, rv); /* infinite hold */
						op(ctx, ORef(r, rv));
						return r;
					case _:
						return Error.abort("Ref should be a local variable", v.epos);
				}
			case ["$setref", [e1, e2]]:
				var v = localOf(e1);
				var r = allocVar(ctx, v, false);
				var rv = evalTo(ctx, e2, switch rtype(ctx, r) {
					case HRef(t): t;
					case _: invalid();
				});
				op(ctx, OSetref(r, rv));
				return r;
			case ["$unref", [e1]]:
				var v = localOf(e1);
				var r = allocVar(ctx, v, false);
				var out = allocTmp(ctx, switch rtype(ctx, r) {
					case HRef(t): t;
					case _: invalid();
				});
				op(ctx, OUnref(out, r));
				return out;
			case ["$refdata", [e1]]:
				var v = evalExpr(ctx, e1);
				var r = allocTmp(ctx, switch toType(ctx, e.etype) {
					case t = HRef(_): t;
					case _: invalid();
				});
				op(ctx, ORefData(r, v));
				return r;
			case ["$refoffset", [r, e1]]:
				var r = evalExpr(ctx, r);
				var e = evalTo(ctx, e1, HI32);
				var r2 = allocTmp(ctx, switch rtype(ctx, r) {
					case t = HRef(_): t;
					case _: invalid();
				});
				op(ctx, ORefOffset(r2, r, e));
				return r2;
			case ["$ttype", [v]]:
				var r = allocTmp(ctx, HType);
				op(ctx, OType(r, toType(ctx, v.etype)));
				return r;
			case ["$tdyntype", [v]]:
				var r = allocTmp(ctx, HType);
				op(ctx, OGetType(r, evalTo(ctx, v, HDyn)));
				return r;
			case ["$tkind", [v]]:
				var r = allocTmp(ctx, HI32);
				op(ctx, OGetTID(r, evalTo(ctx, v, HType)));
				return r;
			case ["$resources", []]:
				var tdef = core.ds.ArrayTools.find(ctx.com.types, t -> isPath(tInfos(t).mtPath, ["haxe", "_Resource"], "ResourceContent"));
				if (tdef == null) return die("", "genhl.ml");
				var t = classType(ctx, switch tdef {
					case TClassDecl(c): c;
					case _: die("", "genhl.ml");
				}, vector(), false);
				var res:Array<{k:String, v:haxe.io.Bytes}> = ctx.com.resources.fold((k, v, acc:Array<{k:String, v:haxe.io.Bytes}>) -> {
					acc.unshift({k: k, v: v});
					acc;
				}, []);
				var size = regInt(ctx, res.length);
				var arr = allocArray(ctx, size, HBytes);
				var ro = allocTmp(ctx, t);
				var rb = allocTmp(ctx, HBytes);
				var ridx = regInt(ctx, 0);
				hold(ctx, ridx);
				var hasLen = switch t {
					case HObj(p): p.pindex.exists("dataLen");
					case _: die("", "genhl.ml");
				}
				for (kv in res) {
					var k = kv.k, v = kv.v;
					op(ctx, ONew(ro));
					op(ctx, OString(rb, allocString(ctx, k)));
					op(ctx, OSetField(ro, 0, rb));
					/* fix for Resource.getString */
					var hasZero = false;
					for (i in 0...v.length) if (v.get(i) == 0) {
						hasZero = true;
						break;
					}
					var str = if (hasZero) v else {
						var b = haxe.io.Bytes.alloc(v.length + 1);
						b.blit(0, v, 0, v.length);
						b.set(v.length, 0);
						b;
					}
					op(ctx, OBytes(rb, allocBytes(ctx, str)));
					op(ctx, OSetField(ro, 1, rb));
					if (hasLen) op(ctx, OSetField(ro, 2, regInt(ctx, v.length)));
					op(ctx, OSetArray(arr, ridx, ro));
					op(ctx, OIncr(ridx));
				}
				free(ctx, ridx);
				return arr;
			case ["$rethrow", [v]]:
				var r = allocTmp(ctx, HVoid);
				op(ctx, ORethrow(evalTo(ctx, v, HDyn)));
				return r;
			case ["$allTypes", []]:
				var r = allocTmp(ctx, toType(ctx, e.etype));
				op(ctx, OGetGlobal(r, allocGlobal(ctx, "__types__", rtype(ctx, r))));
				return r;
			case ["$allTypes", [v]]:
				var v = evalExpr(ctx, v);
				op(ctx, OSetGlobal(allocGlobal(ctx, "__types__", rtype(ctx, v)), v));
				return v;
			case ["$hash", [v]]:
				switch v.eexpr {
					case TConst(TString(str)):
						var r = allocTmp(ctx, HI32);
						op(ctx, OInt(r, allocI32(ctx, hlHash(str))));
						return r;
					case _:
						return Error.abort("Constant string required", v.epos);
				}
			case ["$enumIndex", [v]]:
				return getEnumIndex(ctx, v);
			case ["$__mk_pos__", [{eexpr: TConst(TString(file))}, min, max]]:
				/* macros only - generated by reification */
				var rt = HAbstract("macro_pos", allocString(ctx, "macro_pos"), macroPosIdent);
				var r = allocTmp(ctx, rt);
				var rfile = allocTmp(ctx, HBytes);
				op(ctx, OBytes(rfile, allocBytes(ctx, haxe.io.Bytes.ofString(file))));
				hold(ctx, rfile);
				var min = evalExpr(ctx, min);
				hold(ctx, min);
				var max = evalExpr(ctx, max);
				op(ctx, OCall3(r, allocStd(ctx, "make_macro_pos", [HBytes, HI32, HI32], rt), rfile, min, max));
				free(ctx, rfile);
				free(ctx, min);
				return r;
			case ["$prefetch", [value, mode]]:
				var mode = constModeInt(mode, "Constant mode required", e.epos);
				switch getAccess(ctx, value) {
					case AInstanceField(f, index, _): op(ctx, OPrefetch(evalExpr(ctx, f), index + 1, mode));
					case _: op(ctx, OPrefetch(evalExpr(ctx, value), 0, mode));
				}
				return allocTmp(ctx, HVoid);
			case ["$unsafecast", [value]]:
				var r = allocTmp(ctx, toType(ctx, e.etype));
				op(ctx, OUnsafeCast(r, evalExpr(ctx, value)));
				return r;
			case ["$asm", [mode, value]]:
				var mode = constModeInt(mode, "Constant mode required", e.epos);
				var value = constModeInt(value, "Constant value required", e.epos);
				op(ctx, OAsm(mode, value, 0));
				return allocTmp(ctx, HVoid);
			case ["$asm", [mode, value, reg]]:
				var mode = constModeInt(mode, "Constant mode required", e.epos);
				var value = constModeInt(value, "Constant value required", e.epos);
				op(ctx, OAsm(mode, value, (evalExpr(ctx, reg)) + 1));
				return allocTmp(ctx, HVoid);
			case _:
				return Error.abort("Unknown native call " + s, e.epos);
		}
	}

	static function genAssignOp(ctx:HlContext, acc:Access, e1:TExpr, f0:Int->Int):Int {
		function f(r:Int):Int {
			switch rtype(ctx, r) {
				case HNull(t):
					var r2 = allocTmp(ctx, t);
					op(ctx, OSafeCast(r2, r));
					var r3 = allocTmp(ctx, HNull(t));
					op(ctx, OToDyn(r3, f0(r2)));
					return r3;
				case _:
					return f0(r);
			}
		}
		switch acc {
			case AInstanceField(eobj, findex, _):
				var robj = evalNullCheck(ctx, eobj);
				hold(ctx, robj);
				var t = realType(ctx, e1);
				var r = allocTmp(ctx, t);
				op(ctx, OField(r, robj, findex));
				var r = castTo(ctx, r, toType(ctx, e1.etype), e1.epos);
				var r = f(r);
				free(ctx, robj);
				op(ctx, OSetField(robj, findex, castTo(ctx, r, t, e1.epos)));
				return r;
			case AStaticVar(g, t, fid):
				var o = allocTmp(ctx, t);
				op(ctx, OGetGlobal(o, g));
				var r = allocTmp(ctx, toType(ctx, e1.etype));
				op(ctx, OField(r, o, fid));
				hold(ctx, o);
				var r = f(r);
				free(ctx, o);
				op(ctx, OSetField(o, fid, r));
				return r;
			case AGlobal(g):
				var r = allocTmp(ctx, toType(ctx, e1.etype));
				op(ctx, OGetGlobal(r, g));
				var r = f(r);
				op(ctx, OSetGlobal(g, r));
				return r;
			case ACaptured(idx):
				var r = allocTmp(ctx, toType(ctx, e1.etype));
				op(ctx, OEnumField(r, ctx.m.mcaptreg, 0, idx));
				var r = f(r);
				op(ctx, OSetEnumField(ctx.m.mcaptreg, idx, r));
				return r;
			case AArray(ra, at, vt, ridx):
				hold(ctx, ra);
				hold(ctx, ridx);
				var r = switch at {
					case HDyn:
						/* call getDyn() */
						var r = allocTmp(ctx, HDyn);
						op(ctx, OCallMethod(r, 0, [ra, ridx]));
						var r = f(r);
						/* call setDyn() */
						op(ctx, OCallMethod(allocTmp(ctx, HVoid), 1, [ra, ridx, r]));
						r;
					case _:
						/* bounds check against length */
						var len = allocTmp(ctx, HI32);
						op(ctx, OField(len, ra, 0)); /* length */
						var j = jump(ctx, i -> OJULt(ridx, len, i));
						var fexpand = allocFunPath(ctx, arrayClass(ctx, at).clPath, "__expand");
						op(ctx, OCall2(allocTmp(ctx, HVoid), fexpand, ra, ridx));
						j();
						switch getGroup(at) {
							case GInt | GFloat:
								var hbytes = allocTmp(ctx, HBytes);
								op(ctx, OField(hbytes, ra, 1));
								var ridx = shl(ctx, ridx, typeSizeBits(at));
								hold(ctx, ridx);
								hold(ctx, hbytes);
								var r = allocTmp(ctx, at);
								readMem(ctx, r, hbytes, ridx, at);
								var r = f(r);
								writeMem(ctx, hbytes, ridx, at, r);
								free(ctx, ridx);
								free(ctx, hbytes);
								r;
							case _:
								var arr = allocTmp(ctx, HArray(vt));
								op(ctx, OField(arr, ra, 1));
								var r = allocTmp(ctx, at);
								op(ctx, OGetArray(r, arr, ridx));
								hold(ctx, arr);
								var r = f(r);
								free(ctx, arr);
								op(ctx, OSetArray(arr, ridx, r));
								r;
						}
				}
				free(ctx, ra);
				free(ctx, ridx);
				return r;
			case ADynamic(eobj, fid):
				var robj = evalNullCheck(ctx, eobj);
				hold(ctx, robj);
				var t = realType(ctx, e1);
				var r = allocTmp(ctx, t);
				op(ctx, ODynGet(r, robj, fid));
				var r = castTo(ctx, r, toType(ctx, e1.etype), e1.epos);
				var r = f(r);
				var r = castTo(ctx, r, t, e1.epos);
				free(ctx, robj);
				op(ctx, ODynSet(robj, fid, r));
				return r;
			case ANone | ALocal(_) | AStaticFun(_) | AInstanceFun(_) | AInstanceProto(_) | AVirtualMethod(_) | AEnum(_) | ACArray(_):
				return die("", "genhl.ml");
		}
	}

	static function buildCaptureVars(ctx:HlContext, f:TFunc):MethodCapture {
		var ignoredVars = new IntMap<Bool>();
		var usedVars = new IntMap<TVar>();
		/* get all captured vars in scope, ignore vars that are declared */
		function declVar(v:TVar):Void {
			if (hasVarFlag(v, VCaptured)) ignoredVars.set(v.vId, true);
		}
		function useVar(v:TVar):Void {
			if (hasVarFlag(v, VCaptured)) usedVars.set(v.vId, v);
		}
		function loop(e:TExpr):Void {
			switch e.eexpr {
				case TLocal(v):
					useVar(v);
				case TVar(v, _):
					declVar(v);
				case TTry(_, catches):
					for (c in catches) declVar(c.variable);
				case TFunction(f):
					for (a in f.tfArgs) declVar(a.variable);
				case _:
			}
			core.Texpr.iter(loop, e);
		}
		for (a in f.tfArgs) declVar(a.variable);
		loop(f.tfExpr);
		var cvars = [for (v in usedVars) if (!ignoredVars.exists(v.vId)) v];
		ocamlArraySort((v1:TVar, v2:TVar) -> v1.vId - v2.vId, cvars);
		var cvars = Vector.fromArrayCopy(cvars);
		var indexes = new IntMap<Int>();
		var v0t = if (cvars.length == 1) toType(ctx, cvars[0].vType) else HDyn;
		var ct:Ttype, group:Bool;
		switch cvars.length {
			case 0:
				ct = HVoid;
				group = false;
			case 1 if (isNullable(v0t)):
				ct = v0t;
				group = false;
			case _:
				for (i in 0...cvars.length) indexes.set(cvars[i].vId, i);
				var ctypes = [for (v in cvars) toType(ctx, v.vType)];
				ct = tupleType(ctx, ctypes);
				group = true;
		}
		return new MethodCapture(indexes, cvars, ct, group);
	}

	static function genMethodWrapper(ctx:HlContext, rt:Ttype, t:Ttype, p:Pos):Int {
		var inner = ctx.methodWrappers.get(rt);
		if (inner != null) {
			var fid = inner.get(t);
			if (fid != null) return fid;
		}
		var fid = lookupAlloc(ctx.cfids, true);
		if (inner == null) {
			inner = new TtypeMap();
			ctx.methodWrappers.set(rt, inner);
		}
		inner.set(t, fid);
		var old = ctx.m;
		var targs:Array<Ttype>, tret:Ttype;
		switch t {
			case HFun(args, ret):
				targs = args;
				tret = ret;
			case _:
				targs = die("", "genhl.ml");
				tret = null;
		}
		var iargs:Array<Ttype>, iret:Ttype;
		switch rt {
			case HFun(args, ret):
				iargs = args;
				iret = ret;
			case _:
				iargs = die("", "genhl.ml");
				iret = null;
		}
		ctx.m = methodContext(fid, HDyn, nullCapture, false);
		setCurpos(ctx, p);
		var rfun = allocTmp(ctx, rt);
		var rargs = [
			for (t in targs) {
				var r = allocTmp(ctx, t);
				hold(ctx, r);
				r;
			}
		];
		if (rargs.length != iargs.length) throw new core.ds.InvalidArgument("List.map2");
		var casts = [
			for (i in 0...rargs.length) {
				var r = rargs[i];
				var r2 = castTo(ctx, r, iargs[i], p, true);
				hold(ctx, r2);
				free(ctx, r);
				r2;
			}
		];
		for (r in casts) free(ctx, r);
		var rret = allocTmp(ctx, iret);
		op(ctx, OCallClosure(rret, rfun, casts));
		op(ctx, ORet(castTo(ctx, rret, tret, p)));
		var f = new Fundecl({fst: "", snd: ""}, fid, HFun([rt].concat(targs), tret), Vector.fromArrayCopy(ctx.m.mregs), Vector.fromArrayCopy(ctx.m.mops), makeDebug(ctx, ctx.m.mdebug),
			makeAssigns(ctx.m.massign), false);
		ctx.m = old;
		ctx.cfunctions.push(f);
		return fid;
	}

	static function makeFun(ctx:HlContext, name:FPath, fidx:Int, f:TFunc, cthis:Null<TClass>, cparent:Null<MethodCapture>, ?genContent:Void->Void):MethodCapture {
		var old = ctx.m;
		var capt = buildCaptureVars(ctx, f);
		var hasCapturedVars = capt.cVars.length > 0;
		var useParentCapture = false;
		if (cparent != null && hasCapturedVars && capt.cVars.foreach(v -> cparent.cMap.exists(v.vId))) {
			capt = cparent;
			useParentCapture = true;
		}

		ctx.m = methodContext(fidx, toType(ctx, f.tfType), capt, cthis != null);

		setCurpos(ctx, f.tfExpr.epos);

		var tthis = if (cthis == null) null else {
			var t = toType(ctx, TInst(cthis, vector()));
			hold(ctx, allocTmp(ctx, t)); /* index 0 */
			t;
		}

		var rcapt:Null<Int> = if (hasCapturedVars && cparent != null) {
			if (capt.cGroup) {
				var r = allocTmp(ctx, capt.cType);
				hold(ctx, r);
				r;
			} else allocVar(ctx, capt.cVars[0], true);
		} else null;

		var args = [
			for (a in f.tfArgs) {
				var v = a.variable, o = a.defaultValue;
				var t = toType(ctx, v.vType);
				var r = allocVar(ctx, if (o == null) v else {
					var v2 = v.clone();
					v2.vType = if (!isNullable(t)) TAbstract(ctx.refAbstract, vector(v.vType)) else v.vType;
					v2;
				}, true);
				addAssign(ctx, v, true); /* record var name */
				rtype(ctx, r);
			}
		];

		if (hasCapturedVars) ctx.m.mcaptreg = if (rcapt == null && !capt.cGroup) -1 else if (rcapt == null) {
			var r = allocTmp(ctx, capt.cType);
			hold(ctx, r);
			op(ctx, OEnumAlloc(r, 0));
			addCapture(ctx, r);
			r;
		} else {
			addCapture(ctx, rcapt);
			rcapt;
		}

		for (a in f.tfArgs) {
			var v = a.variable, o = a.defaultValue;
			var r = allocVar(ctx, v, false);
			var vt = toType(ctx, v.vType);
			var capt = capturedIndex(ctx, v);
			switch o {
				case _ if (o == null || o.eexpr.match(TConst(TNull))):
				case c if (!isNullable(vt)):
					/* if optional but not null, turn into a not nullable here */
					var j = jump(ctx, n -> OJNotNull(r, n));
					var t = allocTmp(ctx, vt);
					switch getGroup(vt) {
						case GInt:
							switch c.eexpr {
								case TConst(TInt(i)): op(ctx, OInt(t, allocI32(ctx, i)));
								case TConst(TFloat(s)): op(ctx, OInt(t, allocI32(ctx, int32OfFloat(core.ds.OcamlFloat.ofString(s)))));
								case _: op(ctx, OMov(t, evalTo(ctx, c, vt)));
							}
						case GFloat:
							switch c.eexpr {
								case TConst(TInt(i)): op(ctx, OFloat(t, allocFloat(ctx, i)));
								case TConst(TFloat(s)): op(ctx, OFloat(t, allocFloat(ctx, core.ds.OcamlFloat.ofString(s))));
								case _: op(ctx, OMov(t, evalTo(ctx, c, vt)));
							}
						case GBool:
							switch c.eexpr {
								case TConst(TBool(b)): op(ctx, OBool(t, b));
								case _: op(ctx, OMov(t, evalTo(ctx, c, vt)));
							}
						case _:
							op(ctx, OMov(t, evalTo(ctx, c, vt)));
					}
					if (capt == null) addAssign(ctx, v);
					var jend = jump(ctx, n -> OJAlways(n));
					j();
					op(ctx, OUnref(t, r));
					if (capt == null) addAssign(ctx, v);
					jend();
					ctx.m.mvars.set(v.vId, t);
					free(ctx, r);
					hold(ctx, t);
				case c:
					var j = jump(ctx, n -> OJNotNull(r, n));
					switch c.eexpr {
						case TConst(TNull | TThis | TSuper): die("", "genhl.ml");
						case TConst(TInt(i)) if (toType(ctx, core.Abstract.followWithAbstracts(v.vType)).match(HUI8 | HUI16 | HI32 | HI64 | HDyn)):
							var tmp = allocTmp(ctx, HI32);
							op(ctx, OInt(tmp, allocI32(ctx, i)));
							op(ctx, OToDyn(r, tmp));
						case TConst(TFloat(s)) if (toType(ctx, core.Abstract.followWithAbstracts(v.vType)).match(HUI8 | HUI16 | HI32 | HI64)):
							var tmp = allocTmp(ctx, HI32);
							op(ctx, OInt(tmp, allocI32(ctx, int32OfFloat(core.ds.OcamlFloat.ofString(s)))));
							op(ctx, OToDyn(r, tmp));
						case TConst(TInt(i)):
							var tmp = allocTmp(ctx, HF64);
							op(ctx, OFloat(tmp, allocFloat(ctx, i)));
							op(ctx, OToDyn(r, tmp));
						case TConst(TFloat(s)):
							var tmp = allocTmp(ctx, HF64);
							op(ctx, OFloat(tmp, allocFloat(ctx, core.ds.OcamlFloat.ofString(s))));
							op(ctx, OToDyn(r, tmp));
						case TConst(TBool(b)):
							var tmp = allocTmp(ctx, HBool);
							op(ctx, OBool(tmp, b));
							op(ctx, OToDyn(r, tmp));
						case TConst(TString(s)):
							op(ctx, OMov(r, makeString(ctx, s, f.tfExpr.epos)));
						case _:
							op(ctx, OMov(r, evalTo(ctx, c, vt)));
					}
					j();
			}
			if (capt != null) op(ctx, OSetEnumField(ctx.m.mcaptreg, capt, allocVar(ctx, v, false)));
		}

		var tret = toType(ctx, f.tfType);
		if (genContent == null) {
			evalExpr(ctx, f.tfExpr);
			function hasFinalJump(e:TExpr):Bool {
				/* prevents a jump outside function bounds error */
				return switch e.eexpr {
					case TBlock(el): if (el.length == 0) true else hasFinalJump(el[el.length - 1]);
					case TParenthesis(e): hasFinalJump(e);
					case TReturn(_): false;
					case _: true;
				}
			}
			setCurpos(ctx, maxPos(f.tfExpr));
			if (tEq(tret, HVoid)) op(ctx, ORet(allocTmp(ctx, HVoid))) else if (hasFinalJump(f.tfExpr)) {
				var r = allocTmp(ctx, tret);
				switch getGroup(tret) {
					case GInt: op(ctx, OInt(r, allocI32(ctx, 0)));
					case GFloat: op(ctx, OFloat(r, allocFloat(ctx, 0.)));
					case GBool: op(ctx, OBool(r, false));
					case _: op(ctx, ONull(r));
				}
				op(ctx, ORet(r));
			}
		} else
			genContent();

		var fargs = (if (tthis == null) [] else [tthis]).concat(if (rcapt == null) [] else [rtype(ctx, rcapt)]).concat(args);
		var hlf = new Fundecl(name, fidx, HFun(fargs, tret), Vector.fromArrayCopy(ctx.m.mregs), Vector.fromArrayCopy(ctx.m.mops), makeDebug(ctx, ctx.m.mdebug),
			makeAssigns(ctx.m.massign, true), genContent == null || !(name.fst == "" && name.snd == ""));
		ctx.m = old;
		ctx.definedFuns.set(fidx, true);
		ctx.cfunctions.push(hlf);
		return capt;
	}

	// port: OCaml `Int32.of_float` (C cast; out-of-range values give 0x80000000 on x86-64)
	static function int32OfFloat(f:Float):Int {
		if (Math.isNaN(f) || f >= 2147483648.0 || f <= -2147483649.0) return 0x80000000;
		return Std.int(f);
	}

	static function generateStatic(ctx:HlContext, c:TClass, f:TClassField):Void {
		switch f.cfKind {
			case Var(_):
			case Method(_) if (hasClassFieldFlag(f, CfExtern)):
			case Method(m):
				function addNative(lib:String, name:String):Void {
					var fid = allocFid(ctx, c, f);
					lookup(ctx.cnatives, name + "@" + lib + "\x00" + fid, () -> {
						ctx.definedFuns.set(fid, true);
						var t = toType(ctx, f.cfType);
						var n = allocString(ctx, name);
						var l = allocString(ctx, lib);
						({lib: l, name: n, t: t, findex: fid} : Native);
					});
				}
				for (m in f.cfMeta) {
					if (Meta.metaEq(Meta.HlNative, m.meta)) {
						switch m.exprs {
							case [{expr: EConst(String(lib, _))}, {expr: EConst(String(name, _))}]:
								addNative(lib, name);
							case [{expr: EConst(String(lib, _))}]:
								addNative(lib, f.cfName);
							case [{expr: EConst(Float(ver, _))}]:
								if (compareVersion(ctx.hlVer, ver + ".0") < 0) {
									function genContent():Void {
										op(ctx, OThrow(makeString(ctx, "Requires compiling with -D hl-ver=" + ver + ".0 or higher", nullPos)));
									}
									switch f.cfExpr {
										case null:
											if (!Meta.has(Meta.NoExpr, f.cfMeta)) Error.abort("Missing function body", f.cfPos);
										case {eexpr: TFunction(fn)}:
											makeFun(ctx, {fst: sTypePath(c.clPath), snd: f.cfName}, allocFid(ctx, c, f), fn, null, null, genContent);
										case _:
											if (!Meta.has(Meta.NoExpr, f.cfMeta)) Error.abort("Missing function body", f.cfPos);
									}
								} else
									addNative("std", f.cfName);
							case []:
								addNative("std", f.cfName);
							case _:
								Error.abort("Invalid @:hlNative decl", m.pos);
						}
						return;
					}
				}
				var genContent = if (isExcluded(c)) () -> op(ctx, OAssert(0)) else null;
				switch f.cfExpr {
					case null:
						if (!Meta.has(Meta.NoExpr, f.cfMeta)) Error.abort("Missing function body", f.cfPos);
					case {eexpr: TFunction(fn)}:
						makeFun(ctx, {fst: sTypePath(c.clPath), snd: f.cfName}, allocFid(ctx, c, f), fn, null, null, genContent);
					case _:
						if (!Meta.has(Meta.NoExpr, f.cfMeta)) Error.abort("Missing function body", f.cfPos);
				}
		}
	}

	static function generateMember(ctx:HlContext, c:TClass, f:TClassField):Void {
		switch f.cfKind {
			case Var(_):
			case _ if (isExternField(f)):
			case Method(m):
				var ff:TFunc = switch f.cfExpr {
					case null if (hasClassFieldFlag(f, CfAbstract)):
						var tl, tr;
						switch followWithCoro(f.cfType) {
							case NotCoro(TFun(s)):
								tl = s.args;
								tr = s.ret;
							case Coro(s):
								var s = context.Common.expandCoroType(ctx.com.basic, s.args, s.ret);
								tl = s.args;
								tr = s.ret;
							case _:
								tl = die("", "genhl.ml");
								tr = null;
						}
						var args = tl.map(a -> {
							var v = TFunctions.allocVar(VGenerated, a.name, a.type, nullPos);
							({variable: v, defaultValue: if (a.optional) mk(TConst(TNull), a.type, nullPos) else null} : {variable:TVar, defaultValue:Null<TExpr>});
						});
						{
							tfArgs: args,
							tfType: tr,
							tfExpr: mk(TThrow(mk(TConst(TNull), tDynamic, nullPos)), tDynamic, nullPos)
						};
					case null: Error.abort("Missing function body", f.cfPos);
					case {eexpr: TFunction(f)}: f;
					case _: Error.abort("Missing function body", f.cfPos);
				}
				var genContent = if (isExcluded(c)) () -> op(ctx, OAssert(0)) else if (f.cfName != "new") null else () -> {
					var o = switch classType(ctx, c, extractParamTypes(c.clParams), false) {
						case HObj(o) | HStruct(o): o;
						case _: die("", "genhl.ml");
					}

					/*
						init dynamic functions
					 */
					for (f in c.clOrderedFields) {
						switch f.cfKind {
							case Method(MethDynamic):
								var idx = try getIndex(f.cfName, o) catch (_:NotFound) die("", "genhl.ml");
								var fid = idx.fid, ft = idx.t;
								var fr = allocTmp(ctx, ft);
								op(ctx, OGetThis(fr, fid));
								var jnext = jump(ctx, n -> OJNotNull(fr, n));
								var r = allocTmp(ctx, toType(ctx, f.cfType));
								op(ctx, OInstanceClosure(r, allocFid(ctx, c, f), 0));
								op(ctx, OSetThis(fid, castTo(ctx, r, ft, f.cfPos)));
								jnext();
							case _:
						}
					}
					evalExpr(ctx, ff.tfExpr);
					op(ctx, ORet(allocTmp(ctx, HVoid)));
				}
				makeFun(ctx, {fst: sTypePath(c.clPath), snd: f.cfName}, allocFid(ctx, c, f), ff, c, null, genContent);
				if (f.cfName == "toString" && !hasClassFieldFlag(f, CfOverride) && !c.clFields.exists("__string") && isToString(f.cfType)) {
					var p:Pos = {pfile: f.cfPos.pfile, pmin: f.cfPos.pmin, pmax: f.cfPos.pmin};
					/* function __string() { var str = this.toString(); return if (str == null) null else str.bytes; } */
					var basic = ctx.com.basic;
					var ethis = mk(TConst(TThis), TInst(c, extractParamTypes(c.clParams)), p);
					var tstr = mk(TCall(mk(TField(ethis, FInstance(c, extractParamTypes(c.clParams), f)), f.cfType, p), vector()), basic.tstring, p);
					var vtmp = TFunctions.allocVar(VGenerated, "str", basic.tstring, p);
					var vstr = mk(TLocal(vtmp), basic.tstring, p);
					var cstr:TClass, cfBytes:TClassField;
					switch basic.tstring {
						case TInst(c, _):
							cstr = c;
							cfBytes = c.clFields.get("bytes");
							if (cfBytes == null) die("", "genhl.ml");
						case _:
							cstr = die("", "genhl.ml");
							cfBytes = null;
					}
					var ebytes = mk(TField(vstr, FInstance(cstr, vector(), cfBytes)), cfBytes.cfType, p);
					var econd = mk(TBinop(OpEq, vstr, mk(TConst(TNull), basic.tstring, p)), basic.tbool, p);
					var efun = mk(TBlock(vector(
						mk(TVar(vtmp, tstr), basic.tvoid, p),
						mk(TReturn(mk(TIf(econd, mk(TConst(TNull), cfBytes.cfType, p), ebytes), cfBytes.cfType, p)), cfBytes.cfType, p)
					)), basic.tvoid, p);
					makeFun(ctx, {fst: sTypePath(c.clPath), snd: "__string"}, allocFunPath(ctx, c.clPath, "__string"),
						{tfExpr: efun, tfArgs: vector(), tfType: cfBytes.cfType}, c, null);
				}
		}
	}

	static function generateType(ctx:HlContext, t:ModuleType):Void {
		switch t {
			case TClassDecl(c) if (hasClassFlag(c, CInterface)):
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				for (f in c.clOrderedStatics) for (m in f.cfMeta) if (Meta.metaEq(Meta.HlNative, m.meta)) generateStatic(ctx, c, f);
			case TClassDecl(c):
				for (f in c.clOrderedStatics) generateStatic(ctx, c, f);
				switch c.clConstructor {
					case null:
					case f:
						function mergeInits(e:Null<TExpr>):Null<TExpr> {
							var fn = if (e == null) null else switch e.eexpr {
								case TFunction(fn) if (fn.tfExpr.eexpr.match(TBlock(_))): fn;
								case _: null;
							}
							switch fn {
								case null:
									return e;
								case _:
									var ef = fn.tfExpr;
									var el = switch ef.eexpr {
										case TBlock(el): el;
										case _: die("", "genhl.ml");
									}
									function merge(ei:TExpr):TExpr {
										function loop(ei:TExpr):TExpr {
											var ei = core.Texpr.mapExpr(loop, ei);
											return {eexpr: ei.eexpr, etype: ei.etype, epos: e.epos};
										}
										return if (ei.epos.pmin < e.epos.pmin || ei.epos.pmax > e.epos.pmax) loop(ei) else ei;
									}
									var fn2:TFunc = {tfArgs: fn.tfArgs, tfType: fn.tfType, tfExpr: {eexpr: TBlock(el.map(merge)), etype: ef.etype, epos: ef.epos}};
									return {eexpr: TFunction(fn2), etype: e.etype, epos: e.epos};
							}
						}
						var f2 = f.clone();
						f2.cfExpr = mergeInits(f.cfExpr);
						generateMember(ctx, c, f2);
				}
				for (f in c.clOrderedFields) generateMember(ctx, c, f);
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	static function generateStaticContent(ctx:HlContext, types:Array<ModuleType>, f:TFunc):Void {
		var isInit = allocTmp(ctx, HBool);
		op(ctx, OCall0(isInit, allocFunPath(ctx, {pack: [], name: "Type"}, "init")));
		hold(ctx, isInit);

		/* init class values */
		for (t in types) {
			switch t {
				case TClassDecl(c) if (!hasClassFlag(c, CExtern) && !(isArrayClass(sTypePath(c.clPath)) && c.clPath.name != "ArrayDyn")
					&& c != ctx.coreType && c != ctx.coreEnum):

					var path:GlobalTypePath = if (c == ctx.arrayImpl.abase) {pack: [], name: "Array"} else if (c == ctx.baseClass) {pack: [], name: "Class"} else
						c.clPath;

					var gct = classGlobal(ctx, c, false);
					var g = gct.g, ct = gct.t;
					var ctype = if (c == ctx.arrayImpl.abase) ctx.arrayImpl.aall else c;
					var t = classType(ctx, ctype, extractParamTypes(ctype.clParams), false);

					function index(name:String):Int {
						return switch ct {
							case HObj(o):
								try getIndex(name, o).fid catch (_:NotFound) die("", "genhl.ml");
							case _:
								die("", "genhl.ml");
						}
					}

					var rc = switch t {
						case HObj(o) if ((if (o.pclassglobal == null) -1 else o.pclassglobal) != g):
							/* manual registration for objects with prototype tricks (Array) */

							var rc = allocTmp(ctx, ct);
							op(ctx, ONew(rc));
							op(ctx, OSetGlobal(g, rc));
							hold(ctx, rc);

							var rt = allocTmp(ctx, HType);
							op(ctx, OType(rt, t));
							op(ctx, OSetField(rc, index("__type__"), rt));
							var rn = evalExpr(ctx, {eexpr: TConst(TString(sTypePath(path))), epos: c.clPos, etype: ctx.com.basic.tstring});
							op(ctx, OSetField(rc, index("__name__"), rn));

							var rname = allocTmp(ctx, HBytes);
							op(ctx, OString(rname, allocString(ctx, sTypePath(path))));
							var freg = allocFunPath(ctx, {pack: [], name: "Type"}, "register");
							op(ctx, OCall2(allocTmp(ctx, HVoid), freg, rname, rc));
							rc;

						case _:

							var rct = allocTmp(ctx, HType);
							op(ctx, OType(rct, ct));
							hold(ctx, rct);

							var rt = allocTmp(ctx, HType);
							op(ctx, OType(rt, t));

							var rname = allocTmp(ctx, HBytes);
							op(ctx, OString(rname, allocString(ctx, sTypePath(path))));

							var rc = allocTmp(ctx, classType(ctx, ctx.baseClass, vector(), false));
							op(ctx, OCall3(rc, allocFunPath(ctx, {pack: [], name: "Type"}, if (isExcluded(c)) "loadClass" else "initClass"), rct, rt, rname));
							hold(ctx, rc);
							free(ctx, rct);
							rc;
					}

					function gatherImplements():Array<TClass> {
						var classes:Array<TClass> = [];
						function lookup(cv:TClass):Bool {
							return core.ds.ArrayTools.exists(cv.clImplements, i -> i.cls == c || lookup(i.cls));
						}
						function check(t:ModuleType):Void {
							switch t {
								case TClassDecl(c) if (hasClassFlag(c, CInterface) == false && !hasClassFlag(c, CExtern)):
									if (lookup(c)) classes.unshift(c);
								case _:
							}
						}
						for (t in ctx.com.types) check(t);
						return classes;
					}
					if (hasClassFlag(c, CInterface)) {
						var l = gatherImplements();
						var rt = allocTmp(ctx, HType);
						op(ctx, OType(rt, HType));
						var ra = allocArray(ctx, regInt(ctx, l.length), HType);
						for (i in 0...l.length) {
							op(ctx, OType(rt, toType(ctx, TInst(l[i], vector()))));
							op(ctx, OSetArray(ra, regInt(ctx, i), rt));
						}
						op(ctx, OSetField(rc, index("__implementedBy__"), ra));

						/* TODO : use a plain class for interface object since we don't allow statics */
						var rt = allocTmp(ctx, ct);
						op(ctx, OSafeCast(rt, rc));
						op(ctx, OSetGlobal(g, rt));
					}

					switch core.Texpr.buildMetadata(ctx.com.basic, TClassDecl(c)) {
						case null:
						case e:
							var r = evalTo(ctx, e, HDyn);
							op(ctx, OSetField(rc, index("__meta__"), r));
					}

					free(ctx, rc);

				case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):

					var et = enumClass(ctx, e);
					var t = enumType(ctx, e);

					var ret = allocTmp(ctx, HType);
					op(ctx, OType(ret, et));
					hold(ctx, ret);
					var rt = allocTmp(ctx, HType);
					op(ctx, OType(rt, t));
					var r = allocTmp(ctx, classType(ctx, ctx.baseEnum, vector(), false));
					var etr = allocTmp(ctx, et);
					op(ctx, OCall2(r, allocFunPath(ctx, {pack: [], name: "Type"}, "initEnum"), ret, rt));
					free(ctx, ret);
					op(ctx, OSafeCast(etr, r));

					function index(name:String):Int {
						return switch et {
							case HObj(o):
								try getIndex(name, o).fid catch (_:NotFound) die("", "genhl.ml");
							case _:
								die("", "genhl.ml");
						}
					}

					var avalues = allocTmp(ctx, HArray(t));
					op(ctx, OField(avalues, r, index("__evalues__")));

					for (n in e.eNames) {
						var f = e.eConstrs.get(n);
						if (f == null) throw NotFound.raise();
						switch follow(f.efType) {
							case TFun(_):
							case _:
								var g = allocGlobal(ctx, efieldName(e, f), t);
								var r = allocTmp(ctx, t);
								var rd = allocTmp(ctx, HDyn);
								op(ctx, OGetArray(rd, avalues, regInt(ctx, f.efIndex)));
								op(ctx, OSafeCast(r, rd));
								op(ctx, OSetGlobal(g, r));
								op(ctx, OSetField(etr, index(f.efName), r));
						}
					}

					switch core.Texpr.buildMetadata(ctx.com.basic, TEnumDecl(e)) {
						case null:
						case e:
							var m = evalTo(ctx, e, HDyn);
							op(ctx, OSetField(r, index("__meta__"), m));
					}

				case TAbstractDecl(a) if (a.aPath.pack.length == 0):
					var name = a.aPath.name, pos = a.aPos;
					switch name {
						case "Int" | "Float" | "Dynamic" | "Bool":
							var isBool = name == "Bool";
							var t = classType(ctx, if (isBool) ctx.coreEnum else ctx.coreType, vector(), false);

							function index(name:String):Int {
								return switch t {
									case HObj(o):
										try getIndex(name, o).fid catch (_:NotFound) die("", "genhl.ml");
									case _:
										die("", "genhl.ml");
								}
							}

							var g = allocGlobal(ctx, "$" + name, t);
							var r = allocTmp(ctx, t);
							var rt = allocTmp(ctx, HType);
							op(ctx, ONew(r));
							op(ctx, OType(rt, switch name {
								case "Int": HI32;
								case "Float": HF64;
								case "Dynamic": HDyn;
								case "Bool": HBool;
								case _: die("", "genhl.ml");
							}));
							op(ctx, OSetField(r, index("__type__"), rt));
							var rs = makeString(ctx, name, pos);
							op(ctx, OSetField(r, index(if (isBool) "__ename__" else "__name__"), rs));
							op(ctx, OSetGlobal(g, r));

							var bytes = allocTmp(ctx, HBytes);
							op(ctx, OString(bytes, allocString(ctx, name)));
							var freg = allocFunPath(ctx, {pack: [], name: "Type"}, "register");
							op(ctx, OCall2(allocTmp(ctx, HVoid), freg, bytes, r));
						case _:
					}
				case _:
			}
		}

		var j = jump(ctx, d -> OJTrue(isInit, d));
		op(ctx, ORet(allocTmp(ctx, HVoid)));
		j();
		free(ctx, isInit);
		evalExpr(ctx, f.tfExpr);
		op(ctx, ORet(allocTmp(ctx, HVoid)));
	}

	static function generateStaticInit(ctx:HlContext, types:Array<ModuleType>, main:Null<TExpr>):Int {
		var exprs:Array<TExpr> = []; // port: chronological (upstream builds the list reversed)
		var tVoid = ctx.com.basic.tvoid;

		/* init class statics */
		var initExprs:Array<TExpr> = [];
		for (t in types) {
			switch t {
				case TClassDecl(c) if (c.clInit != null && c.clInit.cfExpr != null && !isExcluded(c)):
					initExprs.push(c.clInit.cfExpr);
				case _:
			}
			switch t {
				case TClassDecl(c) if (!hasClassFlag(c, CExtern) && !isExcluded(c)):
					for (f in c.clOrderedStatics) {
						switch [f.cfKind, f.cfExpr] {
							case [Var(_), e] if (e != null):
								var p = e.epos;
								var e = mk(TBinop(OpAssign, (mk(TField(mk(TTypeExpr(t), tDynamic, p), FStatic(c, f)), f.cfType, p)), e), f.cfType, p);
								exprs.push(e);
							case _:
						}
					}
				case _:
			}
		}
		/* call main() */
		if (main != null) exprs.push(main);
		var fid = lookupAlloc(ctx.cfids, true);
		var exprs = initExprs.concat(exprs);
		var initpos = fakePos("fun$init");
		var f:TFunc = {tfExpr: mk(TBlock(Vector.fromArrayCopy(exprs)), tVoid, initpos), tfArgs: vector(), tfType: tVoid};
		function genContent() generateStaticContent(ctx, types, f);
		makeFun(ctx, {fst: "", snd: ""}, fid, f, null, null, genContent);
		return fid;
	}

	/* --------------------------------------------------------------------------------------------------------------------- */
	/* WRITE */

	/* 	from -500M to +500M
		0[7] = 0-127
		10[+/-][5] [8] = -x2000/+x2000
		11[+/-][5] [24] = -x20000000/+x20000000
	 */
	static function writeIndexGen(b:Int->Void, i:Int):Void {
		if (i < 0) {
			var i = -i;
			if (i < 0x2000) {
				b((i >> 8) | 0xA0);
				b(i & 0xFF);
			} else if (i >= 0x20000000) die("", "genhl.ml") else {
				b((i >> 24) | 0xE0);
				b((i >> 16) & 0xFF);
				b((i >> 8) & 0xFF);
				b(i & 0xFF);
			}
		} else if (i < 0x80)
			b(i)
		else if (i < 0x2000) {
			b((i >> 8) | 0x80);
			b(i & 0xFF);
		} else if (i >= 0x20000000) die("", "genhl.ml") else {
			b((i >> 24) | 0xC0);
			b((i >> 16) & 0xFF);
			b((i >> 8) & 0xFF);
			b(i & 0xFF);
		}
	}

	// port: the fields `write_op` reads with `Obj.field` for the opcodes it writes generically
	static function opFields(op:Opcode):Array<Int> {
		inline function boolInt(v:Bool):Int return v ? 1 : 0;
		return switch op {
			case OMov(a, b): [a, b];
			case OInt(r, i) | OFloat(r, i) | OBytes(r, i) | OString(r, i): [r, i];
			case OBool(r, v): [r, boolInt(v)];
			case ONull(r) | OIncr(r) | ODecr(r) | ORet(r) | OThrow(r) | ORethrow(r) | ONullCheck(r) | ONew(r): [r];
			case OAdd(r, a, c) | OSub(r, a, c) | OMul(r, a, c) | OSDiv(r, a, c) | OUDiv(r, a, c) | OSMod(r, a, c) | OUMod(r, a, c) | OShl(r, a, c) |
				OSShr(r, a, c) | OUShr(r, a, c) | OAnd(r, a, c) | OOr(r, a, c) | OXor(r, a, c): [r, a, c];
			case ONeg(r, v) | ONot(r, v): [r, v];
			case OCall0(r, f): [r, f];
			case OCall1(r, f, a): [r, f, a];
			case OStaticClosure(r, f): [r, f];
			case OInstanceClosure(r, f, v): [r, f, v];
			case OVirtualClosure(r, o, f): [r, o, f];
			case OGetGlobal(r, g): [r, g];
			case OSetGlobal(g, r): [g, r];
			case OField(r, o, f): [r, o, f];
			case OSetField(o, f, r): [o, f, r];
			case OGetThis(r, f): [r, f];
			case OSetThis(f, r): [f, r];
			case ODynGet(r, o, s): [r, o, s];
			case ODynSet(o, s, r): [o, s, r];
			case OJTrue(r, d) | OJFalse(r, d) | OJNull(r, d) | OJNotNull(r, d): [r, d];
			case OJSLt(a, c, d) | OJSGte(a, c, d) | OJSGt(a, c, d) | OJSLte(a, c, d) | OJULt(a, c, d) | OJUGte(a, c, d) | OJNotLt(a, c, d) |
				OJNotGte(a, c, d) | OJEq(a, c, d) | OJNotEq(a, c, d): [a, c, d];
			case OJAlways(d): [d];
			case OToDyn(r, a) | OToSFloat(r, a) | OToUFloat(r, a) | OToInt(r, a) | OSafeCast(r, a) | OUnsafeCast(r, a) | OToVirtual(r, a): [r, a];
			case OTrap(r, d): [r, d];
			case OEndTrap(v): [boolInt(v)];
			case OGetUI8(r, x, p) | OGetUI16(r, x, p) | OGetMem(r, x, p) | OGetArray(r, x, p) | OSetUI8(r, x, p) | OSetUI16(r, x, p) |
				OSetMem(r, x, p) | OSetArray(r, x, p): [r, x, p];
			case OArraySize(r, a) | OGetType(r, a) | OGetTID(r, a) | ORef(r, a) | OUnref(r, a) | OSetref(r, a): [r, a];
			case OEnumAlloc(r, e) | OEnumIndex(r, e): [r, e];
			case OSetEnumField(e, i, r): [e, i, r];
			case ORefData(r, d): [r, d];
			case ORefOffset(r, r2, off): [r, r2, off];
			case OPrefetch(r, f, mode): [r, f, mode];
			case OAsm(mode, value, reg): [mode, value, reg];
			case OCatch(g): [g];
			case OLabel(_) | ONop(_) | OAssert(_) | OCall2(_) | OCall3(_) | OCall4(_) | OCallN(_) | OCallClosure(_) | OCallMethod(_) | OCallThis(_) |
				OMakeEnum(_) | OType(_) | OSwitch(_) | OEnumField(_):
				die("", "genhl.ml");
		}
	}

	public static function writeCode(ch:haxe.io.BytesBuffer, code:Code, debug:Bool):Void {
		var gt = gatherTypes(code);
		var allTypes = gt.all, htypes = gt.types;
		function byte(v:Int) ch.addByte(v & 0xFF);
		function writeIndex(i:Int) writeIndexGen(byte, i);

		function writeType(t:Ttype):Void {
			var i = htypes.get(t);
			if (i == null) die(tstr(t), "genhl.ml");
			writeIndex(i);
		}

		function writeOp(op:Opcode):Void {
			var oid = Type.enumIndex(op);

			switch op {
				case OLabel(_) | ONop(_) | OAssert(_):
					byte(oid);
				case OCall2(r, g, a, b):
					byte(oid);
					writeIndex(r);
					writeIndex(g);
					writeIndex(a);
					writeIndex(b);
				case OCall3(r, g, a, b, c):
					byte(oid);
					writeIndex(r);
					writeIndex(g);
					writeIndex(a);
					writeIndex(b);
					writeIndex(c);
				case OCall4(r, g, a, b, c, d):
					byte(oid);
					writeIndex(r);
					writeIndex(g);
					writeIndex(a);
					writeIndex(b);
					writeIndex(c);
					writeIndex(d);
				case OCallN(r, f, rl) | OCallClosure(r, f, rl) | OCallMethod(r, f, rl) | OCallThis(r, f, rl) | OMakeEnum(r, f, rl):
					byte(oid);
					writeIndex(r);
					writeIndex(f);
					var n = rl.length;
					if (n > 0xFF) die("", "genhl.ml");
					byte(n);
					for (r in rl) writeIndex(r);
				case OType(r, t):
					byte(oid);
					writeIndex(r);
					writeType(t);
				case OSwitch(r, pl, eend):
					byte(oid);
					writeIndex(r);
					writeIndex(pl.length);
					for (p in pl) writeIndex(p);
					writeIndex(eend);
				case OEnumField(r, e, i, idx):
					byte(oid);
					writeIndex(r);
					writeIndex(e);
					writeIndex(i);
					writeIndex(idx);
				case _:
					var fields = opFields(op);
					if (fields.length > 3) die("", "genhl.ml");
					byte(oid);
					for (f in fields) writeIndex(f);
			}
		}

		ch.addString("HLB");
		byte(code.version);

		var flags = 0;
		if (debug) flags = flags | 1;
		byte(flags);

		writeIndex(code.ints.length);
		writeIndex(code.floats.length);
		writeIndex(code.strings.length);
		if (code.version >= 5) writeIndex(code.bytes.length);
		writeIndex(allTypes.length);
		writeIndex(code.globals.length);
		writeIndex(code.natives.length);
		writeIndex(code.functions.length);
		writeIndex(code.constants.length);
		writeIndex(code.entrypoint);

		for (i in code.ints) ch.addInt32(i);
		for (f in code.floats) ch.addDouble(f);

		function writeStrings(strings:Vector<String>):Void {
			var bytes = strings.map(s -> haxe.io.Bytes.ofString(s));
			var strLength = 0;
			for (b in bytes) strLength += b.length + 1;
			ch.addInt32(strLength);
			for (b in bytes) {
				ch.add(b);
				ch.addByte(0);
			}
			for (b in bytes) writeIndex(b.length);
		}
		writeStrings(code.strings);

		function writeBytes(bytes:Vector<haxe.io.Bytes>):Void {
			var bytesLength = 0;
			for (b in bytes) bytesLength += b.length;
			ch.addInt32(bytesLength);
			for (b in bytes) ch.add(b);
			var bytesPos = 0;
			for (b in bytes) {
				writeIndex(bytesPos);
				bytesPos += b.length;
			}
		}
		if (code.version >= 5) writeBytes(code.bytes);

		if (debug) {
			writeIndex(code.debugfiles.length);
			writeStrings(code.debugfiles);
		}

		for (t in allTypes) {
			switch t {
				case HVoid: byte(0);
				case HUI8: byte(1);
				case HUI16: byte(2);
				case HI32: byte(3);
				case HI64: byte(4);
				case HF32: byte(5);
				case HF64: byte(6);
				case HBool: byte(7);
				case HBytes: byte(8);
				case HDyn: byte(9);
				case HFun(args, ret) | HMethod(args, ret):
					var n = args.length;
					if (n > 0xFF) die("", "genhl.ml");
					byte(t.match(HFun(_)) ? 10 : 20);
					byte(n);
					for (a in args) writeType(a);
					writeType(ret);
				case HObj(p) | HStruct(p):
					byte(if (isStruct(t)) 21 else 11);
					writeIndex(p.pid);
					switch p.psuper {
						case null: writeIndex(-1);
						case tsup: writeType(switch t {
								case HObj(_): HObj(tsup);
								case _: HStruct(tsup);
							});
					}
					switch p.pclassglobal {
						case null: writeIndex(0);
						case g: writeIndex(g + 1);
					}
					writeIndex(p.pfields.length);
					writeIndex(p.pproto.length);
					writeIndex(p.pbindings.length);
					for (f in p.pfields) {
						writeIndex(f.nid);
						writeType(f.t);
					}
					for (f in p.pproto) {
						writeIndex(f.fid);
						writeIndex(f.fmethod);
						writeIndex(f.fvirtual == null ? -1 : f.fvirtual);
					}
					for (b in p.pbindings) {
						writeIndex(b.fid);
						writeIndex(b.fidx);
					}
				case HArray(_):
					byte(12);
				case HType:
					byte(13);
				case HRef(t):
					byte(14);
					writeType(t);
				case HVirtual(v):
					byte(15);
					writeIndex(v.vfields.length);
					for (f in v.vfields) {
						writeIndex(f.nid);
						writeType(f.t);
					}
				case HDynObj:
					byte(16);
				case HAbstract(_, i, _):
					byte(17);
					writeIndex(i);
				case HEnum(e):
					byte(18);
					writeIndex(e.eid);
					switch e.eglobal {
						case null: writeIndex(0);
						case g: writeIndex(g + 1);
					}
					writeIndex(e.efields.length);
					for (f in e.efields) {
						writeIndex(f.nid);
						if (f.args.length > 0xFF) die("", "genhl.ml");
						byte(f.args.length);
						for (t in f.args) writeType(t);
					}
				case HNull(t):
					byte(19);
					writeType(t);
				case HPacked(t):
					byte(22);
					writeType(t);
				case HGUID:
					byte(23);
			}
		}

		function writeDebugInfos(debug:Vector<DebugInfo>):Void {
			var curfile = -1;
			var curpos = 0;
			var rcount = 0;
			function flushRepeat(p:Int):Void {
				if (rcount > 0) {
					if (rcount > 15) {
						byte((15 << 2) | 2);
						rcount = rcount - 15;
						flushRepeat(p);
					} else {
						var delta = p - curpos;
						var delta = (if (delta > 0 && delta < 4) delta else 0);
						byte((delta << 6) | (rcount << 2) | 2);
						rcount = 0;
						curpos = curpos + delta;
					}
				}
			}
			for (d in debug) {
				var f = d.file, p = d.line;
				if (f != curfile) {
					flushRepeat(p);
					curfile = f;
					byte((f >> 7) | 1);
					byte(f & 0xFF);
				}
				if (p != curpos) flushRepeat(p);
				if (p == curpos) rcount = rcount + 1 else {
					var delta = p - curpos;
					if (delta > 0 && delta < 32) byte((delta << 3) | 4) else {
						byte(p << 3);
						byte(p >> 5);
						byte(p >> 13);
					}
					curpos = p;
				}
			}
			flushRepeat(curpos);
		}

		for (g in code.globals) writeType(g);
		for (n in code.natives) {
			writeIndex(n.lib);
			writeIndex(n.name);
			writeType(n.t);
			writeIndex(n.findex);
		}
		for (f in code.functions) {
			writeType(f.ftype);
			writeIndex(f.findex);
			writeIndex(f.regs.length);
			writeIndex(f.code.length);
			for (r in f.regs) writeType(r);
			for (o in f.code) writeOp(o);
			if (debug) {
				writeDebugInfos(f.debug);
				writeIndex(f.assigns.length);
				for (a in f.assigns) {
					writeIndex(a.name);
					writeIndex(a.pos + 1);
					if (code.version >= 6) writeIndex(a.scopeEnd + 1);
				}
			}
		}
		for (c in code.constants) {
			writeIndex(c.g);
			writeIndex(c.fields.length);
			for (f in c.fields) writeIndex(f);
		}
	}

	/* --------------------------------------------------------------------------------------------------------------------- */

	static function createContext(com:Gctx):HlContext {
		function getType(name:String):ModuleType {
			var t = core.ds.ArrayTools.find(com.types, t -> isPath(tInfos(t).mtPath, ["hl"], name));
			if (t != null) return t;
			var t = core.ds.ArrayTools.find(com.types, t -> isPath(tInfos(t).mtPath, ["hl", "types"], name));
			if (t != null) return t;
			throw new Failure("hl type " + name + " not found");
		}
		function getClass(name:String):TClass {
			return switch getType(name) {
				case TClassDecl(c): c;
				case _: die("", "genhl.ml");
			}
		}
		function getAbstract(name:String):TAbstract {
			return switch getType(name) {
				case TAbstractDecl(a): a;
				case _: die("", "genhl.ml");
			}
		}
		var hlVer = Gctx.definedValueSafe(com, Define.HlVer, "");
		var ctx = new HlContext();
		ctx.com = com;
		ctx.hlVer = hlVer;
		ctx.optimize = !Gctx.rawDefined(com, "hl_no_opt");
		ctx.wNullCompare = Gctx.rawDefined(com, "hl_w_null_compare");
		ctx.numDomains = core.ds.TaskPool.recommendedDomainCount();
		ctx.m = methodContext(0, HVoid, nullCapture, false);
		ctx.arrayImpl = {
			aall: getClass("ArrayAccess"),
			abase: getClass("ArrayBase"),
			adyn: getClass("ArrayDyn"),
			aobj: getClass("ArrayObj"),
			aui8: getClass("ArrayBytes_hl_UI8"),
			aui16: getClass("ArrayBytes_hl_UI16"),
			ai32: getClass("ArrayBytes_Int"),
			af32: getClass("ArrayBytes_hl_F32"),
			af64: getClass("ArrayBytes_Float"),
			ai64: if (Gctx.rawDefined(com, "hl_legacy32") || hlVer != "" && compareVersion(hlVer, "1.13.0") < 0) null else getClass("ArrayBytes_hl_I64"),
			aguid: if (Gctx.rawDefined(com, "hl_legacy32") || hlVer != "" && compareVersion(hlVer, "1.16.0") < 0) null else getClass("ArrayBytes_hl_GUID"),
		};
		ctx.baseClass = getClass("Class");
		ctx.baseEnum = getClass("Enum");
		ctx.baseType = getClass("BaseType");
		ctx.coreType = getClass("CoreType");
		ctx.coreEnum = getClass("CoreEnum");
		ctx.refAbstract = getAbstract("Ref");
		ctx.tstring = toType(ctx, ctx.com.basic.tstring);
		allocString(ctx, "");
		classType(ctx, ctx.baseClass, vector(), false);
		return ctx;
	}

	// port: Str.global_replace (Str.regexp "[A-Z]+") "_\\0" s, then String.lowercase_ascii
	static function nativeName(s:String):String {
		var buf = new StringBuf();
		var inUpper = false;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			var upper = c >= "A".code && c <= "Z".code;
			if (upper && !inUpper) buf.add("_");
			inUpper = upper;
			buf.addChar(upper ? c + 32 : c);
		}
		return buf.toString();
	}

	static function addTypes(ctx:HlContext, types:Array<ModuleType>):Void {
		for (t in types) {
			switch t {
				case TClassDecl(c) if (c.clPath.pack.join(".") == "hl.types" && (c.clPath.name == "BytesIterator" || c.clPath.name == "BytesKeyValueIterator"
					|| c.clPath.name == "ArrayBytes")):
					addClassFlag(c, CExtern);
				case TClassDecl(c):
					function loop(p:Null<ClassAndParams>, f:TClassField):Bool {
						if (p != null && (p.cls.clFields.exists(f.cfName) || loop(p.cls.clSuper, f))) {
							ctx.overrides.set(overrideKey(f.cfName, p.cls.clPath), true);
							return true;
						}
						return false;
					}
					function checkVirtualRec(c:TClass):Bool {
						return hasMeta(core.MetaList.StrictMeta.Custom(":virtual"), c.clMeta) || (if (c.clSuper == null) false else checkVirtualRec(c.clSuper.cls));
					}
					if (checkVirtualRec(c)) {
						/*
							Assume all fields and superclass fields are overriden from this base class
							Inline methods are excluded because they cannot be overridden.
						 */
						function loopCl(c:TClass):Void {
							for (f in c.clOrderedFields) {
								switch f.cfKind {
									case Method(MethInline):
									case _: loop({cls: c, params: vector()}, f);
								}
							}
							if (c.clSuper != null) loopCl(c.clSuper.cls);
						}
						loopCl(c);
					} else
						for (f in c.clOrderedFields) if (hasClassFieldFlag(f, CfOverride)) loop(c.clSuper, f);
					for (m in c.clMeta) {
						if (Meta.metaEq(Meta.HlNative, m.meta)) {
							var p = m.pos;
							var lib, prefix;
							switch m.exprs {
								case [{expr: EConst(String(l, _))}]:
									lib = l;
									prefix = "";
								case [{expr: EConst(String(l, _))}, {expr: EConst(String(pr, _))}]:
									lib = l;
									prefix = pr;
								case _:
									lib = Error.abort("hlNative on class requires library name", p);
									prefix = null;
							}
							/* adds :hlNative for all empty methods */
							for (f in c.clOrderedStatics) {
								switch f.cfKind {
									case Method(MethNormal) if (!core.ds.ArrayTools.exists(f.cfMeta, m -> Meta.metaEq(Meta.HlNative, m.meta))):
										var empty = switch f.cfExpr {
											case null: true;
											case {eexpr: TFunction({tfExpr: {eexpr: TBlock([])}})}: true;
											case {eexpr: TFunction({tfExpr: {eexpr: TBlock([{eexpr: TReturn({eexpr: TConst(_)})}])}})}: true;
											case _: false;
										}
										if (empty) {
											var name = prefix + nativeName(f.cfName);
											var entry:MetadataEntry = {
												meta: Meta.HlNative,
												exprs: vector({expr: EConst(String(lib, SDoubleQuotes)), pos: p}, {expr: EConst(String(name, SDoubleQuotes)), pos: p}),
												pos: p
											};
											f.cfMeta = [entry].concat(f.cfMeta);
										}
									case _:
								}
							}
						}
					}
				case _:
			}
		}
		for (t in types) generateType(ctx, t);
	}

	static function buildCode(ctx:HlContext, types:Array<ModuleType>, main:Null<TExpr>):Code {
		var ep = generateStaticInit(ctx, types, main);
		var bytes = Vector.fromArrayCopy(ctx.cbytes.arr);
		return new Code(if (compareVersion(ctx.hlVer, "2.0.0") >= 0) 6 else if (bytes.length == 0) 4 else 5, ep, Vector.fromArrayCopy(ctx.cstrings.arr),
			Vector.fromArrayCopy(ctx.cints.arr), Vector.fromArrayCopy(ctx.cfloats.arr), bytes, Vector.fromArrayCopy(ctx.cglobals.arr),
			Vector.fromArrayCopy(ctx.cnatives.arr), Vector.fromArrayCopy(ctx.cfunctions), Vector.fromArrayCopy(ctx.cdebugFiles.arr),
			Vector.fromArrayCopy(ctx.cconstants.arr));
	}

	static function check(ctx:HlContext):Void {
		// port: Hashtbl.iter order of the (string * path) keys of cfids.map, replayed
		// from their insertion order.
		var tbl = new core.ds.OcamlHashtbl<{name:String, path:GlobalTypePath, id:Int}, Bool>(k -> core.ds.OcamlHash.hash(core.ds.OcamlHash.OcamlValue.OBlock(0, [core.ds.OcamlHash.OcamlValue.OString(k.name), core.ds.OcamlHash.ofPath(k.path.pack, k.path.name)])), (a, b) -> a == b);
		for (k in ctx.cfidsKeys) tbl.add(k, true);
		tbl.iter((k, _) -> {
			if (!ctx.definedFuns.exists(k.id)) throw new Failure("Unresolved method " + sTypePath(k.path) + ":" + k.name + "(@" + k.id + ")");
		});
	}

	// port: upstream digests the Marshal image of a (module id, true) Hashtbl; the
	// signature is only compared with the previous one of this process.
	static function makeContextSign(com:Gctx):String {
		var ids = [for (t in com.types) Std.string(tInfos(t).mtModule.mId)];
		return haxe.crypto.Md5.encode(ids.join(","));
	}

	static var prevSign = "";
	static var prevData:Null<haxe.io.Bytes> = null;

	static function escapeCommand(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var ch = s.charAt(i);
			if (ch == '"' || ch == "\\") b.add("\\");
			b.add(ch);
		}
		return "\"" + b.toString() + "\"";
	}

	public static function generate(com:Gctx):Void {
		var dump = Gctx.defined(com, Define.Dump);
		var hlCheck = Gctx.rawDefined(com, "hl_check");

		var sign = makeContextSign(com);
		if (sign == prevSign && !dump && !hlCheck) {
			/* reuse previously generated data */
			sys.io.File.saveBytes(com.file, prevData);
			return;
		}

		var ctx = createContext(com);
		addTypes(ctx, com.types);

		var code = buildCode(ctx, com.types, com.main.mainExpr);
		ocamlVectorSort((n1:Native, n2:Native) -> n1.lib - n2.lib, code.natives);

		if (ctx.optimize) {
			var t = core.Timer.startTimer(com.timerCtx, ["generate", "hl", "opt"]);
			var dumpOut = if (dump) new StringBuf() else null;
			var mutex = new sys.thread.Mutex();
			context.Parallel.runParallelFor(ctx.numDomains, ctx.cfunctions.length, idx -> {
				var f = ctx.cfunctions[idx];
				if (f.needOpt) {
					var r = Hlopt.optimize(dump, i -> code.strings[i], f, "todosign");
					if (dumpOut != null) {
						mutex.acquire();
						dumpOut.add(r.dump);
						mutex.release();
					}
					code.functions[idx] = r.f;
				}
			}, 16);
			if (dumpOut != null) sys.io.File.saveContent("dump/hlopt.txt", dumpOut.toString());
			t();
		}

		if (dump) {
			var buf = new StringBuf();
			Hlcode.dump(s -> buf.add(s + "\n"), code);
			sys.io.File.saveContent("dump/hlcode.txt", buf.toString());
		}
		/*if Gctx.raw_defined com "hl_dump_spec" then begin
			let ch = open_out_bin "dump/hlspec.txt" in
			let write s = output_string ch (s ^ "\n") in
			Array.iter (fun f ->
				write (fundecl_name f);
				let spec = Hlinterp.make_spec code f in
				List.iter (fun s -> write ("\t" ^ Hlinterp.spec_string s)) spec;
				write "";
			) code.functions;
			close_out ch;
		end; */
		if (hlCheck) {
			check(ctx);
			Hlinterp.check(com.error, code);
		}
		var t = core.Timer.startTimer(com.timerCtx, ["generate", "hl", "write"]);

		if (core.Path.fileExtension(com.file) == "c") {
			var gnames = new Vector(code.globals.length, "");
			for (n in ctx.cglobals.map.keys()) gnames[ctx.cglobals.map.get(n)] = n;
			if (!Gctx.defined(com, Define.SourceHeader)) {
				var versionMajor = com.version.major;
				var versionMinor = com.version.minor;
				var versionRevision = com.version.revision;
				Gctx.defineValue(com, Define.SourceHeader, 'Generated by HLC $versionMajor.$versionMinor.$versionRevision (HL v${code.version})');
			}
			Hl2c.writeC(com, com.file, code, gnames, ctx.numDomains);
			var t = core.Timer.startTimer(com.timerCtx, ["nativecompile", "hl"]);
			if (!Gctx.defined(com, Define.NoCompilation) && com.runCommandArgs("haxelib", ["run", "hashlink", "build", escapeCommand(com.file)]) != 0)
				throw new Failure("Build failed");
			t();
		} else {
			var ch = new haxe.io.BytesBuffer();
			writeCode(ch, code, !Gctx.rawDefined(com, "hl_no_debug"));
			var str = ch.getBytes();
			sys.io.File.saveBytes(com.file, str);
			prevSign = sign;
			prevData = str;
		}
		Hlopt.cleanCache();
		t();
		if (Gctx.rawDefined(com, "run")) {
			if (com.runCommandArgs("haxelib", ["run", "hashlink", "run", escapeCommand(com.file)]) != 0) throw new Failure("Failed to run HL");
		}
		if (Gctx.defined(com, Define.Interp)) {
			try {
				var t = core.Timer.startTimer(com.timerCtx, ["generate", "hl", "interp"]);
				var ctx = Hlinterp.create(true);
				Hlinterp.addCode(ctx, code);
				t();
			} catch (e:Failure) {
				Error.abort(e.message, nullPos);
			}
		}
	}
}
