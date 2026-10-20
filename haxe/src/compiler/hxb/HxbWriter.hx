package compiler.hxb;

import core.Ast;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.TOther.ExtType;
import core.TUnification.Monomorph;
import core.TUnification.Unify_error;
import core.MetaList.StrictMeta;
import core.ds.StringPool;
import core.ds.StringDynArray;
import core.ds.NotFound;
import compiler.hxb.HxbData.ChunkKind;
import compiler.hxb.HxbWriterConfig.WriterTargetConfig;
import typing.TanonIdentification;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import String as StdString;

// port: representation differences:
// - OCaml effects (UnboundTTP / UnboundTTPWithoutPosition) are modelled with an
//   explicit handler stack, see catchUnboundTtp / performUnboundTtp.
// - PMap iteration order (ascending OCaml string/int compare) is reproduced by
//   sorting the keys of the port's hash maps.
// - PosWriter compares file names with StrTools.physNeq, which falls back to
//   structural comparison on hosts without string identity.

function binopIndex(op:Binop):Int return switch op {
	case OpAdd: 0;
	case OpMult: 1;
	case OpDiv: 2;
	case OpSub: 3;
	case OpAssign: 4;
	case OpEq: 5;
	case OpNotEq: 6;
	case OpGt: 7;
	case OpGte: 8;
	case OpLt: 9;
	case OpLte: 10;
	case OpAnd: 11;
	case OpOr: 12;
	case OpXor: 13;
	case OpBoolAnd: 14;
	case OpBoolOr: 15;
	case OpShl: 16;
	case OpShr: 17;
	case OpUShr: 18;
	case OpMod: 19;
	case OpInterval: 20;
	case OpArrow: 21;
	case OpIn: 22;
	case OpNullCoal: 23;
	case OpAssignOp(op): 30 + binopIndex(op);
}

function unopIndex(op:Unop, flag:UnopFlag):Int return switch [op, flag] {
	case [Increment, Prefix]: 0;
	case [Decrement, Prefix]: 1;
	case [Not, Prefix]: 2;
	case [Neg, Prefix]: 3;
	case [NegBits, Prefix]: 4;
	case [Spread, Prefix]: 5;
	case [Increment, Postfix]: 6;
	case [Decrement, Postfix]: 7;
	case [Not, Postfix]: 8;
	case [Neg, Postfix]: 9;
	case [NegBits, Postfix]: 10;
	case [Spread, Postfix]: 11;
}

// port: OCaml `compare` on strings: byte-wise lexicographic. Code point order is
// identical to UTF-8 byte order.
function compareOcamlString(a:String, b:String):Int return core.ds.Key.compareStrings(a, b);

// port: keys of a PMap-backed string map, in PMap (ascending) order.
function sortedKeys<V>(m:haxe.ds.StringMap<V>):Array<String> {
	var keys = [for (k in m.keys()) k];
	keys.sort(compareOcamlString);
	return keys;
}

function pathKey(path:GlobalTypePath):String return path.hashKey();

class Pool<K, V> {
	final lut:Map<String, Int> = new Map();

	public final items:Array<V> = [];

	var closed = false;
	final key:K->String;

	public function new(key:K->String) this.key = key;

	public function add(k:K, value:V):Int {
		if (closed) throw "assert: pool closed";
		var index = items.length;
		items.push(value);
		lut.set(key(k), index);
		return index;
	}

	public function get(k:K):Int {
		var i = lut.get(key(k));
		if (i == null) throw NotFound.raise();
		return i;
	}

	public function extract(k:K):V return items[get(k)];

	public function has(k:K):Bool return lut.exists(key(k));

	public function getOrAdd(k:K, value:V):Int {
		var i = lut.get(key(k));
		return i != null ? i : add(k, value);
	}

	public function isEmpty():Bool return items.length == 0;

	public function advance(dummy:V):Void items.push(dummy);

	public function finalize():Array<V> {
		if (closed) throw "assert: pool closed";
		closed = true;
		return items;
	}
}

class IdentityPool<K, V> {
	public final items:Array<{key:K, value:V}> = [];

	var closed = false;

	public function new() {}

	public function add(key:K, value:V):Int {
		if (closed) throw "assert: pool closed";
		var index = items.length;
		items.push({key: key, value: value});
		return index;
	}

	public function get(key:K):Int {
		for (i in 0...items.length) if (items[i].key == key) return i;
		throw NotFound.raise();
	}

	public function getOrAdd(key:K, value:V):Int {
		for (i in 0...items.length) if (items[i].key == key) return i;
		return add(key, value);
	}

	public function toList():Array<{key:K, value:V}> return items.copy();

	public function finalize():Array<{key:K, value:V}> {
		if (closed) throw "assert: pool closed";
		closed = true;
		return items;
	}

	public function length():Int return items.length;
}

class HashedIdentityPool<K, V> {
	final lut:Map<String, Array<{key:K, index:Int}>> = new Map();

	public final items:Array<{key:K, value:V}> = [];

	var closed = false;

	public function new() {}

	public function add(hkey:String, key:K, value:V):Int {
		if (closed) throw "assert: pool closed";
		var index = items.length;
		items.push({key: key, value: value});
		var l = lut.get(hkey);
		if (l == null) lut.set(hkey, l = []);
		l.unshift({key: key, index: index});
		return index;
	}

	public function get(hkey:String, key:K):Int {
		var l = lut.get(hkey);
		if (l != null) for (e in l) if (e.key == key) return e.index;
		throw NotFound.raise();
	}

	public function finalize():Array<{key:K, value:V}> {
		if (closed) throw "assert: pool closed";
		closed = true;
		return items;
	}
}

// port: pool of binary type-instance encodings (StringPool over Bytes.unsafe_to_string upstream).
// Keyed by a content hash with byte comparison, rather than a hex string key
// allocated twice per lookup.
class BytesPool {
	final lut:Map<Int, Array<Int>> = new Map();

	public final items:Array<Bytes> = [];

	public function new() {}

	public function getOrAdd(b:Bytes):Int {
		var h = 0x811C9DC5;
		for (i in 0...b.length) h = (h ^ b.get(i)) * 0x01000193;
		var bucket = lut.get(h);
		if (bucket == null) {
			bucket = [];
			lut.set(h, bucket);
		} else
			for (i in bucket) if (items[i].compare(b) == 0) return i;
		var i = items.length;
		items.push(b);
		bucket.push(i);
		return i;
	}
}

// port: SimnBuffer equivalent: a growable byte buffer whose contents can be read repeatedly.
class ByteBuffer {
	var buffer:Bytes;

	public var length(default, null):Int = 0;

	public function new(size:Int) buffer = Bytes.alloc(size < 16 ? 16 : size);

	inline function ensure(n:Int):Void {
		if (length + n > buffer.length) {
			var size = buffer.length * 2;
			while (size < length + n) size *= 2;
			var nb = Bytes.alloc(size);
			nb.blit(0, buffer, 0, length);
			buffer = nb;
		}
	}

	public function reset():Void length = 0;

	public function addU8(i:Int):Void {
		ensure(1);
		buffer.set(length++, i & 0xFF);
	}

	public function addBytes(b:Bytes):Void {
		ensure(b.length);
		buffer.blit(length, b, 0, b.length);
		length += b.length;
	}

	public function contents():Bytes return buffer.sub(0, length);
}

class Chunk {
	public final kind:ChunkKind;
	public final cp:StringPool;

	final ch:ByteBuffer;

	public function new(kind:ChunkKind, cp:StringPool, initialSize:Int) {
		this.kind = kind;
		this.cp = cp;
		ch = new ByteBuffer(initialSize);
	}

	public function reset():Void ch.reset();

	public function writeU8(v:Int):Void ch.addU8(v);

	public function writeI32(v:Int):Void {
		writeU8(v);
		writeU8(v >>> 8);
		writeU8(v >>> 16);
		writeU8(v >>> 24);
	}

	public function writeI64(v:haxe.Int64):Void {
		writeI32(v.low);
		writeI32(v.high);
	}

	public function writeF64(v:Float):Void writeI64(haxe.io.FPHelper.doubleToI64(v));

	public function writeBytes(b:Bytes):Void ch.addBytes(b);

	public function writeUi16(i:Int):Void {
		writeU8(i);
		writeU8(i >>> 8);
	}

	public function getBytes():Bytes return ch.contents();

	public function writeUleb128(v:Int):Void {
		var b = v & 0x7F;
		var rest = v >>> 7;
		if (rest == 0) writeU8(b)
		else {
			writeU8(b | 0x80);
			writeUleb128(rest);
		}
	}

	public function writeLeb128(v:Int):Void {
		var b = v & 0x7F;
		var rest = v >> 7;
		if ((rest == 0 && (b & 0x40 == 0)) || (rest == -1 && (b & 0x40 == 0x40))) writeU8(b)
		else {
			writeU8(b | 0x80);
			writeLeb128(rest);
		}
	}

	public function writeBytesLengthPrefixed(b:Bytes):Void {
		writeUleb128(b.length);
		writeBytes(b);
	}

	public function writeBool(b:Bool):Void writeU8(b ? 1 : 0);

	public function export(chex:BytesOutput):Void {
		var bytes = getBytes();
		HxbData.writeChunkPrefix(kind, bytes.length, chex);
		chex.writeBytes(bytes, 0, bytes.length);
	}

	public function writeString(s:String):Void writeUleb128(cp.getOrAdd(s));

	// port: inline: see core.ds.List (HashLink boxes Array<B> of a type parameter)
	public inline function writeList<B>(l:Array<B>, f:B->Void):Void {
		writeUleb128(l.length);
		for (x in l) f(x);
	}

	// port: write_dynarray is writeList: DynArray and list are both Array.

	public function writeOption<B>(v:Null<B>, f:B->Void):Void {
		if (v == null) writeU8(0)
		else {
			writeU8(1);
			f(v);
		}
	}

	public function exportData(chunkTo:Chunk):Void chunkTo.writeBytes(getBytes());
}

class PosWriter {
	public var pFile:String;
	public var pMin:Int;
	public var pMax:Int;

	function new(p:Pos) {
		pFile = p.pfile;
		pMin = p.pmin;
		pMax = p.pmax;
	}

	public static function doWritePos(chunk:Chunk, p:Pos):Void {
		chunk.writeString(p.pfile);
		chunk.writeLeb128(p.pmin);
		chunk.writeLeb128(p.pmax);
	}

	public static function create(chunk:Chunk, p:Pos):PosWriter {
		doWritePos(chunk, p);
		return new PosWriter(p);
	}

	public function writePos(chunk:Chunk, writeEqual:Bool, offset:Int, p:Pos):Void {
		if (core.ds.StrTools.physNeq(p.pfile, pFile)) {
			// File changed, write full pos
			chunk.writeU8(4 + offset);
			doWritePos(chunk, p);
			pFile = p.pfile;
			pMin = p.pmin;
			pMax = p.pmax;
		} else if (p.pmin != pMin) {
			if (p.pmax != pMax) {
				// pmin and pmax changed
				chunk.writeU8(3 + offset);
				chunk.writeLeb128(p.pmin);
				chunk.writeLeb128(p.pmax);
				pMin = p.pmin;
				pMax = p.pmax;
			} else {
				// pmin changed
				chunk.writeU8(1 + offset);
				chunk.writeLeb128(p.pmin);
				pMin = p.pmin;
			}
		} else if (p.pmax != pMax) {
			// pmax changed
			chunk.writeU8(2 + offset);
			chunk.writeLeb128(p.pmax);
			pMax = p.pmax;
		} else {
			if (writeEqual) chunk.writeU8(offset);
		}
	}
}

@:structInit class FieldWriterContext {
	public var tPool:BytesPool;
	public var posWriter:PosWriter;
	public var texprThis:Null<TExpr>;
	public var vars:Array<{v:TVar, id:Int}>;

	public inline function new(tPool:BytesPool, posWriter:PosWriter, texprThis:Null<TExpr>, vars:Array<{v:TVar, id:Int}>) {
		this.tPool = tPool;
		this.posWriter = posWriter;
		this.texprThis = texprThis;
		this.vars = vars;
	}

	public inline function clone():FieldWriterContext return new FieldWriterContext(tPool, posWriter, texprThis, vars);
}

typedef ExprChunks = {pre:Chunk, e:Chunk};

// port: a class rather than a structure: HashLink accesses structures through
// virtual tables (a conversion per pop).
@:structInit private class UnboundFrame {
	public final source:Void->String;
	public final p:Null<Pos>;

	public inline function new(source:Void->String, p:Null<Pos>) {
		this.source = source;
		this.p = p;
	}
}

class HxbWriter {
	final config:WriterTargetConfig;
	final warn:(warning:core.Message.WarningCode, msg:String, p:Pos) -> Void;
	final anonId:TanonIdentification<Dynamic>;
	final identifiedAnons:IdentityPool<TAnon, Int> = new IdentityPool();
	var currentModule:ModuleDef = TFunctions.nullModule;
	final chunks:Array<Chunk> = [];
	final cp:StringPool = new StringPool();
	final docs:StringPool = new StringPool();
	var chunk:Chunk = null;

	final classes:Pool<GlobalTypePath, TClass> = new Pool(pathKey);
	final enums:Pool<GlobalTypePath, TEnum> = new Pool(pathKey);
	final typedefs:Pool<GlobalTypePath, TDef> = new Pool(pathKey);
	final abstracts:Pool<GlobalTypePath, TAbstract> = new Pool(pathKey);
	final anons:Pool<GlobalTypePath, Null<Bytes>> = new Pool(pathKey);
	final anonFields:HashedIdentityPool<TClassField, Null<Bytes>> = new HashedIdentityPool();
	final tmonos:IdentityPool<TMono, Bool> = new IdentityPool();

	final ownClasses:Pool<GlobalTypePath, TClass> = new Pool(pathKey);
	final ownEnums:Pool<GlobalTypePath, TEnum> = new Pool(pathKey);
	final ownTypedefs:Pool<GlobalTypePath, TDef> = new Pool(pathKey);
	final ownAbstracts:Pool<GlobalTypePath, TAbstract> = new Pool(pathKey);
	final typeParamLut:Pool<GlobalTypePath, Pool<String, TypedTypeParam>> = new Pool(pathKey);
	final classFields:HashedIdentityPool<TClassField, {c:TClass, kind:ClassFieldRefKind, depth:Int}> = new HashedIdentityPool();
	final enumFields:Pool<{path:GlobalTypePath, name:String},
		{en:TEnum, ef:TEnumField}> = new Pool(function(k:{path:GlobalTypePath, name:String}) return pathKey(k.path)
		+ "#" + k.name);
	var typeTypeParameters:Pool<String, TypedTypeParam> = new Pool(function(s) return s);
	var fieldTypeParameters:IdentityPool<TypedTypeParam, Bool> = new IdentityPool();
	var localTypeParameters:IdentityPool<TypedTypeParam, Bool> = new IdentityPool();
	var fieldStack:Int = 0;
	var wroteLocalTypeParam = false;
	var needsLocalContext = false;
	final unboundTtp:IdentityPool<TypedTypeParam, Bool> = new IdentityPool();
	final unclosedMono:IdentityPool<TMono, Bool> = new IdentityPool();
	final tInstanceChunk:Chunk;
	final unboundFrames:Array<UnboundFrame> = [];

	// port: create config warn anon_id; the defaults serve the legacy bootstrap entry.
	public function new(?config:WriterTargetConfig, ?warn:(warning:core.Message.WarningCode, msg:String, p:Pos) -> Void,
			?anonId:TanonIdentification<Dynamic>) {
		this.config = config != null ? config : new WriterTargetConfig();
		this.warn = warn != null ? warn : function(_, _, _) {};
		this.anonId = anonId != null ? anonId : new TanonIdentification();
		tInstanceChunk = new Chunk(EOM, cp, 32);
	}

	// port: get_backtrace/get_callstack: the host call stack stands in for Printexc's.
	static function getCallstack():String return haxe.CallStack.toString(haxe.CallStack.callStack());

	static function failwith(writer:HxbWriter, msg:String, backtrace:String):Dynamic {
		var msg = ("Compiler failure while writing hxb chunk " + HxbData.stringOfChunkKind(writer.chunk.kind) + " of "
			+ core.Globals.sTypePath(writer.currentModule.mPath) + ": " + msg + "\n")
			+ "Please submit an issue at https://github.com/HaxeFoundation/haxe/issues/new\n"
			+ "Attach the following information:";
		throw new core.Globals.InternalCompilerError(msg, backtrace);
	}

	// fieldStack == 0 (an empty field stack) can happen for cl_init and in EXD
	function inNestedScope():Bool return fieldStack > 1;

	// port: effects

	function moduleFilePos():Pos return core.Globals.filePos(moduleFile(currentModule));

	static function moduleFile(m:ModuleDef):String {
		return core.Path.UniqueKey.lazyPath(m.mExtra.mFile);
	}

	function catchUnboundTtp<R>(f:Void->R, source:Void->String, p:Null<Pos>):R {
		unboundFrames.push({source: source, p: p});
		var r;
		try r = f()
		catch (e:haxe.Exception) {
			unboundFrames.pop();
			throw e;
		}
		unboundFrames.pop();
		return r;
	}

	// port: catchUnboundTtp(() -> writeTexprTypeInstance(fctx, e.etype), () -> "texpr type", e.epos)
	// without a closure per expression node.
	static function texprTypeSource():String return "texpr type";

	function writeTexprTypeInstanceCatching(fctx:FieldWriterContext, e:TExpr):Void {
		unboundFrames.push({source: texprTypeSource, p: e.epos});
		try writeTexprTypeInstance(fctx, e.etype)
		catch (ex:haxe.Exception) {
			unboundFrames.pop();
			throw ex;
		}
		unboundFrames.pop();
	}

	function performUnboundTtp():{source:String, p:Pos} {
		var n = unboundFrames.length;
		if (n == 0) return {source: "module " + core.Globals.sTypePath(currentModule.mPath), p: moduleFilePos()};
		var source = unboundFrames[n - 1].source();
		var i = n - 1;
		while (i >= 0) {
			var p = unboundFrames[i].p;
			if (p != null) return {source: source, p: p};
			i--;
		}
		return {source: source, p: moduleFilePos()};
	}

	// Chunks

	function startChunk(kind:ChunkKind):Void {
		var initialSize = switch kind {
			case EOT | EOF | EOM: 0;
			case MDF: 16;
			case MTF | IMP | CLR | END | ABD | ENR | ABR | TDR | EFR | CFR | AFD: 64;
			case OFR | OFD | OBD | CLD | TDD | EFD: 128;
			case STR | DOC: 256;
			case CFD | EXD: 512;
		};
		var newChunk = new Chunk(kind, cp, initialSize);
		chunks.push(newChunk);
		chunk = newChunk;
	}

	function startTemporaryChunk<A>(initialSize:Int):(Chunk->A)->A {
		var newChunk = new Chunk(EOM, /* TODO: something else? */ cp, initialSize);
		var oldChunk = chunk;
		chunk = newChunk;
		return function(f) {
			chunk = oldChunk;
			return f(newChunk);
		};
	}

	inline function writeInlinedList<A>(offset:Int, max:Int, fByte:Int->Void, fFirst:Void->Void, fElt:A->Void, l:Array<A>):Void {
		var length = l.length;
		if (length > max) {
			fByte(offset + 9);
			fFirst();
			chunk.writeList(l, fElt);
		} else {
			fByte(offset + length);
			fFirst();
			for (elt in l) fElt(elt);
		}
	}

	// Basic compounds

	function writePath(path:GlobalTypePath):Void {
		chunk.writeList(path.pack, chunk.writeString);
		chunk.writeString(path.name);
	}

	function writeFullPath(pack:Array<String>, mname:String, tname:String):Void {
		chunk.writeList(pack, chunk.writeString);
		if (mname == "" || tname == "") failwith(this, 'write_full_path: pack = ${pack.join(".")}, mname = $mname, tname = $tname', getCallstack());
		chunk.writeString(mname);
		chunk.writeString(tname);
	}

	function maybeWriteDocumentation(doc:Documentation):Void {
		if (doc != null && config.generateDocs) {
			chunk.writeU8(1);
			chunk.writeOption(doc.docOwn, function(s) chunk.writeUleb128(docs.getOrAdd(s)));
			chunk.writeList(doc.docInherited, function(s) chunk.writeUleb128(docs.getOrAdd(s)));
		} else chunk.writeU8(0);
	}

	function writePos(p:Pos):Void {
		chunk.writeString(p.pfile);
		chunk.writeLeb128(p.pmin);
		chunk.writeLeb128(p.pmax);
	}

	function writePosPair(p1:Pos, p2:Pos):Void {
		// Write second position offset relative to first position's pmin, which is often within 1 byte range.
		chunk.writeString(p1.pfile);
		chunk.writeLeb128(p1.pmin);
		chunk.writeLeb128(p1.pmax);
		chunk.writeLeb128(p2.pmin - p1.pmin);
		chunk.writeLeb128(p2.pmax - p1.pmin);
	}

	// port: Meta.to_string; the port's MetadataEntry.meta is Dynamic and may also hold a plain name string.
	static function metadataName(value:Dynamic):String {
		if (Std.isOfType(value, StdString)) {
			var name:String = value;
			return StringTools.startsWith(name, ":") ? name : ":" + name;
		}
		return core.Meta.toString(cast value);
	}

	function writeMetadataEntry(entry:MetadataEntry):Void {
		chunk.writeString(metadataName(entry.meta));
		writePos(entry.pos);
		chunk.writeList(entry.exprs, writeExpr);
	}

	function writeMetadata(ml:Metadata):Void chunk.writeList(ml, writeMetadataEntry);

	// expr

	function writeObjectFieldKey(k:{name:String, pos:Pos, quote:QuoteStatus}):Void {
		chunk.writeString(k.name);
		writePos(k.pos);
		switch k.quote {
			case NoQuotes:
				chunk.writeU8(0);
			case DoubleQuotes:
				chunk.writeU8(1);
		}
	}

	function writeTypePath(tp:TypePath):Void {
		chunk.writeList(tp.tpackage, chunk.writeString);
		chunk.writeString(tp.tname);
		chunk.writeList(tp.tparams, writeTypeParamOrConst);
		chunk.writeOption(tp.tsub, chunk.writeString);
	}

	function writePlacedTypePath(ptp:PlacedTypePath):Void {
		writeTypePath(ptp.path);
		writePosPair(ptp.posFull, ptp.posPath);
	}

	function writeTypeParamOrConst(tpc:TypeParamOrConst):Void switch tpc {
		case TPType(th):
			chunk.writeU8(0);
			writeTypeHint(th);
		case TPExpr(e):
			chunk.writeU8(1);
			writeExpr(e);
	}

	function writeComplexType(ct:ComplexType):Void switch ct {
		case CTPath(tp):
			chunk.writeU8(0);
			writePlacedTypePath(tp);
		case CTFunction(thl, th):
			chunk.writeU8(1);
			chunk.writeList(thl, writeTypeHint);
			writeTypeHint(th);
		case CTAnonymous(cffl):
			chunk.writeU8(2);
			chunk.writeList(cffl, writeCfield);
		case CTParent(th):
			chunk.writeU8(3);
			writeTypeHint(th);
		case CTExtend(ptp, cffl):
			chunk.writeU8(4);
			chunk.writeList(ptp, writePlacedTypePath);
			chunk.writeList(cffl, writeCfield);
		case CTOptional(th):
			chunk.writeU8(5);
			writeTypeHint(th);
		case CTNamed(pn, th):
			chunk.writeU8(6);
			writePlacedName(pn);
			writeTypeHint(th);
		case CTIntersection(thl):
			chunk.writeU8(7);
			chunk.writeList(thl, writeTypeHint);
	}

	function writeTypeHint(th:TypeHint):Void {
		writeComplexType(th.type);
		writePos(th.pos);
	}

	function writeTypeParam(tp:TypeParam):Void {
		writePlacedName(tp.tpName);
		chunk.writeList(tp.tpParams, writeTypeParam);
		chunk.writeOption(tp.tpConstraints, writeTypeHint);
		chunk.writeOption(tp.tpDefault, writeTypeHint);
		chunk.writeList(tp.tpMeta, writeMetadataEntry);
	}

	function writeFuncArg(a:FuncArg):Void {
		writePlacedName(a.name);
		chunk.writeBool(a.optional);
		writeMetadata(a.meta);
		chunk.writeOption(a.type, writeTypeHint);
		chunk.writeOption(a.expr, writeExpr);
	}

	function writeFunc(f:Func):Void {
		chunk.writeList(f.fParams, writeTypeParam);
		chunk.writeList(f.fArgs, writeFuncArg);
		chunk.writeOption(f.fType, writeTypeHint);
		chunk.writeOption(f.fExpr, writeExpr);
	}

	function writePlacedName(pn:PlacedName):Void {
		chunk.writeString(pn.name);
		writePos(pn.pos);
	}

	function writeAccess(ac:Access):Void {
		var i = switch ac {
			case APublic: 0;
			case APrivate: 1;
			case AStatic: 2;
			case AOverride: 3;
			case ADynamic: 4;
			case AInline: 5;
			case AMacro: 6;
			case AFinal: 7;
			case AExtern: 8;
			case AAbstract: 9;
			case AOverload: 10;
			case AEnum: 11;
		};
		chunk.writeU8(i);
	}

	function writePlacedAccess(pa:PlacedAccess):Void {
		writeAccess(pa.access);
		writePos(pa.pos);
	}

	function writeCfieldKind(k:ClassFieldKind):Void switch k {
		case FVar(tho, eo):
			chunk.writeU8(0);
			chunk.writeOption(tho, writeTypeHint);
			chunk.writeOption(eo, writeExpr);
		case FFun(f):
			chunk.writeU8(1);
			writeFunc(f);
		case FProp(pn1, pn2, tho, eo):
			chunk.writeU8(2);
			writePlacedName(pn1);
			writePlacedName(pn2);
			chunk.writeOption(tho, writeTypeHint);
			chunk.writeOption(eo, writeExpr);
	}

	function writeCfield(cff:ClassField):Void {
		writePlacedName(cff.cffName);
		maybeWriteDocumentation(cff.cffDoc);
		writePos(cff.cffPos);
		writeMetadata(cff.cffMeta);
		chunk.writeList(cff.cffAccess, writePlacedAccess);
		writeCfieldKind(cff.cffKind);
	}

	function writeExpr(e:Expr):Void {
		writePos(e.pos);
		switch e.expr {
			case EConst(Int(s, suffix)):
				chunk.writeU8(0);
				chunk.writeString(s);
				chunk.writeOption(suffix, chunk.writeString);
			case EConst(Float(s, suffix)):
				chunk.writeU8(1);
				chunk.writeString(s);
				chunk.writeOption(suffix, chunk.writeString);
			case EConst(String(s, qs)):
				chunk.writeU8(2);
				chunk.writeString(s);
				switch qs {
					case SDoubleQuotes: chunk.writeU8(0);
					case SSingleQuotes: chunk.writeU8(1);
				}
			case EConst(Ident(s)):
				chunk.writeU8(3);
				chunk.writeString(s);
			case EConst(Regexp(s1, s2)):
				chunk.writeU8(4);
				chunk.writeString(s1);
				chunk.writeString(s2);
			case EArray(e1, e2):
				chunk.writeU8(5);
				writeExpr(e1);
				writeExpr(e2);
			case EBinop(op, e1, e2):
				chunk.writeU8(6);
				chunk.writeU8(binopIndex(op));
				writeExpr(e1);
				writeExpr(e2);
			case EField(e1, s, kind):
				chunk.writeU8(7);
				writeExpr(e1);
				chunk.writeString(s);
				switch kind {
					case EFNormal: chunk.writeU8(0);
					case EFSafe: chunk.writeU8(1);
				}
			case EParenthesis(e1):
				chunk.writeU8(8);
				writeExpr(e1);
			case EObjectDecl(fl):
				chunk.writeU8(9);
				chunk.writeList(fl, function(f) {
					writeObjectFieldKey(f.key);
					writeExpr(f.expr);
				});
			case EArrayDecl(el):
				chunk.writeU8(10);
				chunk.writeList(el, writeExpr);
			case ECall(e1, el):
				chunk.writeU8(11);
				writeExpr(e1);
				chunk.writeList(el, writeExpr);
			case ENew(ptp, el):
				chunk.writeU8(12);
				writePlacedTypePath(ptp);
				chunk.writeList(el, writeExpr);
			case EUnop(op, flag, e1):
				chunk.writeU8(13);
				chunk.writeU8(unopIndex(op, flag));
				writeExpr(e1);
			case EVars(vl):
				chunk.writeU8(14);
				chunk.writeList(vl, function(v) {
					writePlacedName(v.evName);
					chunk.writeBool(v.evFinal);
					chunk.writeBool(v.evStatic);
					chunk.writeOption(v.evType, writeTypeHint);
					chunk.writeOption(v.evExpr, writeExpr);
					writeMetadata(v.evMeta);
				});
			case EFunction(fk, f):
				chunk.writeU8(15);
				switch fk {
					case FKAnonymous: chunk.writeU8(0);
					case FKNamed(pn, inl):
						chunk.writeU8(1);
						writePlacedName(pn);
						chunk.writeBool(inl);
					case FKArrow: chunk.writeU8(2);
				}
				writeFunc(f);
			case EBlock(el):
				chunk.writeU8(16);
				chunk.writeList(el, writeExpr);
			case EFor(e1, e2):
				chunk.writeU8(17);
				writeExpr(e1);
				writeExpr(e2);
			case EIf(e1, e2, null):
				chunk.writeU8(18);
				writeExpr(e1);
				writeExpr(e2);
			case EIf(e1, e2, e3):
				chunk.writeU8(19);
				writeExpr(e1);
				writeExpr(e2);
				writeExpr(e3);
			case EWhile(e1, e2, NormalWhile):
				chunk.writeU8(20);
				writeExpr(e1);
				writeExpr(e2);
			case EWhile(e1, e2, DoWhile):
				chunk.writeU8(21);
				writeExpr(e1);
				writeExpr(e2);
			case ESwitch(e1, cases, def):
				chunk.writeU8(22);
				writeExpr(e1);
				chunk.writeList(cases, function(c) {
					chunk.writeList(c.values, writeExpr);
					chunk.writeOption(c.guard, writeExpr);
					chunk.writeOption(c.expr, writeExpr);
					writePos(c.pos);
				});
				chunk.writeOption(def, function(d) {
					chunk.writeOption(d.expr, writeExpr);
					writePos(d.pos);
				});
			case ETry(e1, catches):
				chunk.writeU8(23);
				writeExpr(e1);
				chunk.writeList(catches, function(c) {
					writePlacedName(c.name);
					chunk.writeOption(c.type, writeTypeHint);
					writeExpr(c.expr);
					writePos(c.pos);
				});
			case EReturn(null):
				chunk.writeU8(24);
			case EReturn(e1):
				chunk.writeU8(25);
				writeExpr(e1);
			case EBreak:
				chunk.writeU8(26);
			case EContinue:
				chunk.writeU8(27);
			case EUntyped(e1):
				chunk.writeU8(28);
				writeExpr(e1);
			case EThrow(e1):
				chunk.writeU8(29);
				writeExpr(e1);
			case ECast(e1, null):
				chunk.writeU8(30);
				writeExpr(e1);
			case ECast(e1, th):
				chunk.writeU8(31);
				writeExpr(e1);
				writeTypeHint(th);
			case EIs(e1, th):
				chunk.writeU8(32);
				writeExpr(e1);
				writeTypeHint(th);
			case EDisplay(e1, dk):
				chunk.writeU8(33);
				writeExpr(e1);
				switch dk {
					case DKCall: chunk.writeU8(0);
					case DKDot: chunk.writeU8(1);
					case DKStructure: chunk.writeU8(2);
					case DKMarked: chunk.writeU8(3);
					case DKPattern(b):
						chunk.writeU8(4);
						chunk.writeBool(b);
				}
			case ETernary(e1, e2, e3):
				chunk.writeU8(34);
				writeExpr(e1);
				writeExpr(e2);
				writeExpr(e3);
			case ECheckType(e1, th):
				chunk.writeU8(35);
				writeExpr(e1);
				writeTypeHint(th);
			case EMeta(m, e1):
				chunk.writeU8(36);
				writeMetadataEntry(m);
				writeExpr(e1);
		}
	}

	// References

	function writeClassRef(c:TClass):Void chunk.writeUleb128(classes.getOrAdd(c.clPath, c));

	function writeEnumRef(en:TEnum):Void chunk.writeUleb128(enums.getOrAdd(en.ePath, en));

	function writeTypedefRef(td:TDef):Void chunk.writeUleb128(typedefs.getOrAdd(td.tPath, td));

	function writeAbstractRef(a:TAbstract):Void chunk.writeUleb128(abstracts.getOrAdd(a.aPath, a));

	function writeTmonoRef(mono:TMono):Void chunk.writeUleb128(tmonos.getOrAdd(mono, true));

	function writeFieldRef(c:TClass, kind:ClassFieldRefKind, cf:TClassField):Void {
		var index = try classFields.get(cf.cfName, cf) catch (_:NotFound) {
			function findOverloadBase(c:TClass, cfBase:TClassField):Null<{c:TClass, depth:Int}> {
				var cfl = [cfBase].concat(cfBase.cfOverloads);
				for (depth in 0...cfl.length) if (cfl[depth] == cf) return {c: c, depth: depth};
				return null;
			}
			function findOverload(c:TClass):Null<{c:TClass, depth:Int}> {
				return try findOverloadBase(c, TFunctions.findField(c, cf.cfName, kind)) catch (_:NotFound) null;
			}
			var r = switch kind {
				case CfrStatic | CfrConstructor:
					findOverload(c);
				case CfrInit:
					{c: c, depth: 0};
				case CfrMember:
					// For member overloads we need to find the correct class, which is a mess.
					function loop(c:TClass):Null<{c:TClass, depth:Int}> {
						var r = findOverload(c);
						if (r != null) return r;
						if (TFunctions.hasClassFlag(c, CInterface)) {
							for (i in c.clImplements) {
								var r = loop(i.cls);
								if (r != null) return r;
							}
							return null;
						} else if (c.clSuper != null) {
							return loop(c.clSuper.cls);
						} else return null;
					}
					loop(c);
			};
			var cd = if (r == null) {
				Sys.println('Could not resolve ${core.TPrinting.sClassFieldRefKind(kind)} overload for ${cf.cfName} on ${core.Globals.sTypePath(c.clPath)}');
				{c: c, depth: 0};
			} else r;
			classFields.add(cf.cfName, cf, {c: cd.c, kind: kind, depth: cd.depth});
		};
		chunk.writeUleb128(index);
	}

	function writeEnumFieldRef(en:TEnum, ef:TEnumField):Void {
		var key = {path: en.ePath, name: ef.efName};
		try chunk.writeUleb128(enumFields.get(key))
		catch (_:NotFound) {
			enums.getOrAdd(en.ePath, en);
			chunk.writeUleb128(enumFields.add(key, {en: en, ef: ef}));
		}
	}

	function writeVarKind(vk:TVarKind):Void {
		var b = 0, sl:Array<String> = [];
		switch vk {
			case VUser(TVOLocalVariable):
				b = 0;
			case VUser(TVOArgument):
				b = 1;
			case VUser(TVOForVariable):
				b = 2;
			case VUser(TVOPatternVariable):
				b = 3;
			case VUser(TVOCatchVariable):
				b = 4;
			case VUser(TVOLocalFunction):
				b = 5;
			case VGenerated:
				b = 6;
			case VInlined:
				b = 7;
			case VInlinedConstructorVariable(l):
				b = 8;
				sl = l;
			case VExtractorVariable:
				b = 9;
			case VAbstractThis:
				b = 10;
		}
		chunk.writeU8(b);
		if (b == 8) chunk.writeList(sl, chunk.writeString);
	}

	function writeVar(fctx:FieldWriterContext, v:TVar):Void {
		chunk.writeUleb128(v.vId);
		chunk.writeString(v.vName);
		writeVarKind(v.vKind);
		chunk.writeUleb128(v.vFlags);
		writeMetadata(v.vMeta);
		writePos(v.vPos);
	}

	function writeAnon(an:TAnon):Void {
		inline function writeFields() {
			var restore = startTemporaryChunk(256);
			var i = 0;
			for (k in sortedKeys(an.aFields)) {
				writeAnonFieldRef(an.aFields.get(k));
				i++;
			}
			var bytes = restore(function(newChunk) return newChunk.getBytes());
			chunk.writeUleb128(i);
			chunk.writeBytes(bytes);
		}
		switch an.aStatus {
			case Closed:
				chunk.writeU8(0);
				writeFields();
			case Const:
				chunk.writeU8(1);
				writeFields();
			case Extend(tl):
				chunk.writeU8(2);
				writeTypes(tl);
				writeFields();
			case ClassStatics(_) | EnumStatics(_) | AbstractStatics(_):
				throw "assert: false";
		}
	}

	function writeAnonRef(an:TAnon):Void {
		try {
			var index = identifiedAnons.get(an);
			chunk.writeU8(0);
			chunk.writeUleb128(index);
		} catch (_:NotFound) {
			var pfm = anonId.identifyAnon(AnonIdMode.strict, an);
			try {
				var index = anons.get(pfm.pfmPath);
				chunk.writeU8(0);
				chunk.writeUleb128(index);
			} catch (_:NotFound) {
				var restore = startTemporaryChunk(256);
				// Reset the flag to find out whether this anon (on its own) needs local
				// context, but remember the outer value: a sibling field may have already
				// required it, and writing this anon must not discard that.
				var old = needsLocalContext;
				needsLocalContext = false;
				writeAnon(an);
				var bytes = restore(function(newChunk) return newChunk.getBytes());
				var anonNeedsLocalContext = needsLocalContext;
				needsLocalContext = old || anonNeedsLocalContext;
				if (anonNeedsLocalContext) {
					var index = anons.add(pfm.pfmPath, null);
					identifiedAnons.add(an, index);
					chunk.writeU8(1);
					chunk.writeUleb128(index);
					chunk.writeBytes(bytes);
				} else {
					var index = anons.add(pfm.pfmPath, bytes);
					identifiedAnons.add(an, index);
					chunk.writeU8(0);
					chunk.writeUleb128(index);
				}
			}
		}
	}

	function writeAnonFieldRef(cf:TClassField):Void {
		try {
			var index = anonFields.get(cf.cfName, cf);
			chunk.writeU8(0);
			chunk.writeUleb128(index);
		} catch (_:NotFound) {
			var restore = startTemporaryChunk(256);
			var old = wroteLocalTypeParam;
			wroteLocalTypeParam = false;
			writeClassFieldAndOverloadsData(true, cf);
			var bytes = restore(function(newChunk) return newChunk.getBytes());
			if (needsLocalContext || wroteLocalTypeParam) {
				// If we access something from the method scope, we have to write the anon field immediately.
				// This should be fine because in such cases the field cannot be referenced elsewhere.
				var index = anonFields.add(cf.cfName, cf, null);
				needsLocalContext = true;
				chunk.writeU8(1);
				chunk.writeUleb128(index);
				chunk.writeBytes(bytes);
			} else {
				var index = anonFields.add(cf.cfName, cf, bytes);
				chunk.writeU8(0);
				chunk.writeUleb128(index);
			}
			wroteLocalTypeParam = old;
		}
	}

	// Type instances

	function writeTypeParameterRef(ttp:TypedTypeParam):Void {
		try {
			switch ttp.ttpHost {
				case TPHType:
					var i = typeTypeParameters.get(ttp.ttpName);
					// TODO: this isn't correct, but if we don't do this we'll have to communicate the current class
					wroteLocalTypeParam = true;
					chunk.writeU8(1);
					chunk.writeUleb128(i);
				case TPHMethod | TPHEnumConstructor | TPHAnonField | TPHConstructor:
					var i = fieldTypeParameters.get(ttp);
					wroteLocalTypeParam = true;
					chunk.writeU8(2);
					chunk.writeUleb128(i);
				case TPHLocal:
					var index = localTypeParameters.get(ttp);
					wroteLocalTypeParam = true;
					chunk.writeU8(3);
					chunk.writeUleb128(index);
				case TPHUnbound:
					throw NotFound.raise();
			}
		} catch (_:NotFound) {
			var r = performUnboundTtp();
			var msg = 'Unbound type parameter ${core.Globals.sTypePath(ttp.ttpClass.clPath)} while writing ${r.source}';
			// if not (Hashtbl.mem writer.unbound_ttp (msg, p)) then begin
			// 	Hashtbl.add writer.unbound_ttp (msg, p) true;
			try unboundTtp.get(ttp)
			catch (_:NotFound) {
				unboundTtp.add(ttp, true);
				warn(core.Message.WarningCode.WUnboundTypeParameter, msg, r.p);
			}
			wroteLocalTypeParam = true;
			chunk.writeU8(5);
			writePath(ttp.ttpClass.clPath);
		}
	}

	// port: write_type_instance's local helpers, as methods so each call does not allocate closures.
	function writeFunctionArg(a:{name:String, optional:Bool, type:T}) {
		chunk.writeString(a.name);
		chunk.writeBool(a.optional);
		catchUnboundTtp(function() {
			writeTypeInstance(a.type);
			return null;
		}, function() return 'function arg `${a.name}`', null);
	}

	inline function inlinedList<A>(offset:Int, max:Int, fFirst:Void->Void, fElt:A->Void, l:Array<A>) {
		writeInlinedList(offset, max, chunk.writeU8, fFirst, fElt, l);
	}

	/*
		simple references:
			0 - mono
			1 -> type ttp
			2 -> field ttp
			3 -> local ttp
			4 -> Dynamic

		special references:
			10 - class statics
			11 - enum statics
			12 - abstract statics
			13 - KExpr

		void functions:
			20: () -> Void
			21: (A) -> Void
			22: (A, B) -> Void
			23: (A, B, C) -> Void
			24: (A, B, C) -> Void
			29: (?) -> Void

		non-void functions:
			30: () -> T
			31: (A) -> T
			32: (A, B) -> T
			33: (A, B, C) -> T
			34: (A, B, C, D) -> T
			39: (?) -> T

		class:
			40: C
			41: C<A>
			42: C<A, B>
			49: C<?>

		enum:
			50: E
			51: E<A>
			52: E<A, B>
			59: E<?>

		typedef:
			60: T
			61: T<A>
			62: T<A, B>
			69: T<?>

		abstract:
			70: A
			71: A<A>
			72: A<A, B>
			79: A<?>

		anons:
			80: {}
			81: any anon
			89: Dynamic<T>

		concrete types:
			100: Void
			101: Int
			102: Float
			103: Bool
			104: String
	*/
	function writeTypeInstance(t:T):Void {
		switch t {
			case TAbstract({aPath: {pack: [], name: "Void"}}, []):
				chunk.writeU8(100);
			case TAbstract({aPath: {pack: [], name: "Int"}}, []):
				chunk.writeU8(101);
			case TAbstract({aPath: {pack: [], name: "Float"}}, []):
				chunk.writeU8(102);
			case TAbstract({aPath: {pack: [], name: "Bool"}}, []):
				chunk.writeU8(103);
			case TInst({clPath: {pack: [], name: "String"}}, []):
				chunk.writeU8(104);
			case TMono(r):
				try Monomorph.close(r)
				catch (e:Unify_error) {
					try unclosedMono.get(r)
					catch (_:NotFound) {
						unclosedMono.add(r, true);
						var p = moduleFilePos();
						var msg = "Error while handling unclosed monomorph:\n"
							+ core.Error.errorMsg(Unify(e.errors))
							+ "\n\n"
							+
							"Unclosed monomorph should not reach hxb writer, please submit an issue at https://github.com/HaxeFoundation/haxe/issues/new";
						warn(core.Message.WarningCode.WUnclosedMonomorph, msg, p);
					}
				}
				if (r.tmType == null) {
					chunk.writeU8(0);
					writeTmonoRef(r);
				} else {
					// Don't write bound monomorphs, write underlying type directly
					writeTypeInstance(r.tmType);
				}
			case TLazy(f):
				writeTypeInstance(TFunctions.lazyType(f));
			case TInst({clKind: KTypeParameter(ttp)}, []):
				writeTypeParameterRef(ttp);
			case TInst({clKind: KExpr(e)}, []):
				chunk.writeU8(13);
				writeExpr(e);
			case TInst(c, []):
				chunk.writeU8(40);
				writeClassRef(c);
			case TEnum(en, []):
				chunk.writeU8(50);
				writeEnumRef(en);
			case TType(td, []):
				inline function defaultCase() {
					chunk.writeU8(60);
					writeTypedefRef(td);
				}
				switch td.tType {
					case TAnon(an):
						switch an.aStatus {
							case ClassStatics(c):
								chunk.writeU8(10);
								writeClassRef(c);
							case EnumStatics(en):
								chunk.writeU8(11);
								writeEnumRef(en);
							case AbstractStatics(a):
								chunk.writeU8(12);
								writeAbstractRef(a);
							case _:
								defaultCase();
						}
					case _:
						defaultCase();
				}
			case TAbstract(a, []):
				chunk.writeU8(70);
				writeAbstractRef(a);
			case TDynamic(null):
				chunk.writeU8(4);
			case TFun({args: [], ret: t}) if (ExtType.isVoid(TFunctions.followLazyAndMono(t))):
				chunk.writeU8(20);
			case TFun({args: args, ret: t}) if (ExtType.isVoid(TFunctions.followLazyAndMono(t))):
				inlinedList(20, 4, function() {}, writeFunctionArg, args);
			case TFun({args: args, ret: t}):
				inlinedList(30, 4, function() {}, writeFunctionArg, args);
				writeTypeInstance(t);
			case TInst(c, tl):
				inlinedList(40, 2, function() writeClassRef(c), writeTypeInstance, tl);
			case TEnum(en, tl):
				inlinedList(50, 2, function() writeEnumRef(en), writeTypeInstance, tl);
			case TType(td, tl):
				inlinedList(60, 2, function() writeTypedefRef(td), writeTypeInstance, tl);
			case TAbstract(a, tl):
				inlinedList(70, 2, function() writeAbstractRef(a), writeTypeInstance, tl);
			case TAnon(an) if (!an.aFields.keys().hasNext()):
				chunk.writeU8(80);
			case TAnon(an):
				chunk.writeU8(81);
				writeAnonRef(an);
			case TDynamic(t):
				chunk.writeU8(89);
				writeTypeInstance(t);
		}
	}

	function writeTypes(tl:Array<T>):Void chunk.writeList(tl, writeTypeInstance);

	// texpr

	function writeTexprTypeInstance(fctx:FieldWriterContext, t:T):Void {
		var oldChunk = chunk;
		chunk = tInstanceChunk;
		chunk.reset();
		writeTypeInstance(t);
		var tBytes = chunk.getBytes();
		chunk = oldChunk;
		var index = fctx.tPool.getOrAdd(tBytes);
		chunk.writeUleb128(index);
	}

	function writeTexpr(fctx:FieldWriterContext, e:TExpr):Void {
		inline function declareVar(v:TVar) {
			var index = if (TFunctions.hasVarFlag(v, VHxb)) {
				// Duplicate var declaration! Can happen when writing both cf_expr and cf_expr_unoptimized,
				// although it arguably shouldn't. In this case we don't add the var again and instead write
				// out the existing ID.
				v.vId;
			} else {
				var index = fctx.vars.length;
				fctx.vars.push({v: v, id: v.vId});
				// Store local index in v_id so we find it easily for all the TLocal expressions.
				// This is set back by the var writer in start_texpr.
				v.vId = index;
				TFunctions.addVarFlag(v, VHxb);
				index;
			}
			chunk.writeUleb128(index);
			chunk.writeOption(v.vExtra, function(ve) {
				chunk.writeList(ve.vParams, function(ttp) {
					var index = localTypeParameters.add(ttp, true);
					chunk.writeUleb128(index);
				});
				catchUnboundTtp(function() {
					chunk.writeOption(ve.vExpr, function(e) writeTexpr(fctx, e));
					return null;
				}, function() return "var expression", v.vPos);
			});
			catchUnboundTtp(function() {
				writeTypeInstance(v.vType);
				return null;
			}, function() return "var type", v.vPos);
		}
		var loopEl:Array<TExpr>->Void = null;
		function loop(e1:TExpr):Void {
			var writeType = switch e1.eexpr {
				// values 0-19
				case TConst(ct):
					switch ct {
						case TNull:
							chunk.writeU8(0);
							true;
						case TThis:
							fctx.texprThis = e1;
							chunk.writeU8(1);
							false;
						case TSuper:
							chunk.writeU8(2);
							true;
						case TBool(false) if (ExtType.isBool(TFunctions.followLazyAndMono(e1.etype))):
							chunk.writeU8(3);
							false;
						case TBool(true) if (ExtType.isBool(TFunctions.followLazyAndMono(e1.etype))):
							chunk.writeU8(4);
							false;
						case TInt(i32) if (ExtType.isInt(TFunctions.followLazyAndMono(e1.etype))):
							chunk.writeU8(5);
							chunk.writeI32(i32);
							false;
						case TFloat(f) if (ExtType.isFloat(TFunctions.followLazyAndMono(e1.etype))):
							chunk.writeU8(6);
							chunk.writeString(f);
							false;
						case TString(s) if (ExtType.isString(TFunctions.followLazyAndMono(e1.etype))):
							chunk.writeU8(7);
							chunk.writeString(s);
							false;
						case TBool(false):
							chunk.writeU8(13);
							true;
						case TBool(true):
							chunk.writeU8(14);
							true;
						case TInt(i32):
							chunk.writeU8(15);
							chunk.writeI32(i32);
							true;
						case TFloat(f):
							chunk.writeU8(16);
							chunk.writeString(f);
							true;
						case TString(s):
							chunk.writeU8(17);
							chunk.writeString(s);
							true;
					}
				// vars 20-29
				case TLocal(v):
					chunk.writeU8(20);
					chunk.writeUleb128(v.vId);
					true; // I think there are cases where v_type != etype
				case TVar(v, null):
					chunk.writeU8(21);
					declareVar(v);
					false;
				case TVar(v, e2):
					chunk.writeU8(22);
					declareVar(v);
					loop(e2);
					false;
				// blocks 30-49
				case TBlock([]):
					chunk.writeU8(30);
					true;
				case TBlock(el):
					var restore = startTemporaryChunk(256);
					var i = 0;
					for (e in el) {
						i++;
						loop(e);
					}
					var bytes = restore(function(newChunk) return newChunk.getBytes());
					var l = i;
					switch l {
						case 1: chunk.writeU8(31);
						case 2: chunk.writeU8(32);
						case 3: chunk.writeU8(33);
						case 4: chunk.writeU8(34);
						case 5: chunk.writeU8(35);
						case _:
							if (l <= 0xFF) {
								chunk.writeU8(36);
								chunk.writeU8(l);
							} else {
								chunk.writeU8(39);
								chunk.writeUleb128(l);
							}
					}
					chunk.writeBytes(bytes);
					true;
				// function 50-59
				case TFunction(tf):
					chunk.writeU8(50);
					chunk.writeList(tf.tfArgs, function(a) {
						declareVar(a.variable);
						chunk.writeOption(a.defaultValue, loop);
					});
					if (e == e1) writeTypeInstance(tf.tfType)
					else catchUnboundTtp(function() {
						writeTypeInstance(tf.tfType);
						return null;
					}, function() return "TFunction", e1.epos);
					loop(tf.tfExpr);
					true;
				// texpr compounds 60-79
				case TArray(e2, e3):
					chunk.writeU8(60);
					loop(e2);
					loop(e3);
					true;
				case TParenthesis(e2):
					chunk.writeU8(61);
					loop(e2);
					false; // surely this is always the nested type
				case TArrayDecl(el):
					chunk.writeU8(62);
					loopEl(el);
					true;
				case TObjectDecl(fl):
					chunk.writeU8(63);
					chunk.writeList(fl, function(f) {
						chunk.writeString(f.key.name);
						writePos(f.key.pos);
						switch f.key.quote {
							case NoQuotes:
								chunk.writeU8(0);
							case DoubleQuotes:
								chunk.writeU8(1);
						}
						loop(f.expr);
					});
					true;
				case TCall(e2, el):
					writeInlinedList(70, 4, chunk.writeU8, function() loop(e2), loop, el);
					true;
				case TMeta(m, e2):
					chunk.writeU8(65);
					writeMetadataEntry(m);
					loop(e2);
					true;
				// branching 80-89
				case TIf(e2, e3, null):
					chunk.writeU8(80);
					loop(e2);
					loop(e3);
					false;
				case TIf(e2, e3, e4):
					chunk.writeU8(81);
					loop(e2);
					loop(e3);
					loop(e4);
					true;
				case TSwitch(s):
					chunk.writeU8(82);
					loop(s.switchSubject);
					chunk.writeList(s.switchCases, function(c) {
						loopEl(c.casePatterns);
						loop(c.caseExpr);
					});
					chunk.writeOption(s.switchDefault, loop);
					true;
				case TTry(e2, catches):
					chunk.writeU8(83);
					loop(e2);
					chunk.writeList(catches, function(c) {
						declareVar(c.variable);
						loop(c.expr);
					});
					true;
				case TWhile(e2, e3, flag):
					chunk.writeU8(flag == NormalWhile ? 84 : 85);
					loop(e2);
					loop(e3);
					false;
				// control flow 90-99
				case TReturn(null):
					chunk.writeU8(90);
					true;
				case TReturn(e2):
					chunk.writeU8(91);
					loop(e2);
					true;
				case TContinue:
					chunk.writeU8(92);
					true;
				case TBreak:
					chunk.writeU8(93);
					true;
				case TThrow(e2):
					chunk.writeU8(94);
					loop(e2);
					true;
				// access 100-119
				case TEnumIndex(e2):
					chunk.writeU8(100);
					loop(e2);
					false;
				case TEnumParameter(e2, ef, i):
					chunk.writeU8(101);
					loop(e2);
					var en = switch TFunctions.follow(ef.efType) {
						case TFun({ret: tr}):
							switch TFunctions.follow(tr) {
								case TEnum(en, _): en;
								case _: core.Globals.die("", "hxbWriter.ml");
							}
						case _:
							core.Globals.die("", "hxbWriter.ml");
					};
					writeEnumFieldRef(en, ef);
					chunk.writeUleb128(i);
					true;
				case TField({eexpr: TConst(TThis), epos: p1}, FInstance(c, tl, cf)) if (fctx.texprThis != null):
					chunk.writeU8(111);
					fctx.posWriter.writePos(chunk, true, 0, p1);
					writeClassRef(c);
					writeTypes(tl);
					writeFieldRef(c, CfrMember, cf);
					true;
				case TField(e2, FInstance(c, tl, cf)):
					chunk.writeU8(102);
					loop(e2);
					writeClassRef(c);
					writeTypes(tl);
					writeFieldRef(c, CfrMember, cf);
					true;
				case TField({eexpr: TTypeExpr(TClassDecl(c2)), epos: p1}, FStatic(c, cf)) if (c == c2):
					chunk.writeU8(110);
					fctx.posWriter.writePos(chunk, true, 0, p1);
					writeClassRef(c);
					writeFieldRef(c, CfrStatic, cf);
					true;
				case TField(e2, FStatic(c, cf)):
					chunk.writeU8(103);
					loop(e2);
					writeClassRef(c);
					writeFieldRef(c, CfrStatic, cf);
					true;
				case TField(e2, FAnon(cf)):
					chunk.writeU8(104);
					loop(e2);
					writeAnonFieldRef(cf);
					true;
				case TField(e2, FClosure(ctl, cf)) if (ctl != null):
					chunk.writeU8(105);
					loop(e2);
					writeClassRef(ctl.cls);
					writeTypes(ctl.params);
					writeFieldRef(ctl.cls, CfrMember, cf);
					true;
				case TField(e2, FClosure(_, cf)):
					chunk.writeU8(106);
					loop(e2);
					writeAnonFieldRef(cf);
					true;
				case TField(e2, FEnum(en, ef)):
					chunk.writeU8(107);
					loop(e2);
					writeEnumRef(en);
					writeEnumFieldRef(en, ef);
					true;
				case TField(e2, FDynamic(s)):
					chunk.writeU8(108);
					loop(e2);
					chunk.writeString(s);
					true;
				// module types 120-139
				case TTypeExpr(TClassDecl({clKind: KTypeParameter(ttp)})):
					chunk.writeU8(128);
					writeTypeParameterRef(ttp);
					true;
				case TTypeExpr(TClassDecl(c)):
					chunk.writeU8(120);
					writeClassRef(c);
					false;
				case TTypeExpr(TEnumDecl(en)):
					chunk.writeU8(121);
					writeEnumRef(en);
					false;
				case TTypeExpr(TAbstractDecl(a)):
					chunk.writeU8(122);
					writeAbstractRef(a);
					true;
				case TTypeExpr(TTypeDecl(td)):
					chunk.writeU8(123);
					writeTypedefRef(td);
					true;
				case TCast(e2, null):
					chunk.writeU8(124);
					loop(e2);
					true;
				case TCast(e2, md):
					chunk.writeU8(125);
					loop(e2);
					var infos = TFunctions.tInfos(md);
					var m = infos.mtModule;
					writeFullPath(m.mPath.pack, m.mPath.name, infos.mtPath.name);
					true;
				case TNew({clKind: KTypeParameter(ttp)}, tl, el):
					chunk.writeU8(127);
					writeTypeParameterRef(ttp);
					writeTypes(tl);
					loopEl(el);
					true;
				case TNew(c, tl, el):
					chunk.writeU8(126);
					writeClassRef(c);
					writeTypes(tl);
					loopEl(el);
					true;
				// unops 140-159
				case TUnop(op, flag, e2):
					chunk.writeU8(140 + unopIndex(op, flag));
					loop(e2);
					true;
				// binops 160-219
				case TBinop(op, e2, e3):
					chunk.writeU8(160 + binopIndex(op));
					loop(e2);
					loop(e3);
					true;
				// rest 250-254
				case TIdent(s):
					chunk.writeU8(250);
					chunk.writeString(s);
					true;
			};
			if (writeType) {
				// Unbound TTP in top level expr type will be caught be calling site with a better position
				if (e == e1) writeTexprTypeInstance(fctx, e.etype)
				else writeTexprTypeInstanceCatching(fctx, e1);
			}
			fctx.posWriter.writePos(chunk, true, 0, e1.epos);
		}
		loopEl = function(el:Array<TExpr>) chunk.writeList(el, loop);
		loop(e);
	}

	function writeTypeParametersForward(ttps:TypeParams):Void {
		chunk.writeList(ttps, function(ttp) {
			writePath(ttp.ttpClass.clPath);
			writePos(ttp.ttpClass.clNamePos);
			var i = switch ttp.ttpHost {
				case TPHType: 0;
				case TPHConstructor: 1;
				case TPHMethod: 2;
				case TPHEnumConstructor: 3;
				case TPHAnonField: 4;
				case TPHLocal: 5;
				case TPHUnbound: 6;
			};
			chunk.writeU8(i);
		});
	}

	function writeTypeParametersData(ttps:TypeParams):Void {
		for (ttp in ttps) {
			var c = ttp.ttpClass;
			writeMetadata(c.clMeta);
			writeTypes(TFunctions.getConstraints(ttp));
			chunk.writeOption(ttp.ttpDefault, writeTypeInstance);
		}
	}

	function writeTypeParameters(ttps:TypeParams):Void {
		writeTypeParametersForward(ttps);
		writeTypeParametersData(ttps);
	}

	// Fields

	function writeFieldKind(k:FieldKind):Void switch k {
		case Method(MethNormal):
			chunk.writeU8(0);
		case Method(MethInline):
			chunk.writeU8(1);
		case Method(MethDynamic):
			chunk.writeU8(2);
		case Method(MethMacro):
			chunk.writeU8(3);
		// normal read
		case Var({vRead: AccNormal, vWrite: AccNormal}):
			chunk.writeU8(10);
		case Var({vRead: AccNormal, vWrite: AccNo}):
			chunk.writeU8(11);
		case Var({vRead: AccNormal, vWrite: AccNever}):
			chunk.writeU8(12);
		case Var({vRead: AccNormal, vWrite: AccCtor}):
			chunk.writeU8(13);
		case Var({vRead: AccNormal, vWrite: AccCall}):
			chunk.writeU8(14);
		// inline read
		case Var({vRead: AccInline, vWrite: AccNever}):
			chunk.writeU8(20);
		// getter read
		case Var({vRead: AccCall, vWrite: AccNormal}):
			chunk.writeU8(30);
		case Var({vRead: AccCall, vWrite: AccNo}):
			chunk.writeU8(31);
		case Var({vRead: AccCall, vWrite: AccNever}):
			chunk.writeU8(32);
		case Var({vRead: AccCall, vWrite: AccCtor}):
			chunk.writeU8(33);
		case Var({vRead: AccCall, vWrite: AccCall}):
			chunk.writeU8(34);
		// weird/overlooked combinations
		case Var({vRead: r, vWrite: w}):
			chunk.writeU8(100);
			inline function f(a:VarAccess) switch a {
				case AccNormal:
					chunk.writeU8(0);
				case AccNo:
					chunk.writeU8(1);
				case AccNever:
					chunk.writeU8(2);
				case AccCtor:
					chunk.writeU8(3);
				case AccCall:
					chunk.writeU8(4);
				case AccInline:
					chunk.writeU8(5);
				case AccRequire(s, so):
					chunk.writeU8(6);
					chunk.writeString(s);
					chunk.writeOption(so, chunk.writeString);
				case AccPrivateCall:
					chunk.writeU8(7);
			}
			f(r);
			f(w);
	}

	function openFieldScope(params:TypeParams):Void->Void {
		fieldStack++;
		var nested = inNestedScope();
		var oldFieldParams = fieldTypeParameters;
		var oldLocalParams = localTypeParameters;
		if (!nested) {
			localTypeParameters = new IdentityPool();
			fieldTypeParameters = new IdentityPool();
		}
		for (ttp in params) fieldTypeParameters.add(ttp, true);
		return function() {
			fieldTypeParameters = oldFieldParams;
			localTypeParameters = oldLocalParams;
			fieldStack--;
		};
	}

	function writeClassFieldForward(cf:TClassField):Void {
		chunk.writeString(cf.cfName);
		writePosPair(cf.cfPos, cf.cfNamePos);
		writeMetadata(cf.cfMeta);
		chunk.writeList(cf.cfOverloads, writeClassFieldForward);
	}

	function startTexpr(p:Pos):{fctx:FieldWriterContext, close:Void->ExprChunks} {
		var restore = startTemporaryChunk(512);
		var fctx:FieldWriterContext = {
			tPool: new BytesPool(),
			posWriter: PosWriter.create(chunk, p),
			texprThis: null,
			vars: []
		};
		return {
			fctx: fctx,
			close: function() {
				return restore(function(newChunk:Chunk):ExprChunks {
					var restore = startTemporaryChunk(512);
					if (inNestedScope()) chunk.writeU8(0)
					else {
						chunk.writeU8(1);
						var ltp = [for (e in localTypeParameters.toList()) e.key];
						writeTypeParameters(ltp);
					}
					chunk.writeOption(fctx.texprThis, function(e:TExpr) {
						catchUnboundTtp(function() {
							writeTypeInstance(e.etype);
							return null;
						}, function() return "`this` type", e.epos);
					});
					var a = fctx.tPool.items;
					chunk.writeUleb128(a.length);
					for (bytes in a) chunk.writeBytes(bytes);
					chunk.writeUleb128(fctx.vars.length);
					for (entry in fctx.vars) {
						entry.v.vId = entry.id;
						TFunctions.removeVarFlag(entry.v, VHxb);
						writeVar(fctx, entry.v);
					}
					return restore(function(newerChunk:Chunk):ExprChunks return {pre: newerChunk, e: newChunk});
				});
			}
		};
	}

	function commitFieldTypeParameters(params:TypeParams):Void {
		chunk.writeUleb128(params.length);
		if (inNestedScope()) chunk.writeU8(0)
		else {
			chunk.writeU8(1);
			var ftp = [for (e in fieldTypeParameters.toList()) e.key];
			writeTypeParameters(ftp);
		}
	}

	function writeClassFieldData(writeExprImmediately:Bool, cf:TClassField):Null<ExprChunks> {
		var restore = startTemporaryChunk(512);
		catchUnboundTtp(function() {
			writeTypeInstance(cf.cfType);
			return null;
		}, function() return "field type", cf.cfPos);
		chunk.writeUleb128(cf.cfFlags);
		maybeWriteDocumentation(cf.cfDoc);
		writeFieldKind(cf.cfKind);
		var exprChunk:Null<ExprChunks> = if (cf.cfExpr == null) {
			chunk.writeU8(0);
			null;
		} else if (!writeExprImmediately) {
			var e = cf.cfExpr;
			chunk.writeU8(2);
			var st = startTexpr(e.epos);
			catchUnboundTtp(function() {
				writeTexpr(st.fctx, e);
				return null;
			}, function() return "field expression", cf.cfPos);
			catchUnboundTtp(function() {
				chunk.writeOption(cf.cfExprUnoptimized, function(e) writeTexpr(st.fctx, e));
				return null;
			}, function() return "field unoptimized expression", cf.cfPos);
			st.close();
		} else {
			var e = cf.cfExpr;
			chunk.writeU8(1);
			var st = startTexpr(e.epos);
			catchUnboundTtp(function() {
				writeTexpr(st.fctx, e);
				return null;
			}, function() return "field expression", cf.cfPos);
			catchUnboundTtp(function() {
				chunk.writeOption(cf.cfExprUnoptimized, function(e) writeTexpr(st.fctx, e));
				return null;
			}, function() return "field unoptimized expression", cf.cfPos);
			var c = st.close();
			c.pre.exportData(chunk);
			c.e.exportData(chunk);
			null;
		};
		restore(function(newChunk:Chunk) {
			commitFieldTypeParameters(cf.cfParams);
			newChunk.exportData(chunk);
			return null;
		});
		return exprChunk;
	}

	function writeClassFieldAndOverloadsData(writeExprImmediately:Bool, cf:TClassField):Array<{cf:TClassField, e:ExprChunks}> {
		var cfl = [cf].concat(cf.cfOverloads);
		chunk.writeUleb128(cfl.length);
		var result = [];
		for (cf in cfl) {
			var close = openFieldScope(cf.cfParams);
			var exprChunk = writeClassFieldData(writeExprImmediately, cf);
			close();
			if (exprChunk != null) result.push({cf: cf, e: exprChunk});
		}
		return result;
	}

	// Module types

	function selectType(path:GlobalTypePath):Void {
		typeTypeParameters = typeParamLut.extract(path);
	}

	function writeCommonModuleType(infos:TInfos):Void {
		chunk.writeBool(infos.mtPrivate);
		maybeWriteDocumentation(infos.mtDoc);
		writeMetadata(infos.mtMeta);
		writeTypeParametersData(infos.mtParams);
		chunk.writeList(infos.mtUsing, function(u) {
			writeClassRef(u.cls);
			writePos(u.pos);
		});
	}

	function writeClassKind(k:TClassKind):Void switch k {
		case KNormal:
			chunk.writeU8(0);
		case KTypeParameter(ttp):
			core.Globals.die("", "hxbWriter.ml");
		case KExpr(e):
			chunk.writeU8(2);
			writeExpr(e);
		case KGeneric:
			chunk.writeU8(3);
		case KGenericInstance(c, tl):
			chunk.writeU8(4);
			writeClassRef(c);
			writeTypes(tl);
		case KMacroType:
			chunk.writeU8(5);
		case KGenericBuild(l):
			chunk.writeU8(6);
			chunk.writeList(l, writeCfield);
		case KAbstractImpl(a):
			chunk.writeU8(7);
			writeAbstractRef(a);
		case KModuleFields(md):
			chunk.writeU8(8);
	}

	static function classInfos(c:TClass):TInfos return TFunctions.tInfos(TClassDecl(c));

	function writeClass(c:TClass):Void {
		switch c.clKind {
			case KAbstractImpl(a):
				selectType(a.aPath);
			case _:
				selectType(c.clPath);
		}
		writeCommonModuleType(classInfos(c));
		writeClassKind(c.clKind);
		chunk.writeOption(c.clSuper, function(s) {
			writeClassRef(s.cls);
			writeTypes(s.params);
		});
		chunk.writeList(c.clImplements, function(s) {
			writeClassRef(s.cls);
			writeTypes(s.params);
		});
		chunk.writeOption(c.clDynamic, writeTypeInstance);
		chunk.writeOption(c.clArrayAccess, writeTypeInstance);
	}

	function writeAbstract(a:TAbstract):Void {
		try selectType(a.aPath)
		catch (_:NotFound) {
			Sys.stderr().writeString("Could not select abstract " + core.Globals.sTypePath(a.aPath) + "\n");
		}
		writeCommonModuleType(TFunctions.tInfos(TAbstractDecl(a)));
		chunk.writeOption(a.aImpl, writeClassRef);
		if (core.Meta.has(StrictMeta.CoreType, a.aMeta)) chunk.writeU8(0)
		else {
			chunk.writeU8(1);
			catchUnboundTtp(function() {
				writeTypeInstance(a.aThis);
				return null;
			},
				function() return 'underlying type for abstract `${core.Globals.sTypePath(a.aPath)}`', a.aPos);
		}
		inline function writeFromTo(source:String, t:T) {
			catchUnboundTtp(function() {
				writeTypeInstance(t);
				return null;
			}, function() {
				var tPath = try core.Globals.sTypePath(TFunctions.tPath(TFunctions.moduleTypeOfType(t))) catch (_:core.ds.Exit)
					core.TPrinting.sType(core.TPrinting.printContext(), t);
				return '`$source` type `$tPath` for abstract `${core.Globals.sTypePath(a.aPath)}`';
			}, a.aPos);
		}
		chunk.writeList(a.aFrom, function(t) writeFromTo("from", t));
		chunk.writeList(a.aTo, function(t) writeFromTo("to", t));
		chunk.writeBool(a.aExtern);
		chunk.writeBool(a.aEnum);
	}

	function writeAbstractFields(a:TAbstract):Void {
		var c = a.aImpl == null ? TFunctions.nullClass : a.aImpl;
		chunk.writeList(a.aArray, function(cf) writeFieldRef(c, CfrStatic, cf));
		chunk.writeOption(a.aRead, function(cf) writeFieldRef(c, CfrStatic, cf));
		chunk.writeOption(a.aWrite, function(cf) writeFieldRef(c, CfrStatic, cf));
		chunk.writeOption(a.aCall, function(cf) writeFieldRef(c, CfrStatic, cf));
		chunk.writeOption(a.aConstructor, function(cf) writeFieldRef(c, CfrStatic, cf));
		chunk.writeList(a.aOps, function(o) {
			chunk.writeU8(binopIndex(o.op));
			writeFieldRef(c, CfrStatic, o.field);
		});
		chunk.writeList(a.aUnops, function(o) {
			chunk.writeU8(unopIndex(o.op, o.flag));
			writeFieldRef(c, CfrStatic, o.field);
		});
		chunk.writeList(a.aFromField, function(f) writeFieldRef(c, CfrStatic, f.field));
		chunk.writeList(a.aToField, function(f) writeFieldRef(c, CfrStatic, f.field));
	}

	function writeEnum(e:TEnum):Void {
		selectType(e.ePath);
		writeCommonModuleType(TFunctions.tInfos(TEnumDecl(e)));
		chunk.writeUleb128(e.eFlags);
		chunk.writeList(e.eNames, chunk.writeString);
	}

	function writeTypedef(td:TDef):Void {
		selectType(td.tPath);
		writeCommonModuleType(TFunctions.tInfos(TTypeDecl(td)));
		catchUnboundTtp(function() {
			writeTypeInstance(td.tType);
			return null;
		},
			function() return 'typedef `${core.Globals.sTypePath(td.tPath)}`', td.tPos);
	}

	// Module
	// port: PMap.foldi (fun s f acc -> (s,f) :: acc) m []: descending key order.
	static function enumConstructorsDescending(e:TEnum):Array<{name:String, ef:TEnumField}> {
		var keys = sortedKeys(e.eConstrs);
		keys.reverse();
		return [for (k in keys) {name: k, ef: e.eConstrs.get(k)}];
	}

	function forwardDeclareType(mt:ModuleType):Void {
		var name = "";
		var i = switch mt {
			case TClassDecl(c):
				classes.add(c.clPath, c);
				ownClasses.add(c.clPath, c);
				name = c.clPath.name;
				0;
			case TEnumDecl(e):
				enums.add(e.ePath, e);
				ownEnums.add(e.ePath, e);
				name = e.ePath.name;
				1;
			case TTypeDecl(t):
				typedefs.add(t.tPath, t);
				ownTypedefs.add(t.tPath, t);
				name = t.tPath.name;
				2;
			case TAbstractDecl(a):
				abstracts.add(a.aPath, a);
				ownAbstracts.add(a.aPath, a);
				name = a.aPath.name;
				3;
		};
		var infos = TFunctions.tInfos(mt);
		chunk.writeU8(i);
		writePath({pack: infos.mtPath.pack, name: name});
		writePosPair(infos.mtPos, infos.mtNamePos);
		writeTypeParametersForward(infos.mtParams);
		var params = new Pool<String, TypedTypeParam>(function(s) return s);
		typeTypeParameters = params;
		typeParamLut.add(infos.mtPath, params);
		for (ttp in infos.mtParams) typeTypeParameters.add(ttp.ttpName, ttp);

		// Forward declare fields
		switch mt {
			case TClassDecl(c):
				chunk.writeUleb128(c.clFlags);
				chunk.writeOption(c.clConstructor, writeClassFieldForward);
				chunk.writeOption(c.clInit, writeClassFieldForward);

				// Write in reverse order so reader can read tail-recursively without List.rev
				inline function writeFields(cfl:Array<TClassField>):{n:Int, bytes:Bytes} {
					var restore = startTemporaryChunk(256);
					var i = cfl.length;
					while (i-- > 0) writeClassFieldForward(cfl[i]);
					var bytes = restore(function(newChunk) return newChunk.getBytes());
					return {n: cfl.length, bytes: bytes};
				}
				var fields = writeFields(c.clOrderedFields);
				var statics = writeFields(c.clOrderedStatics);
				chunk.writeUleb128(fields.n);
				chunk.writeUleb128(statics.n);
				chunk.writeBytes(fields.bytes);
				chunk.writeBytes(statics.bytes);
			case TEnumDecl(e):
				chunk.writeList(enumConstructorsDescending(e), function(entry) {
					chunk.writeString(entry.name);
					writePosPair(entry.ef.efPos, entry.ef.efNamePos);
					chunk.writeUleb128(entry.ef.efIndex);
				});
			case TAbstractDecl(_):
			case TTypeDecl(_):
		}
	}

	function writeStringPool(kind:ChunkKind, a:StringDynArray):Void {
		startChunk(kind);
		chunk.writeUleb128(a.length);
		for (i in 0...a.length) chunk.writeBytesLengthPrefixed(Bytes.ofString(a.get(i)));
	}

	public function writeModule(m:ModuleDef):Void {
		catchUnboundTtpModule(function() doWriteModule(m));
	}

	// port: the top-level effect handler of upstream write_module is performUnboundTtp's
	// empty-stack branch.
	inline function catchUnboundTtpModule(f:Void->Void):Void f();

	function doWriteModule(m:ModuleDef):Void {
		currentModule = m;

		startChunk(MTF);
		chunk.writeList(m.mTypes, forwardDeclareType);

		var items = ownAbstracts.finalize();
		if (items.length > 0) {
			startChunk(ABD);
			chunk.writeList(items, writeAbstract);
			startChunk(AFD);
			chunk.writeList(items, writeAbstractFields);
		}
		var items = ownClasses.finalize();
		if (items.length > 0) {
			startChunk(CLD);
			chunk.writeList(items, writeClass);
			startChunk(CFD);
			var exprChunks:Array<{c:TClass, l:Array<{cf:TClassField, kind:ClassFieldRefKind, e:ExprChunks}>}> = [];
			chunk.writeList(items, function(c) {
				switch c.clKind {
					case KAbstractImpl(a):
						selectType(a.aPath);
					case _:
						selectType(c.clPath);
				}
				var cExprChunks = [];
				inline function writeField(refKind:ClassFieldRefKind, cf:TClassField) {
					var l = writeClassFieldAndOverloadsData(false, cf);
					for (x in l) cExprChunks.push({cf: x.cf, kind: refKind, e: x.e});
				}
				chunk.writeOption(c.clConstructor, function(cf) writeField(CfrConstructor, cf));
				chunk.writeOption(c.clInit, function(cf) writeField(CfrInit, cf));
				chunk.writeList(c.clOrderedFields, function(cf) writeField(CfrMember, cf));
				chunk.writeList(c.clOrderedStatics, function(cf) writeField(CfrStatic, cf));
				if (cExprChunks.length > 0) exprChunks.push({c: c, l: cExprChunks});
			});
			if (exprChunks.length > 0) {
				startChunk(EXD);
				chunk.writeList(exprChunks, function(x) {
					writeClassRef(x.c);
					chunk.writeList(x.l, function(f) {
						writeFieldRef(x.c, f.kind, f.cf);
						var bytesPre = f.e.pre.getBytes();
						var bytesE = f.e.e.getBytes();
						chunk.writeUleb128(bytesPre.length + bytesE.length);
						chunk.writeBytes(bytesPre);
						chunk.writeBytes(bytesE);
					});
				});
			}
		}
		var items = ownEnums.finalize();
		if (items.length > 0) {
			startChunk(END);
			chunk.writeList(items, writeEnum);
			startChunk(EFD);
			chunk.writeList(items, function(e) {
				chunk.writeList(enumConstructorsDescending(e), function(entry) {
					var ef = entry.ef;
					selectType(e.ePath);
					var close = openFieldScope(ef.efParams);
					chunk.writeString(entry.name);
					var restore = startTemporaryChunk(32);
					catchUnboundTtp(function() {
						writeTypeInstance(ef.efType);
						return null;
					}, function() return "enum field type", ef.efPos);
					var tBytes = restore(function(newChunk) return newChunk.getBytes());
					commitFieldTypeParameters(ef.efParams);
					chunk.writeBytes(tBytes);
					maybeWriteDocumentation(ef.efDoc);
					writeMetadata(ef.efMeta);
					close();
				});
			});
		}
		var items = ownTypedefs.finalize();
		if (items.length > 0) {
			startChunk(TDD);
			chunk.writeList(items, writeTypedef);
		}

		var items = classFields.finalize();
		if (items.length > 0) {
			startChunk(CFR);
			chunk.writeUleb128(items.length);
			for (item in items) {
				var cf = item.key;
				writeClassRef(item.value.c);
				switch item.value.kind {
					case CfrStatic:
						chunk.writeU8(0);
						chunk.writeString(cf.cfName);
					case CfrMember:
						chunk.writeU8(1);
						chunk.writeString(cf.cfName);
					case CfrConstructor:
						chunk.writeU8(2);
					case CfrInit:
						chunk.writeU8(3);
				}
				chunk.writeUleb128(item.value.depth);
			}
		}

		var items = enumFields.finalize();
		if (items.length > 0) {
			startChunk(EFR);
			chunk.writeUleb128(items.length);
			for (item in items) {
				writeEnumRef(item.en);
				chunk.writeString(item.ef.efName);
			}
		}

		var items = anonFields.finalize();
		if (items.length > 0) {
			startChunk(OFR);
			chunk.writeUleb128(items.length);
			for (item in items) writeClassFieldForward(item.key);

			var anonFieldsWithExpr = [];
			for (i in 0...items.length) {
				var bytes = items[i].value;
				if (bytes != null) anonFieldsWithExpr.push({index: i, bytes: bytes});
			}
			if (anonFieldsWithExpr.length > 0) {
				startChunk(OFD);
				chunk.writeUleb128(anonFieldsWithExpr.length);
				for (x in anonFieldsWithExpr) {
					chunk.writeUleb128(x.index);
					chunk.writeBytes(x.bytes);
				}
			}
		}

		var items = classes.finalize();
		if (items.length > 0) {
			startChunk(CLR);
			chunk.writeList(items, function(c) {
				var m = c.clModule;
				writeFullPath(m.mPath.pack, m.mPath.name, c.clPath.name);
			});
		}
		var items = abstracts.finalize();
		if (items.length > 0) {
			startChunk(ABR);
			chunk.writeList(items, function(a) {
				var m = a.aModule;
				writeFullPath(m.mPath.pack, m.mPath.name, a.aPath.name);
			});
		}
		var items = enums.finalize();
		if (items.length > 0) {
			startChunk(ENR);
			chunk.writeList(items, function(en) {
				var m = en.eModule;
				writeFullPath(m.mPath.pack, m.mPath.name, en.ePath.name);
			});
		}
		var items = typedefs.finalize();
		if (items.length > 0) {
			startChunk(TDR);
			chunk.writeList(items, function(td) {
				var m = td.tModule;
				writeFullPath(m.mPath.pack, m.mPath.name, td.tPath.name);
			});
		}

		startChunk(MDF);
		writePath(m.mPath);
		chunk.writeString(moduleFile(m));
		var anonItems = anons.finalize();
		chunk.writeUleb128(anonItems.length);
		chunk.writeUleb128(tmonos.finalize().length);

		var anonsWithoutContext = [];
		for (i in 0...anonItems.length) {
			var bytes = anonItems[i];
			if (bytes != null) anonsWithoutContext.push({index: i, bytes: bytes});
		}
		if (anonsWithoutContext.length > 0) {
			startChunk(OBD);
			chunk.writeUleb128(anonsWithoutContext.length);
			for (x in anonsWithoutContext) {
				chunk.writeUleb128(x.index);
				chunk.writeBytes(x.bytes);
			}
		}

		{
			var imports = [];
			var ids = [for (k in m.mExtra.mDeps.keys()) k];
			ids.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
			for (id in ids) {
				var mdep = m.mExtra.mDeps.get(id);
				switch [mdep.mdKind, mdep.mdOrigin] {
					case [MCode | MExtern, MDepFromImport] if (mdep.mdSign == m.mExtra.mSign):
						imports.push(mdep.mdPath);
					case _:
				}
			}
			if (imports.length > 0) {
				startChunk(IMP);
				chunk.writeUleb128(imports.length);
				for (path in imports) writePath(path);
			}
		}

		startChunk(EOT);
		startChunk(EOF);
		startChunk(EOM);

		var a = cp.finalize();
		writeStringPool(STR, a);
		{
			var a = docs.finalize();
			if (a.length > 0) writeStringPool(DOC, a);
		}
	}

	static function chunkOrder(kind:ChunkKind):Int return Type.enumIndex(kind);

	function getSortedChunks():Array<Chunk> {
		// port: List.sort is stable; Array.sort in Haxe is not guaranteed to be.
		var l = chunks.copy();
		haxe.ds.ArraySort.sort(l, function(chunk1, chunk2) return chunkOrder(chunk1.kind) - chunkOrder(chunk2.kind));
		return l;
	}

	public function getChunks():Array<{kind:ChunkKind, data:Bytes}> {
		return [for (chunk in getSortedChunks()) {kind: chunk.kind, data: chunk.getBytes()}];
	}

	public function export(ch:BytesOutput):Void {
		HxbData.writeHeader(ch);
		for (io in getSortedChunks()) io.export(ch);
	}

	public function exportModule():Bytes {
		var output = new BytesOutput();
		export(output);
		return output.getBytes();
	}
}
