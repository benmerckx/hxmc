package hxmc;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;
import core.Globals.GlobalTypePath;
import core.TType;
import compiler.hxb.HxbData;
import compiler.server.ServerCache;
import context.Common;
import core.Message.CompilerMessageKind;
import core.Message.WarningMode;
import hxmc.ModuleStore;
import core.ds.VectorTools.vector;
import hxmc.ModuleCache;
import hxmc.ModuleCacheState;
using core.ds.VectorTools;

// What the sort of the types (Finalization.sortTypes) walks of a class's
// fields, kept per module: a module restored from the store has its
// expressions as the filters left them, and the sort must walk what it saw
// when the module was typed (the order of the types, and so the program's
// type numbering, follows it). Per expression (a class's init, a static
// field, the constructor), the walk's events in order: a type expression
// (0, its kind, module and name), a construction (1, the class), a static
// field (2, the class and field). Played back as a block of those
// expressions, the walk does the same.
class Skeletons {
	static function moduleKey(sign:String, p:GlobalTypePath):String
		return sign + "\x00" + ModuleCache.key(p);

	static function restoredEntry(s:ModuleCacheState, m:ModuleDef):Null<ModuleStore.Variant>
		return s.restored(m);

	static function typeRef(o:BytesOutput, m:ModuleDef, name:String) {
		ModuleStore.path(o, m.mPath);
		ModuleStore.str(o, name);
	}

	static function record(e:TExpr):Bytes {
		var o = new BytesOutput();
		function rec(e:TExpr)
			switch e.eexpr {
				case TTypeExpr(t):
					o.writeByte(0);
					o.writeByte(switch t {
						case TClassDecl(_): 0;
						case TEnumDecl(_): 1;
						case TAbstractDecl(_): 2;
						case TTypeDecl(_): 3;
					});
					var i = core.TFunctions.tInfos(t);
					typeRef(o, i.mtModule, i.mtPath.name);
				case TNew(c, _, _):
					core.Texpr.iter(rec, e);
					o.writeByte(1);
					typeRef(o, c.clModule, c.clPath.name);
				case TField(e1, FStatic(c, cf)):
					rec(e1);
					o.writeByte(2);
					typeRef(o, c.clModule, c.clPath.name);
					ModuleStore.str(o, cf.cfName);
				case _:
					core.Texpr.iter(rec, e);
			}
		rec(e);
		return o.getBytes();
	}

	static function computeClass(s:ModuleCacheState, c:TClass) {
		var mk = moduleKey(c.clModule.mExtra.mSign, c.clModule.mPath);
		var ck = mk + "\x00" + c.clPath.name;
		if (s.walked.exists(ck)) return;
		s.walked.set(ck, true);
		var map = s.skeletons.get(mk);
		if (map == null) s.skeletons.set(mk, map = new Map());
		var init = core.TOther.TClassTools.getClInit(c);
		if (init != null) map.set(c.clPath.name + "\x00", record(init));
		for (cf in c.clStatics)
			if (cf.cfExpr != null) map.set(c.clPath.name + "\x00" + cf.cfName, record(cf.cfExpr));
		if (c.clConstructor != null && c.clConstructor.cfExpr != null) map.set(c.clPath.name + "\x00new", record(c.clConstructor.cfExpr));
	}

	// the classes of the modules this build typed (not restored)
	public static function computeAll(com:CommonContext) {
		var s = ModuleCache.current();
		if (s == null) return;
		var key = "com:" + context.CommonCache.getCacheSign(com);
		if (s.walked.exists(key)) return;
		s.walked.set(key, true);
		// (the walks recorded in parallel: each reads its own expression)
		var work:Array<{map:Map<String, Bytes>, name:String, e:TExpr}> = [];
		com.moduleLut.iter(function(_, m) {
			if (restoredEntry(s, m) != null) return;
			for (t in m.mTypes)
				switch t {
					case TClassDecl(c):
						var mk = moduleKey(c.clModule.mExtra.mSign, c.clModule.mPath);
						var ck = mk + "\x00" + c.clPath.name;
						if (s.walked.exists(ck)) continue;
						s.walked.set(ck, true);
						var map = s.skeletons.get(mk);
						if (map == null) s.skeletons.set(mk, map = new Map());
						var init = core.TOther.TClassTools.getClInit(c);
						if (init != null) work.push({map: map, name: c.clPath.name + "\x00", e: init});
						for (cf in c.clStatics)
							if (cf.cfExpr != null) work.push({map: map, name: c.clPath.name + "\x00" + cf.cfName, e: cf.cfExpr});
						if (c.clConstructor != null && c.clConstructor.cfExpr != null)
							work.push({map: map, name: c.clPath.name + "\x00new", e: c.clConstructor.cfExpr});
					case _:
				}
		});
		var recorded = @:privateAccess ModuleCache.parallel(com, pool -> context.Parallel.ParallelArray.map(pool, w -> record(w.e), work, null));
		for (i in 0...work.length)
			work[i].map.set(work[i].name, recorded[i]);
	}

	// Finalization.sortExprHook
	public static function sortExpr(c:TClass, cf:Null<TClassField>, e:TExpr):TExpr {
		var s = ModuleCache.current();
		if (s == null) return e;
		var com = ModuleCache.comFor(s.com, c.clModule.mExtra.mSign);
		if (com != null) computeAll(com);
		var entry = restoredEntry(s, c.clModule);
		if (entry == null) return e;
		if (entry.skeletonMap == null) {
			if (entry.skeletons == null) return e;
			entry.skeletonMap = decode(entry.skeletons);
		}
		var b = entry.skeletonMap.get(c.clPath.name + "\x00" + (cf == null ? "" : cf == c.clConstructor ? "new" : cf.cfName));
		var r = b == null || com == null ? null : play(com, b);
		if (r == null) {
			if (s.log) Sys.println("hxmc: module cache: no walk kept for " + core.Globals.sTypePath(c.clPath) + "." + (cf == null ? "__init__" : cf.cfName));
			return e;
		}
		return r;
	}

	static function findType(com:CommonContext, i:BytesInput):Null<ModuleType> {
		var mp = ModuleStore.rpath(i);
		var name = ModuleStore.rstr(i);
		var m = com.moduleLut.findOpt(mp);
		if (m == null) return null;
		for (t in m.mTypes)
			if (core.TFunctions.tInfos(t).mtPath.name == name) return t;
		return null;
	}

	static function play(com:CommonContext, b:Bytes):Null<TExpr> {
		var i = new BytesInput(b);
		var nodes:Array<TExpr> = [];
		var p = core.Globals.nullPos;
		var t = core.TFunctions.tDynamic;
		inline function mk(d:TExprDef):TExpr
			return core.TFunctions.mk(d, t, p);
		while (i.position < b.length)
			switch i.readByte() {
				case 0:
					i.readByte();
					var mt = findType(com, i);
					if (mt == null) return null;
					nodes.push(mk(TTypeExpr(mt)));
				case 1:
					switch findType(com, i) {
						case TClassDecl(c): nodes.push(mk(TNew(c, vector(), vector())));
						case _: return null;
					}
				case _:
					var mt = findType(com, i);
					var f = ModuleStore.rstr(i);
					switch mt {
						case TClassDecl(c) if (c.clStatics.exists(f)):
							nodes.push(mk(TField(mk(TConst(TNull)), FStatic(c, c.clStatics.get(f)))));
						case _:
							return null;
					}
			}
		return mk(TBlock(haxe.ds.Vector.fromArrayCopy(nodes)));
	}

	public static function encode(s:ModuleCacheState, sign:String, p:GlobalTypePath):Bytes {
		var map = s.skeletons.get(moduleKey(sign, p));
		var o = new BytesOutput();
		var keys = map == null ? [] : [for (k in map.keys()) k];
		keys.sort(Reflect.compare);
		o.writeInt32(keys.length);
		for (k in keys) {
			ModuleStore.str(o, k);
			var b = map.get(k);
			o.writeInt32(b.length);
			o.write(b);
		}
		return o.getBytes();
	}

	static function decode(b:Bytes):Map<String, Bytes> {
		var i = new BytesInput(b);
		var m = new Map<String, Bytes>();
		for (_ in 0...i.readInt32()) {
			var k = ModuleStore.rstr(i);
			m.set(k, i.read(i.readInt32()));
		}
		return m;
	}
}
