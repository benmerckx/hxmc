package compiler.hxb;

import core.Ast;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.TOther;
import core.TPrinting;
import core.TUnification;
import core.TUnification.Monomorph;
import core.Timer;
import core.Timer.TimerContext;
import core.MetaList.StrictMeta;
import core.ds.AtomicLazy;
import core.ds.InvalidArgument;
import core.ds.NotFound;
import compiler.hxb.HxbData;
import compiler.hxb.HxbData.ChunkKind;
import compiler.hxb.HxbData.TypingMode;
import compiler.hxb.HxbData.CachedChunks;
import compiler.hxb.HxbReaderApi;
import context.HxbReaderStats.HxbReaderStatsData;
import haxe.io.Bytes;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: representation notes:
// - `hxb_reader_stats` is context.HxbReaderStats (shared with Common), so
//   create_hxb_reader_stats is HxbReaderStats.create.
// - OCaml lists become arrays. Where upstream builds a list by consing
//   (class fields in MTF), the array is reversed after reading so the
//   resulting order matches upstream's.
// - Records copied with `{ r with ... }` are fresh objects here as well
//   (positions in particular are never mutated in place).

@:structInit class FieldReaderContext {
	public var tPool:Vector<T>;
	public var pos:Pos;
	public var vars:Vector<TVar>;
	public var tthis:Null<T>;

	public inline function new(tPool:Vector<T>, pos:Pos, vars:Vector<TVar>, tthis:Null<T>) {
		this.tPool = tPool;
		this.pos = pos;
		this.vars = vars;
		this.tthis = tthis;
	}
}

function createFieldReaderContext(p:Pos, ts:Vector<T>, vars:Vector<TVar>, tthis:Null<T>):FieldReaderContext return {
	tPool: ts,
	pos: p,
	vars: vars,
	tthis: tthis
};

// port: module ClassFieldInfo
@:structInit class ClassFieldInfo {
	public var typeParameters:core.TType.TypeParams;

	public inline function new(typeParameters:core.TType.TypeParams) this.typeParameters = typeParameters;

	public static function create(params:core.TType.TypeParams):ClassFieldInfo return {typeParameters: params};
}

// port: module ClassFieldInfos
class ClassFieldInfos {
	public final infos:Array<ClassFieldInfo> = [];

	static final meta = StrictMeta.HxbId;

	public function new() {}

	public static function create():ClassFieldInfos return new ClassFieldInfos();

	public static function get(infos:ClassFieldInfos, cf:TClassField):ClassFieldInfo {
		var p = core.Meta.get(meta, cf.cfMeta).pos;
		return infos.infos[p.pmin];
	}

	public static function unset(infos:ClassFieldInfos, cf:TClassField):Void {
		cf.cfMeta = core.Meta.remove(meta, cf.cfMeta);
	}

	public static function set(infos:ClassFieldInfos, info:ClassFieldInfo, cf:TClassField):Void {
		var index = infos.infos.length;
		infos.infos.push(info);
		var np = Globals.nullPos;
		cf.cfMeta = [
			({meta: meta, exprs: vector(), pos: new Pos(np.pfile, index, np.pmax)} : MetadataEntry)
		].concat(cf.cfMeta);
	}
}

// port: module BytesWithPosition
class BytesWithPosition {
	public final bytes:Bytes;
	public var pos:Int;

	public inline function new(bytes:Bytes, pos:Int) {
		this.bytes = bytes;
		this.pos = pos;
	}

	public static inline function create(bytes:Bytes):BytesWithPosition return new BytesWithPosition(bytes, 0);

	public static inline function readByte(b:BytesWithPosition):Int {
		var i = b.bytes.get(b.pos);
		b.pos = b.pos + 1;
		return i;
	}

	public static function readBytes(b:BytesWithPosition, length:Int):Bytes {
		var out = Bytes.alloc(length);
		out.blit(0, b.bytes, b.pos, length);
		b.pos = b.pos + length;
		return out;
	}

	public static function readI16(i:BytesWithPosition):Int {
		var ch2 = readByte(i);
		var ch1 = readByte(i);
		var n = ch1 | (ch2 << 8);
		return if (ch2 & 128 != 0) n - 65536 else n;
	}

	public static function readRealI32(ch:BytesWithPosition):Int {
		var ch1 = readByte(ch);
		var ch2 = readByte(ch);
		var ch3 = readByte(ch);
		var base = ch1 | (ch2 << 8) | (ch3 << 16);
		var big = readByte(ch) << 24;
		return base | big;
	}

	public static function readI64(ch:BytesWithPosition):haxe.Int64 {
		var big = readRealI32(ch);
		var ch4 = readByte(ch);
		var ch3 = readByte(ch);
		var ch2 = readByte(ch);
		var ch1 = readByte(ch);
		var base = ch1 | (ch2 << 8) | (ch3 << 16);
		var small = base | (ch4 << 24);
		return haxe.Int64.make(big, small);
	}

	public static function readDouble(ch:BytesWithPosition):Float {
		var i = readI64(ch);
		return haxe.io.FPHelper.i64ToDouble(i.low, i.high);
	}
}

function readUleb128(ch:BytesWithPosition):Int {
	// port: upstream recurses: (b land 0x7F) lor ((read_uleb128 ch) lsl 7).
	var result = 0;
	var shift = 0;
	while (true) {
		var b = BytesWithPosition.readByte(ch);
		result |= (b & 0x7F) << shift;
		if (b < 0x80) break;
		shift += 7;
	}
	return result;
}

function readLeb128(ch:BytesWithPosition):Int {
	var acc = 0;
	var shift = 0;
	var last = 0;
	while (true) {
		var b = BytesWithPosition.readByte(ch);
		acc = ((b & 0x7F) << shift) | acc;
		shift += 7;
		if (b < 0x80) {
			last = b;
			break;
		}
	}
	// port: OCaml ints are wider than 32 bits; a shift past the Int width keeps acc.
	return if ((last & 0x40) != 0) (shift < 32 ? acc | ((~0) << shift) : acc) else acc;
}

function dumpStats(name:String, stats:HxbReaderStatsData):Void {
	Sys.println('hxb_reader stats for $name');
	Sys.println('  modules partially restored: ${stats.modulesPartiallyRestored - stats.modulesFullyRestored}');
	Sys.println('  modules fully restored: ${stats.modulesFullyRestored}');
}

private function dumpBacktrace():Void {
	Sys.println(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
}

class HxbReader {
	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx): a field a module read refers to,
	// ... not in its class: true when the pending passes that make it were run (look again); always null in
	// ... the compiler itself.
	public static var missingFieldHook:Null<(c:TClass) -> Bool> = null;

	final mpath:GlobalTypePath;
	final stats:HxbReaderStatsData;
	final timerCtx:Null<TimerContext>;

	var api:HxbReaderApi = null;
	var typingMode:TypingMode = FullTyping;
	var currentModule:ModuleDef = TFunctions.nullModule;

	var ch:BytesWithPosition = BytesWithPosition.create(Bytes.alloc(0));
	var stringPool = new Vector<String>(0);
	var docPool = new Vector<String>(0);

	var classes = new Vector<AtomicLazy<TClass>>(0);
	var abstracts = new Vector<AtomicLazy<TAbstract>>(0);
	var enums = new Vector<AtomicLazy<TEnum>>(0);
	var typedefs = new Vector<AtomicLazy<TDef>>(0);
	var anons = new Vector<TAnon>(0);
	var anonFields = new Vector<TClassField>(0);
	var tmonos = new Vector<T>(0);
	var classFields = new Vector<AtomicLazy<TClassField>>(0);
	var enumFields = new Vector<AtomicLazy<TEnumField>>(0);

	var typeTypeParameters:core.TType.TypeParams = vector();
	var fieldTypeParameters:core.TType.TypeParams = vector();
	var localTypeParameters:core.TType.TypeParams = vector();

	var fieldTypeParameterOffset = 0;
	final emptyAnon:T = mkAnon(Closed);

	public function new(mpath:GlobalTypePath, stats:HxbReaderStatsData, timerCtx:Null<TimerContext>) {
		this.mpath = mpath;
		this.stats = stats;
		this.timerCtx = timerCtx;
	}

	public function resolveType(pack:Array<String>, mname:String, tname:String):ModuleType {
		try {
			var mt = api.resolveType(pack, mname, tname, typingMode);
			switch typingMode {
				case AllowPartialTyping:
					var mdep = tModule(mt);
					if (mdep != TFunctions.nullModule && currentModule.mPath.hashKey() != mdep.mPath.hashKey())
						currentModule.mExtra.mDisplayDeps.set(mdep.mId, createDependency(mdep, MDepFromTyping));
				case FullTyping:
			}
			return mt;
		} catch (_:NotFound) {
			dumpBacktrace();
			return
				HxbData.error('[HXB] [${Globals.sTypePath(currentModule.mPath)}] Cannot resolve type ${Globals.sTypePath({pack: pack.concat([mname]), name: tname})}');
		}
	}

	function makeLazyTypeDynamic(f:Void->T):T {
		return api.makeLazyType(tDynamic, f);
	}

	// Primitives

	inline function readByte():Int return BytesWithPosition.readByte(ch);

	inline function uleb():Int return readUleb128(ch);

	public function readI32():Int return BytesWithPosition.readRealI32(ch);

	public function readI16():Int return BytesWithPosition.readI16(ch);

	public function readF64():Float return BytesWithPosition.readDouble(ch);

	public function readBool():Bool return readByte() != 0;

	inline function readFromStringPool(pool:Vector<String>):String return pool[uleb()];

	public function readString():String return readFromStringPool(stringPool);

	public function readRawString():String {
		var l = uleb();
		var b = BytesWithPosition.readBytes(ch, l);
		return bytesToString(b);
	}

	// port: Bytes.unsafe_to_string. HashLink's Bytes.getString stops at
	// the first NUL byte, so strings containing NUL ("\x00" literals) are
	// decoded segment by segment (NUL never occurs inside a UTF-8 sequence).
	static function bytesToString(b:Bytes):String {
		var start = 0;
		var buf:StringBuf = null;
		for (i in 0...b.length) {
			if (b.get(i) == 0) {
				if (buf == null) buf = new StringBuf();
				buf.add(b.getString(start, i - start));
				buf.addChar(0);
				start = i + 1;
			}
		}
		if (buf == null) return b.getString(0, b.length);
		buf.add(b.getString(start, b.length - start));
		return buf.toString();
	}

	// Basic compounds
	// port: inline: see core.ds.List (HashLink boxes Array<B> of a type parameter)
	public inline function readList<A>(f:Void->A):Array<A> {
		var l = uleb();
		return [for (_ in 0...l) f()];
	}

	// port: read_list into a Vector (an AST list kept as one), allocated at its length
	public inline function readVector<A>(f:Void->A):haxe.ds.Vector<A> {
		var l = uleb();
		var v = new haxe.ds.Vector<A>(l);
		for (i in 0...l) v[i] = f();
		return v;
	}

	public inline function readOption<A>(f:Void->A):Null<A> {
		return switch readByte() {
			case 0: null;
			case _: f();
		}
	}

	public function readPath():GlobalTypePath {
		var pack = readList(readString);
		var name = readString();
		return {pack: pack, name: name};
	}

	public function readFullPath():{pack:Array<String>, mname:String, tname:String} {
		var pack = readList(readString);
		var mname = readString();
		var tname = readString();
		return {pack: pack, mname: mname, tname: tname};
	}

	public function readDocumentation():DocBlock {
		var docOwn = readOption(function() return readFromStringPool(docPool));
		var docInherited = readList(function() return readFromStringPool(docPool));
		return {docOwn: docOwn, docInherited: docInherited};
	}

	public function readPos():Pos {
		var file = readString();
		var min = readLeb128(ch);
		var max = readLeb128(ch);
		return new Pos(file, min, max);
	}

	public function readPosPair():{p1:Pos, p2:Pos} {
		var file = readString();
		var min1 = readLeb128(ch);
		var max1 = readLeb128(ch);
		var min2 = readLeb128(ch);
		var max2 = readLeb128(ch);
		var pos1 = new Pos(file, min1, max1);
		var pos2 = new Pos(pos1.pfile, pos1.pmin + min2, pos1.pmin + max2);
		return {p1: pos1, p2: pos2};
	}

	public function readMetadataEntry():MetadataEntry {
		var name = readString();
		var p = readPos();
		var el = readVector(readExpr);
		return {meta: core.Meta.fromString(name), exprs: el, pos: p};
	}

	public function readMetadata():Metadata {
		return readList(readMetadataEntry);
	}

	// References

	public function readClassRef():AtomicLazy<TClass> return classes[uleb()];

	public function readAbstractRef():AtomicLazy<TAbstract> return abstracts[uleb()];

	public function readEnumRef():AtomicLazy<TEnum> return enums[uleb()];

	public function readTypedefRef():AtomicLazy<TDef> return typedefs[uleb()];

	public function readFieldRef():TClassField {
		var cf = classFields[uleb()];
		return cf.force();
	}

	public function readEnumFieldRef():TEnumField {
		var ef = enumFields[uleb()];
		return ef.force();
	}

	public function readAnonRef():TAnon {
		return switch readByte() {
			case 0:
				anons[uleb()];
			case 1:
				var an = anons[uleb()];
				readAnon(an);
				an;
			case _:
				throw "assert false";
		}
	}

	public function readAnonFieldRef():TClassField {
		return switch readByte() {
			case 0:
				anonFields[uleb()];
			case 1:
				var cf = anonFields[uleb()];
				readClassFieldAndOverloadsData(cf);
				cf;
			case _:
				throw "assert false";
		}
	}

	// Expr

	public function getBinop(i:Int):Binop return switch i {
		case 0: OpAdd;
		case 1: OpMult;
		case 2: OpDiv;
		case 3: OpSub;
		case 4: OpAssign;
		case 5: OpEq;
		case 6: OpNotEq;
		case 7: OpGt;
		case 8: OpGte;
		case 9: OpLt;
		case 10: OpLte;
		case 11: OpAnd;
		case 12: OpOr;
		case 13: OpXor;
		case 14: OpBoolAnd;
		case 15: OpBoolOr;
		case 16: OpShl;
		case 17: OpShr;
		case 18: OpUShr;
		case 19: OpMod;
		case 20: OpInterval;
		case 21: OpArrow;
		case 22: OpIn;
		case 23: OpNullCoal;
		case _: OpAssignOp(getBinop(i - 30));
	}

	public function getUnop(i:Int):{op:Unop, flag:UnopFlag}
		return switch i {
			case 0: {op: Increment, flag: Prefix};
			case 1: {op: Decrement, flag: Prefix};
			case 2: {op: Not, flag: Prefix};
			case 3: {op: Neg, flag: Prefix};
			case 4: {op: NegBits, flag: Prefix};
			case 5: {op: Spread, flag: Prefix};
			case 6: {op: Increment, flag: Postfix};
			case 7: {op: Decrement, flag: Postfix};
			case 8: {op: Not, flag: Postfix};
			case 9: {op: Neg, flag: Postfix};
			case 10: {op: NegBits, flag: Postfix};
			case 11: {op: Spread, flag: Postfix};
			case _: throw "assert false";
		}

	public function readPlacedName():PlacedName {
		var s = readString();
		var p = readPos();
		return {name: s, pos: p};
	}

	public function readTypePath():TypePath {
		var pack = readList(readString);
		var name = readString();
		var tparams = readVector(readTypeParamOrConst);
		var tsub = readOption(readString);
		return {
			tpackage: pack,
			tname: name,
			tparams: tparams,
			tsub: tsub
		};
	}

	public function readPlacedTypePath():PlacedTypePath {
		var tp = readTypePath();
		var pp = readPosPair();
		return {
			path: tp,
			posFull: pp.p1,
			posPath: pp.p2
		};
	}

	public function readTypeParam():TypeParam {
		var pn = readPlacedName();
		var ttp = readVector(readTypeParam);
		var tho = readOption(readTypeHint);
		var def = readOption(readTypeHint);
		var meta = readMetadata();
		return {
			tpName: pn,
			tpParams: ttp,
			tpConstraints: tho,
			tpMeta: meta,
			tpDefault: def
		};
	}

	public function readTypeParamOrConst():TypeParamOrConst {
		return switch readByte() {
			case 0: TPType(readTypeHint());
			case 1: TPExpr(readExpr());
			case _: throw "assert false";
		}
	}

	public function readFuncArg():FuncArg {
		var pn = readPlacedName();
		var b = readBool();
		var meta = readMetadata();
		var tho = readOption(readTypeHint);
		var eo = readOption(readExpr);
		return {
			name: pn,
			optional: b,
			meta: meta,
			type: tho,
			expr: eo
		};
	}

	public function readFunc():Func {
		var params = readVector(readTypeParam);
		var args = readVector(readFuncArg);
		var tho = readOption(readTypeHint);
		var eo = readOption(readExpr);
		return {
			fParams: params,
			fArgs: args,
			fType: tho,
			fExpr: eo
		};
	}

	public function readComplexType():ComplexType {
		return switch readByte() {
			case 0: CTPath(readPlacedTypePath());
			case 1:
				var thl = readVector(readTypeHint);
				var th = readTypeHint();
				CTFunction(thl, th);
			case 2: CTAnonymous(readVector(readCfield));
			case 3: CTParent(readTypeHint());
			case 4:
				var ptp = readVector(readPlacedTypePath);
				var cffl = readVector(readCfield);
				CTExtend(ptp, cffl);
			case 5: CTOptional(readTypeHint());
			case 6:
				var pn = readPlacedName();
				var th = readTypeHint();
				CTNamed(pn, th);
			case 7: CTIntersection(readVector(readTypeHint));
			case _: throw "assert false";
		}
	}

	public function readTypeHint():TypeHint {
		var ct = readComplexType();
		var p = readPos();
		return {type: ct, pos: p};
	}

	public function readAccess():Access {
		return switch readByte() {
			case 0: APublic;
			case 1: APrivate;
			case 2: AStatic;
			case 3: AOverride;
			case 4: ADynamic;
			case 5: AInline;
			case 6: AMacro;
			case 7: AFinal;
			case 8: AExtern;
			case 9: AAbstract;
			case 10: AOverload;
			case 11: AEnum;
			case _: throw "assert false";
		}
	}

	public function readPlacedAccess():PlacedAccess {
		var ac = readAccess();
		var p = readPos();
		return {access: ac, pos: p};
	}

	public function readCfieldKind():ClassFieldKind {
		return switch readByte() {
			case 0:
				var tho = readOption(readTypeHint);
				var eo = readOption(readExpr);
				FVar(tho, eo);
			case 1: FFun(readFunc());
			case 2:
				var pn1 = readPlacedName();
				var pn2 = readPlacedName();
				var tho = readOption(readTypeHint);
				var eo = readOption(readExpr);
				FProp(pn1, pn2, tho, eo);
			case _: throw "assert false";
		}
	}

	public function readCfield():ClassField {
		var pn = readPlacedName();
		var doc = readOption(readDocumentation);
		var pos = readPos();
		var meta = readMetadata();
		var access = readList(readPlacedAccess);
		var kind = readCfieldKind();
		return {
			cffName: pn,
			cffDoc: doc,
			cffPos: pos,
			cffMeta: meta,
			cffAccess: access,
			cffKind: kind
		};
	}

	public function readExpr():Expr {
		var p = readPos();
		var e:ExprDef = switch readByte() {
			case 0:
				var s = readString();
				var suffix = readOption(readString);
				EConst(Int(s, suffix));
			case 1:
				var s = readString();
				var suffix = readOption(readString);
				EConst(Float(s, suffix));
			case 2:
				var s = readString();
				var qs = switch readByte() {
					case 0: SDoubleQuotes;
					case 1: SSingleQuotes;
					case _: throw "assert false";
				}
				EConst(String(s, qs));
			case 3:
				EConst(Ident(readString()));
			case 4:
				var s1 = readString();
				var s2 = readString();
				EConst(Regexp(s1, s2));
			case 5:
				var e1 = readExpr();
				var e2 = readExpr();
				EArray(e1, e2);
			case 6:
				var op = getBinop(readByte());
				var e1 = readExpr();
				var e2 = readExpr();
				EBinop(op, e1, e2);
			case 7:
				var e = readExpr();
				var s = readString();
				var kind = switch readByte() {
					case 0: EFNormal;
					case 1: EFSafe;
					case _: throw "assert false";
				}
				EField(e, s, kind);
			case 8:
				EParenthesis(readExpr());
			case 9:
				var fields = readVector(function():ObjectField {
					var n = readString();
					var p = readPos();
					var qs = switch readByte() {
						case 0: NoQuotes;
						case 1: DoubleQuotes;
						case _: throw "assert false";
					}
					var e = readExpr();
					return {key: {name: n, pos: p, quote: qs}, expr: e};
				});
				EObjectDecl(fields);
			case 10:
				var el = readVector(readExpr);
				EArrayDecl(el);
			case 11:
				var e = readExpr();
				var el = readVector(readExpr);
				ECall(e, el);
			case 12:
				var ptp = readPlacedTypePath();
				var el = readVector(readExpr);
				ENew(ptp, el);
			case 13:
				var u = getUnop(readByte());
				var e = readExpr();
				EUnop(u.op, u.flag, e);
			case 14:
				var vl = readVector(function():EVar {
					var name = readPlacedName();
					var final_ = readBool();
					var static_ = readBool();
					var t = readOption(readTypeHint);
					var expr = readOption(readExpr);
					var meta = readMetadata();
					return {
						evName: name,
						evFinal: final_,
						evStatic: static_,
						evType: t,
						evExpr: expr,
						evMeta: meta
					};
				});
				EVars(vl);
			case 15:
				var fk = switch readByte() {
					case 0: FKAnonymous;
					case 1:
						var pn = readPlacedName();
						var b = readBool();
						FKNamed(pn, b);
					case 2: FKArrow;
					case _: throw "assert false";
				}
				var f = readFunc();
				EFunction(fk, f);
			case 16:
				EBlock(readVector(readExpr));
			case 17:
				var e1 = readExpr();
				var e2 = readExpr();
				EFor(e1, e2);
			case 18:
				var e1 = readExpr();
				var e2 = readExpr();
				EIf(e1, e2, null);
			case 19:
				var e1 = readExpr();
				var e2 = readExpr();
				var e3 = readExpr();
				EIf(e1, e2, e3);
			case 20:
				var e1 = readExpr();
				var e2 = readExpr();
				EWhile(e1, e2, NormalWhile);
			case 21:
				var e1 = readExpr();
				var e2 = readExpr();
				EWhile(e1, e2, DoWhile);
			case 22:
				var e1 = readExpr();
				var cases = readVector(function():SwitchCase {
					var el = readVector(readExpr);
					var eg = readOption(readExpr);
					var eo = readOption(readExpr);
					var p = readPos();
					return {
						values: el,
						guard: eg,
						expr: eo,
						pos: p
					};
				});
				var def = readOption(function():SwitchDefault {
					var eo = readOption(readExpr);
					var p = readPos();
					return {expr: eo, pos: p};
				});
				ESwitch(e1, cases, def);
			case 23:
				var e1 = readExpr();
				var catches = readVector(function():Catch {
					var pn = readPlacedName();
					var th = readOption(readTypeHint);
					var e = readExpr();
					var p = readPos();
					return {
						name: pn,
						type: th,
						expr: e,
						pos: p
					};
				});
				ETry(e1, catches);
			case 24: EReturn(null);
			case 25: EReturn(readExpr());
			case 26: EBreak;
			case 27: EContinue;
			case 28: EUntyped(readExpr());
			case 29: EThrow(readExpr());
			case 30: ECast(readExpr(), null);
			case 31:
				var e1 = readExpr();
				var th = readTypeHint();
				ECast(e1, th);
			case 32:
				var e1 = readExpr();
				var th = readTypeHint();
				EIs(e1, th);
			case 33:
				var e1 = readExpr();
				var dk = switch readByte() {
					case 0: DKCall;
					case 1: DKDot;
					case 2: DKStructure;
					case 3: DKMarked;
					case 4: DKPattern(readBool());
					case _: throw "assert false";
				}
				EDisplay(e1, dk);
			case 34:
				var e1 = readExpr();
				var e2 = readExpr();
				var e3 = readExpr();
				ETernary(e1, e2, e3);
			case 35:
				var e1 = readExpr();
				var th = readTypeHint();
				ECheckType(e1, th);
			case 36:
				var m = readMetadataEntry();
				var e = readExpr();
				EMeta(m, e);
			case _: throw "assert false";
		}
		return {expr: e, pos: p};
	}

	// Type instances

	public function resolveTtpRef(i:Int):TypedTypeParam {
		return switch i {
			case 1:
				var i = uleb();
				typeTypeParameters[i];
			case 2:
				var i = uleb();
				fieldTypeParameters[i];
			case 3:
				var k = uleb();
				localTypeParameters[k];
			case _:
				Globals.die("", "hxbReader.ml resolve_ttp_ref");
		}
	}

	function readFunArg():{name:String, optional:Bool, type:T} {
		var name = readString();
		var opt = readBool();
		var t = readTypeInstance();
		return {name: name, optional: opt, type: t};
	}

	public function readTypeInstance():T {
		return switch readByte() {
			case 0:
				var i = uleb();
				tmonos[i];
			case 1:
				var i = uleb();
				typeTypeParameters[i].ttpType;
			case 2:
				var i = uleb();
				fieldTypeParameters[i].ttpType;
			case 3:
				var k = uleb();
				localTypeParameters[k].ttpType;
			case 4:
				tDynamic;
			case 5:
				var path = readPath();
				var c = TFunctions.nullClass.clone();
				c.clPath = path;
				mkTypeParam(c, TPHUnbound, null, null).ttpType;
			case 10:
				var c = readClassRef();
				var c = c.force();
				c.clType;
			case 11:
				var en = readEnumRef();
				makeLazyTypeDynamic(function() return en.force().eType);
			case 12:
				var a = readAbstractRef();
				// self#make_lazy_type_dynamic (fun () ->
				TType(abstractModuleType(a.force(), vector()), vector());
				// )
			case 13:
				var e = readExpr();
				var c = TFunctions.nullClass.clone();
				c.clKind = KExpr(e);
				c.clModule = currentModule;
				TInst(c, vector());
			case 20:
				TFun({args: vector(), ret: api.basicTypes().tvoid});
			case 21:
				var arg1 = readFunArg();
				TFun({args: vector(arg1), ret: api.basicTypes().tvoid});
			case 22:
				var arg1 = readFunArg();
				var arg2 = readFunArg();
				TFun({args: vector(arg1, arg2), ret: api.basicTypes().tvoid});
			case 23:
				var arg1 = readFunArg();
				var arg2 = readFunArg();
				var arg3 = readFunArg();
				TFun({args: vector(arg1, arg2, arg3), ret: api.basicTypes().tvoid});
			case 24:
				var arg1 = readFunArg();
				var arg2 = readFunArg();
				var arg3 = readFunArg();
				var arg4 = readFunArg();
				TFun({args: vector(arg1, arg2, arg3, arg4), ret: api.basicTypes().tvoid});
			case 29:
				var args = readVector(readFunArg);
				TFun({args: args, ret: api.basicTypes().tvoid});
			case 30:
				var ret = readTypeInstance();
				TFun({args: vector(), ret: ret});
			case 31:
				var arg1 = readFunArg();
				var ret = readTypeInstance();
				TFun({args: vector(arg1), ret: ret});
			case 32:
				var arg1 = readFunArg();
				var arg2 = readFunArg();
				var ret = readTypeInstance();
				TFun({args: vector(arg1, arg2), ret: ret});
			case 33:
				var arg1 = readFunArg();
				var arg2 = readFunArg();
				var arg3 = readFunArg();
				var ret = readTypeInstance();
				TFun({args: vector(arg1, arg2, arg3), ret: ret});
			case 34:
				var arg1 = readFunArg();
				var arg2 = readFunArg();
				var arg3 = readFunArg();
				var arg4 = readFunArg();
				var ret = readTypeInstance();
				TFun({args: vector(arg1, arg2, arg3, arg4), ret: ret});
			case 39:
				var args = readVector(readFunArg);
				var ret = readTypeInstance();
				TFun({args: args, ret: ret});
			case 40:
				var c = readClassRef();
				var c = c.force();
				TInst(c, vector());
			case 41:
				var c = readClassRef();
				var t1 = readTypeInstance();
				var c = c.force();
				TInst(c, vector(t1));
			case 42:
				var c = readClassRef();
				var t1 = readTypeInstance();
				var t2 = readTypeInstance();
				var c = c.force();
				TInst(c, vector(t1, t2));
			case 49:
				var c = readClassRef();
				var tl = readTypes();
				var c = c.force();
				TInst(c, tl);
			case 50:
				var en = readEnumRef();
				makeLazyTypeDynamic(function() return TEnum(en.force(), vector()));
			case 51:
				var en = readEnumRef();
				var t1 = readTypeInstance();
				makeLazyTypeDynamic(function() return TEnum(en.force(), vector(t1)));
			case 52:
				var en = readEnumRef();
				var t1 = readTypeInstance();
				var t2 = readTypeInstance();
				makeLazyTypeDynamic(function() return TEnum(en.force(), vector(t1, t2)));
			case 59:
				var e = readEnumRef();
				var tl = readTypes();
				makeLazyTypeDynamic(function() return TEnum(e.force(), tl));
			case 60:
				var td = readTypedefRef();
				makeLazyTypeDynamic(function() return TType(td.force(), vector()));
			case 61:
				var td = readTypedefRef();
				var t1 = readTypeInstance();
				makeLazyTypeDynamic(function() return TType(td.force(), vector(t1)));
			case 62:
				var td = readTypedefRef();
				var t1 = readTypeInstance();
				var t2 = readTypeInstance();
				makeLazyTypeDynamic(function() return TType(td.force(), vector(t1, t2)));
			case 69:
				var t = readTypedefRef();
				var tl = readTypes();
				makeLazyTypeDynamic(function() return TType(t.force(), tl));
			case 70:
				var a = readAbstractRef();
				// self#make_lazy_type_dynamic (fun () ->
				TAbstract(a.force(), vector());
				// )
			case 71:
				var a = readAbstractRef();
				var t1 = readTypeInstance();
				// self#make_lazy_type_dynamic (fun () ->
				TAbstract(a.force(), vector(t1));
				// )
			case 72:
				var a = readAbstractRef();
				var t1 = readTypeInstance();
				var t2 = readTypeInstance();
				// self#make_lazy_type_dynamic (fun () ->
				TAbstract(a.force(), vector(t1, t2));
				// )
			case 79:
				var a = readAbstractRef();
				var tl = readTypes();
				// self#make_lazy_type_dynamic (fun () ->
				TAbstract(a.force(), tl);
				// )
			case 80:
				emptyAnon;
			case 81:
				TAnon(readAnonRef());
			case 89:
				TDynamic(readTypeInstance());
			case 100:
				api.basicTypes().tvoid;
			case 101:
				api.basicTypes().tint;
			case 102:
				api.basicTypes().tfloat;
			case 103:
				api.basicTypes().tbool;
			case 104:
				api.basicTypes().tstring;
			case i:
				HxbData.error('Bad type instance id: $i');
		}
	}

	public function readTypes():core.TType.TParams {
		return readVector(readTypeInstance);
	}

	public function readTypeParametersForward():core.TType.TypeParams {
		var length = uleb();
		var a = new haxe.ds.Vector<TypedTypeParam>(length);
		for (i in 0...length) {
			a[i] = {
				var path = readPath();
				var pos = readPos();
				var host = switch readByte() {
					case 0: TPHType;
					case 1: TPHConstructor;
					case 2: TPHMethod;
					case 3: TPHEnumConstructor;
					case 4: TPHAnonField;
					case 5: TPHLocal;
					case i: Globals.die('Invalid type paramter host: $i', "hxbReader.ml read_type_parameters_forward");
				}
				var c = mkClass(currentModule, path, pos, pos);
				mkTypeParam(c, host, null, null);
			}
		}
		return a;
	}

	public function readTypeParametersData(a:core.TType.TypeParams):Void {
		for (ttp in a) {
			var meta = readMetadata();
			var constraints = readTypes();
			var def = readOption(readTypeInstance);
			var c = ttp.ttpClass;
			ttp.ttpDefault = def;
			ttp.ttpConstraints = AtomicLazy.fromVal(constraints);
			c.clMeta = meta;
		}
	}

	// Fields

	public function readFieldKind():FieldKind {
		return switch readByte() {
			case 0: Method(MethNormal);
			case 1: Method(MethInline);
			case 2: Method(MethDynamic);
			case 3: Method(MethMacro);
			case 10: Var({vRead: AccNormal, vWrite: AccNormal});
			case 11: Var({vRead: AccNormal, vWrite: AccNo});
			case 12: Var({vRead: AccNormal, vWrite: AccNever});
			case 13: Var({vRead: AccNormal, vWrite: AccCtor});
			case 14: Var({vRead: AccNormal, vWrite: AccCall});
			case 20: Var({vRead: AccInline, vWrite: AccNever});
			case 30: Var({vRead: AccCall, vWrite: AccNormal});
			case 31: Var({vRead: AccCall, vWrite: AccNo});
			case 32: Var({vRead: AccCall, vWrite: AccNever});
			case 33: Var({vRead: AccCall, vWrite: AccCtor});
			case 34: Var({vRead: AccCall, vWrite: AccCall});
			case 100:
				function f(i:Int):VarAccess return switch i {
					case 0: AccNormal;
					case 1: AccNo;
					case 2: AccNever;
					case 3: AccCtor;
					case 4: AccCall;
					case 5: AccInline;
					case 6:
						var s = readString();
						var so = readOption(readString);
						AccRequire(s, so);
					case 7: AccPrivateCall;
					case i:
						HxbData.error('Bad accessor kind: $i');
				}
				var r = f(readByte());
				var w = f(readByte());
				Var({vRead: r, vWrite: w});
			case i:
				HxbData.error('Bad field kind: $i');
		}
	}

	public function readVarKind():TVarKind {
		return switch readByte() {
			case 0: VUser(TVOLocalVariable);
			case 1: VUser(TVOArgument);
			case 2: VUser(TVOForVariable);
			case 3: VUser(TVOPatternVariable);
			case 4: VUser(TVOCatchVariable);
			case 5: VUser(TVOLocalFunction);
			case 6: VGenerated;
			case 7: VInlined;
			case 8: VInlinedConstructorVariable(readList(readString));
			case 9: VExtractorVariable;
			case 10: VAbstractThis;
			case _: throw "assert false";
		}
	}

	public function readVar():TVar {
		var id = uleb();
		var name = readString();
		var kind = readVarKind();
		var flags = uleb();
		var meta = readMetadata();
		var pos = readPos();
		var v:TVar = {
			vId: api.getVarId(id),
			vName: name,
			vType: tDynamic,
			vKind: kind,
			vMeta: meta,
			vPos: pos,
			vExtra: null,
			vFlags: flags
		};
		return v;
	}

	public function readTexpr(fctx:FieldReaderContext):TExpr {
		function declareLocal():TVar {
			var v = fctx.vars[uleb()];
			v.vExtra = readOption(function():TVarExtra {
				var params = readVector(function() {
					var i = uleb();
					return localTypeParameters[i];
				});
				var vexpr = readOption(function() return readTexpr(fctx));
				return {
					vParams: params,
					vExpr: vexpr
				};
			});
			v.vType = readTypeInstance();
			return v;
		}
		function updatePmin():Void {
			var p = fctx.pos;
			fctx.pos = new Pos(p.pfile, readLeb128(ch), p.pmax);
		}
		function updatePmax():Void {
			var p = fctx.pos;
			fctx.pos = new Pos(p.pfile, p.pmin, readLeb128(ch));
		}
		function updatePminmax():Void {
			var pmin = readLeb128(ch);
			var pmax = readLeb128(ch);
			fctx.pos = new Pos(fctx.pos.pfile, pmin, pmax);
		}
		function updateP():Void {
			fctx.pos = readPos();
		}
		function readRelpos():Pos {
			switch readByte() {
				case 0:
				case 1:
					updatePmin();
				case 2:
					updatePmax();
				case 3:
					updatePminmax();
				case 4:
					updateP();
				case _:
					throw "assert false";
			}
			return fctx.pos;
		}
		var loopEl:Void->haxe.ds.Vector<TExpr> = null;
		function loop():TExpr {
			var e:TExprDef;
			var t:Null<T>;
			switch readByte() {
				// values 0-19
				case 0:
					e = TConst(TNull);
					t = null;
				case 1:
					e = TConst(TThis);
					t = fctx.tthis;
				case 2:
					e = TConst(TSuper);
					t = null;
				case 3:
					e = TConst(TBool(false));
					t = api.basicTypes().tbool;
				case 4:
					e = TConst(TBool(true));
					t = api.basicTypes().tbool;
				case 5:
					e = TConst(TInt(readI32()));
					t = api.basicTypes().tint;
				case 6:
					e = TConst(TFloat(readString()));
					t = api.basicTypes().tfloat;
				case 7:
					e = TConst(TString(readString()));
					t = api.basicTypes().tstring;
				case 13:
					e = TConst(TBool(false));
					t = null;
				case 14:
					e = TConst(TBool(true));
					t = null;
				case 15:
					e = TConst(TInt(readI32()));
					t = null;
				case 16:
					e = TConst(TFloat(readString()));
					t = null;
				case 17:
					e = TConst(TString(readString()));
					t = null;

				// vars 20-29
				case 20:
					e = TLocal(fctx.vars[uleb()]);
					t = null;
				case 21:
					var v = declareLocal();
					e = TVar(v, null);
					t = api.basicTypes().tvoid;
				case 22:
					var v = declareLocal();
					var e1 = loop();
					e = TVar(v, e1);
					t = api.basicTypes().tvoid;

				// blocks 30-49
				case 30:
					e = TBlock(vector());
					t = null;
				case i = 31 | 32 | 33 | 34 | 35:
					var l = i - 30;
					var el = new haxe.ds.Vector<TExpr>(l);
					for (j in 0...l) el[j] = loop();
					e = TBlock(el);
					t = null;
				case 36:
					var l = readByte();
					var el = new haxe.ds.Vector<TExpr>(l);
					for (j in 0...l) el[j] = loop();
					e = TBlock(el);
					t = null;
				case 39:
					var el = readVector(loop);
					e = TBlock(el);
					t = null;

				// function 50-59
				case 50:
					function readTfunctionArg() {
						var v = declareLocal();
						var cto = readOption(loop);
						return {variable: v, defaultValue: cto};
					}
					var args = readVector(readTfunctionArg);
					var r = readTypeInstance();
					var e1 = loop();
					e = TFunction({
						tfArgs: args,
						tfType: r,
						tfExpr: e1
					});
					t = null;
				// texpr compounds 60-79
				case 60:
					var e1 = loop();
					var e2 = loop();
					e = TArray(e1, e2);
					t = null;
				case 61:
					var e1 = loop();
					e = TParenthesis(e1);
					t = e1.etype;
				case 62:
					e = TArrayDecl(loopEl());
					t = null;
				case 63:
					var fl = readVector(function() {
						var name = readString();
						var p = readPos();
						var qs = switch readByte() {
							case 0: NoQuotes;
							case 1: DoubleQuotes;
							case _: throw "assert false";
						}
						var e = loop();
						return {key: {name: name, pos: p, quote: qs}, expr: e};
					});
					e = TObjectDecl(fl);
					t = null;
				case 65:
					var m = readMetadataEntry();
					var e1 = loop();
					e = TMeta(m, e1);
					t = null;

				// calls 70 - 79
				case 70:
					var e1 = loop();
					e = TCall(e1, vector());
					t = null;
				case i = 71 | 72 | 73 | 74:
					var e1 = loop();
					var el = new haxe.ds.Vector<TExpr>(i - 70);
					for (j in 0...i - 70) el[j] = loop();
					e = TCall(e1, el);
					t = null;
				case 79:
					var e1 = loop();
					var el = readVector(loop);
					e = TCall(e1, el);
					t = null;

				// branching 80-89
				case 80:
					var e1 = loop();
					var e2 = loop();
					e = TIf(e1, e2, null);
					t = api.basicTypes().tvoid;
				case 81:
					var e1 = loop();
					var e2 = loop();
					var e3 = loop();
					e = TIf(e1, e2, e3);
					t = null;
				case 82:
					var subject = loop();
					var cases = readVector(function():TSwitchCase {
						var patterns = loopEl();
						var ec = loop();
						return {casePatterns: patterns, caseExpr: ec};
					});
					var def = readOption(function() return loop());
					e = TSwitch({
						switchSubject: subject,
						switchCases: cases,
						switchDefault: def,
						switchExhaustive: true
					});
					t = null;
				case 83:
					var e1 = loop();
					var catches = readVector(function() {
						var v = declareLocal();
						var e = loop();
						return {variable: v, expr: e};
					});
					e = TTry(e1, catches);
					t = null;
				case 84:
					var e1 = loop();
					var e2 = loop();
					e = TWhile(e1, e2, NormalWhile);
					t = api.basicTypes().tvoid;
				case 85:
					var e1 = loop();
					var e2 = loop();
					e = TWhile(e1, e2, DoWhile);
					t = api.basicTypes().tvoid;

				// control flow 90-99
				case 90:
					e = TReturn(null);
					t = null;
				case 91:
					e = TReturn(loop());
					t = null;
				case 92:
					e = TContinue;
					t = null;
				case 93:
					e = TBreak;
					t = null;
				case 94:
					e = TThrow(loop());
					t = null;

				// access 100-119
				case 100:
					e = TEnumIndex(loop());
					t = api.basicTypes().tint;
				case 101:
					var e1 = loop();
					var ef = readEnumFieldRef();
					var i = uleb();
					e = TEnumParameter(e1, ef, i);
					t = null;
				case 102:
					var e1 = loop();
					var c = readClassRef();
					var c = c.force();
					var tl = readTypes();
					var cf = readFieldRef();
					e = TField(e1, FInstance(c, tl, cf));
					t = null;
				case 103:
					var e1 = loop();
					var c = readClassRef();
					var c = c.force();
					var cf = readFieldRef();
					e = TField(e1, FStatic(c, cf));
					t = null;
				case 104:
					var e1 = loop();
					var cf = readAnonFieldRef();
					e = TField(e1, FAnon(cf));
					t = null;
				case 105:
					var e1 = loop();
					var c = readClassRef();
					var c = c.force();
					var tl = readTypes();
					var cf = readFieldRef();
					e = TField(e1, FClosure({cls: c, params: tl}, cf));
					t = null;
				case 106:
					var e1 = loop();
					var cf = readAnonFieldRef();
					e = TField(e1, FClosure(null, cf));
					t = null;
				case 107:
					var e1 = loop();
					var en = readEnumRef();
					var ef = readEnumFieldRef();
					var en = en.force();
					e = TField(e1, FEnum(en, ef));
					t = null;
				case 108:
					var e1 = loop();
					var s = readString();
					e = TField(e1, FDynamic(s));
					t = null;

				case 110:
					var p = readRelpos();
					var c = readClassRef();
					var c = c.force();
					var cf = readFieldRef();
					var e1 = core.Texpr.Builder.makeStaticThis(c, p);
					e = TField(e1, FStatic(c, cf));
					t = null;
				case 111:
					var p = readRelpos();
					var c = readClassRef();
					var c = c.force();
					var tl = readTypes();
					var cf = readFieldRef();
					var tthis = fctx.tthis;
					if (tthis == null) throw "Option.get";
					var ethis = mk(TConst(TThis), tthis, p);
					e = TField(ethis, FInstance(c, tl, cf));
					t = null;

				// module types 120-139
				case 120:
					var c = readClassRef();
					var c = c.force();
					e = TTypeExpr(TClassDecl(c));
					t = c.clType;
				case 121:
					var en = readEnumRef();
					var en = en.force();
					e = TTypeExpr(TEnumDecl(en));
					t = en.eType;
				case 122:
					e = TTypeExpr(TAbstractDecl(readAbstractRef().force()));
					t = null;
				case 123:
					e = TTypeExpr(TTypeDecl(readTypedefRef().force()));
					t = null;
				case 124:
					e = TCast(loop(), null);
					t = null;
				case 125:
					var e1 = loop();
					var fp = readFullPath();
					var mt = resolveType(fp.pack, fp.mname, fp.tname);
					e = TCast(e1, mt);
					t = null;
				case 126:
					var c = readClassRef();
					var c = c.force();
					var tl = readTypes();
					var el = loopEl();
					e = TNew(c, tl, el);
					t = null;
				case 127:
					var ttp = resolveTtpRef(uleb());
					var tl = readTypes();
					var el = loopEl();
					e = TNew(ttp.ttpClass, tl, el);
					t = null;
				case 128:
					var ttp = resolveTtpRef(uleb());
					e = TTypeExpr(TClassDecl(ttp.ttpClass));
					t = null;

				// unops 140-159
				case i if (i >= 140 && i < 160):
					var u = getUnop(i - 140);
					var e1 = loop();
					e = TUnop(u.op, u.flag, e1);
					t = null;

				// binops 160-219
				case i if (i >= 160 && i < 220):
					var op = getBinop(i - 160);
					var e1 = loop();
					var e2 = loop();
					e = TBinop(op, e1, e2);
					t = null;
				// rest 250-254
				case 250:
					e = TIdent(readString());
					t = null;

				case i:
					return Globals.die('  [ERROR] Unhandled texpr $i at:', "hxbReader.ml read_texpr");
			}
			var t:T = t == null ? fctx.tPool[uleb()] : t;
			var p = readRelpos();
			var e:TExpr = {
				eexpr: e,
				etype: t,
				epos: p
			};
			return e;
		}
		loopEl = function() return readVector(loop);
		return loop();
	}

	public function readClassFieldForward():TClassField {
		var name = readString();
		var pp = readPosPair();
		var cfMeta = readMetadata();
		var overloads = readList(readClassFieldForward);
		var cf = TFunctions.nullField.clone();
		cf.cfName = name;
		cf.cfPos = pp.p1;
		cf.cfNamePos = pp.p2;
		cf.cfOverloads = overloads;
		cf.cfMeta = cfMeta;
		// port: fresh list values: Haxe arrays are mutable, OCaml lists are not.
		cf.cfParams = vector();
		return cf;
	}

	public function startTexpr():FieldReaderContext {
		switch readByte() {
			case 0:
			case 1:
				var a = readTypeParametersForward();
				localTypeParameters = a;
				readTypeParametersData(a);
			case i:
				Globals.die("", "hxbReader.ml start_texpr");
		}
		var tthis = readOption(readTypeInstance);
		var l = uleb();
		var ts = new Vector<T>(l);
		for (i in 0...l)
			ts[i] = readTypeInstance();
		var l = uleb();
		var vars = new Vector<TVar>(l);
		for (i in 0...l)
			vars[i] = readVar();
		return createFieldReaderContext(readPos(), ts, vars, tthis);
	}

	public function readFieldTypeParameters():core.TType.TypeParams {
		var numParams = uleb();
		switch readByte() {
			case 0:
			case 1:
				var a = readTypeParametersForward();
				fieldTypeParameters = a;
				readTypeParametersData(a);
				fieldTypeParameterOffset = 0; // num_params is added below
			case i:
				Globals.die("", "hxbReader.ml read_field_type_parameters");
		}
		var params = new haxe.ds.Vector<TypedTypeParam>(numParams);
		for (offset in 0...numParams) params[offset] = fieldTypeParameters[fieldTypeParameterOffset + offset];
		fieldTypeParameterOffset = fieldTypeParameterOffset + numParams;
		return params;
	}

	public function readExpression(fctx:FieldReaderContext):{e:TExpr, eUnopt:Null<TExpr>} {
		var e = readTexpr(fctx);
		var eUnopt = readOption(function() return readTexpr(fctx));
		return {e: e, eUnopt: eUnopt};
	}

	final classFieldInfos = ClassFieldInfos.create();

	public function readClassFieldData(cf:TClassField):Void {
		var params = readFieldTypeParameters();

		var t = readTypeInstance();

		var flags = uleb();

		var doc = readOption(readDocumentation);
		var kind = readFieldKind();

		var expr:Null<TExpr> = null, exprUnoptimized:Null<TExpr> = null;
		switch readByte() {
			case 0:
			case 1:
				var fctx = startTexpr();
				var r = readExpression(fctx);
				expr = r.e;
				exprUnoptimized = r.eUnopt;
			case 2:
				// store type parameter info for EXD
				var info = ClassFieldInfo.create(fieldTypeParameters);
				ClassFieldInfos.set(classFieldInfos, info, cf);
			case _:
				Globals.die("", "hxbReader.ml read_class_field_data");
		}

		cf.cfType = t;
		cf.cfDoc = doc;
		cf.cfKind = kind;
		cf.cfExpr = expr;
		cf.cfExprUnoptimized = exprUnoptimized;
		cf.cfParams = params;
		cf.cfFlags = flags;
	}

	public function readClassFieldAndOverloadsData(cf:TClassField):Void {
		var depth = uleb();
		var cfl = [cf].concat(cf.cfOverloads);
		for (cf in cfl) {
			if (!(depth > 0)) throw "assert false";
			readClassFieldData(cf);
			depth--;
		}
		if (!(depth == 0)) throw "assert false";
	}

	public function selectClassTypeParameters(c:TClass):Void {
		switch c.clKind {
			case KAbstractImpl(a):
				typeTypeParameters = a.aParams.copy();
			case _:
				typeTypeParameters = c.clParams.copy();
		}
	}

	public function readClassFields(c:TClass):Void {
		selectClassTypeParameters(c);
		readOption(function() {
			var cf = c.clConstructor;
			if (cf == null) throw "Option.get";
			readClassFieldAndOverloadsData(cf);
			return true;
		});
		readOption(function() {
			var cf = c.clInit;
			if (cf == null) throw "Option.get";
			readClassFieldAndOverloadsData(cf);
			return true;
		});
		function loop(refKind:ClassFieldRefKind, num:Int, cfl:Array<TClassField>):Void {
			for (cf in cfl) {
				if (!(num > 0)) throw "assert false";
				readClassFieldAndOverloadsData(cf);
				num--;
			}
			if (!(num == 0)) throw "assert false";
		}
		loop(CfrMember, uleb(), c.clOrderedFields);
		loop(CfrStatic, uleb(), c.clOrderedStatics);
	}

	public function readEnumFields(e:TEnum):Void {
		typeTypeParameters = e.eParams.copy();
		readList(function() {
			var name = readString();
			var ef = findMap(e.eConstrs, name);
			ef.efParams = readFieldTypeParameters();
			ef.efType = readTypeInstance();
			ef.efDoc = readOption(readDocumentation);
			ef.efMeta = readMetadata();
			return true;
		});
	}

	// Module types
	// port: read_common_module_type takes the tinfos view of a module type
	// (Obj.magic upstream); the setters below write the corresponding fields.
	public function readCommonModuleType(mt:ModuleType):Void {
		var private_ = readBool();
		switch mt {
			case TClassDecl(c):
				c.clPrivate = private_;
			case TEnumDecl(e):
				e.ePrivate = private_;
			case TTypeDecl(t):
				t.tPrivate = private_;
			case TAbstractDecl(a):
				a.aPrivate = private_;
		}
		var doc = readOption(readDocumentation);
		switch mt {
			case TClassDecl(c):
				c.clDoc = doc;
			case TEnumDecl(e):
				e.eDoc = doc;
			case TTypeDecl(t):
				t.tDoc = doc;
			case TAbstractDecl(a):
				a.aDoc = doc;
		}
		var meta = readMetadata();
		switch mt {
			case TClassDecl(c):
				c.clMeta = meta;
			case TEnumDecl(e):
				e.eMeta = meta;
			case TTypeDecl(t):
				t.tMeta = meta;
			case TAbstractDecl(a):
				a.aMeta = meta;
		}
		var params = switch mt {
			case TClassDecl(c): c.clParams.copy();
			case TEnumDecl(e): e.eParams.copy();
			case TTypeDecl(t): t.tParams.copy();
			case TAbstractDecl(a): a.aParams.copy();
		}
		typeTypeParameters = params;
		readTypeParametersData(params);
		var params = typeTypeParameters.copy();
		switch mt {
			case TClassDecl(c):
				c.clParams = params;
			case TEnumDecl(e):
				e.eParams = params;
			case TTypeDecl(t):
				t.tParams = params;
			case TAbstractDecl(a):
				a.aParams = params;
		}
		var using_ = readList(function() {
			var c = readClassRef();
			var c = c.force();
			var p = readPos();
			return {cls: c, pos: p};
		});
		switch mt {
			case TClassDecl(c):
				c.clUsing = using_;
			case TEnumDecl(e):
				e.eUsing = using_;
			case TTypeDecl(t):
				t.tUsing = using_;
			case TAbstractDecl(a):
				a.aUsing = using_;
		}
	}

	public function readClassKind():TClassKind {
		return switch readByte() {
			case 0: KNormal;
			case 1: Globals.die("", "hxbReader.ml read_class_kind");
			case 2: KExpr(readExpr());
			case 3: KGeneric;
			case 4:
				var c = readClassRef();
				var c = c.force();
				var tl = readTypes();
				KGenericInstance(c, tl);
			case 5: KMacroType;
			case 6: KGenericBuild(readVector(readCfield));
			case 7: KAbstractImpl(readAbstractRef().force());
			case 8: KModuleFields(currentModule);
			case i:
				HxbData.error('Invalid class kind id: $i');
		}
	}

	public function readClass(c:TClass):Void {
		readCommonModuleType(TClassDecl(c));
		c.clKind = readClassKind();
		function readRelation() {
			var c = readClassRef();
			var c = c.force();
			var tl = readTypes();
			return {cls: c, params: tl};
		}
		c.clSuper = readOption(readRelation);
		c.clImplements = readList(readRelation);
		c.clDynamic = readOption(readTypeInstance);
		c.clArrayAccess = readOption(readTypeInstance);
		switch c.clKind {
			case KModuleFields(md):
				md.mStatics = c;
			case _:
		}
	}

	public function readAbstract(a:TAbstract):Void {
		readCommonModuleType(TAbstractDecl(a));
		a.aImpl = readOption(function() return readClassRef().force());
		switch readByte() {
			case 0:
				a.aThis = TAbstract(a, extractParamTypes(a.aParams));
			case _:
				a.aThis = readTypeInstance();
		}
		a.aFrom = readList(readTypeInstance);
		a.aTo = readList(readTypeInstance);
		a.aExtern = readBool();
		a.aEnum = readBool();
	}

	public function readAbstractFields(a:TAbstract):Void {
		a.aArray = readList(readFieldRef);
		a.aRead = readOption(readFieldRef);
		a.aWrite = readOption(readFieldRef);
		a.aCall = readOption(readFieldRef);
		a.aConstructor = readOption(readFieldRef);

		a.aOps = readList(function() {
			var i = readByte();
			var op = getBinop(i);
			var cf = readFieldRef();
			return {op: op, field: cf};
		});

		a.aUnops = readList(function() {
			var i = readByte();
			var u = getUnop(i);
			var cf = readFieldRef();
			return {op: u.op, flag: u.flag, field: cf};
		});

		a.aFromField = readList(function() {
			var cf = readFieldRef();
			var t = switch cf.cfType {
				case TFun(sig) if (sig.args.length > 0): sig.args[0].type;
				case _: Globals.die("", "hxbReader.ml read_abstract_fields");
			}
			return {type: t, field: cf};
		});

		a.aToField = readList(function() {
			var cf = readFieldRef();
			var t = switch cf.cfType {
				case TFun(sig): sig.ret;
				case _: Globals.die("", "hxbReader.ml read_abstract_fields");
			}
			return {type: t, field: cf};
		});
	}

	public function readEnum(e:TEnum):Void {
		readCommonModuleType(TEnumDecl(e));
		e.eFlags = uleb();
		e.eNames = readList(readString);
	}

	public function readTypedef(td:TDef):Void {
		readCommonModuleType(TTypeDecl(td));
		var t = readTypeInstance();
		switch td.tType {
			case TMono(r):
				if (r.tmType == null) Monomorph.bind(r, t);
				else
					Globals.die('typedef ${Globals.sTypePath(td.tPath)} is already initialized to ${TPrinting.sTypeKind(r.tmType)}, but new init to ${TPrinting.sTypeKind(t)} was attempted',
						"hxbReader.ml read_typedef");
			case _:
				Globals.die("", "hxbReader.ml read_typedef");
		}
	}

	// Chunks

	public function readStringPool():Vector<String> {
		var l = uleb();
		var a = new Vector<String>(l);
		for (i in 0...l)
			a[i] = readRawString();
		return a;
	}

	public function readEfr():Void {
		var l = uleb();
		var a = new Vector<AtomicLazy<TEnumField>>(l);
		for (i in 0...l)
			a[i] = {
				var en = readEnumRef();
				var name = readString();
				AtomicLazy.fromFun(function() {
					var en = en.force();
					return findMap(en.eConstrs, name);
				});
			}
		enumFields = a;
	}

	public function readOfr():Void {
		var l = uleb();
		var a = new Vector<TClassField>(l);
		for (i in 0...l)
			a[i] = readClassFieldForward();
		anonFields = a;
	}

	public function readOfd():Void {
		var l = uleb();
		for (_ in 0...l) {
			var index = uleb();
			var cf = anonFields[index];
			readClassFieldAndOverloadsData(cf);
		}
	}

	public function readObd():Void {
		var l = uleb();
		for (_ in 0...l) {
			var index = uleb();
			readAnon(anons[index]);
		}
	}

	public function readCfr():Void {
		var l = uleb();
		var a = new Vector<AtomicLazy<TClassField>>(l);
		for (i in 0...l)
			a[i] = {
				var c = readClassRef();
				var kind = switch readByte() {
					case 0: CfrStatic;
					case 1: CfrMember;
					case 2: CfrConstructor;
					case 3: CfrInit;
					case _: Globals.die("", "hxbReader.ml read_cfr");
				}
				var name = switch kind {
					case CfrStatic | CfrMember:
						readString();
					case CfrConstructor | CfrInit:
						null;
				}
				var depth = uleb();

				AtomicLazy.fromFun(function() {
					var c = c.force();
					var cf = switch kind {
						case CfrStatic:
							try {
								c.clBuild();
								try findMap(c.clStatics, name) catch (e:NotFound) {
									// port: hxmc's module cache: a class typed from its source in this build, its
									// ... fields made by the passes still pending (an interface's accessors)
									if (missingFieldHook == null || !missingFieldHook(c)) throw e;
									findMap(c.clStatics, name);
								}
							} catch (_:NotFound) {
								throw new HxbFailure('Could not read static field $name on ${Globals.sTypePath(c.clPath)} while hxbing ${Globals.sTypePath(currentModule.mPath)}');
							}
						case CfrMember:
							try {
								c.clBuild();
								try findMap(c.clFields, name) catch (e:NotFound) {
									// port: hxmc's module cache: a class typed from its source in this build, its
									// ... fields made by the passes still pending (an interface's accessors)
									if (missingFieldHook == null || !missingFieldHook(c)) throw e;
									findMap(c.clFields, name);
								}
							} catch (_:NotFound) {
								throw new HxbFailure('Could not read instance field $name on ${Globals.sTypePath(c.clPath)} while hxbing ${Globals.sTypePath(currentModule.mPath)}');
							}
						case CfrConstructor:
							var cf = c.clConstructor;
							if (cf == null) throw "Option.get";
							cf;
						case CfrInit:
							var cf = c.clInit;
							if (cf == null) throw "Option.get";
							cf;
					}
					function pickOverload(cf:TClassField, depth:Int):TClassField {
						var cfl = [cf].concat(cf.cfOverloads);
						if (depth < cfl.length) return cfl[depth];
						throw new HxbFailure('Bad overload depth for ${cf.cfName} on ${Globals.sTypePath(c.clPath)}: $depth');
					}
					return if (depth == 0) cf else pickOverload(cf, depth);
				});
			}
		classFields = a;
	}

	public function readCfd():Void {
		var l = uleb();
		for (i in 0...l) {
			var c = classes[i];
			var c = c.force();
			readClassFields(c);
		}
	}

	public function readExd():Void {
		readList(function() {
			var c = readClassRef();
			var c = c.force();
			readList(function() {
				var cf = readFieldRef();
				var length = uleb();
				var chCf = new BytesWithPosition(ch.bytes, ch.pos);
				ch.pos = ch.pos + length;
				function readExpressions():Void {
					selectClassTypeParameters(c);
					fieldTypeParameters = ClassFieldInfos.get(classFieldInfos, cf).typeParameters;
					ClassFieldInfos.unset(classFieldInfos, cf);
					fieldTypeParameterOffset = 0;
					var old = ch;
					ch = chCf;
					var fctx = startTexpr();
					var r = readExpression(fctx);
					ch = old;
					cf.cfExpr = r.e;
					cf.cfExprUnoptimized = r.eUnopt;
				}
				if (api.readExpressionEagerly(cf))
					readExpressions();
				else {
					var t = cf.cfType;
					var tl = api.makeLazyType(cf.cfType, function() {
						cf.cfType = t;
						readExpressions();
						return t;
					});
					cf.cfType = tl;
				}
				return true;
			});
			return true;
		});
	}

	public function readAfd():Void {
		var l = uleb();
		for (i in 0...l) {
			var a = abstracts[i].force();
			readAbstractFields(a);
		}
	}

	public function readCld():Void {
		var l = uleb();
		for (i in 0...l) {
			var c = classes[i];
			var c = c.force();
			readClass(c);
		}
	}

	public function readAbd():Void {
		var l = uleb();
		for (i in 0...l) {
			var a = abstracts[i].force();
			readAbstract(a);
		}
	}

	public function readEnd():Void {
		var l = uleb();
		for (i in 0...l) {
			var en = enums[i].force();
			readEnum(en);
		}
	}

	public function readEfd():Void {
		var l = uleb();
		for (i in 0...l) {
			var e = enums[i].force();
			readEnumFields(e);
			TUnification.unify(TType(enumModuleType(e), vector()), e.eType);
		}
	}

	public function readAnon(an:TAnon):Void {
		function readFields():Void {
			var acc = new haxe.ds.StringMap<TClassField>();
			var i = uleb();
			while (i != 0) {
				var cf = readAnonFieldRef();
				acc.set(cf.cfName, cf);
				i--;
			}
			an.aFields = acc;
		}

		switch readByte() {
			case 0:
				an.aStatus = Closed;
				readFields();
			case 1:
				an.aStatus = Const;
				readFields();
			case 2:
				an.aStatus = Extend(readTypes());
				readFields();
			case _:
				throw "assert false";
		}
	}

	public function readTdd():Void {
		var l = uleb();
		for (i in 0...l) {
			var t = typedefs[i].force();
			readTypedef(t);
		}
	}

	public function readClr():Void {
		var l = uleb();
		var a = new Vector<AtomicLazy<TClass>>(l);
		for (i in 0...l)
			a[i] = {
				var fp = readFullPath();
				AtomicLazy.fromFun(function() {
					return switch resolveType(fp.pack, fp.mname, fp.tname) {
						case TClassDecl(c):
							c;
						case _:
							HxbData.error("Unexpected type where class was expected: "
								+ Globals.sTypePath({pack: fp.pack, name: fp.tname}));
					}
				});
			}
		classes = a;
	}

	public function readAbr():Void {
		var l = uleb();
		var a = new Vector<AtomicLazy<TAbstract>>(l);
		for (i in 0...l)
			a[i] = {
				var fp = readFullPath();
				AtomicLazy.fromFun(function() {
					return switch resolveType(fp.pack, fp.mname, fp.tname) {
						case TAbstractDecl(a):
							a;
						case _:
							HxbData.error("Unexpected type where abstract was expected: "
								+ Globals.sTypePath({pack: fp.pack, name: fp.tname}));
					}
				});
			}
		abstracts = a;
	}

	public function readEnr():Void {
		var l = uleb();
		var a = new Vector<AtomicLazy<TEnum>>(l);
		for (i in 0...l)
			a[i] = {
				var fp = readFullPath();
				AtomicLazy.fromFun(function() {
					return switch resolveType(fp.pack, fp.mname, fp.tname) {
						case TEnumDecl(en):
							en;
						case _:
							HxbData.error("Unexpected type where enum was expected: " + Globals.sTypePath({pack: fp.pack, name: fp.tname}));
					}
				});
			}
		enums = a;
	}

	public function readTdr():Void {
		var l = uleb();
		var a = new Vector<AtomicLazy<TDef>>(l);
		for (i in 0...l)
			a[i] = {
				var fp = readFullPath();
				AtomicLazy.fromFun(function() {
					return switch resolveType(fp.pack, fp.mname, fp.tname) {
						case TTypeDecl(tpd):
							tpd;
						case _:
							HxbData.error("Unexpected type where typedef was expected: "
								+ Globals.sTypePath({pack: fp.pack, name: fp.tname}));
					}
				});
			}
		typedefs = a;
	}

	public function readImports():Void {
		var length = uleb();
		for (_ in 0...length) {
			var path = readPath();
			api.resolveModule(path, typingMode);
		}
	}

	public function readMtf():Array<ModuleType> {
		return readList(function() {
			var kind = readByte();
			var path = readPath();
			var pp = readPosPair();
			var pos = pp.p1, namePos = pp.p2;
			var params = readTypeParametersForward();
			var mt = switch kind {
				case 0:
					var c = mkClass(currentModule, path, pos, namePos);
					c.clParams = params.copy();
					c.clFlags = uleb();

					function readField() {
						return readClassFieldForward();
					}

					c.clConstructor = readOption(readField);
					c.clInit = readOption(readField);
					// port: upstream conses each field read onto the accumulator, so
					// the list holds them in reverse reading order.
					function readFields(i:Int):{l:Array<TClassField>, pm:haxe.ds.StringMap<TClassField>} {
						var accL = [];
						var accPm = new haxe.ds.StringMap<TClassField>();
						while (i != 0) {
							var cf = readClassFieldForward();
							accL.push(cf);
							accPm.set(cf.cfName, cf);
							i--;
						}
						accL.reverse();
						return {l: accL, pm: accPm};
					}
					var numFields = uleb();
					var numStatics = uleb();
					var r = readFields(numFields);
					c.clOrderedFields = r.l;
					c.clFields = r.pm;
					var r = readFields(numStatics);
					c.clOrderedStatics = r.l;
					c.clStatics = r.pm;

					TClassDecl(c);
				case 1:
					var en = TOther.mkEnum(currentModule, path, pos, namePos);
					en.eParams = params.copy();

					function readField():TEnumField {
						var name = readString();
						var pp = readPosPair();
						var index = uleb();

						var ef = TFunctions.nullEnumField.clone();
						ef.efName = name;
						ef.efPos = pp.p1;
						ef.efNamePos = pp.p2;
						ef.efIndex = index;
						// port: fresh list values: Haxe arrays are mutable, OCaml lists are not.
						ef.efParams = vector();
						ef.efMeta = [];
						return ef;
					}
					var acc = new haxe.ds.StringMap<TEnumField>();
					var i = uleb();
					while (i != 0) {
						var ef = readField();
						acc.set(ef.efName, ef);
						i--;
					}
					en.eConstrs = acc;
					TEnumDecl(en);
				case 2:
					var td = mkTypedef(currentModule, path, pos, namePos, mkMono());
					td.tParams = params.copy();
					typedefs = typedefs.snoc(AtomicLazy.fromVal(td));
					TTypeDecl(td);
				case 3:
					var a = TOther.mkAbstract(currentModule, path, pos, namePos);
					a.aParams = params.copy();
					abstracts = abstracts.snoc(AtomicLazy.fromVal(a));
					TAbstractDecl(a);
				case _:
					HxbData.error("Invalid type kind: " + kind);
			}
			return mt;
		});
	}

	public function readMdf():ModuleDef {
		var path = readPath();
		var file = readString();

		var l = uleb();
		anons = new Vector<TAnon>(l);
		for (i in 0...l)
			anons[i] = ({
				aFields:new haxe.ds.StringMap(), aStatus:Closed
			} : TAnon);
		var l = uleb();
		tmonos = new Vector<T>(l);
		for (i in 0...l)
			tmonos[i] = mkMono();
		return api.makeModule(path, file);
	}

	function readChunkPrefix():{name:String, size:Int} {
		var name = BytesWithPosition.readBytes(ch, 3).getString(0, 3);
		var size = readI32();
		return {name: name, size: size};
	}

	function readChunkDataPrime(kind:ChunkKind):Void {
		switch kind {
			case STR:
				stringPool = readStringPool();
			case DOC:
				docPool = readStringPool();
			case MDF:
				currentModule = readMdf();
				stats.modulesPartiallyRestored++;
				if (typingMode == AllowPartialTyping) currentModule.mExtra.mDisplayDeps = new haxe.ds.IntMap();
			case MTF:
				currentModule.mTypes = readMtf();
				api.addModule(currentModule);
			case IMP:
				if (typingMode == FullTyping) readImports();
			case CLR:
				readClr();
			case ENR:
				readEnr();
			case ABR:
				readAbr();
			case TDR:
				readTdr();
			case OFR:
				readOfr();
			case OFD:
				readOfd();
			case OBD:
				readObd();
			case CLD:
				readCld();
			case END:
				readEnd();
			case ABD:
				readAbd();
			case TDD:
				readTdd();
			case EOT:
			case EFR:
				readEfr();
			case CFR:
				readCfr();
			case CFD:
				readCfd();
			case EFD:
				readEfd();
			case AFD:
				readAfd();
			case EOF:
			case EXD:
				readExd();
			case EOM:
				stats.modulesFullyRestored++;
		}
	}

	function failwith(chunk:ChunkKind, msg:String, backtrace:String):Dynamic {
		var msg = 'Compiler failure while reading hxb chunk ${HxbData.stringOfChunkKind(chunk)} of ${Globals.sTypePath(mpath)}: ${msg}\n'
			+ "Please submit an issue at https://github.com/HaxeFoundation/haxe/issues/new\n"
			+ "Attach the following information:";
		throw new core.Globals.InternalCompilerError(msg, backtrace);
	}

	function readChunkData(kind:ChunkKind):Void {
		var path = Globals.sTypePath(mpath).split(".").join("_");
		var id = ["hxb", "read", HxbData.stringOfChunkKind(kind), path];
		var close = if (timerCtx != null) Timer.startTimer(timerCtx, id) else function() {};
		try {
			readChunkDataPrime(kind);
		} catch (e:InvalidArgument) {
			close();
			failwith(kind, e.message, haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
		}
		close();
	}

	public function readChunks(newApi:HxbReaderApi, chunks:CachedChunks):ModuleDef {
		return readChunksUntil(newApi, chunks, EOM, FullTyping).m;
	}

	public function readChunksUntil(newApi:HxbReaderApi, chunks:CachedChunks, endChunk:ChunkKind,
			typingMode_:TypingMode):{m:ModuleDef, remaining:CachedChunks} {
		api = newApi;
		typingMode = typingMode_;
		var i = 0;
		while (true) {
			if (i >= chunks.length) Globals.die("", "hxbReader.ml read_chunks_until");
			var chunk = chunks[i++];
			ch = BytesWithPosition.create(chunk.data);
			readChunkData(chunk.kind);
			if (chunk.kind == endChunk) break;
		}
		return {m: currentModule, remaining: chunks.slice(i)};
	}

	public function read(newApi:HxbReaderApi, bytes:Bytes):ChunkKind->ModuleDef {
		api = newApi;
		typingMode = FullTyping;
		ch = BytesWithPosition.create(bytes);
		if (BytesWithPosition.readBytes(ch, 3).toString() != "hxb") throw new HxbFailure("magic");
		var version = readByte();
		if (version != HxbData.VERSION) throw new HxbFailure('version mismatch: hxb version $version, reader version ${HxbData.VERSION}');
		return function(endChunk:ChunkKind) {
			while (true) {
				var prefix = readChunkPrefix();
				var kind = HxbData.chunkKindOfString(prefix.name);
				readChunkData(kind);
				if (kind == endChunk) break;
			}
			return currentModule;
		};
	}
}
