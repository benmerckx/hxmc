import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

using StringTools;

typedef ApiField = {
	name:String,
	// "new", "static", "instance", "case" (an enum's constructor, an enum abstract's value), "field" (a typedef's)
	group:String,
	sig:String,
	doc:String,
}

typedef ApiType = {
	// "os", "ui": the package whose page lists it
	pkg:String,
	// its dotted path (hxmc.ui.widgets.Widgets) and its anchor (widgets.Widgets)
	path:String,
	anchor:String,
	name:String,
	kind:String,
	sig:String,
	doc:String,
	file:String,
	line:Int,
	fields:Array<ApiField>,
}

// The packages' API reference, from the compiler: the site's build types
// each package's modules (the hxmc tool, --json: haxe.display's types,
// with positions) and reads the comment above each public declaration
// from its source (the packages document with // comments, which the
// compiler does not keep). The signatures are the typed ones: inferred
// types written out, abstracts with their underlying type.
class Api {
	public final types:Array<ApiType>;

	// the packages' modules typed together: the root package and these
	public static final INCLUDE = [
		"os" => ["hxmc.os", "hxmc.os.audio"],
		"gfx" => ["hxmc.gfx"],
		"3d" => [
			"hxmc.scene", "hxmc.scene.math", "hxmc.scene.gltf", "hxmc.scene.render", "hxmc.scene.anim", "hxmc.scene.input", "hxmc.scene.debug"
		],
		"physics" => ["hxmc.physics"],
		"text" => ["hxmc.text"],
		"view" => ["hxmc.view"],
		"ui" => ["hxmc.ui", "hxmc.ui.widgets", "hxmc.ui.draw"],
		"web" => ["hxmc.web"],
	];

	public function new(types:Array<ApiType>) {
		this.types = types;
	}

	public function of(pkg:String):Array<ApiType>
		return types.filter(t -> t.pkg == pkg);

	public static function extract():Api {
		var json = Site.build + "/api.json";
		var args = [];
		for (p in Examples.PACKAGES)
			args = args.concat(["-cp", 'packages/$p/src']);
		args = args.concat([
			"-D", "hxmc.view.renderer.ui=hxmc.ui.view.NodeRenderer", "-D", "hxmc.view.renderer.html=hxmc.web.StaticRenderer", "-cp", "bin/hxmc/std",
			"--custom-target", 'hxmc=${Site.build}/api.out', "--no-output", "-D", "doc-gen", "--json", json
		]);
		for (pkg => packs in INCLUDE)
			for (p in packs)
				args = args.concat(["--macro", 'include("$p", false, null, ["packages/$pkg/src"])']);
		var t0 = haxe.Timer.stamp();
		if (Sys.command(Site.tool, args) != 0) throw "site: the API's types could not be read";
		var all:Array<Dynamic> = haxe.Json.parse(File.getContent(json));
		FileSystem.deleteFile(json);
		var api = read(all);
		Sys.println('site: API of ${api.types.length} types in ${Math.round((haxe.Timer.stamp() - t0) * 10) / 10} s');
		return api;
	}

	// the anchors of the types listed, by dotted path: links between them
	static var anchors = new Map<String, {pkg:String, anchor:String}>();

	static function read(all:Array<Dynamic>):Api {
		var byPath = new Map<String, Dynamic>();
		for (t in all)
			byPath.set(dotted(t.pack, t.name), t);
		var listed:Array<Dynamic> = [];
		for (t in all) {
			var pack:Array<String> = t.pack;
			if (pack.length < 2 || pack[0] != "hxmc") continue;
			var pkg = pack[1];
			var packs = INCLUDE.get(pkg);
			if (packs == null || !packs.contains(pack.join("."))) continue;
			if (t.isPrivate || hidden(t.meta) || (t.name : String).endsWith("_Impl_") || (t.name : String).startsWith("_")) continue;
			listed.push(t);
			anchors.set(dotted(pack, t.name), {pkg: pkg, anchor: anchorOf(pack, t.name)});
		}
		var types = [];
		for (t in listed) {
			var pack:Array<String> = t.pack;
			var file:String = t.pos.file;
			var info = docAt(file, t.pos.min);
			var at:ApiType = {
				pkg: pack[1],
				path: dotted(pack, t.name),
				anchor: anchorOf(pack, t.name),
				name: t.name,
				kind: t.kind,
				sig: "",
				doc: info.doc,
				file: file,
				line: info.line,
				fields: []
			};
			var params = typeParams(t.params);
			switch (t.kind : String) {
				case "class":
					var a:Dynamic = t.args;
					var head = (a.isInterface ? "interface " : "class ") + strong(t.name) + params;
					if (a.superClass != null) head += " extends " + pathType(a.superClass);
					var ifaces:Array<Dynamic> = a.interfaces;
					if (ifaces.length > 0) head += (a.isInterface ? " extends " : " implements ") + ifaces.map(pathType).join(", ");
					at.sig = head;
					if (a.constructor != null && isShown(a.constructor)) at.fields.push(field(a.constructor, "new", false));
					for (f in (a.statics : Array<Dynamic>))
						if (isShown(f)) at.fields.push(field(f, "static", false));
					for (f in (a.fields : Array<Dynamic>))
						if (isShown(f)) at.fields.push(field(f, "instance", false));
				case "enum":
					at.sig = "enum " + strong(t.name) + params;
					for (c in (t.args.constructors : Array<Dynamic>)) {
						var sig = strong(c.name);
						if (c.type.kind == "TFun") sig += "(" + (c.type.args.args : Array<Dynamic>).map(arg).join(", ") + ")";
						at.fields.push({name: c.name, group: "case", sig: sig, doc: c.pos == null ? "" : docAt(c.pos.file, c.pos.min).doc});
					}
				case "typedef":
					var target:Dynamic = t.args.type;
					if (target.kind == "TAnonymous") {
						at.sig = "typedef " + strong(t.name) + params;
						for (f in (target.args.fields : Array<Dynamic>))
							at.fields.push(field(f, "field", false));
					} else at.sig = "typedef " + strong(t.name) + params + " = " + type(target);
				case "abstract":
					var a:Dynamic = t.args;
					var isEnum = hasMeta(t.meta, ":enum");
					var head = (isEnum ? "enum abstract " : "abstract ") + strong(t.name) + params + "(" + type(a.type) + ")";
					var from:Array<Dynamic> = a.from, to:Array<Dynamic> = a.to;
					if (from.length > 0) head += " from " + from.map(f -> type(f.t)).join(", ");
					if (to.length > 0) head += " to " + to.map(f -> type(f.t)).join(", ");
					at.sig = head;
					var impl = a.impl == null ? null : byPath.get(dotted(a.impl.pack, a.impl.typeName));
					if (impl != null)
						for (f in (impl.args.statics : Array<Dynamic>)) {
							if (!isShown(f) && !(isEnum && hasMeta(f.meta, ":enum"))) continue;
							if (isEnum && f.kind.kind == "FVar") at.fields.push({name: f.name, group: "case", sig: strong(f.name), doc: docAt(f.pos.file, f.pos.min).doc});
							else at.fields.push(field(f, hasMeta(f.meta, ":impl") ? (f.name == "_new" ? "new" : "instance") : "static", hasMeta(f.meta, ":impl")));
						}
				case _:
			}
			types.push(at);
		}
		types.sort((a, b) -> a.path == b.path ? 0 : a.path < b.path ? -1 : 1);
		return new Api(types);
	}

	static function dotted(pack:Array<String>, name:String):String
		return pack.length == 0 ? name : pack.join(".") + "." + name;

	static function anchorOf(pack:Array<String>, name:String):String
		return pack.slice(2).concat([name]).join(".");

	static function hasMeta(meta:Array<Dynamic>, name:String):Bool
		return meta != null && Lambda.exists(meta, m -> m.name == name);

	static function hidden(meta:Array<Dynamic>):Bool
		return hasMeta(meta, ":noCompletion") || hasMeta(meta, ":noDoc") || hasMeta(meta, ":dox");

	static function isShown(f:Dynamic):Bool {
		var name:String = f.name;
		return f.isPublic && !hidden(f.meta) && (!name.startsWith("_") || name == "_new") && !name.startsWith("get_") && !name.startsWith("set_");
	}

	static function strong(s:String):String
		return '<b>${Esc.html(s)}</b>';

	static function field(f:Dynamic, group:String, impl:Bool):ApiField {
		var name:String = f.name == "_new" ? "new" : f.name;
		var t:Dynamic = f.type;
		var sig = "";
		var params = typeParams(f.params);
		if (f.kind.kind == "FMethod" && t.kind == "TFun") {
			var args:Array<Dynamic> = t.args.args;
			// (an abstract's method: this first)
			if (impl && name != "new") args = args.slice(1);
			var kw = group == "static" ? "static function " : group == "field" ? "" : "function ";
			var ret = name == "new" ? "" : ":" + type(t.args.ret);
			sig = kw + strong(name) + params + "(" + args.map(arg).join(", ") + ")" + ret;
		} else {
			var opt = hasMeta(f.meta, ":optional") ? "?" : "";
			var kw = group == "field" ? "" : (group == "static" ? "static " : "") + (f.isFinal ? "final " : "var ");
			var access = "";
			if (f.kind.kind == "FVar" && group != "field") {
				var r:String = f.kind.args.read.kind, w:String = f.kind.args.write.kind;
				if (r != "AccNormal" || (w != "AccNormal" && !f.isFinal)) access = "(" + accName(r, true) + ", " + accName(w, false) + ")";
			}
			sig = kw + opt + strong(name) + access + ":" + type(t);
		}
		var doc = f.pos == null ? "" : docAt(f.pos.file, f.pos.min).doc;
		return {name: name, group: group, sig: sig, doc: doc};
	}

	static function accName(k:String, read:Bool):String {
		return switch k {
			case "AccNormal": "default";
			case "AccNo": "null";
			case "AccNever": "never";
			case "AccCall": read ? "get" : "set";
			case "AccCtor": "ctor";
			case "AccInline": "inline";
			case _: "default";
		}
	}

	static function typeParams(params:Array<Dynamic>):String
		return params == null || params.length == 0 ? "" : "&lt;" + params.map(p -> Esc.html(p.name)).join(", ") + "&gt;";

	static function arg(a:Dynamic):String {
		var name:String = a.name;
		return (a.opt ? "?" : "") + (name == "" ? "" : Esc.html(name) + ":") + type(a.t);
	}

	static function pathType(p:Dynamic):String
		return typePath(p.path.pack, p.path.typeName, p.params);

	static function typePath(pack:Array<String>, name:String, params:Array<Dynamic>):String {
		var a = anchors.get(dotted(pack, name));
		var n = Esc.html(name);
		var s = a == null ? n : '<a href="${a.pkg}.html#${a.anchor}">$n</a>';
		if (params != null && params.length > 0) s += "&lt;" + params.map(type).join(", ") + "&gt;";
		return s;
	}

	// a type as Haxe writes it, linked to its entry when listed
	public static function type(t:Dynamic):String {
		if (t == null) return "?";
		return switch (t.kind : String) {
			case "TInst" | "TEnum" | "TType" | "TAbstract":
				typePath(t.args.path.pack, t.args.path.typeName, t.args.params);
			case "TFun":
				var args:Array<Dynamic> = t.args.args;
				var ret = type(t.args.ret);
				(args.length == 1 && args[0].name == "" && !args[0].opt ? type(args[0].t) : "(" + args.map(arg).join(", ") + ")") + "-&gt;" + ret;
			case "TAnonymous":
				var fs:Array<Dynamic> = t.args.fields;
				"{" + fs.map(f -> (hasMeta(f.meta, ":optional") ? "?" : "") + Esc.html(f.name) + ":" + type(f.type)).join(", ") + "}";
			case "TDynamic":
				t.args == null ? "Dynamic" : "Dynamic&lt;" + type(t.args) + "&gt;";
			case "TMono": "?";
			case _: Esc.html(t.kind);
		}
	}

	static final sources = new Map<String, Bytes>();

	// the comment above a declaration: the // lines before its line (past its
	// metadata), as HTML; and the declaration's line
	public static function docAt(file:String, min:Int):{doc:String, line:Int} {
		if (file == null || !FileSystem.exists(file)) return {doc: "", line: 0};
		var b = sources.get(file);
		if (b == null) sources.set(file, b = File.getBytes(file));
		if (min > b.length) return {doc: "", line: 0};
		// the start of the declaration's line
		var start = min;
		while (start > 0 && b.get(start - 1) != "\n".code)
			start--;
		var line = 1;
		for (k in 0...start)
			if (b.get(k) == "\n".code) line++;
		var lines = [];
		var end = start;
		while (end > 0) {
			var s = end - 1;
			while (s > 0 && b.get(s - 1) != "\n".code)
				s--;
			var text = b.getString(s, end - 1 - s).trim();
			if (text.startsWith("//")) {
				lines.unshift(text.substr(2).trim());
			} else if (text.startsWith("@") || (text.startsWith("*") || text.startsWith("/**")) && lines.length == 0) {
				// metadata between the comment and the declaration; a /** */ doc
				if (text.startsWith("/**") || text.startsWith("*")) lines.unshift(text.replace("/**", "").replace("*/", "").replace("*", "").trim());
			} else break;
			end = s;
		}
		var text = lines.join("\n").trim();
		if (text == "") return {doc: "", line: line};
		// (paragraphs at blank comment lines; inline Markdown)
		var md = new Markdown(s -> s);
		var paras = [for (p in ~/\n\s*\n/g.split(text)) "<p>" + md.inlines(p) + "</p>"];
		return {doc: paras.join(""), line: line};
	}
}
