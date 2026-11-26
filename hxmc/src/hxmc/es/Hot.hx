package hxmc.es;

import haxe.Json;
import haxe.crypto.Md5;
import haxe.io.Path;

// -D hxmc.js.hot (es-modules): what a build has of the program that a running one can take without starting again
// (docs/js.md, "Hot reload"). Each build writes, beside the entry, `_hx_hot.json`: of each class its methods' code
// and its shape (its super class, constructor, fields: what its instances already have), of each other declaration
// its code, of each file its bindings, and the runtime's parts. The next build compares its own with them: where only
// methods differ, a patch (`_hx_hot/<n>.js`, Chunk.hotPatch) replaces those of the running classes, which keep their
// identity, and so their instances and statics; anything else, a reason to start again.
//
// The record is of the program running: after a patch, of the files and the runtime as the program loaded them,
// which a patch does not change.
typedef HotRecord = {
	var seq:Int;
	// (a file's path) the names it exports
	var files:haxe.DynamicAccess<Array<String>>;
	var runtime:Array<String>;
	// (a class's path) its shape, its methods' code (by their slot: HotMethod)
	var classes:haxe.DynamicAccess<{shape:String, methods:haxe.DynamicAccess<String>}>;
	// (a declaration's path, but a class's) its code
	var others:haxe.DynamicAccess<String>;
	// what the build is to the program running: a patch's file, or why it cannot be one (null: the first)
	@:optional var patch:Null<String>;
	@:optional var reload:Null<String>;
}

// a class's method: its slot (`s`/`i`: static or not, `m`/`g`/`s`: a method, a getter, a setter, then `:` and its key as
// printed), its code's hash
typedef HotMethod = {
	var slot:String;
	var hash:String;
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
		prev = try sys.FileSystem.exists(path) ? Json.parse(sys.io.File.getContent(path)) : null catch (_:Dynamic) null;
		cur = {
			seq: prev == null ? 0 : prev.seq + 1,
			files: {},
			runtime: [],
			classes: {},
			others: {}
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

	public function other(path:String, code:String) cur.others.set(path, hash(code));

	// a class's shape and methods; what of them a patch takes (null: none, or the class is not one a patch can change)
	public function cls(path:String, shape:String, methods:Array<HotMethod>):Null<{changed:Array<String>, removed:Array<String>}> {
		var m = new haxe.DynamicAccess<String>();
		for (x in methods) m.set(x.slot, x.hash);
		cur.classes.set(path, {shape: hash(shape), methods: m});
		if (prev == null) return null;
		var was = prev.classes.get(path);
		if (was == null) return null;
		if (was.shape != hash(shape)) {
			reasons.push(path + ": its shape (super class, constructor, fields)");
			return null;
		}
		var changed = [for (x in methods) if (was.methods.get(x.slot) != x.hash) x.slot];
		// (as the runtime's hotPatch deletes them: "s:x", "i:x"; not a computed key's, nor a symbol's)
		var removed = [];
		for (slot in was.methods.keys()) {
			var k = slot.substr(3);
			if (m.exists(slot) || k.charAt(0) == "[" || k.charAt(0) == "#") continue;
			// (not where the key has a member still: a method now a getter)
			if (Lambda.exists(methods, x -> x.slot.charAt(0) == slot.charAt(0) && x.slot.substr(3) == k)) continue;
			removed.push(slot.charAt(0) + ":" + (k.charAt(0) == "\"" ? Json.parse(k) : k));
		}
		return changed.length == 0 && removed.length == 0 ? null : {changed: changed, removed: removed};
	}

	// compared with the previous build: what else keeps a patch from being enough (patching: a patch of the classes',
	// which may use any of the runtime's parts this build has)
	public function compare(patching:Bool) {
		if (prev == null) return;
		for (path => code in cur.others) {
			var was = prev.others.get(path);
			if (was != null && was != code) reasons.push(path + ": changed (only classes' methods are patched)");
		}
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
		var path = Path.join([dir, RECORD]);
		sys.io.File.saveContent(path, Json.stringify(cur, null, "\t"));
	}
}
