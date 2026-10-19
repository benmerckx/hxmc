package hxmc.scene.anim;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.Node;
import hxmc.scene.gltf.GltfDoc;
import hxmc.scene.math.Quat;

// Keyframes of nodes' transforms (glTF's animations: translation,
// rotation, scale; step, linear and cubic-spline interpolation), each
// track a node index (the glTF node's) and its times and values, sampled
// at a time into the nodes given (Animator; apply), and morph targets'
// weights (a node's MorphWeights).
class AnimationClip {
	public final name:String;
	public final tracks:Array<Track>;
	// the last keyframe's time
	public final duration:Float;

	public function new(name:String, tracks:Array<Track>) {
		this.name = name;
		this.tracks = tracks;
		var d = 0.0;
		for (t in tracks)
			if (t.times.length > 0 && t.times[t.times.length - 1] > d) d = t.times[t.times.length - 1];
		duration = d;
	}

	// a glTF animation's clip
	public static function fromGltf(doc:GltfDoc, animation:Int):AnimationClip {
		var a = doc.animations[animation];
		var tracks = [];
		for (c in a.channels) {
			var path = switch c.path {
				case "translation": Translation;
				case "rotation": Rotation;
				case "scale": Scale;
				case "weights": Weights;
				case _: continue;
			}
			tracks.push(new Track(c.node, path, doc.floats(c.input), doc.floats(c.output), switch c.interpolation {
				case "STEP": Step;
				case "CUBICSPLINE": CubicSpline;
				case _: Linear;
			}));
		}
		return new AnimationClip(a.name, tracks);
	}

	// the clip at time t (clamped to 0..duration) on nodes (by track index:
	// a glTF node's index; missing ones skipped), blended by weight (1: set)
	public function apply(nodes:Array<Node>, t:Float, weight = 1.0) {
		for (track in tracks) {
			var n = track.node < nodes.length ? nodes[track.node] : Node.NONE;
			if (n.isNone || !n.valid) continue;
			switch track.path {
				case Translation:
					var v = track.vec3(t);
					n.position = weight >= 1 ? v : lerp(n.position, v, weight);
				case Scale:
					var v = track.vec3(t);
					n.scale = weight >= 1 ? v : lerp(n.scale, v, weight);
				case Rotation:
					var q = track.quat(t);
					n.rotation = weight >= 1 ? q : Quat.slerp(n.rotation, q, weight);
				case Weights:
					var m = MorphWeights.of(n);
					if (m != null) track.weightsAt(t, m.weights, weight);
			}
		}
	}

	static inline function lerp(a:Vec3, b:Vec3, t:Float):Vec3
		return a + (b - a) * t;
}

enum TrackPath {
	Translation;
	Rotation;
	Scale;
	Weights;
}

enum Interpolation {
	Step;
	Linear;
	CubicSpline;
}

class Track {
	public final node:Int;
	public final path:TrackPath;
	public final times:Array<Float>;
	// per time: the value's components (a cubic spline's: in-tangent, value, out-tangent)
	public final values:Array<Float>;
	public final interpolation:Interpolation;
	final size:Int;

	public function new(node:Int, path:TrackPath, times:Array<Float>, values:Array<Float>, interpolation:Interpolation) {
		this.node = node;
		this.path = path;
		this.times = times;
		this.values = values;
		this.interpolation = interpolation;
		// (weights: as many as the values over the keys)
		size = path == Rotation ? 4 : path == Weights ? Std.int(values.length / Math.max(times.length * (interpolation == CubicSpline ? 3 : 1), 1)) : 3;
	}

	// the keyframe before t (the last one at or before it) and how far t is to the next
	function locate(t:Float):{k:Int, f:Float, dt:Float} {
		var n = times.length;
		if (n == 0 || t <= times[0]) return {k: 0, f: 0.0, dt: 0.0};
		if (t >= times[n - 1]) return {k: n - 1, f: 0.0, dt: 0.0};
		var lo = 0, hi = n - 1;
		while (hi - lo > 1) {
			var mid = (lo + hi) >> 1;
			if (times[mid] <= t) lo = mid else hi = mid;
		}
		var dt = times[lo + 1] - times[lo];
		return {k: lo, f: dt > 0 ? (t - times[lo]) / dt : 0.0, dt: dt};
	}

	// component c of the value at t
	function component(at:{k:Int, f:Float, dt:Float}, c:Int):Float {
		var k = at.k, f = at.f;
		return switch interpolation {
			case Step: values[k * size + c];
			case Linear:
				var a = values[k * size + c];
				f == 0 ? a : a + (values[(k + 1) * size + c] - a) * f;
			case CubicSpline:
				// (Hermite: value k, its out-tangent, value k+1, its in-tangent, tangents scaled by the interval)
				var p0 = values[(3 * k + 1) * size + c];
				if (f == 0) p0 else {
					var m0 = values[(3 * k + 2) * size + c] * at.dt, p1 = values[(3 * (k + 1) + 1) * size + c],
						m1 = values[(3 * (k + 1)) * size + c] * at.dt;
					var f2 = f * f, f3 = f2 * f;
					(2 * f3 - 3 * f2 + 1) * p0 + (f3 - 2 * f2 + f) * m0 + (-2 * f3 + 3 * f2) * p1 + (f3 - f2) * m1;
				}
		}
	}

	// morph weights at t into out, blended by weight (1: set)
	public function weightsAt(t:Float, out:Array<Float>, weight = 1.0) {
		var at = locate(t);
		for (c in 0...Std.int(Math.min(size, out.length))) {
			var v = component(at, c);
			out[c] = weight >= 1 ? v : out[c] + (v - out[c]) * weight;
		}
	}

	public function vec3(t:Float):Vec3 {
		var at = locate(t);
		return new Vec3(component(at, 0), component(at, 1), component(at, 2));
	}

	public function quat(t:Float):Quat {
		var at = locate(t);
		if (interpolation == Linear && at.f > 0) {
			var k = at.k * 4, j = k + 4;
			return Quat.slerp(new Quat(values[k], values[k + 1], values[k + 2], values[k + 3]),
				new Quat(values[j], values[j + 1], values[j + 2], values[j + 3]), at.f);
		}
		return new Quat(component(at, 0), component(at, 1), component(at, 2), component(at, 3)).normalized();
	}
}
