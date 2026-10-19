package hxmc.scene.render;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.math.MathTools;

// Picking: the nearest shown node drawing a mesh whose bounds a ray
// crosses (each node's mesh bounds in its own frame, the ray brought
// there: turned and scaled boxes fit), for a click (Camera.ray) or a line
// of sight. Bounds, not triangles: a game wanting exact hits narrows the
// candidates with physics or its own test.
//   var r = camera.ray(x, y, aspect);
//   var hit = Pick.ray(world, r.origin, r.dir);
class Pick {
	public static function ray(world:World, origin:Vec3, dir:Vec3):Null<{node:Node, distance:Float, point:Vec3}> {
		var meshes = world.store(MeshRenderer.KIND);
		var best:Null<Node> = null, bestT = Math.POSITIVE_INFINITY, bestPoint = origin;
		var l = Math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
		if (l == 0) return null;
		var d = dir / l;
		for (k in 0...meshes.length) {
			var node = meshes.nodeAt(k), mesh = meshes.valueAt(k);
			if (!node.shown() || !world.inTree(node) || mesh.bounds.isEmpty()) continue;
			var m = node.worldMatrix(), inv = MathTools.inverse(m);
			var lo = MathTools.transformPoint(inv, origin), ld = MathTools.transformDir(inv, d);
			var t = mesh.bounds.ray(lo, ld);
			if (t < 0) continue;
			// (back in the world: the distance along the unit ray)
			var p = MathTools.transformPoint(m, lo + ld * t), e = p - origin;
			var dist = Math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
			if (dist < bestT) {
				bestT = dist;
				best = node;
				bestPoint = p;
			}
		}
		return best == null ? null : {node: best, distance: bestT, point: bestPoint};
	}
}
