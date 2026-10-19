package hxmc.scene;

import hxmc.dev.Hot;

// A world's transforms carried across a reload under `hxmc dev` (fast
// refresh, docs/dev.md): the new build makes its world again in main as on
// a cold start, then HotWorld.keep(world, key) puts back the position,
// rotation and scale the old build's nodes had, by path (names from the
// root, "a/b/c", a repeated name among siblings numbered "c#1"), so a node
// the new build no longer has is dropped and a new one keeps what main
// gave it. Without -D hxmc.dev it compiles to nothing.
class HotWorld {
	public static function keep(world:World, key:String) {
		var type = Hot.typeOf((_ : WorldTransforms));
		var last:Null<WorldTransforms> = Hot.load(key, type);
		if (last != null) restore(world, last);
		Hot.onSnapshot(() -> Hot.save(key, save(world), type));
	}

	// every node's path and transform (10 floats each: position, rotation, scale)
	public static function save(world:World):WorldTransforms {
		var out:WorldTransforms = {paths: [], trs: []};
		visit(world.root, "", (n, path) -> {
			out.paths.push(path);
			var p = n.position, r = n.rotation, s = n.scale;
			for (x in [p.x, p.y, p.z, r.x, r.y, r.z, r.w, s.x, s.y, s.z])
				out.trs.push(x);
		});
		return out;
	}

	// the saved transforms put back on the nodes with the same paths; returns how many
	public static function restore(world:World, saved:WorldTransforms):Int {
		var at = new Map<String, Int>();
		for (i in 0...saved.paths.length)
			at.set(saved.paths[i], i);
		var count = 0;
		visit(world.root, "", (n, path) -> {
			var i = at.get(path);
			if (i == null || 10 * i + 10 > saved.trs.length) return;
			var t = saved.trs, b = 10 * i;
			n.position = new hxmc.gfx.shader.Vec3(t[b], t[b + 1], t[b + 2]);
			n.rotation = new hxmc.scene.math.Quat(t[b + 3], t[b + 4], t[b + 5], t[b + 6]);
			n.scale = new hxmc.gfx.shader.Vec3(t[b + 7], t[b + 8], t[b + 9]);
			count++;
		});
		return count;
	}

	static function visit(n:Node, path:String, f:(Node, String) -> Void) {
		f(n, path);
		var seen = new Map<String, Int>();
		for (c in n.children()) {
			var k = seen.exists(c.name) ? seen.get(c.name) + 1 : 0;
			seen.set(c.name, k);
			visit(c, path + "/" + c.name + (k > 0 ? "#" + k : ""), f);
		}
	}
}

typedef WorldTransforms = {
	var paths:Array<String>;
	var trs:Array<Float>;
}
