import Harness.*;
import sys.FileSystem;

using StringTools;

// ESM product gate (Genesm emit, upstream unit with -D esm, hot-reload harnesses):
//   make esm
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Esm [--haxe <compiler>] [--summary <file>] [lane ...]
// Lane ids default to all lanes in order; names match the printed lane column.
// Needs bin/npm/native/$(HOST)/haxe (make npm) for Genesm; lix for utest (make lix).
class Esm {
	static var results:Array<{name:String, ok:Bool}> = [];
	static final SCRIPT = ["bin/hxmc/hxmc", "-cp", "hxmc/test", "-cp", "haxe/test", "-cp", "hxmc/src", "--run"];
	static final LANES:Array<{id:String, name:String, harness:String}> = [
		{id: "genesm", name: "genesm layout", harness: "EsmGenesmCheck"},
		{id: "unit", name: "upstream unit", harness: "EsmSuites"},
		{id: "body-swap", name: "hot body swap", harness: "EsmHotBodySwapCheck"},
		{id: "watch-patch", name: "hot watch and patch", harness: "EsmHotWatchPatchCheck"},
		{id: "cells", name: "hot cells and ordinals", harness: "EsmHotCellsCheck"},
		{id: "cells-markup", name: "hot cells markup entry", harness: "EsmHotCellsMarkupCheck"},
		{id: "layout", name: "hot class and enum layout", harness: "EsmHotLayoutCheck"},
		{id: "heap", name: "hot heap serializer", harness: "EsmHotHeapCheck"},
		{id: "dual-flavor", name: "hot dual compile", harness: "EsmHotDualCheck"},
		{id: "std-globals", name: "hot std static inits", harness: "EsmHotStdGlobalsCheck"},
		{id: "std-registry", name: "hot registry Std imports", harness: "EsmHotStdRegistryCheck"},
		{id: "static-fn", name: "hot static method emit", harness: "EsmHotStaticFnCheck"},
		{id: "class-static", name: "hot class static vars", harness: "EsmHotClassStaticVarCheck"},
		{id: "shallow-capture", name: "hot shallow capture", harness: "EsmHotShallowCapCheck"},
		{id: "module-import", name: "hot module import client", harness: "EsmHotModuleImportCheck"},
	];

	static function lane(name:String, f:Void->{ok:Bool, detail:String}) {
		var t = now();
		var r = try f() catch (e:Dynamic) {ok: false, detail: Std.string(e)};
		results.push({name: name, ok: r.ok});
		Sys.println(pad(name, 28) + " " + (r.ok ? "ok  " : "FAIL") + " " + fixed(now() - t).lpad(" ", 6) + "s  " + r.detail);
	}

	static function lastLine(s:String):String {
		var lines = [for (l in s.trim().split("\n")) if (l.trim() != "") l];
		return lines.length == 0 ? "" : lines[lines.length - 1];
	}

	static function harness(name:String, haxe:String, harness:String) {
		return () -> {
			var cmd = SCRIPT.concat([harness, "--haxe", haxe]);
			var r = exec(cmd, {merge: true});
			{ok: r.code == 0, detail: lastLine(r.out)};
		};
	}

	static function pick(rest:Array<String>):Array<{id:String, name:String, harness:String}> {
		if (rest.length == 0) return LANES;
		var out = [];
		for (l in LANES)
			if (rest.contains(l.id) || rest.contains(l.harness))
				out.push(l);
		if (out.length == 0) {
			var ids = [for (l in LANES) l.id].join(", ");
			fail('unknown lane(s) ${rest.join(", ")} (lanes: $ids)');
		}
		return out;
	}

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe", "--summary"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe (make npm natives or pass --haxe)");
		var lanes = pick(o.rest);
		var t0 = now();
		for (l in lanes)
			lane(l.name, harness(l.name, haxe, l.harness));
		var bad = [for (r in results) if (!r.ok) r.name];
		var foot = 'esm: ${results.length - bad.length}/${results.length} lanes ok, ${Math.round(now() - t0)}s'
			+ (bad.length == 0 ? "" : "; FAILED: " + bad.join(", "));
		Sys.println(foot);
		summary(o.opts["--summary"], foot + "\n");
		Sys.exit(bad.length > 0 ? 1 : 0);
	}
}