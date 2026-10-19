package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.math.MathTools;
import hxmc.scene.render.ParticleShader;

// Particle systems, a renderable kind added by a feature
// (renderer.use(new Particles(device))): emitters are components of nodes
// (Emitter, at the node's world position), simulated by update(world, dt)
// at the fixed step, drawn at the renderer's AfterOpaque point as
// camera-facing quads in one instanced draw per emitter, added to the
// scene behind them. Deterministic: each emitter's random numbers come
// from its own seed.
class Particles implements RenderFeature {
	final device:Device;
	final pipeline:Pipeline;
	final quad:Buffer;
	final indices:Buffer;
	final viewBytes = Bytes.alloc(ParticleShader.uniforms[0].size);
	var instanceBytes = Bytes.alloc(32 * 256);
	var instances:Buffer = Buffer.NONE;
	var capacity = 0;

	static final LAYOUT:Array<VertexBufferLayout> = [
		{stride: 8, attributes: [{location: 0, format: Float2, offset: 0}]},
		{
			stride: 32,
			step: Instance,
			attributes: [{location: 1, format: Float3, offset: 0}, {location: 2, format: Float1, offset: 12}, {location: 3, format: Float4, offset: 16}]
		}
	];

	public function new(device:Device) {
		this.device = device;
		var d = ParticleShader.pipeline({blend: Additive, depthCompare: Less, depthWrite: false});
		d.layout = LAYOUT;
		pipeline = device.createPipeline(d);
		var q = Bytes.alloc(32);
		var c = [-1.0, -1, 1, -1, 1, 1, -1, 1];
		for (k in 0...8)
			q.setFloat(4 * k, c[k]);
		quad = device.createBuffer({size: 32, usage: Vertex, data: q});
		var ib = Bytes.alloc(12);
		var idx = [0, 1, 2, 0, 2, 3];
		for (k in 0...6)
			ib.setUInt16(2 * k, idx[k]);
		indices = device.createBuffer({size: 12, usage: Index, data: ib});
	}

	public function attach(renderer:Renderer)
		renderer.inject(AfterOpaque, (enc, frame) -> draw(enc, frame));

	// every emitter of world, dt seconds on
	public static function update(world:World, dt:Float) {
		var store = world.store(Emitter.KIND);
		for (k in 0...store.length)
			store.valueAt(k).step(store.nodeAt(k), dt);
	}

	function draw(enc:Encoder, frame:Renderer.FrameInfo) {
		var world = frame.world;
		if (world == null) return;
		var store = world.store(Emitter.KIND);
		if (store.length == 0) return;
		// (the camera's right and up: its node's world axes)
		var m = frame.camera.node.worldMatrix();
		var right = MathTools.transformDir(m, new Vec3(1, 0, 0)), up = MathTools.transformDir(m, new Vec3(0, 1, 0));
		ParticleShader.writeParticleView({viewProj: frame.viewProj, right: new Vec4(right.x, right.y, right.z, 0), up: new Vec4(up.x, up.y, up.z, 0)},
			viewBytes);
		// (all emitters' particles in one buffer: gfx writes buffers at once, ahead of the frame's commands)
		var total = 0;
		for (k in 0...store.length)
			if (store.nodeAt(k).shown()) total += store.valueAt(k).count;
		if (total == 0) return;
		if (instanceBytes.length < total * 32) instanceBytes = Bytes.alloc(total * 64);
		var n = 0;
		for (k in 0...store.length)
			if (store.nodeAt(k).shown()) n = store.valueAt(k).write(instanceBytes, n);
		if (total * 32 > capacity) {
			if (capacity > 0) device.destroyBuffer(instances);
			capacity = instanceBytes.length;
			instances = device.createBuffer({size: capacity, usage: Vertex});
		}
		device.writeBuffer(instances, 0, instanceBytes, 0, total * 32);
		enc.setPipeline(pipeline);
		enc.setUniforms(0, viewBytes);
		enc.setVertexBuffer(0, quad);
		enc.setVertexBuffer(1, instances);
		enc.setIndexBuffer(indices, UInt16);
		enc.drawIndexed(6, total);
	}
}
