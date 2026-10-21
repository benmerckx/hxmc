package hxmc;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;
import core.Globals.GlobalTypePath;
import core.TType;
import compiler.hxb.HxbData;
import core.Json.JsonValue;
import core.Message.CompilerMessageKind;
import core.Message.WarningMode;

// The module cache's store on disk (ModuleCache.hx): in <cache>/modules/<tool>/,
// an index per key (<key>.idx: the working directory, the class paths and
// the std) and the modules' HXB in blobs (b/<xx>/<name>: the HXB chunks,
// the monomorphs' modifiers, the skeletons; read only for the modules a
// build restores), each named uniquely when written, never rewritten (its
// size is in the index), removed once no index names it. An index lists variants of the modules, newest first: per module (its
// role, the program's context or the macros', and its path) the variants
// typed with different defines; each with what selects it (the defines it
// read: its file's conditions, its macros' Context.defined, and those the
// compiler read in the build that typed it, Read), its ModuleDefExtra as
// written (with the signatures of that build, rewritten when restored), its
// file (date, size, content hash), the hash of its interface
// (ModuleInterface; null: its whole content counts) and its dependencies
// with the hash each had when it was typed (StoredDep).

// a define read, in a role (0: the program's context, 1: the macros'); its
// value then (null: not defined); the name "*" stands for every define
// (Context.getDefines), its value a hash of them all
@:structInit class Read {
	public var role:Int;
	public var name:String;
	public var value:Null<String>;
}

@:structInit class StoredFile {
	public var mtime:Float;
	public var size:Float;
	public var hash:String;
}

// a dependency of a variant: its role (-1: of no context the store knows),
// path, whether its interface stands for it (a dependency in the same
// context) or its whole content (a module of the macros' context: its code
// runs), and that hash when the variant was typed
@:structInit class StoredDep {
	public var role:Int;
	public var path:GlobalTypePath;
	public var key:String;
	public var eligible:Bool;
	public var expect:String;
}

typedef BlobData = {chunks:CachedChunks, monos:Bytes, skeletons:Bytes};

class Variant {
	public var role:Int;
	public var path:GlobalTypePath;
	// hxmc.ModuleCache.key(path)
	public var key:String;
	public var id:Int;
	// the ModuleDefExtra as written, with the signatures of the build that
	// wrote it (signs: the program's, the macros')
	public var extra:Bytes;
	public var signs:haxe.ds.Vector<Null<String>>; // per role
	public var kind:ModuleKind;
	// mProcessed as restored (-1: processed in an earlier compilation)
	public var processed:Int;
	public var mtime:Float;
	public var file:Null<String>;
	public var fileRec:Null<StoredFile>;
	// the defines its own file and macros read
	public var reads:Array<Read>;
	// the defines the compiler read in the build that typed it (an index of
	// the index's builds)
	public var build:Int;
	public var buildReads:Array<Read>;
	// ModuleInterface.hash of its file (null: its whole content counts)
	public var iface:Null<String>;
	public var blob:String;
	public var blobSize:Int;
	// (blob: the pack of the build that wrote it, b/<blob>.pk, at blobOff)
	public var blobOff:Int = 0;
	public var deps:haxe.ds.Vector<StoredDep>;
	// the class fields its typing marked as maybe used through a structure
	// (CfMaybeUsed, which DCE reads): role|module|class|kind|field
	public var marks:Array<String> = [];
	// the macro classes whose static variables the macros run in its typing
	// used (state kept between macro calls, for other modules' macros too):
	// typed every build then, so that the macros run again
	public var macroState:Array<String> = [];

	// in a build: whether its reads match the build's defines, the server's
	// copy, the blob once read
	public var matched = false;
	public var mc:Null<compiler.hxb.HxbData.ModuleCache> = null;
	public var x:Null<ModuleDefExtra> = null;
	public var loaded = false;
	public var chunks:Null<CachedChunks> = null;
	public var monos:Null<Bytes> = null;
	public var skeletons:Null<Bytes> = null;
	public var skeletonMap:Null<Map<String, Bytes>> = null;
	// a blob to write (encoded by this build)
	public var blobData:Null<BlobData> = null;
	// (in a capture: the key of its file's parse, whose interface it gets)
	public var ifacePk:Null<String> = null;
	// (in a capture: the variant it was restored from, processed again)
	public var prev:Null<Variant> = null;
	public var fresh = false;

	public function new() {}

	public function roleKey():String
		return role + "|" + key;
}

class StoreIndex {
	public var moduleHigh = 0;
	public var varHigh = 0;
	public var variants:Array<Variant> = [];

	public function new() {}
}

class ModuleStore {
	public static inline var MAGIC = "hxmc-modules 13";

	public static final chunkKinds:Array<ChunkKind> = [
		STR, DOC, MDF, MTF, IMP, CLR, ENR, ABR, TDR, OFR, OFD, OBD, CLD, END, ABD, TDD, EOT, EFR, CFR, CFD, EFD, AFD, EOF, EXD, EOM
	];
	public static final moduleKinds:Array<ModuleKind> = [MCode, MMacro, MFake, MExtern, MImport];
	static final policies:Array<ModuleCheckPolicy> = [NoFileSystemCheck, CheckFileModificationTime, CheckFileContentModification];
	static final diagnosticsKinds:Array<core.Message.MessageKind> = [
		DKUnusedImport, DKUnresolvedIdentifier, DKCompilerMessage, DKReplacableCode, DKParserError, DKDeprecationWarning, DKInactiveBlock, DKMissingFields
	];
	public static final origins:Array<ModuleDepOrigin> = [MDepFromTyping, MDepFromImport, MDepFromMacro, MDepFromMacroInclude, MDepFromMacroDefine];

	public static function str(o:BytesOutput, s:String) {
		var b = Bytes.ofString(s);
		o.writeInt32(b.length);
		o.write(b);
	}

	public static function rstr(i:BytesInput):String {
		var n = i.readInt32();
		return i.readString(n);
	}

	public static function path(o:BytesOutput, p:GlobalTypePath) {
		o.writeInt32(p.pack.length);
		for (s in p.pack)
			str(o, s);
		str(o, p.name);
	}

	public static function rpath(i:BytesInput):GlobalTypePath {
		var pack = [for (_ in 0...i.readInt32()) rstr(i)];
		return {pack: pack, name: rstr(i)};
	}

	public static function json(o:BytesOutput, j:JsonValue)
		switch j {
			case JString(v):
				o.writeByte(0);
				str(o, v);
			case JFloat(v):
				o.writeByte(1);
				o.writeDouble(v);
			case JInt(v):
				o.writeByte(2);
				o.writeInt32(v);
			case JObject(fields):
				o.writeByte(3);
				o.writeInt32(fields.length);
				for (f in fields) {
					str(o, f.name);
					json(o, f.value);
				}
			case JArray(values):
				o.writeByte(4);
				o.writeInt32(values.length);
				for (v in values)
					json(o, v);
			case JBool(v):
				o.writeByte(v ? 6 : 5);
			case JNull:
				o.writeByte(7);
		}

	public static function rjson(i:BytesInput):JsonValue
		return switch i.readByte() {
			case 0: JString(rstr(i));
			case 1: JFloat(i.readDouble());
			case 2: JInt(i.readInt32());
			case 3: JObject([
					for (_ in 0...i.readInt32()) {
						var name = rstr(i);
						({name: name, value: rjson(i)} : core.Json.JsonField);
					}
				]);
			case 4: JArray([for (_ in 0...i.readInt32()) rjson(i)]);
			case 5: JBool(false);
			case 6: JBool(true);
			case _: JNull;
		}

	// a module's ModuleDefExtra (what the server's binary cache keeps of it;
	// mProcessed only as processed or not)
	public static function writeExtra(x:ModuleDefExtra):Bytes {
		var o = new BytesOutput();
		str(o, core.Path.UniqueKey.lazyPath(x.mFile));
		str(o, x.mSign);
		o.writeDouble(x.mTime);
		o.writeByte(x.mKind.getIndex());
		o.writeByte(x.mProcessed != 0 ? 1 : 0);
		o.writeByte(x.mCheckPolicy.length);
		for (p in x.mCheckPolicy)
			o.writeByte(p.getIndex());
		var ids = [for (k in x.mDeps.keys()) k];
		ids.sort((a, b) -> a - b);
		o.writeInt32(ids.length);
		for (id in ids) {
			var d = x.mDeps.get(id);
			o.writeInt32(id);
			str(o, d.mdSign);
			o.writeByte(d.mdKind.getIndex());
			path(o, d.mdPath);
			o.writeByte(d.mdOrigin.getIndex());
		}
		var objs = x.mCacheBoundObjects;
		o.writeInt32(objs.length);
		for (c in objs)
			switch c {
				case Resource(name, data):
					o.writeByte(0);
					str(o, name);
					o.writeInt32(data.length);
					o.write(data);
				case IncludeFile(file, contents):
					o.writeByte(1);
					str(o, file);
					str(o, contents);
				case Message(cm):
					o.writeByte(2);
					str(o, cm.cmMessage);
					str(o, cm.cmPos.pfile);
					o.writeInt32(cm.cmPos.pmin);
					o.writeInt32(cm.cmPos.pmax);
					o.writeInt32(cm.cmDepth);
					o.writeByte(cm.cmFromMacro ? 1 : 0);
					switch cm.cmMessageKind {
						case MKError:
							o.writeByte(0);
						case MKInfo:
							o.writeByte(2);
						case MKWarning(w, options):
							o.writeByte(1);
							str(o, w);
							o.writeInt32(options.length);
							for (l in options) {
								o.writeInt32(l.length);
								for (wo in l) {
									str(o, wo.woWarning);
									o.writeByte(wo.woMode.getIndex());
								}
							}
					}
					o.writeByte(cm.cmDiagnosticsKind.getIndex());
					json(o, cm.cmJson);
			}
		var fs = [for (k in x.mFeatures.keys()) k];
		fs.sort(Reflect.compare);
		o.writeInt32(fs.length);
		for (f in fs) {
			str(o, f);
			o.writeByte(x.mFeatures.get(f) ? 1 : 0);
		}
		return o.getBytes();
	}

	public static function readExtra(b:Bytes):ModuleDefExtra {
		var i = new BytesInput(b);
		var file = rstr(i);
		var sign = rstr(i);
		var time = i.readDouble();
		var kind = moduleKinds[i.readByte()];
		// (processed in an earlier compilation: below every compilation step)
		var processed = i.readByte() == 1 ? -1 : 0;
		var policy = [for (_ in 0...i.readByte()) policies[i.readByte()]];
		var x = core.TFunctions.moduleExtra(file, sign, time, kind, 0, policy);
		x.mProcessed = processed;
		for (_ in 0...i.readInt32()) {
			var id = i.readInt32();
			var dsign = rstr(i);
			var dkind = moduleKinds[i.readByte()];
			var dpath = rpath(i);
			var origin = origins[i.readByte()];
			x.mDeps.set(id, ({mdSign: dsign, mdKind: dkind, mdPath: dpath, mdOrigin: origin} : ModuleDep));
		}
		for (_ in 0...i.readInt32())
			switch i.readByte() {
				case 0:
					var name = rstr(i);
					var data = i.read(i.readInt32());
					x.mCacheBoundObjects.push(Resource(name, data));
				case 1:
					var f = rstr(i);
					x.mCacheBoundObjects.push(IncludeFile(f, rstr(i)));
				case _:
					var msg = rstr(i);
					var pfile = rstr(i);
					var pmin = i.readInt32();
					var pmax = i.readInt32();
					var depth = i.readInt32();
					var fromMacro = i.readByte() == 1;
					var kind = switch i.readByte() {
						case 0: MKError;
						case 2: MKInfo;
						case _:
							var w:core.Message.WarningCode = rstr(i);
							var options = [
								for (_ in 0...i.readInt32()) [
									for (_ in 0...i.readInt32()) {
										var ww:core.Message.WarningCode = rstr(i);
										({woWarning: ww, woMode: i.readByte() == 0 ? WMEnable : WMDisable} : core.Message.WarningOption);
									}
								]
							];
							MKWarning(w, options);
					}
					var dk = diagnosticsKinds[i.readByte()];
					x.mCacheBoundObjects.push(Message(({
						cmMessage: msg,
						cmPos: {pfile: pfile, pmin: pmin, pmax: pmax},
						cmDepth: depth,
						cmFromMacro: fromMacro,
						cmMessageKind: kind,
						cmDiagnosticsKind: dk,
						cmJson: rjson(i)
					} : core.Message.CompilerMessage)));
			}
		for (_ in 0...i.readInt32()) {
			var f = rstr(i);
			x.mFeatures.set(f, i.readByte() == 1);
		}
		return x;
	}

	static function reads(o:BytesOutput, l:Array<Read>) {
		o.writeInt32(l.length);
		for (r in l) {
			o.writeByte(r.role);
			str(o, r.name);
			if (r.value == null) o.writeByte(0) else {
				o.writeByte(1);
				str(o, r.value);
			}
		}
	}

	static function rreads(i:BytesInput):Array<Read>
		return [
			for (_ in 0...i.readInt32()) {
				var role = i.readByte();
				var name = rstr(i);
				({role: role, name: name, value: i.readByte() == 0 ? null : rstr(i)} : Read);
			}
		];

	public static function readsKey(l:Array<Read>):String {
		var a = [for (r in l) r.role + ":" + r.name + (r.value == null ? "!" : "=" + r.value)];
		a.sort(Reflect.compare);
		return a.join("\x00");
	}

	public static function writeIndex(ix:StoreIndex):Bytes {
		var o = new BytesOutput();
		str(o, MAGIC);
		o.writeInt32(ix.moduleHigh);
		o.writeInt32(ix.varHigh);
		// the builds' reads, once each
		var builds:Array<Array<Read>> = [];
		var byKey = new Map<String, Int>();
		var refs = [];
		for (v in ix.variants) {
			var k = readsKey(v.buildReads);
			var n = byKey.get(k);
			if (n == null) {
				byKey.set(k, n = builds.length);
				builds.push(v.buildReads);
			}
			refs.push(n);
		}
		o.writeInt32(builds.length);
		for (b in builds)
			reads(o, b);
		o.writeInt32(ix.variants.length);
		for (k in 0...ix.variants.length) {
			var v = ix.variants[k];
			o.writeByte(v.role);
			path(o, v.path);
			o.writeInt32(v.id);
			o.writeInt32(v.extra.length);
			o.write(v.extra);
			str(o, v.signs[0]);
			str(o, v.signs[1] == null ? "" : v.signs[1]);
			if (v.fileRec == null) o.writeByte(0) else {
				o.writeByte(1);
				o.writeDouble(v.fileRec.mtime);
				o.writeDouble(v.fileRec.size);
				str(o, v.fileRec.hash);
			}
			reads(o, v.reads);
			o.writeInt32(refs[k]);
			str(o, v.iface == null ? "" : v.iface);
			str(o, v.blob);
			o.writeInt32(v.blobOff);
			o.writeInt32(v.blobSize);
			o.writeByte(0);
			o.writeInt32(v.macroState.length);
			for (c in v.macroState)
				str(o, c);
			o.writeInt32(v.marks.length);
			for (m in v.marks)
				str(o, m);
			o.writeInt32(v.deps.length);
			for (d in v.deps) {
				o.writeByte(d.role + 1);
				path(o, d.path);
				o.writeByte(d.eligible ? 1 : 0);
				str(o, d.expect);
			}
		}
		return o.getBytes();
	}

	public static function readIndex(file:String):Null<StoreIndex> {
		var b = try File.getBytes(file) catch (_:Dynamic) return null;
		var i = new BytesInput(b);
		if (rstr(i) != MAGIC) return null;
		var ix = new StoreIndex();
		ix.moduleHigh = i.readInt32();
		ix.varHigh = i.readInt32();
		var builds = [for (_ in 0...i.readInt32()) rreads(i)];
		for (_ in 0...i.readInt32()) {
			var v = new Variant();
			v.role = i.readByte();
			v.path = rpath(i);
			v.key = hxmc.ModuleCache.key(v.path);
			v.id = i.readInt32();
			v.extra = i.read(i.readInt32());
			var s0 = rstr(i), s1 = rstr(i);
			v.signs = core.ds.VectorTools.vector(s0, s1 == "" ? null : s1);
			if (i.readByte() == 1) {
				var mtime = i.readDouble();
				var size = i.readDouble();
				v.fileRec = {mtime: mtime, size: size, hash: rstr(i)};
			}
			v.reads = rreads(i);
			v.build = i.readInt32();
			v.buildReads = builds[v.build];
			var f = rstr(i);
			v.iface = f == "" ? null : f;
			v.blob = rstr(i);
			v.blobOff = i.readInt32();
			v.blobSize = i.readInt32();
			i.readByte();
			v.macroState = [for (_ in 0...i.readInt32()) rstr(i)];
			v.marks = [for (_ in 0...i.readInt32()) rstr(i)];
			var ndeps = i.readInt32();
			v.deps = new haxe.ds.Vector(ndeps > 0 ? ndeps : 0);
			for (k in 0...ndeps) {
				var role = i.readByte() - 1;
				var p = rpath(i);
				var eligible = i.readByte() == 1;
				v.deps[k] = ({role: role, path: p, key: hxmc.ModuleCache.key(p), eligible: eligible, expect: rstr(i)} : StoredDep);
			}
			var x = readExtra(v.extra);
			v.kind = x.mKind;
			v.processed = x.mProcessed;
			v.mtime = x.mTime;
			v.file = core.Path.UniqueKey.lazyPath(x.mFile);
			ix.variants.push(v);
		}
		return ix;
	}

	// a blob: the HXB chunks, the monomorphs' modifiers, the skeletons
	// a blob's length as written (writeBlob)
	public static function blobLength(d:BlobData):Int {
		var n = 4;
		for (c in d.chunks)
			n += 5 + c.data.length;
		return n + 4 + d.monos.length + 4 + d.skeletons.length;
	}

	public static function writeBlob(o:haxe.io.Output, d:BlobData) {
		o.writeInt32(d.chunks.length);
		for (c in d.chunks) {
			o.writeByte(c.kind.getIndex());
			o.writeInt32(c.data.length);
			o.write(c.data);
		}
		o.writeInt32(d.monos.length);
		o.write(d.monos);
		o.writeInt32(d.skeletons.length);
		o.write(d.skeletons);
	}

	// whether two blobs are the same
	public static function sameBlob(a:BlobData, b:BlobData):Bool {
		if (a.chunks.length != b.chunks.length || a.monos.compare(b.monos) != 0 || a.skeletons.compare(b.skeletons) != 0) return false;
		for (i in 0...a.chunks.length)
			if (a.chunks[i].kind != b.chunks[i].kind || a.chunks[i].data.compare(b.chunks[i].data) != 0) return false;
		return true;
	}

	// a build's blobs, in one file (b/<name>.pk: one write per build, not
	// one per module)
	public static function packPath(dir:String, name:String):String
		return dir + "b/" + name + ".pk";

	// (the packs open in this build)
	static final packs = new Map<String, sys.io.FileInput>();
	static final packsMutex = new sys.thread.Mutex();

	static function readRange(path:String, off:Int, size:Int):Null<Bytes> {
		packsMutex.acquire();
		try {
			var f = packs.get(path);
			if (f == null) packs.set(path, f = File.read(path, true));
			f.seek(off, SeekBegin);
			var b = Bytes.alloc(size);
			var n = 0;
			while (n < size) {
				var r = f.readBytes(b, n, size - n);
				if (r <= 0) throw "short";
				n += r;
			}
			packsMutex.release();
			return b;
		} catch (_:Dynamic) {
			packsMutex.release();
			return null;
		}
	}

	// the packs opened by this build, closed
	public static function closePacks() {
		packsMutex.acquire();
		for (f in packs)
			try f.close() catch (_:Dynamic) {}
		packs.clear();
		packsMutex.release();
	}

	// the blob into the variant (false: missing or damaged)
	public static function loadBlob(dir:String, v:Variant):Bool {
		if (v.loaded) return true;
		var b = readRange(packPath(dir, v.blob), v.blobOff, v.blobSize);
		if (b == null) return false;
		try {
			var i = new BytesInput(b);
			var chunks:CachedChunks = [];
			for (_ in 0...i.readInt32()) {
				var kind = chunkKinds[i.readByte()];
				chunks.push({kind: kind, data: i.read(i.readInt32())});
			}
			v.monos = i.read(i.readInt32());
			v.skeletons = i.read(i.readInt32());
			v.chunks = chunks;
		} catch (_:Dynamic) {
			return false;
		}
		v.loaded = true;
		return true;
	}

	// a pack written (the blobs of the variants that have their bytes,
	// their offsets set)
	public static function savePack(dir:String, name:String, list:Array<Variant>):Bool {
		var p = packPath(dir, name);
		var tmp = p + ".tmp";
		try {
			var d = haxe.io.Path.directory(p);
			if (!FileSystem.exists(d)) FileSystem.createDirectory(d);
			var o = File.write(tmp, true);
			var off = 0;
			for (v in list)
				if (v.blobData != null) {
					v.blob = name;
					v.blobOff = off;
					v.blobSize = blobLength(v.blobData);
					// (a blob at a time: the file's writes are not buffered)
					var b = new BytesOutput();
					writeBlob(b, v.blobData);
					o.write(b.getBytes());
					off += v.blobSize;
				}
			o.close();
			if (!CacheDir.replace(tmp, p)) return false;
			CacheDir.wrote(off);
			return true;
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
			return false;
		}
	}

	// the packs an index names (CacheDir.trim: removed with the last index
	// naming them)
	public static function packsOf(file:String):Array<String> {
		var ix = readIndex(file);
		return ix == null ? [] : [for (v in ix.variants) "b/" + v.blob + ".pk"];
	}
}
