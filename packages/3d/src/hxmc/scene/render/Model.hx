package hxmc.scene.render;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#else
import haxe.io.Bytes;
import hxmc.gfx.Device;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.gltf.Gltf;
import hxmc.scene.gltf.GltfDoc;
import hxmc.scene.gltf.GltfScene;
#end

// A glTF model referenced where it is used: Model.of("models/hero.glb") is
// a macro that checks the file exists, reads its structure when compiling
// and types the result from it: model.nodes, model.meshes,
// model.materials and model.animations have a field per name in the file (its value the name,
// for World.find; a name that is no identifier made one: "Left Hand" is
// Left_Hand), so a typo is a compile error. The file goes with the build:
// up to 64 KB (-D hxmc.scene.embed=<bytes>) built into the program, else
// copied beside it (assets/) and listed in <output>.assets.json, which
// os's browser.mjs fetches before main (options.assets) while the module
// loads; natively read from beside the executable (Android and iOS: built
// in for now). Either way the model is ready at once:
//
//   var hero = Model.of("models/hero.glb");
//   var root = hero.instantiate(world, device);
//   var hand = root.find(hero.nodes.LeftHand);
//
// Model.of(path, Lazy) is an Asset of the model instead, loaded in the
// background (big games, loading screens: asset.then, asset.ready), its
// names typed the same; Model.load(path) loads a path known only at run
// time (an Asset, names unknown).
//
// Its GPU meshes are made by the first instantiate with a device and
// shared by every instance.
class Model<N, M, A, C> {
	#if !macro
	public final doc:GltfDoc;
	public final nodes:N;
	public final meshes:M;
	public final materials:A;
	public final animations:C;

	var scene:Null<GltfScene>;
	var device:Null<Device>;

	@:noCompletion public function new(bytes:Bytes, nodes:N, meshes:M, materials:A, animations:C) {
		doc = Gltf.parse(bytes);
		this.nodes = nodes;
		this.meshes = meshes;
		this.materials = materials;
		this.animations = animations;
	}

	// the model's scene as nodes of world (under parent, by default the root)
	public function instantiate(world:World, device:Device, ?parent:Node, ?made:Array<Node>):Node {
		if (scene == null || this.device != device) {
			scene = new GltfScene(doc, device);
			this.device = device;
		}
		return scene.instantiate(world, parent, null, made);
	}

	// an animation of the model by name (model.animations.Run), for an Animator
	public function clip(name:String):hxmc.scene.anim.AnimationClip {
		for (k in 0...doc.animations.length)
			if (doc.animations[k].name == name) return hxmc.scene.anim.AnimationClip.fromGltf(doc, k);
		throw 'Model: no animation $name';
	}

	// the model's GPU meshes released
	public function dispose() {
		if (scene != null) scene.dispose(device);
		scene = null;
	}
	#end

	#if macro
	static var assets:Array<String> = [];
	static var registered = false;
	#else
	// a model whose path is known only at run time: loaded in the background
	// (in the browser fetched, relative to the page; natively read at once),
	// its names unknown when compiling (find nodes by name: model.doc)
	public static function load(path:String):hxmc.scene.Asset<Model<{}, {}, {}, {}>>
		return loadNamed(path, {}, {}, {}, {});

	@:noCompletion public static function loadNamed<N, M, A, C>(path:String, nodes:N, meshes:M, materials:A, animations:C):hxmc.scene.Asset<Model<N, M, A, C>> {
		var asset = new hxmc.scene.Asset<Model<N, M, A, C>>();
		var f = hxmc.os.Fetch.start(path);
		hxmc.scene.Assets.track(() -> {
			if (f.poll()) {
				try
					asset.resolve(new Model(f.bytes, nodes, meshes, materials, animations))
				catch (e:String)
					asset.fail(e);
				return true;
			}
			if (f.failed) {
				asset.fail('Model: $path not found');
				return true;
			}
			return false;
		});
		return asset;
	}

	// (Lazy: beside the executable natively, relative to the page in the browser)
	@:noCompletion public static function lazyPath(rel:String):String {
		#if (hxmc.target == "wasm32-wasi")
		return rel;
		#else
		return haxe.io.Path.join([haxe.io.Path.directory(Sys.programPath()), rel]);
		#end
	}

	// a file the build put beside the program (assets/...): natively next to
	// the executable, in the browser fetched before main (os's browser.mjs)
	public static function file(rel:String):Bytes {
		#if (hxmc.target == "wasm32-wasi")
		return sys.io.File.getBytes(rel);
		#else
		return sys.io.File.getBytes(haxe.io.Path.join([haxe.io.Path.directory(Sys.programPath()), rel]));
		#end
	}
	#end

	public static macro function of(path:String, ?mode:Expr):Expr {
		var lazy = switch mode {
			case null | {expr: EConst(CIdent("null"))}: false;
			case {expr: EConst(CIdent("Lazy"))}: true;
			case _: Context.error("Model.of: the mode is Lazy", mode.pos);
		}
		var pos = Context.currentPos();
		var file = try Context.resolvePath(path) catch (_:Dynamic) path;
		if (!sys.FileSystem.exists(file)) Context.error('Model.of: $path not found', pos);
		Context.registerModuleDependency(Context.getLocalModule(), file);
		var bytes = sys.io.File.getBytes(file);
		// (the structure read with the runtime's file splitting; the runtime's
		// reader checks the rest when the model is made)
		var root:Dynamic = try haxe.Json.parse(hxmc.scene.gltf.GltfFile.split(bytes).json) catch (e:Dynamic) Context.error('Model.of: $path: $e', pos);
		function list(f:String):Array<Dynamic> {
			var v:Dynamic = Reflect.field(root, f);
			return Std.isOfType(v, Array) ? v : [];
		}
		function nameOf(o:Dynamic):String {
			var v:Dynamic = Reflect.field(o, "name");
			return Std.isOfType(v, String) ? v : "";
		}
		var buffers = list("buffers");
		var outside = [for (im in list("images")) if (Reflect.hasField(im, "uri") && !StringTools.startsWith(Reflect.field(im, "uri"), "data:")) im];
		if (buffers.length > 1 || outside.length > 0 || buffers.length == 1 && Reflect.hasField(buffers[0], "uri")
			&& !StringTools.startsWith(Reflect.field(buffers[0], "uri"), "data:"))
			Context.error('Model.of: $path: only self-contained files (one embedded buffer, images inside it) yet', pos);
		function names(list:Array<String>):Expr {
			var seen = new Map<String, Bool>(), fields:Array<ObjectField> = [];
			for (n in list) {
				if (n == null || n == "") continue;
				var id = ~/[^A-Za-z0-9_]/g.replace(n, "_");
				if (~/^[0-9]/.match(id)) id = "_" + id;
				if (seen.exists(id)) continue;
				seen.set(id, true);
				fields.push({field: id, expr: macro $v{n}});
			}
			return {expr: EObjectDecl(fields), pos: pos};
		}
		var n = names([for (x in list("nodes")) nameOf(x)]), m = names([for (x in list("meshes")) nameOf(x)]), a = names([for (x in list("materials")) nameOf(x)]),
			c = names([for (x in list("animations")) nameOf(x)]);
		// (small files, and every file on Android and iOS for now, built into
		// the program; others copied beside it, assets/, and listed in
		// <output>.assets.json for the browser to fetch before main)
		var limit = Context.defined("hxmc.scene.embed") ? Std.parseInt(Context.definedValue("hxmc.scene.embed")) : 65536;
		var target = Context.defined("hxmc.target") ? Context.definedValue("hxmc.target") : "";
		var output = haxe.macro.Compiler.getOutput();
		// (the repository tool's `hxmc <output> <args>` hides it: -D hxmc.scene.out=<output>)
		if ((output == null || output == "") && Context.defined("hxmc.scene.out")) output = Context.definedValue("hxmc.scene.out");
		if (!lazy && bytes.length <= limit || StringTools.startsWith(target, "android") || StringTools.startsWith(target, "ios") || output == null || output == "") {
			var data = haxe.crypto.Base64.encode(bytes);
			var made = macro new hxmc.scene.render.Model(haxe.crypto.Base64.decode($v{data}), $n, $m, $a, $c);
			// (Lazy where the file is built in: an asset ready at once)
			return lazy ? macro {
				var asset = new hxmc.scene.Asset();
				asset.resolve($made);
				asset;
			} : made;
		}
		var rel = "assets/" + haxe.io.Path.withoutDirectory(file);
		var dir = haxe.io.Path.directory(output);
		var dest = haxe.io.Path.join([dir == "" ? "." : dir, rel]);
		sys.FileSystem.createDirectory(haxe.io.Path.directory(dest));
		sys.io.File.saveBytes(dest, bytes);
		// (Lazy files are not fetched before main: the program loads them)
		if (!lazy && !assets.contains(rel)) assets.push(rel);
		if (!registered) {
			registered = true;
			Context.onAfterGenerate(() -> sys.io.File.saveContent(output + ".assets.json", haxe.Json.stringify(assets)));
		}
		if (lazy) return macro hxmc.scene.render.Model.loadNamed(hxmc.scene.render.Model.lazyPath($v{rel}), $n, $m, $a, $c);
		return macro new hxmc.scene.render.Model(hxmc.scene.render.Model.file($v{rel}), $n, $m, $a, $c);
	}
}
