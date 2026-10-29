package hxmc;

import haxe.ds.ObjectMap;
import haxe.ds.Vector;
import haxe.io.Bytes;
import core.TType;
import hxmc.ir.Ir;
import hxmc.ir.Lower;
import hxmc.LowerCache;
import hxmc.ModuleStore.Variant;
import hxmc.ModuleCacheState.Verdict;

// Lowered bodies kept in the store (docs/plans/compiler.md, "One cache",
// stage 2b): per module, a CacheKind LoweredBodies entry (i/b<hash>) holding
// the entries LowerCache records for its fields (each body as lowered, with
// the calls it made into the lowering and their answers), which a one-shot
// build replays for a module whose verdict is Valid, as the compilation
// server replays the entries it keeps in memory (CachedLower.replay: the
// calls asked again, the answers bound or compared, a difference abandoning
// the lowering, done again from scratch).
//
// The key: the module's (Variant.typedKey: its file, its reads, the hashes
// its dependencies had) and the build's part (prefixOf): the class path's
// index, what the lowering reads beyond the program (target, platform, Mir
// host, lines, bounds, null and span checks, resources' names, the Haxe
// functions of the runtime bindHosts calls), and what the filters, which
// run on every module each build before the lowering, read beyond a
// module's own dependencies: every define, the features (Common.hasFeature,
// filters.ml's insert_save_stacks) and the exceptions' std modules
// (ExceptionInit). A module's own dependencies are in its key by interface
// with theirs (or by whole content, -D analyzer-optimize, ModuleCache): the
// @:declared answers of LowerQueries are those.
//
// The codec. Each field's entry (with the closures written in its body) is
// read on its own, when the lowering asks for it: its calls, then the
// objects its bodies name, then the bodies, each read once its calls are
// replayed, straight into the current build's objects (CachedLower's
// binding, as CachedLower.stmts copies a body kept in memory). The IR objects
// (ClassInfo, EnumInfo, FuncInfo, LambdaInfo, SigInfo, ShapeInfo, Local) are
// written once and then referred to, with what the binding reads of them
// (CachedLower.bindClass...); a class's, constructor's or shape's field
// types name the classes and enums in them (weak: bound to the entry's object
// of that name when it has one, else compared by name). The typed program's
// objects (TClass, TClassField, TEnum, TEnumField, TAbstract, TDef) are
// written by module and path and read back as the current build's; a type
// structurally (named types by path with their parameters; monomorphs, type
// parameters and anonymous structures by identity, which Lower.ty and
// TUnification.fastEq read). An entry naming an object the build does not
// have is not replayed (its field is lowered); a module whose entries cannot
// be written so (an overloaded field, a type of no module, a lazy type not
// forced, @:analyzer metadata: what the analyzer reads of other modules'
// bodies) is not kept.
class LoweredBodies {
	// the codec's version (in every entry and in the key)
	public static inline var MAGIC = "hxmc-bodies 1";

	// the std modules the exceptions filter reads (filters/exception/ExceptionInit)
	static final FILTER_MODULES = ["haxe|Exception", "haxe|ValueException", "haxe|NativeStackTrace"];

	final s:hxmc.ModuleCacheState;
	final com:context.Common.CommonContext;
	public final paths:TypePaths;
	// the build's part of every key (null: not computed yet; "": none, the store not used)
	var prefix:Null<String> = null;
	// per module (ModuleCache.key), its stored entry (null: none)
	var loaded = new Map<String, Null<StoredModule>>();
	// the closure bodies of the entries read, by their recorded function (until replayed)
	public final lambdas = new ObjectMap<FuncInfo, Entry>();
	var gens = 0;

	public var modulesRead = 0;
	public var modulesMissing = 0;
	public var entriesRead = 0;
	public var entriesBroken = 0;
	public var replayed = 0;
	public var modulesWritten = 0;
	public var bytesWritten = 0;
	public var notStorable = 0;
	public var notStorableWhy:Null<String> = null;
	public var readTime = 0.0; // (the entries' calls and objects)
	public var bodyTime = 0.0; // (their bodies, into the build's objects)
	public var replayTime = 0.0; // (their replay, their bodies included)
	public var writeTime = 0.0;

	public var disabled:Null<String> = null;

	public function new(s:hxmc.ModuleCacheState, com:context.Common.CommonContext) {
		this.s = s;
		this.com = com;
		paths = new TypePaths(com);
	}

	// the store for this build, or null (no module cache, not asked for:
	// HXMC_LOWER_STORE=1, the survey)
	public static function open(com:context.Common.CommonContext):Null<LoweredBodies> {
		var s = ModuleCache.current();
		if (s == null || !s.captured || Sys.getEnv("HXMC_LOWER_STORE") != "1" || Lower.survey) return null;
		return new LoweredBodies(s, com);
	}

	var keptByKey:Null<Map<String, Variant>> = null;

	// the variant of the program's context a module is kept as after this
	// build (its key): the capture's, or (a build that kept the index as it
	// is) the one restored, Valid; else null
	function keptVariant(path:core.Globals.GlobalTypePath):Null<Variant> {
		var k = ModuleCache.key(path);
		if (s.kept != null) {
			if (keptByKey == null) {
				keptByKey = new Map();
				for (v in s.kept)
					if (v.role == 0) keptByKey.set(v.key, v);
			}
			return keptByKey.get(k);
		}
		var v = s.chosen[0].get(k);
		return v != null && s.verdicts.get(v.roleKey()) == Valid ? v : null;
	}

	static function pathOf(k:String):core.Globals.GlobalTypePath {
		var i = k.indexOf("|");
		var pack = k.substr(0, i);
		return {pack: pack == "" ? [] : pack.split("/"), name: k.substr(i + 1)};
	}

	// the build's part of the key (l: the lowering, for the runtime's Haxe functions)
	@:access(hxmc.ir.Lower)
	function prefixOf(l:Lower):String {
		if (prefix != null) return prefix;
		var parts = [MAGIC, s.indexKey];
		parts.push([
			Lower.targetCode, Lower.targetPlatform, Lower.targetOs, Lower.targetArm, Lower.mirHost, Lower.lines ? 1 : 0, Lower.bounds,
			Lower.nullChecks ? 1 : 0, Lower.spanChecks ? 1 : 0, Lower.classSpans ? 1 : 0, Lower.interp ? 1 : 0
		].join(","));
		parts.push([for (r in Lower.resources) r.name].join("\x01"));
		// (the runtime's functions implemented in Haxe: bindHosts calls them in place of the runtime's)
		var hosts = [
			for (n => h in l.hostImpls)
				n + "=" + core.Globals.sTypePath(h.c.clModule.mPath) + ":" + core.Globals.sTypePath(h.c.clPath) + "." + h.cf.cfName
		];
		hosts.sort(Reflect.compare);
		parts.push(hosts.join("\x01"));
		var defs = [for (k => v in com.defines.values) k + "=" + v];
		defs.sort(Reflect.compare);
		parts.push(defs.join("\x01"));
		var feats = [for (k => v in com.features) k + "=" + (v ? 1 : 0)];
		feats.sort(Reflect.compare);
		parts.push(feats.join("\x01"));
		for (k in FILTER_MODULES) {
			var v = keptVariant(pathOf(k));
			if (v == null) {
				disabled = "no key for " + k;
				return prefix = "";
			}
			parts.push(k + "=" + v.typedKey());
		}
		return prefix = Fingerprint.hash(parts.join("\x00"));
	}

	function keyOf(l:Lower, m:ModuleDef, read:Bool):Null<CacheKey> {
		var p = prefixOf(l);
		if (p == "") return null;
		var v = keptVariant(m.mPath);
		if (v == null) return null;
		// (read: restored as it is)
		if (read && s.verdicts.get(v.roleKey()) != Valid) return null;
		return CacheKey.of(CacheKind.LoweredBodies, p, [v.typedKey()]);
	}

	// the stored entry of a field (skey: CachedLower.stableKey) of module m,
	// its calls read (its bodies when replayed), or null
	public function find(l:CachedLower, m:ModuleDef, skey:String):Null<Entry> {
		var mk = ModuleCache.key(m.mPath);
		var sm = loaded.get(mk);
		if (sm == null) {
			if (loaded.exists(mk)) return null;
			sm = load(l, m);
			loaded.set(mk, sm);
			if (sm == null) return null;
		}
		var pos = sm.dir.get(skey);
		if (pos == null) return null;
		var t0 = haxe.Timer.stamp();
		var r = new EntryReader(sm, this, false);
		var e = try r.read(pos) catch (x:Dynamic) {
			if (Sys.getEnv("HXMC_LOWER_WHY") == "1") Sys.println("hxmc: lowered bodies: " + skey + " not read: " + Std.string(x));
			null;
		}
		readTime += haxe.Timer.stamp() - t0;
		entriesRead++;
		if (e == null || r.broken) {
			entriesBroken++;
			return null;
		}
		return e;
	}

	// a closure's entry read (lazy: where it is), its calls (its body when replayed)
	public function lambdaAt(lazy:Entry):Entry {
		var t0 = haxe.Timer.stamp();
		var r = new EntryReader(lazy.lazy.sm, this, false);
		var e = try r.read(lazy.lazy.pos) catch (x:Dynamic) throw new Mismatch("a stored closure: " + Std.string(x));
		readTime += haxe.Timer.stamp() - t0;
		if (r.broken) throw new Mismatch("a stored closure names what the build does not have");
		return e;
	}

	function load(l:CachedLower, m:ModuleDef):Null<StoredModule> {
		var k = keyOf(l, m, true);
		if (k == null) return null;
		var t0 = haxe.Timer.stamp();
		var r = s.store.readIndex(k);
		var sm = r == null ? null : try new StoredModule(r.data, gens++) catch (x:Dynamic) null;
		readTime += haxe.Timer.stamp() - t0;
		if (sm == null) {
			modulesMissing++;
			return null;
		}
		s.store.used(k);
		modulesRead++;
		return sm;
	}

	// the bodies of the lowering l (its last pass) written: per module some of
	// whose fields were lowered from their typed expressions in this build,
	// those entries with the others of its stored entry
	public function save(l:CachedLower) {
		var p = prefixOf(l);
		if (p == "") return;
		var t0 = haxe.Timer.stamp();
		var mods = new Map<String, {m:ModuleDef, entries:Map<String, Entry>}>();
		var order = [];
		for (k in l.keyed) {
			if (!k.fresh) continue;
			var mk = ModuleCache.key(k.m.mPath);
			var g = mods.get(mk);
			if (g == null) {
				mods.set(mk, g = {m: k.m, entries: new Map()});
				order.push(mk);
			}
			g.entries.set(k.skey, k.e);
		}
		for (mk in order) {
			var g = mods.get(mk);
			var key = keyOf(l, g.m, false);
			if (key == null) continue;
			var v = keptVariant(g.m.mPath);
			if (v == null || s.verdicts.get(v.roleKey()) == Retyped) continue;
			var b = try {
				if (analyzed(g.m)) throw new NotStorable("@:analyzer metadata");
				// (the stored entry's others, read back as written)
				var rawLambdas = new ObjectMap<FuncInfo, Entry>();
				var sm = loaded.get(mk);
				if (sm != null)
					for (sk => pos in sm.dir)
						if (!g.entries.exists(sk)) {
							var r = new EntryReader(sm, this, true);
							var e = try r.read(pos) catch (_:Dynamic) null;
							if (e == null || r.broken) continue;
							for (f => x in r.lambdas)
								rawLambdas.set(f, x);
							g.entries.set(sk, e);
						}
				new BodyWriter(paths, fi -> {
					var e = l.lambdaOf(fi);
					e != null ? e : rawLambdas.get(fi);
				}).write(g.entries);
			} catch (e:NotStorable) {
				notStorable++;
				if (notStorableWhy == null) notStorableWhy = core.Globals.sTypePath(g.m.mPath) + ": " + e.why;
				if (Sys.getEnv("HXMC_LOWER_WHY") == "1") Sys.println("hxmc: lowered bodies: " + core.Globals.sTypePath(g.m.mPath) + " not kept: " + e.why);
				continue;
			}
			if (s.store.writeIndex(key, [], b)) {
				modulesWritten++;
				bytesWritten += b.length;
			}
		}
		writeTime = haxe.Timer.stamp() - t0;
	}

	// whether a type of the module has @:analyzer metadata (the analyzer
	// optimizes there, reading the purity of other modules' bodies)
	static function analyzed(m:ModuleDef):Bool {
		inline function has(ml:core.Ast.Metadata):Bool
			return core.Meta.has(Analyzer, ml);
		for (t in m.mTypes)
			switch t {
				case TClassDecl(c):
					if (has(c.clMeta)) return true;
					for (cf in c.clOrderedFields)
						if (has(cf.cfMeta)) return true;
					for (cf in c.clOrderedStatics)
						if (has(cf.cfMeta)) return true;
					if (c.clConstructor != null && has(c.clConstructor.cfMeta)) return true;
				case TAbstractDecl(a):
					if (has(a.aMeta)) return true;
				case _:
			}
		return false;
	}

	public function newGen():Int
		return -1000000 - (gens++);

	public function summary():String
		return '${replayed} replayed from ${modulesRead} modules (${entriesRead} entries read, ${entriesBroken} naming what the build does not have; ${modulesMissing} modules without; read ${Std.int(readTime * 1000)} ms, replayed ${Std.int(replayTime * 1000)} ms, their bodies ${Std.int(bodyTime * 1000)} ms), '
			+ '${modulesWritten} modules written (${bytesWritten} bytes, ${Std.int(writeTime * 1000)} ms), ${notStorable} not storable'
			+ (notStorableWhy != null ? ' (${notStorableWhy})' : '') + (disabled != null ? ' (not used: ${disabled})' : '');
}

// a class or enum a stored entry names in a field type: the entry's object
// of that name (target), else compared by name only (CachedLower.bindClass)
class WeakClass extends ClassInfo {
	public var target:Null<ClassInfo> = null;

	public function new(name)
		super(name, "", null);
}

class WeakEnum extends EnumInfo {
	public var target:Null<EnumInfo> = null;

	public function new(name)
		super(name, "");
}

class NotStorable {
	public var why:String;

	public function new(why)
		this.why = why;
}

// a module's stored entry: its strings, and where each field's entry starts
class StoredModule {
	public final b:Bytes;
	public final strs:Array<String> = [];
	public final dir = new Map<String, Int>();
	// (the numbers of the builds that recorded its entries, numbered anew: Entry.gen)
	public final gens = new Map<Int, Int>();

	public function new(b:Bytes, _) {
		this.b = b;
		var magic = LoweredBodies.MAGIC + "\n";
		if (b.length < magic.length || b.getString(0, magic.length) != magic) throw "not an entry of this version";
		var pos = magic.length;
		function u():Int {
			var r = 0, shift = 0;
			while (true) {
				var x = b.get(pos++);
				r |= (x & 0x7f) << shift;
				if (x & 0x80 == 0) return r;
				shift += 7;
			}
		}
		for (_ in 0...u()) {
			var n = u();
			strs.push(b.getString(pos, n));
			pos += n;
		}
		for (_ in 0...u()) {
			var k = strs[u() - 1];
			var n = u();
			dir.set(k, pos);
			pos += n;
		}
		if (pos != b.length) throw "trailing bytes";
	}
}

// the typed program's types by module and path (LowerCache.typeKey), from
// every module of the build (com.modules: also the types DCE removed, which
// a body may still name in a type); null: two of one path
class TypePaths {
	public final types = new Map<String, Null<ModuleType>>();
	// (and each one's key, by its object: TClass, TEnum, TAbstract, TDef)
	public final keys = new ObjectMap<{}, String>();

	public function new(com:context.Common.CommonContext) {
		for (m in com.modules)
			for (t in m.mTypes) {
				var k = key(t);
				types.set(k, types.exists(k) ? null : t);
				keys.set(switch t {
					case TClassDecl(c): c;
					case TEnumDecl(e): e;
					case TAbstractDecl(a): a;
					case TTypeDecl(d): d;
				}, k);
			}
	}

	// the key of a type of the build, found again by it (null: none)
	public function keyOf(o:{}):Null<String> {
		var k = keys.get(o);
		return k != null && types.get(k) != null ? k : null;
	}

	public static function key(t:ModuleType):String
		return switch t {
			case TClassDecl(c): CachedLower.typeKey(c.clModule, c.clPath);
			case TEnumDecl(e): CachedLower.typeKey(e.eModule, e.ePath);
			case TAbstractDecl(a): CachedLower.typeKey(a.aModule, a.aPath);
			case TTypeDecl(d): CachedLower.typeKey(d.tModule, d.tPath);
		}
}

// ---- the codec
//
// A module's entry: MAGIC, its strings, then per field its key and the
// length and bytes of its entry. A field's entry: the entry (its function,
// build, flags, closures named, locals, calls; a closure written in its body:
// after the call making it, its own entry so), then the objects its bodies
// (its own and its closures', in that order) name that its calls did not,
// then each body (its length first). An object is written where it is first
// named: 0 null, 1 the catches' mark (CachedLower.MARK), 2 a new one (its
// kind, then what it is), else the one numbered n - 3, numbered in the order
// they are written; a type of the typed program likewise, numbered after its
// parts.

private enum abstract K(Int) to Int from Int {
	var KClass = 0;
	var KEnum = 1;
	var KFunc = 2;
	var KLambda = 3;
	var KSig = 4;
	var KShape = 5;
	var KLocal = 6;
}

class BodyWriter {
	final paths:TypePaths;
	final lambdaOf:FuncInfo->Null<Entry>;
	var b = new Buf();
	var strs = new Map<String, Int>();
	var strList:Array<String> = [];
	// (per field's entry: its objects and types)
	var objs = new ObjectMap<{}, Int>();
	var nobj = 0;
	var ts = new ObjectMap<{}, Int>();
	var nt = 0;
	var gens = new Map<Int, Int>();
	var counts = [0, 0]; // (the builds numbered, the objects tyKey numbered)
	var tests:Null<ObjectMap<{}, Ex>> = null;
	// (writing a body: the objects it names first written to defs)
	var defs:Null<Buf> = null;
	var depth = 0;
	var saved:Null<Buf> = null;

	public function new(paths, lambdaOf) {
		this.paths = paths;
		this.lambdaOf = lambdaOf;
	}

	// (a closure's entry, a unit of its own: the module's strings and numbers)
	function child():BodyWriter {
		var w = new BodyWriter(paths, lambdaOf);
		w.strs = strs;
		w.strList = strList;
		w.gens = gens;
		w.counts = counts;
		w.ids = ids;
		w.tyKeys = tyKeys;
		return w;
	}

	public function write(entries:Map<String, Entry>):Bytes {
		var keys = [for (k in entries.keys()) k];
		keys.sort(Reflect.compare);
		var out = [];
		for (k in keys) {
			var e = entries.get(k);
			if (e.tf == null && !e.fromStore) continue;
			str(k);
			out.push({k: strs.get(k), b: field(e)});
		}
		b = new Buf(1 << 16);
		b.str(LoweredBodies.MAGIC + "\n");
		u(strList.length);
		for (s in strList) {
			var sb = Bytes.ofString(s);
			u(sb.length);
			b.bytes(sb);
		}
		u(out.length);
		for (o in out) {
			u(o.k + 1);
			u(o.b.length);
			b.bytes(o.b);
		}
		return b.toBytes();
	}

	function field(e:Entry):Bytes {
		objs = new ObjectMap();
		nobj = 0;
		ts = new ObjectMap();
		nt = 0;
		var head = new Buf(1024);
		b = head;
		var order = [];
		entry(e, order);
		var d = new Buf(256);
		var bodies = [];
		for (x in order) {
			var bb = new Buf(1024);
			b = bb;
			defs = d;
			tests = x.tests;
			stmts(x.body);
			bodies.push(bb.toBytes());
		}
		defs = null;
		tests = null;
		b = head;
		head.buf(d);
		u(0);
		for (x in bodies) {
			u(x.length);
			head.bytes(x);
		}
		return head.toBytes();
	}

	inline function u(v:Int) {
		while (v >>> 7 != 0) {
			b.u8((v & 0x7f) | 0x80);
			v = v >>> 7;
		}
		b.u8(v);
	}

	inline function z(v:Int)
		u((v << 1) ^ (v >> 31));

	function str(s:Null<String>) {
		if (s == null) {
			u(0);
			return;
		}
		var i = strs.get(s);
		if (i == null) {
			i = strList.length;
			strList.push(s);
			strs.set(s, i);
		}
		u(i + 1);
	}

	inline function bool(v:Bool)
		b.u8(v ? 1 : 0);

	// an entry's head: its function, build, flags, closures, locals and
	// calls (its closures' entries after the calls making them), its body
	// in order
	function entry(e:Entry, order:Array<Entry>) {
		order.push(e);
		func(e.fi);
		var g = gens.get(e.gen);
		if (g == null) gens.set(e.gen, g = counts[0]++);
		u(g);
		u((e.bound ? 1 : 0) | (e.hasTry ? 2 : 0));
		u(e.nlambdas);
		u(e.locals.length);
		for (x in e.locals)
			local(x);
		// (a type whose answer has no object of the lowering, or only objects an
		// earlier type's answer of the entry had: its replay skips it,
		// CachedLower.call's skipTy, so it is not written. Not a function type:
		// asked again, it lowers its arguments' types, which its signature does
		// not show; the same type object, though, is the same answer)
		var seen = new Map<String, Bool>();
		var log = [];
		for (c in e.log)
			switch c {
				case CTy(x, r):
					var k = tyKey(r);
					if (k != null && closes) {
						var i = ids.get(cast x);
						if (i == null) ids.set(cast x, i = counts[1]++);
						k = "t" + i;
					}
					if (k == null || seen.exists(k)) continue;
					seen.set(k, true);
					log.push(c);
				// (a call asked again with the same arguments and the same answer:
				// the lowering's answers to these are kept, so the call has no
				// effect the first did not have, and its replay checks nothing
				// more: not written)
				case CClass(_) | CEnum(_) | CCtorInfo(_) | CStatic(_) | CMethod(_) | CCtor(_) | CStructCtor(_) | CStructBox(_) | CStaticVar(_) | CReflect(_) |
					CReflectEnum(_) | CNeedsDispatch(_) | CRootDecl(_) | CSuperOf(_) | CRoot(_) | CSig(_) | CShape(_) | CGlobalTy(_) | CSelectorName(_) |
					CDefaults(_) | CFieldDefaults(_) | CExtern(_) | CSelector(_):
					var k = callKey(c);
					if (seen.exists(k)) continue;
					seen.set(k, true);
					log.push(c);
				case _:
					log.push(c);
			}
		u(log.length);
		for (c in log)
			call(c, order);
	}

	// a call by its kind, arguments and answer: strings, numbers and Bools by
	// value, every other value by its identity
	function callKey(c:LCall):String {
		inline function o(x:{}):String
			return "," + oid(x);
		inline function s(x:Null<String>):String
			return "," + sid(x);
		return switch c {
			case CClass(k, r): "a" + o(k) + o(r);
			case CEnum(e, r): "b" + o(e) + o(r);
			case CCtorInfo(ef, e, r): "c" + o(ef) + o(e) + o(r);
			case CStatic(k, cf, r): "d" + o(k) + o(cf) + o(r);
			case CMethod(k, cf, r): "e" + o(k) + o(cf) + o(r);
			case CCtor(k, r): "f" + o(k) + o(r);
			case CStructCtor(k, r): "g" + o(k) + o(r);
			case CStructBox(name, r): "h" + s(name) + o(r);
			case CStaticVar(k, cf, r): "i" + o(k) + o(cf) + "," + r;
			case CReflect(k): "j" + o(k);
			case CReflectEnum(e): "k" + o(e);
			case CNeedsDispatch(k, name, r): "l" + o(k) + s(name) + (r ? ",1" : ",0");
			case CRootDecl(k, name, r): "m" + o(k) + s(name) + o(r);
			case CSuperOf(ci, r): "n" + o(ci) + o(r);
			case CRoot(r): "o" + o(r);
			// (asked again, its replay skips one whose answer is bound)
			case CSig(_, _, r): "p" + o(r);
			case CShape(_, r): "q" + o(r);
			case CGlobalTy(g, r): "r," + g + o(cast r);
			case CSelectorName(sel, r): "s," + sel + s(r);
			case CDefaults(f, key): "t" + o(f) + s(key);
			case CFieldDefaults(k, cf, key): "u" + o(k) + o(cf) + s(key);
			case CExtern(sym, k, cf): "v" + s(sym) + o(k) + o(cf);
			case CSelector(name, sg, r): "w" + s(name) + o(sg) + "," + r;
			case _: throw "not a call kept once";
		}
	}

	function oid(x:{}):Int {
		if (x == null) return -1;
		var i = ids.get(x);
		if (i == null) ids.set(x, i = counts[1]++);
		return i;
	}

	// (a string's number in the module's strings)
	function sid(x:Null<String>):Int {
		if (x == null) return -1;
		var i = strs.get(x);
		if (i == null) {
			i = strList.length;
			strList.push(x);
			strs.set(x, i);
		}
		return i;
	}

	// a type's objects of the lowering by their identity (null: none)
	var ids = new ObjectMap<{}, Int>();
	var closes = false; // (the last tyKey met a function type)

	// (per answer: its key, and whether it met a function type)
	var tyKeys = new ObjectMap<{}, {k:Null<String>, closes:Bool}>();

	function tyKey(t:Ty):Null<String> {
		var m = tyKeys.get(cast t);
		if (m != null) {
			closes = m.closes;
			return m.k;
		}
		var k = tyKey1(t);
		tyKeys.set(cast t, {k: k, closes: closes});
		return k;
	}

	function tyKey1(t:Ty):Null<String> {
		var b = new StringBuf();
		var any = false;
		closes = false;
		function id(o:{}) {
			var i = ids.get(o);
			if (i == null) ids.set(o, i = counts[1]++);
			b.add(i);
			any = true;
		}
		function ty(t:Ty)
			switch t {
				case TRef(r):
					switch r {
						case RObj(c):
							b.add("o");
							id(c);
						case REnum(e):
							b.add("e");
							if (e != null) id(e);
						case RCtor(c):
							b.add("c");
							id(c);
						case RClos(s):
							b.add("f");
							id(s);
							closes = true;
						case RArr(t) | RNativeArr(t) | RBox(t) | RNull(t):
							b.add(Type.enumIndex(r));
							ty(t);
						case _:
							b.add(Type.enumIndex(r));
					}
				case _:
					b.add(Type.enumIndex(t));
			}
		ty(t);
		return any ? b.toString() : null;
	}

	// ---- IR objects

	// false: written as a reference; true: a new one, its kind written, what it
	// is to follow, then done (in a body, it goes to defs, the body referring
	// to it)
	function def(o:{}, k:K):Bool {
		if (o == null) {
			u(0);
			return false;
		}
		if (o == CachedLower.MARK) {
			u(1);
			return false;
		}
		var i = objs.get(o);
		if (i != null) {
			u(i + 3);
			return false;
		}
		if (defs != null && depth == 0) {
			saved = b;
			b = defs;
		}
		depth++;
		u(2);
		u(k);
		objs.set(o, nobj++);
		return true;
	}

	function done(o:{}) {
		depth--;
		if (depth == 0 && saved != null) {
			b = saved;
			saved = null;
			u(objs.get(o) + 3);
		}
	}

	function cls(c:Null<ClassInfo>) {
		if (!def(c, KClass)) return;
		str(c.name);
		bool(c.isInterface);
		str(c.sup == null ? null : c.sup.name);
		u(c.fields.length);
		for (f in c.fields) {
			str(f.name);
			ty(f.ty, true);
		}
		done(c);
	}

	function en(e:Null<EnumInfo>) {
		if (!def(e, KEnum)) return;
		str(e.name);
		u(e.ctors.length);
		for (c in e.ctors) {
			if (c.en != e) throw new NotStorable("a constructor of another enum");
			str(c.name);
			z(c.tag);
			z(c.global);
			u(c.params.length);
			for (p in c.params)
				ty(p, true);
		}
		done(e);
	}

	function ctor(c:CtorInfo) {
		if (c.en == null) throw new NotStorable("a constructor without its enum");
		var i = -1;
		for (k in 0...c.en.ctors.length)
			if (c.en.ctors[k] == c) i = k;
		if (i < 0) throw new NotStorable("a constructor not of its enum");
		en(c.en);
		u(i);
	}

	function func(f:Null<FuncInfo>) {
		if (!def(f, KFunc)) return;
		str(f.name);
		u(f.args.length);
		for (a in f.args)
			local(a);
		ty(f.ret, false);
		cls(f.selfClass);
		lambda(f.lambda);
		done(f);
	}

	function lambda(l:Null<LambdaInfo>) {
		if (!def(l, KLambda)) return;
		sig(l.sig);
		u(l.captures.length);
		for (c in l.captures)
			local(c);
		func(l.fn);
		done(l);
	}

	function sig(s:Null<SigInfo>) {
		if (!def(s, KSig)) return;
		str(s.key);
		u(s.args.length);
		for (a in s.args)
			ty(a, false);
		ty(s.ret, false);
		done(s);
	}

	function shape(s:Null<ShapeInfo>) {
		if (!def(s, KShape)) return;
		u(s.fields.length);
		for (f in s.fields) {
			str(f.name);
			ty(f.ty, true);
		}
		done(s);
	}

	function local(l:Local) {
		if (!def(l, KLocal)) return;
		z(l.id);
		str(l.name);
		ty(l.ty, false);
		done(l);
	}

	// (weak: a class's, constructor's or shape's field types: the classes
	// and enums by name)
	function ty(t:Ty, weak:Bool) {
		switch t {
			case TI32:
				u(0);
			case TBool:
				u(1);
			case TU8:
				u(2);
			case TF64:
				u(3);
			case TI64:
				u(4);
			case TVoid:
				u(5);
			case TRef(r):
				u(6);
				rty(r, weak);
			case TStruct(name, size):
				u(7);
				str(name);
				z(size);
		}
	}

	function rty(r:RefTy, weak:Bool) {
		switch r {
			case RObj(c):
				u(0);
				if (weak) str(c.name) else cls(c);
			case REnum(e):
				u(1);
				if (weak) str(e == null ? null : e.name) else en(e);
			case RCtor(c):
				u(2);
				ctor(c);
			case RArr(t):
				u(3);
				ty(t, weak);
			case RNativeArr(t):
				u(4);
				ty(t, weak);
			case RClos(s):
				u(5);
				sig(s);
			case RBox(t):
				u(6);
				ty(t, weak);
			case RNull(t):
				u(7);
				ty(t, weak);
			case RStr:
				u(8);
			case RAnon:
				u(9);
			case RAny:
				u(10);
			case RType:
				u(11);
			case RNative(p):
				u(12);
				str(p);
		}
	}

	function typeRef(t:TypeRef) {
		switch t {
			case TRClass(c):
				u(0);
				cls(c);
			case TREnum(e):
				u(1);
				en(e);
			case TRBuiltin(n):
				u(2);
				str(n);
		}
	}

	// ---- statements and expressions

	function stmts(ss:Vector<Stmt>) {
		u(ss.length);
		for (s in ss)
			stmt(s);
	}

	function exs(xs:Vector<Ex>) {
		u(xs.length);
		for (x in xs)
			ex(x);
	}

	function stmt(s:Stmt) {
		u(Type.enumIndex(s));
		switch s {
			case SSet(l, e):
				local(l);
				ex(e);
			case SExpr(e):
				ex(e);
			case SSetField(c, idx, o, v):
				cls(c);
				z(idx);
				ex(o);
				ex(v);
			case SAnonSet(name, t, o, v):
				str(name);
				ty(t, false);
				ex(o);
				ex(v);
			case SArrSet(t, a, i, v):
				ty(t, false);
				local(a);
				ex(i);
				ex(v);
			case SArrPush(t, a, v):
				ty(t, false);
				local(a);
				ex(v);
			case SBoxSet(t, x, v):
				ty(t, false);
				ex(x);
				ex(v);
			case SSetGlobal(g, v):
				z(g);
				ex(v);
			case SIf(c, a, e):
				ex(c);
				stmts(a);
				stmts(e);
			case SLoop(body):
				stmts(body);
			case SBreak | SContinue:
			case SSwitch(e, cases, def):
				ex(e);
				u(cases.length);
				for (c in cases) {
					u(c.values.length);
					for (v in c.values)
						z(v);
					stmts(c.body);
				}
				stmts(def);
			case SReturn(e):
				bool(e != null);
				if (e != null) ex(e);
			case SThrow(e):
				ex(e);
			case STry(body, cs):
				stmts(body);
				u(cs.length);
				for (c in cs) {
					if (c.test == null) bool(false) else {
						var t = tests == null ? null : tests.get(c);
						if (t == null) throw new NotStorable("a catch without its test");
						bool(true);
						ex(t);
					}
					local(c.l);
					stmts(c.body);
				}
			case SCold(id, x):
				z(id);
				stmt(x);
			case SPos(file, line):
				str(file);
				z(line);
		}
	}

	function ex(e:Ex) {
		u(Type.enumIndex(e));
		switch e {
			case EInt(v):
				z(v);
			case EF64(v):
				var x = haxe.io.FPHelper.doubleToI64(v);
				b.u32(x.low);
				b.u32(x.high);
			case EStr(s):
				str(s);
			case ENull(t):
				ty(t, false);
			case ELocal(l):
				local(l);
			case EGlobal(g, t):
				z(g);
				ty(t, false);
			case EBin(op, a, c):
				u(Type.enumIndex(op));
				ex(a);
				ex(c);
			case ENot(a):
				ex(a);
			case EConv(op, a):
				u(Type.enumIndex(op));
				ex(a);
			case EBox(t, a) | EUnbox(t, a) | ECast(t, a) | EBoxGet(t, a) | ENewBox(t, a):
				ty(t, false);
				ex(a);
			case EField(c, idx, o) | EFieldAddr(c, idx, o):
				cls(c);
				z(idx);
				ex(o);
			case EAnonGet(name, t, o, hint):
				str(name);
				ty(t, false);
				ex(o);
				shape(hint);
			case EInstOf(c, a):
				cls(c);
				ex(a);
			case EEnumTag(a, n):
				ex(a);
				en(n);
			case EEnumParam(c, idx, a):
				ctor(c);
				z(idx);
				ex(a);
			case EArrLen(a):
				ex(a);
			case EArrGet(t, a, i) | EArrGetU(t, a, i):
				ty(t, false);
				ex(a);
				ex(i);
			case ECapture(l, idx, c):
				lambda(l);
				z(idx);
				ex(c);
			case EType(t):
				typeRef(t);
			case ECall(f, args):
				func(f);
				exs(args);
			case ECallDispatch(sel, s, args):
				z(sel);
				sig(s);
				exs(args);
			case ECallClos(s, c, args):
				sig(s);
				ex(c);
				exs(args);
			case ECallAnon(name, s, o, args):
				str(name);
				sig(s);
				ex(o);
				exs(args);
			case ECallHost(name, args, ret):
				str(name);
				exs(args);
				ty(ret, false);
			case ENewObj(c):
				cls(c);
			case ENewEnum(c, args):
				ctor(c);
				exs(args);
			case ENewArr(t, vals):
				ty(t, false);
				exs(vals);
			case ENewClos(l, caps):
				lambda(l);
				exs(caps);
			case ENewAnon(sh, vals):
				shape(sh);
				exs(vals);
		}
	}

	// ---- the typed program's objects, by module and path

	function path(t:ModuleType) {
		var o:{} = switch t {
			case TClassDecl(c): c;
			case TEnumDecl(e): e;
			case TAbstractDecl(a): a;
			case TTypeDecl(d): d;
		}
		var k = paths.keyOf(o);
		if (k == null) throw new NotStorable("a type not found by its path: " + TypePaths.key(t));
		str(k);
	}

	function tclass(c:Null<TClass>) {
		if (c == null) {
			u(0);
			return;
		}
		switch c.clKind {
			case KTypeParameter(_): throw new NotStorable("a type parameter's class");
			case _:
		}
		u(1);
		path(TClassDecl(c));
	}

	function tenum(e:TEnum)
		path(TEnumDecl(e));

	// a field: its class, how the class has it, its name
	function tfield(c:TClass, cf:Null<TClassField>) {
		tclass(c);
		if (cf == null) {
			u(0);
			return;
		}
		var k = if (c.clConstructor == cf) 1 else if (c.clStatics.get(cf.cfName) == cf) 2 else if (c.clFields.get(cf.cfName) == cf) 3 else if (c.clInit == cf) 4 else 0;
		if (k == 0) throw new NotStorable("a field not found by its name: " + cf.cfName);
		u(k);
		str(cf.cfName);
	}

	// the class declaring field cf found from c (CRootDecl's answer)
	function owner(c:TClass, cf:TClassField, depth = 0):Null<TClass> {
		if (c == null || depth > 64) return null;
		if (c.clFields.get(cf.cfName) == cf || c.clStatics.get(cf.cfName) == cf) return c;
		if (c.clSuper != null) {
			var r = owner(c.clSuper.cls, cf, depth + 1);
			if (r != null) return r;
		}
		for (i in c.clImplements) {
			var r = owner(i.cls, cf, depth + 1);
			if (r != null) return r;
		}
		return null;
	}

	// a type: 0 one written before (its number), else what it is, numbered
	// after its parts (by the type object; a type parameter by its class; a
	// class's statics, Class<C>, by its typedef)
	function t(x:T, depth = 0) {
		if (depth > 100) throw new NotStorable("a type too deep");
		var key:{} = switch x {
			case TInst(c, _) if (c.clKind.match(KTypeParameter(_))): c;
			case TType(d, ps) if (staticsOf(d, ps) != null): d;
			case _: cast x;
		}
		var i = ts.get(key);
		if (i != null) {
			u(0);
			u(i);
			return;
		}
		t1(x, depth);
		ts.set(key, nt++);
	}

	function t1(x:T, depth:Int) {
		switch x {
			case TMono(m):
				if (m.tmType == null) u(1) else {
					u(2);
					t(m.tmType, depth + 1);
				}
			case TInst(c, ps):
				if (c.clKind.match(KTypeParameter(_))) u(3) else {
					u(4);
					path(TClassDecl(c));
					params(ps, depth);
				}
			case TEnum(e, ps):
				u(5);
				path(TEnumDecl(e));
				params(ps, depth);
			case TAbstract(a, ps):
				u(6);
				path(TAbstractDecl(a));
				params(ps, depth);
			case TType(d, ps):
				// (a class's, enum's or abstract's statics, Class<C>: a typedef of
				// no module; Lower.ty reads its expansion)
				var st = staticsOf(d, ps);
				if (st != null) t1(st, depth + 1) else {
					u(7);
					path(TTypeDecl(d));
					params(ps, depth);
				}
			case TFun(s):
				u(8);
				u(s.args.length);
				for (a in s.args) {
					str(a.name);
					bool(a.optional);
					t(a.type, depth + 1);
				}
				t(s.ret, depth + 1);
			case TAnon(an):
				switch an.aStatus {
					case ClassStatics(c):
						u(10);
						path(TClassDecl(c));
					case EnumStatics(e):
						u(11);
						path(TEnumDecl(e));
					case AbstractStatics(a):
						u(12);
						path(TAbstractDecl(a));
					case _:
						u(9);
				}
			case TDynamic(_):
				u(13);
			case TLazy(l):
				switch l.value {
					case LAvailable(v):
						u(14);
						t(v, depth + 1);
					case _:
						throw new NotStorable("a lazy type not forced");
				}
		}
	}

	function staticsOf(d:TDef, ps:TParams):Null<T> {
		if (ps.length > 0 || paths.keys.exists(d)) return null;
		return switch d.tType {
			case TAnon(an):
				switch an.aStatus {
					case ClassStatics(_) | EnumStatics(_) | AbstractStatics(_): d.tType;
					case _: null;
				}
			case _: null;
		}
	}

	function params(ps:TParams, depth:Int) {
		u(ps.length);
		for (p in ps)
			t(p, depth + 1);
	}

	function tys(l:Array<Ty>) {
		u(l.length);
		for (x in l)
			ty(x, false);
	}

	function call(c:LCall, order:Array<Entry>) {
		u(Type.enumIndex(c));
		switch c {
			case CTy(x, r):
				t(x);
				ty(r, false);
			case CClass(k, r):
				tclass(k);
				cls(r);
			case CEnum(e, r):
				tenum(e);
				en(r);
			case CCtorInfo(ef, e, r):
				tenum(e);
				if (e.eConstrs.get(ef.efName) != ef) throw new NotStorable("a constructor not found by its name");
				str(ef.efName);
				ctor(r);
			case CStatic(k, cf, r) | CMethod(k, cf, r):
				tfield(k, cf);
				func(r);
			case CCtor(k, r) | CStructCtor(k, r):
				tclass(k);
				func(r);
			case CStructBox(name, r):
				str(name);
				cls(r);
			case CStaticVar(k, cf, r):
				tfield(k, cf);
				z(r);
			case CReflect(k):
				tclass(k);
			case CReflectEnum(e):
				tenum(e);
			case CStaticClos(f, r):
				func(f);
				lambda(r);
			case CHostClos(name, s, self, r):
				str(name);
				sig(s);
				bool(self != null);
				if (self != null) ty(self, false);
				lambda(r);
			case CCtorClos(ci, s, r):
				ctor(ci);
				sig(s);
				lambda(r);
			case CBoundClos(f, d, o, r):
				func(f);
				bool(d != null);
				if (d != null) {
					z(d.sel);
					sig(d.sig);
					tys(d.args);
					tclass(d.cls);
				}
				func(o);
				lambda(r);
			case CAdapter(from, to, r):
				sig(from);
				sig(to);
				lambda(r);
			case CDynAdapter(to, r):
				sig(to);
				lambda(r);
			case CLambda(s, caps, name, module, r):
				sig(s);
				u(caps.length);
				for (x in caps)
					local(x);
				str(name);
				str(module);
				lambda(r);
				var body = lambdaOf(r.fn);
				if (body == null) throw new NotStorable("closure " + name + " without its body");
				// (its entry: a unit of its own, read when the closure's body is replayed)
				var unit = child().field(body);
				u(unit.length);
				b.bytes(unit);
			case CSelector(name, s, r):
				str(name);
				sig(s);
				z(r);
			case CNeedsDispatch(k, name, r):
				tclass(k);
				str(name);
				bool(r);
			case CLookup(k, name, r):
				tclass(k);
				str(name);
				bool(r != null);
				if (r != null) tfield(r.cls, r.field);
			case CImplementors(k, name, r):
				tclass(k);
				str(name);
				u(r.length);
				for (x in r)
					tfield(x.cls, x.field);
			case CRootDecl(k, name, r):
				tclass(k);
				str(name);
				bool(r != null);
				if (r != null) {
					var o = owner(k, r);
					if (o == null) throw new NotStorable("the declaration of " + name + " not found");
					tfield(o, r);
				}
			case CSuperOf(ci, r):
				cls(ci);
				tclass(r);
			case CRoot(r):
				cls(r);
			case CSig(args, ret, r):
				tys(args);
				ty(ret, false);
				sig(r);
			case CShape(fields, r):
				u(fields.length);
				for (f in fields) {
					str(f.name);
					ty(f.ty, false);
				}
				shape(r);
			case CGlobalTy(g, r):
				z(g);
				ty(r, false);
			case CSelectorName(sel, r):
				z(sel);
				str(r);
			case CDefaults(f, key):
				func(f);
				str(key);
			case CFieldDefaults(k, cf, key):
				tfield(k, cf);
				str(key);
			case CExtern(sym, k, cf):
				str(sym);
				tfield(k, cf);
		}
	}
}

// A field's entry read: its head and its closures' (the calls), the objects
// its bodies name; each body read when asked (body): through the binding of
// the lowering replaying it (into the current build's objects), or as written
// (raw: an entry written again, LoweredBodies.save)
@:access(hxmc.CachedLower)
class EntryReader {
	final sm:StoredModule;
	final b:Bytes;
	final store:LoweredBodies;
	final raw:Bool;
	var pos = 0;
	var objs:Array<Dynamic> = [];
	var ts:Array<T> = [];
	public var broken = false;
	// (raw: the closures' entries by their function)
	public final lambdas = new ObjectMap<FuncInfo, Entry>();
	// (weak references: the objects of the entry by name, the placeholders)
	var classes = new Map<String, ClassInfo>();
	var enums = new Map<String, EnumInfo>();
	var weakClasses = new Map<String, WeakClass>();
	var weakEnums = new Map<String, WeakEnum>();
	// (a body read through the binding: the lowering replaying it; the
	// binding of the entry's objects, CachedLower.map while it is replayed)
	var m:Null<CachedLower> = null;
	public final map = new ObjectMap<{}, Dynamic>();
	var tests:Null<ObjectMap<{}, Ex>> = null;

	static final binops = Type.allEnums(BinOp);
	static final convops = Type.allEnums(ConvOp);

	public function new(sm:StoredModule, store, raw) {
		this.sm = sm;
		this.b = sm.b;
		this.store = store;
		this.raw = raw;
	}

	public function read(at:Int):Entry {
		pos = at;
		var order = [];
		var e = entry(order);
		// (the objects the bodies name)
		while (true) {
			var v = u();
			if (v == 0) break;
			if (v != 2) throw "an object expected";
			define(u());
		}
		pending = order.length;
		for (x in order) {
			var n = u();
			if (raw) {
				var p = pos;
				x.body = body(p, null);
				x.tests = tests;
				tests = null;
			} else x.src = {r: this, pos: pos};
			pos += n;
		}
		// (weak references: to the entry's object of that name, else by name)
		for (name => c in weakClasses)
			c.target = classes.get(name);
		for (name => e in weakEnums)
			e.target = enums.get(name);
		return e;
	}

	inline function byte():Int
		return b.get(pos++);

	function u():Int {
		var r = 0, shift = 0;
		while (true) {
			var x = byte();
			r |= (x & 0x7f) << shift;
			if (x & 0x80 == 0) return r;
			shift += 7;
		}
	}

	inline function z():Int {
		var v = u();
		return (v >>> 1) ^ -(v & 1);
	}

	function str():Null<String> {
		var i = u();
		return i == 0 ? null : sm.strs[i - 1];
	}

	inline function bool():Bool
		return byte() != 0;

	function entry(order:Array<Entry>):Entry {
		var fi = func();
		var e = new Entry(null, fi);
		order.push(e);
		var g = u();
		var gen = sm.gens.get(g);
		if (gen == null) sm.gens.set(g, gen = store.newGen());
		e.gen = gen;
		var flags = u();
		e.bound = flags & 1 != 0;
		e.hasTry = flags & 2 != 0;
		e.nlambdas = u();
		e.locals = [for (_ in 0...u()) local()];
		var n = u();
		for (_ in 0...n)
			e.log.push(call(order));
		e.fromStore = true;
		return e;
	}

	// an object: null, the mark, one read before, or a new one (read now)
	function obj():Dynamic {
		var v = u();
		if (v == 0) return null;
		if (v == 1) return CachedLower.MARK;
		if (v >= 3) return objs[v - 3];
		return define(u());
	}

	function define(k:Int):Dynamic {
		switch k {
			case KClass:
				var c = new ClassInfo(str(), "", null);
				objs.push(c);
				c.isInterface = bool();
				var sup = str();
				if (sup != null) c.sup = weakClass(sup);
				for (_ in 0...u()) {
					var name = str();
					c.fields.push({name: name, ty: ty(true)});
				}
				if (!classes.exists(c.name)) classes.set(c.name, c);
				return c;
			case KEnum:
				var e = new EnumInfo(str(), "");
				objs.push(e);
				var n = u();
				e.ctors = new Vector(n);
				for (i in 0...n) {
					var name = str();
					var tag = z();
					var c = new CtorInfo(e, name, tag, null);
					c.global = z();
					var np = u();
					c.params = new Vector(np);
					for (k in 0...np)
						c.params[k] = ty(true);
					e.ctors[i] = c;
				}
				if (!enums.exists(e.name)) enums.set(e.name, e);
				return e;
			case KFunc:
				var f = new FuncInfo(str(), "");
				objs.push(f);
				for (_ in 0...u())
					f.args.push(local());
				f.ret = ty(false);
				f.selfClass = cls();
				f.lambda = lambda();
				return f;
			case KLambda:
				var l = new LambdaInfo(-1, null, null, null);
				objs.push(l);
				l.sig = sig();
				var n = u();
				l.captures = new Vector(n);
				for (i in 0...n)
					l.captures[i] = local();
				l.fn = func();
				return l;
			case KSig:
				var s = new SigInfo(-1, null, TVoid, str());
				objs.push(s);
				var n = u();
				s.args = new Vector(n);
				for (i in 0...n)
					s.args[i] = ty(false);
				s.ret = ty(false);
				return s;
			case KShape:
				var s = new ShapeInfo(-1, null);
				objs.push(s);
				var n = u();
				s.fields = new Vector(n);
				for (i in 0...n) {
					var name = str();
					s.fields[i] = {name: name, ty: ty(true)};
				}
				return s;
			case KLocal:
				var l = new Local(0, null, TVoid);
				objs.push(l);
				l.id = z();
				l.name = str();
				l.ty = ty(false);
				return l;
			case _:
				throw "an object's kind expected: " + k;
		}
	}

	inline function cls():Null<ClassInfo>
		return obj();

	inline function en():Null<EnumInfo>
		return obj();

	inline function func():Null<FuncInfo>
		return obj();

	inline function lambda():Null<LambdaInfo>
		return obj();

	inline function sig():Null<SigInfo>
		return obj();

	inline function shape():Null<ShapeInfo>
		return obj();

	inline function local():Local
		return obj();

	function ctor():CtorInfo {
		var e = en();
		var i = u();
		if (e == null || i >= e.ctors.length) throw "a constructor expected";
		return e.ctors[i];
	}

	function weakClass(name:String):ClassInfo {
		var c = weakClasses.get(name);
		if (c == null) weakClasses.set(name, c = new WeakClass(name));
		return c;
	}

	function weakEnum(name:String):EnumInfo {
		var e = weakEnums.get(name);
		if (e == null) weakEnums.set(name, e = new WeakEnum(name));
		return e;
	}

	function ty(weak:Bool):Ty {
		return switch u() {
			case 0: TI32;
			case 1: TBool;
			case 2: TU8;
			case 3: TF64;
			case 4: TI64;
			case 5: TVoid;
			case 6: TRef(rty(weak));
			case 7:
				var name = str();
				TStruct(name, z());
			case x: throw "a type expected: " + x;
		}
	}

	function rty(weak:Bool):RefTy {
		return switch u() {
			case 0: RObj(weak ? weakClass(str()) : cls());
			case 1:
				if (weak) {
					var n = str();
					REnum(n == null ? null : weakEnum(n));
				} else REnum(en());
			case 2: RCtor(ctor());
			case 3: RArr(ty(weak));
			case 4: RNativeArr(ty(weak));
			case 5: RClos(sig());
			case 6: RBox(ty(weak));
			case 7: RNull(ty(weak));
			case 8: RStr;
			case 9: RAnon;
			case 10: RAny;
			case 11: RType;
			case 12: RNative(str());
			case x: throw "a reference type expected: " + x;
		}
	}

	// ---- a body: through the binding (m: CachedLower.stmts' copy), or as written

	// (its entries replayed: their types forgotten by the lowering)
	var pending = 0;

	public function replayed(l:Lower) {
		if (--pending > 0) return;
		for (t in ts)
			l.forgetTy(t);
		ts = [];
	}

	public function body(at:Int, m:Null<CachedLower>):Vector<Stmt> {
		var t0 = haxe.Timer.stamp();
		var saved = pos;
		pos = at;
		this.m = m;
		var r = stmts();
		this.m = null;
		pos = saved;
		if (m != null) store.bodyTime += haxe.Timer.stamp() - t0;
		return r;
	}

	inline function mObj<X>(o:X):X
		return m == null ? o : m.obj(o);

	inline function mLocal(l:Local):Local
		return m == null ? l : m.local(l);

	// (a body's types: their objects through the binding)
	function bty():Ty {
		var t = ty(false);
		return m == null ? t : m.mapTy(t);
	}

	function stmts():Vector<Stmt> {
		var n = u();
		var r = new Vector<Stmt>(n);
		for (i in 0...n)
			r[i] = stmt();
		return r;
	}

	function exs():Vector<Ex> {
		var n = u();
		var r = new Vector<Ex>(n);
		for (i in 0...n)
			r[i] = ex();
		return r;
	}

	// (each part read in its order: locals, not the arguments' evaluation order)
	function stmt():Stmt {
		switch u() {
			case 0:
				var l = mLocal(local());
				return SSet(l, ex());
			case 1:
				return SExpr(ex());
			case 2:
				var c = mObj(cls());
				var idx = z();
				var o = ex();
				return SSetField(c, idx, o, ex());
			case 3:
				var name = str();
				var t = bty();
				var o = ex();
				return SAnonSet(name, t, o, ex());
			case 4:
				var t = bty();
				var a = mLocal(local());
				var i = ex();
				return SArrSet(t, a, i, ex());
			case 5:
				var t = bty();
				var a = mLocal(local());
				return SArrPush(t, a, ex());
			case 6:
				var t = bty();
				var x = ex();
				return SBoxSet(t, x, ex());
			case 7:
				var g = z();
				if (m != null) g = m.glob(g);
				return SSetGlobal(g, ex());
			case 8:
				var c = ex();
				var a = stmts();
				return SIf(c, a, stmts());
			case 9:
				return SLoop(stmts());
			case 10:
				return SBreak;
			case 11:
				return SContinue;
			case 12:
				var e = ex();
				var n = u();
				var cases = new Vector<IrCase>(n);
				for (i in 0...n) {
					var nv = u();
					var values = new Vector<Int>(nv);
					for (k in 0...nv)
						values[k] = z();
					var body = stmts();
					cases[i] = {values: values, body: body};
				}
				return SSwitch(e, cases, stmts());
			case 13:
				return SReturn(bool() ? ex() : null);
			case 14:
				return SThrow(ex());
			case 15:
				var body = stmts();
				var n = u();
				var cs = new Vector<IrCatch>(n);
				for (i in 0...n) {
					var t = bool() ? ex() : null;
					var l = mLocal(local());
					var b = stmts();
					var c:IrCatch = if (m != null) {
						{test: t == null ? null : CachedLower.testOf(t), l: l, body: b};
					} else {
						{test: t == null ? null : x -> x, l: l, body: b};
					}
					if (t != null && m == null) {
						if (tests == null) tests = new ObjectMap();
						tests.set(c, t);
					}
					cs[i] = c;
				}
				return STry(body, cs);
			case 16:
				var id = z();
				return SCold(id, stmt());
			case 17:
				var file = str();
				return SPos(file, z());
			case x:
				throw "a statement expected: " + x;
		}
	}

	function ex():Ex {
		switch u() {
			case 0:
				return EInt(z());
			case 1:
				var v = b.getDouble(pos);
				pos += 8;
				return EF64(v);
			case 2:
				return EStr(str());
			case 3:
				return ENull(bty());
			case 4:
				var l = local();
				// (the catches' mark stays: a test's template)
				return ELocal(l == CachedLower.MARK ? l : mLocal(l));
			case 5:
				var g = z();
				if (m != null) g = m.glob(g);
				return EGlobal(g, bty());
			case 6:
				var op = binops[u()];
				var a = ex();
				return EBin(op, a, ex());
			case 7:
				return ENot(ex());
			case 8:
				var op = convops[u()];
				return EConv(op, ex());
			case 9:
				var t = bty();
				return EBox(t, ex());
			case 10:
				var t = bty();
				return EUnbox(t, ex());
			case 11:
				var c = mObj(cls());
				var idx = z();
				return EField(c, idx, ex());
			case 12:
				var c = mObj(cls());
				var idx = z();
				return EFieldAddr(c, idx, ex());
			case 13:
				var name = str();
				var t = bty();
				var o = ex();
				return EAnonGet(name, t, o, mObj(shape()));
			case 14:
				var t = bty();
				return ECast(t, ex());
			case 15:
				var c = mObj(cls());
				return EInstOf(c, ex());
			case 16:
				var a = ex();
				return EEnumTag(a, mObj(en()));
			case 17:
				var c = mObj(ctor());
				var idx = z();
				return EEnumParam(c, idx, ex());
			case 18:
				return EArrLen(ex());
			case 19:
				var t = bty();
				var a = ex();
				return EArrGet(t, a, ex());
			case 20:
				var t = bty();
				var a = ex();
				return EArrGetU(t, a, ex());
			case 21:
				var t = bty();
				return EBoxGet(t, ex());
			case 22:
				var l = mObj(lambda());
				var idx = z();
				return ECapture(l, idx, ex());
			case 23:
				var t = switch u() {
					case 0: TRClass(mObj(cls()));
					case 1: TREnum(mObj(en()));
					case 2: TRBuiltin(str());
					case x: throw "a type reference expected: " + x;
				}
				return EType(t);
			case 24:
				var f = mObj(func());
				return ECall(f, exs());
			case 25:
				var sel = z();
				if (m != null) sel = m.sel(sel);
				var s = mObj(sig());
				return ECallDispatch(sel, s, exs());
			case 26:
				var s = mObj(sig());
				var c = ex();
				return ECallClos(s, c, exs());
			case 27:
				var name = str();
				var s = mObj(sig());
				var o = ex();
				return ECallAnon(name, s, o, exs());
			case 28:
				var name = str();
				var args = exs();
				return ECallHost(name, args, bty());
			case 29:
				return ENewObj(mObj(cls()));
			case 30:
				var c = mObj(ctor());
				return ENewEnum(c, exs());
			case 31:
				var t = bty();
				return ENewArr(t, exs());
			case 32:
				var l = mObj(lambda());
				return ENewClos(l, exs());
			case 33:
				var t = bty();
				return ENewBox(t, ex());
			case 34:
				var sh = mObj(shape());
				return ENewAnon(sh, exs());
			case x:
				throw "an expression expected: " + x;
		}
	}

	// ---- the typed program's objects

	function path():Null<ModuleType> {
		var k = str();
		var t = store.paths.types.get(k);
		if (t == null) broken = true;
		return t;
	}

	function tclass():Null<TClass> {
		if (u() == 0) return null;
		return switch path() {
			case TClassDecl(c): c;
			case _:
				broken = true;
				null;
		}
	}

	function tenum():Null<TEnum> {
		return switch path() {
			case TEnumDecl(e): e;
			case _:
				broken = true;
				null;
		}
	}

	function tfield():{c:Null<TClass>, cf:Null<TClassField>} {
		var c = tclass();
		var k = u();
		if (k == 0) return {c: c, cf: null};
		var name = str();
		if (c == null) return {c: null, cf: null};
		var cf = switch k {
			case 1: c.clConstructor;
			case 2: c.clStatics.get(name);
			case 3: c.clFields.get(name);
			case 4: c.clInit;
			case _: throw "a field expected";
		}
		if (cf == null || cf.cfName != name) broken = true;
		return {c: c, cf: cf};
	}

	function t():T {
		var tag = u();
		if (tag == 0) return ts[u()];
		var r = switch tag {
			case 1: TMono(new TMono(null, [], [], []));
			case 2: TMono(new TMono(t(), [], [], []));
			// (a type parameter: what Lower.ty reads of one, Dynamic; one object
			// per parameter, as fastEq compares them)
			case 3: TMono(new TMono(null, [], [], []));
			case 4:
				var p = path();
				var ps = params();
				switch p {
					case TClassDecl(c): TInst(c, ps);
					case _:
						broken = true;
						TDynamic(null);
				}
			case 5:
				var p = path();
				var ps = params();
				switch p {
					case TEnumDecl(e): TEnum(e, ps);
					case _:
						broken = true;
						TDynamic(null);
				}
			case 6:
				var p = path();
				var ps = params();
				switch p {
					case TAbstractDecl(a): TAbstract(a, ps);
					case _:
						broken = true;
						TDynamic(null);
				}
			case 7:
				var p = path();
				var ps = params();
				switch p {
					case TTypeDecl(d): TType(d, ps);
					case _:
						broken = true;
						TDynamic(null);
				}
			case 8:
				var n = u();
				var args = new Vector<{name:String, optional:Bool, type:T}>(n);
				for (i in 0...n) {
					var name = str();
					var opt = bool();
					args[i] = {name: name, optional: opt, type: t()};
				}
				TFun(new TSignature(args, t()));
			case 9: TAnon(new TAnon(new haxe.ds.StringMap(), Closed));
			case 10:
				switch path() {
					case TClassDecl(c): TAnon(new TAnon(new haxe.ds.StringMap(), ClassStatics(c)));
					case _:
						broken = true;
						TDynamic(null);
				}
			case 11:
				switch path() {
					case TEnumDecl(e): TAnon(new TAnon(new haxe.ds.StringMap(), EnumStatics(e)));
					case _:
						broken = true;
						TDynamic(null);
				}
			case 12:
				switch path() {
					case TAbstractDecl(a): TAnon(new TAnon(new haxe.ds.StringMap(), AbstractStatics(a)));
					case _:
						broken = true;
						TDynamic(null);
				}
			case 13: TDynamic(null);
			case 14: TLazy(new TLazy(LAvailable(t())));
			case x: throw "a type expected: " + x;
		}
		ts.push(r);
		return r;
	}

	function params():TParams {
		var n = u();
		var r = new Vector<T>(n);
		for (i in 0...n)
			r[i] = t();
		return r;
	}

	function tys():Array<Ty>
		return [for (_ in 0...u()) ty(false)];

	function call(order:Array<Entry>):LCall {
		return switch u() {
			case 0:
				var x = t();
				CTy(x, ty(false));
			case 1:
				var k = tclass();
				CClass(k, cls());
			case 2:
				var e = tenum();
				CEnum(e, en());
			case 3:
				var e = tenum();
				var name = str();
				var ef = e == null ? null : e.eConstrs.get(name);
				if (ef == null) broken = true;
				CCtorInfo(ef, e, ctor());
			case 4:
				var f = tfield();
				CStatic(f.c, f.cf, func());
			case 5:
				var f = tfield();
				CMethod(f.c, f.cf, func());
			case 6:
				var k = tclass();
				CCtor(k, func());
			case 7:
				var k = tclass();
				CStructCtor(k, func());
			case 8:
				var name = str();
				CStructBox(name, cls());
			case 9:
				var f = tfield();
				CStaticVar(f.c, f.cf, z());
			case 10: CReflect(tclass());
			case 11: CReflectEnum(tenum());
			case 12:
				var f = func();
				CStaticClos(f, lambda());
			case 13:
				var name = str();
				var s = sig();
				var self = bool() ? ty(false) : null;
				CHostClos(name, s, self, lambda());
			case 14:
				var ci = ctor();
				var s = sig();
				CCtorClos(ci, s, lambda());
			case 15:
				var f = func();
				var d = if (bool()) {
					var sel = z();
					var s = sig();
					var args = tys();
					var cls = tclass();
					({sel: sel, sig: s, args: args, cls: cls} : {sel:Int, sig:SigInfo, args:Array<Ty>, ?cls:TClass});
				} else null;
				var o = func();
				CBoundClos(f, d, o, lambda());
			case 16:
				var from = sig();
				var to = sig();
				CAdapter(from, to, lambda());
			case 17:
				var to = sig();
				CDynAdapter(to, lambda());
			case 18:
				var s = sig();
				var n = u();
				var caps = new Vector<Local>(n);
				for (i in 0...n)
					caps[i] = local();
				var name = str();
				var module = str();
				var r = lambda();
				var len = u();
				var at = pos;
				pos += len;
				if (raw) {
					var sub = new EntryReader(sm, store, true);
					var body = sub.read(at);
					if (sub.broken) broken = true;
					for (f => x in sub.lambdas)
						lambdas.set(f, x);
					lambdas.set(r.fn, body);
				} else {
					var lazy = new Entry(null, null);
					lazy.fromStore = true;
					lazy.lazy = {sm: sm, pos: at};
					store.lambdas.set(r.fn, lazy);
				}
				CLambda(s, caps, name, module, r);
			case 19:
				var name = str();
				var s = sig();
				CSelector(name, s, z());
			case 20:
				var k = tclass();
				var name = str();
				CNeedsDispatch(k, name, bool());
			case 21:
				var k = tclass();
				var name = str();
				var r = if (bool()) {
					var f = tfield();
					{cls: f.c, field: f.cf};
				} else null;
				CLookup(k, name, r);
			case 22:
				var k = tclass();
				var name = str();
				var r = [
					for (_ in 0...u()) {
						var f = tfield();
						{cls: f.c, field: f.cf};
					}
				];
				CImplementors(k, name, r);
			case 23:
				var k = tclass();
				var name = str();
				var r = bool() ? tfield().cf : null;
				CRootDecl(k, name, r);
			case 24:
				var ci = cls();
				CSuperOf(ci, tclass());
			case 25: CRoot(cls());
			case 26:
				var args = tys();
				var ret = ty(false);
				CSig(args, ret, sig());
			case 27:
				var fields = [
					for (_ in 0...u()) {
						var name = str();
						{name: name, ty: ty(false)};
					}
				];
				CShape(fields, shape());
			case 28:
				var g = z();
				CGlobalTy(g, ty(false));
			case 29:
				var s = z();
				CSelectorName(s, str());
			case 30:
				var f = func();
				CDefaults(f, str());
			case 31:
				var f = tfield();
				CFieldDefaults(f.c, f.cf, str());
			case 32:
				var sym = str();
				var f = tfield();
				CExtern(sym, f.c, f.cf);
			case x: throw "a call expected: " + x;
		}
	}
}
