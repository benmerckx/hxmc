package hxmc.es;

import haxe.Json;
import haxe.crypto.Md5;
import haxe.io.Path;

// -D hxmc.js.hot (es-modules): what a build has of the program that a running one can take without starting again
// (docs/js.md, "Hot reload"). Each build writes, beside the entry, `_hx_hot.json`: each declaration as named parts with
// their hashes (a class's methods, fields, constructor; an enum's constructors; ...: Chunk.hotPatch names them), the
// names each file exports, and the runtime's parts. The next build compares its own with them: what changed in each
// declaration, which Chunk.hotPatch turns into a patch (`_hx_hot/<n>.js`) or into a reason to start again.
//
// The record is of the program running: after a patch, of the files and the runtime as the program loaded them,
// which a patch does not change.
typedef HotRecord = {
	var seq:Int;
	// (a file's path) the names it exports
	var files:haxe.DynamicAccess<Array<String>>;
	var runtime:Array<String>;
	// (a declaration's path) its parts' hashes
	var units:haxe.DynamicAccess<haxe.DynamicAccess<String>>;
	// what the build is to the program running: a patch's file, or why it cannot be one (neither: nothing changed, or
	// the first build)
	@:optional var patch:Null<String>;
	@:optional var reload:Null<String>;
}

// what changed in a declaration's parts, by their names
typedef HotDiff = {
	var added:Array<String>;
	var changed:Array<String>;
	var removed:Array<String>;
}

class Hot {
	public static final RECORD = "_hx_hot.json";
	public static final DIR = "_hx_hot";

	final dir:String;
	final prev:Null<HotRecord>;
	final cur:HotRecord;
	final reasons:Array<String> = [];

	public function new(dir:String) {
		this.dir = dir;
		var path = Path.join([dir, RECORD]);
		var was:Null<HotRecord> = try sys.FileSystem.exists(path) ? Json.parse(sys.io.File.getContent(path)) : null catch (_:Dynamic) null;
		// (a record of another shape: as if none)
		prev = was != null && was.units != null ? was : null;
		cur = {
			seq: was == null ? 0 : was.seq + 1,
			files: {},
			runtime: [],
			units: {}
		};
	}

	public static function hash(s:String):String return Md5.encode(s);

	public function file(path:String, names:Array<String>) {
		names.sort(Reflect.compare);
		cur.files.set(path, names);
	}

	public function runtime(parts:Array<String>) {
		parts.sort(Reflect.compare);
		cur.runtime = parts;
	}

	// a declaration's parts; what changed in them since the previous build (null: nothing, or the declaration is new)
	public function unit(path:String, parts:Map<String, String>):Null<HotDiff> {
		var m = new haxe.DynamicAccess<String>();
		for (k => v in parts) m.set(k, v);
		cur.units.set(path, m);
		var was = prev == null ? null : prev.units.get(path);
		if (was == null) return null;
		var d:HotDiff = {added: [], changed: [], removed: []};
		for (k => v in parts) if (!was.exists(k)) d.added.push(k) else if (was.get(k) != v) d.changed.push(k);
		for (k in was.keys()) if (!parts.exists(k)) d.removed.push(k);
		for (l in [d.added, d.changed, d.removed]) l.sort(Reflect.compare);
		return d.added.length + d.changed.length + d.removed.length == 0 ? null : d;
	}

	// why the program running cannot take this build
	public function restart(why:String) reasons.push(why);

	// compared with the previous build: what else keeps a patch from being enough (patching: a patch, which may use
	// any of the runtime's parts this build has)
	public function compare(patching:Bool) {
		if (prev == null) return;
		for (path => names in cur.files) {
			var was = prev.files.get(path);
			if (was != null && was.join(",") != names.join(",")) reasons.push(path + ": its exports changed");
		}
		if (patching) for (p in cur.runtime) if (!prev.runtime.contains(p)) reasons.push("the runtime's " + p + " is new");
	}

	public var first(get, never):Bool;

	function get_first() return prev == null;

	public var reload(get, never):Null<String>;

	function get_reload() return reasons.length == 0 ? null : reasons.join("; ");

	public function patchPath():String return DIR + "/" + cur.seq + ".js";

	// the record, of the program running (patch: the patch's path, null where nothing changed)
	public function save(patch:Null<String>) {
		if (prev != null && reload == null) {
			// (the files and the runtime as the program loaded them; those it has not yet, as they are now)
			for (path => names in prev.files) cur.files.set(path, names);
			cur.runtime = prev.runtime;
			cur.patch = patch;
		} else if (prev != null) cur.reload = reload;
		sys.io.File.saveContent(Path.join([dir, RECORD]), Json.stringify(cur, null, "\t"));
	}
}
