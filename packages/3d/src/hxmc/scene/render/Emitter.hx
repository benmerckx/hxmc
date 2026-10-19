package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.Node;
import hxmc.scene.StoreKind;

// An emitter: rate particles a second from its node's world position,
// each living life seconds, starting with velocity plus a random spread,
// pulled by gravity, growing from size to endSize, its colour fading out.
class Emitter {
	public static final KIND = new StoreKind<Emitter>("emitter");

	public var rate = 40.0;
	public var life = 1.5;
	public var velocity = new Vec3(0, 2, 0);
	public var spread = 1.0;
	public var gravity = new Vec3(0, -2, 0);
	public var size = 0.08;
	public var endSize = 0.02;
	public var color = new Vec4(2.5, 1.2, 0.4, 1);
	public var max = 512;
	public var count(default, null) = 0;

	// (per particle: x y z, vx vy vz, age)
	final data:Array<Float> = [];
	var due = 0.0;
	var seed:Int;

	public function new(seed = 1) {
		this.seed = seed;
	}

	public static inline function attach(node:Node, e:Emitter):Emitter
		return node.world.store(KIND).set(node, e);

	// (a linear congruential generator: the same particles on every target)
	inline function random():Float {
		seed = (seed * 1103515245 + 12345) & 0x7fffffff;
		return seed / 0x7fffffff;
	}

	@:allow(hxmc.scene.render.Particles) function step(node:Node, dt:Float) {
		// age, move, drop the dead
		var i = 0;
		while (i < count) {
			var b = 7 * i;
			data[b + 6] += dt;
			if (data[b + 6] >= life) {
				// (the last one into its place)
				var last = 7 * (count - 1);
				for (k in 0...7)
					data[b + k] = data[last + k];
				count--;
				continue;
			}
			data[b + 3] += gravity.x * dt;
			data[b + 4] += gravity.y * dt;
			data[b + 5] += gravity.z * dt;
			data[b] += data[b + 3] * dt;
			data[b + 1] += data[b + 4] * dt;
			data[b + 2] += data[b + 5] * dt;
			i++;
		}
		due += rate * dt;
		var p = node.worldPosition();
		while (due >= 1 && count < max) {
			due -= 1;
			var b = 7 * count;
			while (data.length < b + 7)
				data.push(0);
			data[b] = p.x;
			data[b + 1] = p.y;
			data[b + 2] = p.z;
			data[b + 3] = velocity.x + (random() * 2 - 1) * spread;
			data[b + 4] = velocity.y + (random() * 2 - 1) * spread;
			data[b + 5] = velocity.z + (random() * 2 - 1) * spread;
			data[b + 6] = 0;
			count++;
		}
		if (due > 1) due = 1;
	}

	// the particles as instances (center, size, colour) from instance k on; the next k
	@:allow(hxmc.scene.render.Particles) function write(out:Bytes, k:Int):Int {
		for (i in 0...count) {
			var b = 7 * i, o = 32 * k, t = data[b + 6] / life;
			out.setFloat(o, data[b]);
			out.setFloat(o + 4, data[b + 1]);
			out.setFloat(o + 8, data[b + 2]);
			out.setFloat(o + 12, size + (endSize - size) * t);
			out.setFloat(o + 16, color.x);
			out.setFloat(o + 20, color.y);
			out.setFloat(o + 24, color.z);
			out.setFloat(o + 28, color.w * (1 - t));
			k++;
		}
		return k;
	}
}
