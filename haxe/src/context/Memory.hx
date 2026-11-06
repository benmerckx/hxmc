package context;

import core.Globals;
import core.Globals.GlobalTypePath;
import core.TType;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import haxe.ds.IntMap;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeGc;
#end

// port: memory inspection measures OCaml heap objects (Objsize, Obj.repr). The
// structure is translated; the sizes are what the host runtime can measure
// (Objsize below): the hxmc build walks its own heap (`hxmc.NativeGc.objsize`,
// hxmc/std/hxmc/rt/Gc.hx: the bytes of the reachable heap objects, headers
// included), other hosts report 0 and never "reach" an object.

// port: Objsize.info (data/headers/depth are reported as one byte count)
class ObjsizeInfo {
	public final bytes:Int;
	public final reached:Bool;

	public function new(bytes:Int, reached:Bool) {
		this.bytes = bytes;
		this.reached = reached;
	}
}

// port: the host side of the objsize C stubs
class Objsize {
	public static function objsize(v:Dynamic, exclude:Array<Dynamic>, out:Array<Dynamic>):ObjsizeInfo {
		#if (target.name == "hxmc")
		var bytes = NativeGc.objsize(v, exclude, out);
		return new ObjsizeInfo(Std.int(Math.min(bytes, 2147483647.)), NativeGc.reached());
		#else
		return new ObjsizeInfo(0, false);
		#end
	}

	public static function sizeWithHeaders(inf:ObjsizeInfo):Int return inf.bytes;

	// port: Gc.quick_stat().heap_words * (Sys.word_size / 8)
	public static function heapBytes():Float {
		#if (target.name == "hxmc")
		return NativeGc.heapBytes();
		#else
		return 0.;
		#end
	}
}

class Memory {
	public static function clearDescendants(md:ModuleDef):Void {
		for (t in md.mTypes) switch t {
			case TClassDecl(c):
				c.clDescendants = [];
			case _:
		}
	}

	public static function updateModuleTypeDeps(deps:Array<Dynamic>, md:ModuleDef):Array<Dynamic> {
		var deps:Array<Dynamic> = [(md : Dynamic)].concat(deps);
		for (t in md.mTypes) switch t {
			case TClassDecl(c):
				deps.unshift(c);
				c.clDescendants = []; /* prevent false positive */
				for (f in c.clOrderedStatics) deps.unshift(f);
				for (f in c.clOrderedFields) deps.unshift(f);
			case TEnumDecl(e):
				deps.unshift(e);
				for (n in e.eNames) deps.unshift(e.eConstrs.get(n));
			case TTypeDecl(t):
				deps.unshift(t);
			case TAbstractDecl(a):
				deps.unshift(a);
		}
		return deps;
	}

	public static function scanModuleDeps(cs:compiler.CompilationCache.Cache, m:ModuleDef, h:OcamlHashtbl<Int, ModuleDef>):Void {
		if (h.mem(m.mId)) {} else {
			h.add(m.mId, m);
			// port: PMap.iter visits the keys in increasing order
			var keys = [for (k in m.mExtra.mDeps.keys()) k];
			keys.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			for (k in keys) {
				var mdep = m.mExtra.mDeps.get(k);
				var m = (cs.getContext(mdep.mdSign)).findModule(mdep.mdPath);
				scanModuleDeps(cs, m, h);
			}
		}
	}

	public static function moduleSign(key:String, md:ModuleDef):String return md.mExtra.mSign == key ? "" : "(" + md.mExtra.mSign + ")";

	public static function collectLeaks(m:ModuleDef, deps:Array<Dynamic>, out:IntMap<ModuleDef>):Array<String> {
		var leaks:Array<String> = [];
		function leak(s:String) {
			leaks.unshift(s);
		}
		if ((Objsize.objsize(m, deps, [Common.memoryMarker])).reached) leak("common");
		if ((Objsize.objsize(m, deps, [Typecore.memoryMarker])).reached) leak("typecore");
		for (id in sortedIds(out)) {
			var md = out.get(id);
			if ((Objsize.objsize(m, deps, [md])).reached) leak(Globals.sTypePath(md.mPath) + moduleSign(m.mExtra.mSign, md));
		}
		return leaks;
	}

	// port: PMap.iter/fold over the module ids visit them in increasing order
	static function sortedIds(out:IntMap<ModuleDef>):Array<Int> {
		var keys = [for (k in out.keys()) k];
		keys.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return keys;
	}

	public static function getOut(out:IntMap<ModuleDef>):Array<Dynamic> {
		var acc:Array<Dynamic> = [];
		for (id in sortedIds(out)) acc.unshift(out.get(id));
		return ([Common.memoryMarker, Typecore.memoryMarker] : Array<Dynamic>).concat(acc);
	}

	public static function getModuleMemory(cs:compiler.CompilationCache.Cache, allModules:IntMap<ModuleDef>,
			m:ModuleDef):{size:Int, reached:Bool, deps:Array<Dynamic>, out:IntMap<ModuleDef>, leaks:Array<String>} {
		var mdeps = new OcamlHashtbl<Int, ModuleDef>(i -> OcamlHash.hash(core.ds.OcamlHash.OcamlValue.OInt(i)), (a, b) -> a == b, 0);
		scanModuleDeps(cs, m, mdeps);
		var deps:Array<Dynamic> = [core.TFunctions.nullModule];
		var out = allModules.copy();
		var deps = mdeps.fold(function(_, md:ModuleDef, deps:Array<Dynamic>) {
			out.remove(md.mId);
			return if (m == md) deps else updateModuleTypeDeps(deps, md);
		}, deps);
		clearDescendants(m);
		var chk = getOut(out);
		var inf = Objsize.objsize(m, deps, chk);
		var leaks = if (inf.reached) collectLeaks(m, deps, out) else [];
		return {
			size: Objsize.sizeWithHeaders(inf),
			reached: inf.reached,
			deps: deps,
			out: out,
			leaks: leaks
		};
	}

	public static function fmtSize(sz:Int):String {
		if (sz < 1024) return Std.string(sz) + " B";
		if (sz < 1024 * 1024) return Std.string(sz >> 10) + " KB";
		// port: Printf.sprintf "%.1f MB"
		var r = Math.round(sz / (1024. * 1024.) * 10);
		return Std.string(Std.int(r / 10)) + "." + Std.string(r % 10) + " MB";
	}

	public static function fmtWord(f:Float):String {
		return fmtSize(Std.int(f) * 8);
	}

	// port: Common.mem_size
	public static function memSize(v:Dynamic):Int return Objsize.sizeWithHeaders(Objsize.objsize(v, [], []));

	public static function size(v:Dynamic):String return fmtSize(memSize(v));
}
