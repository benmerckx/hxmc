package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.math.MathTools;
import hxmc.scene.render.SkyShader;

// A sky behind the scene, opted in (renderer.use(new Sky(device))): drawn
// at the renderer's BeforeOpaque point, a gradient from the ground to the
// horizon to the zenith with the sun's disc in the direction of the
// world's light. The environment-map sky and its lighting come later
// (docs/plans/3d.md, step 3).
class Sky implements RenderFeature {
	public var zenith = new Vec3(0.18, 0.32, 0.65);
	public var horizon = new Vec3(0.7, 0.75, 0.82);
	public var ground = new Vec3(0.12, 0.11, 0.1);
	public var sunColor = new Vec3(1, 0.9, 0.7);

	final device:Device;
	final pipeline:Pipeline;
	final quad:Buffer;
	final bytes = Bytes.alloc(SkyShader.uniforms[0].size);

	public function new(device:Device) {
		this.device = device;
		pipeline = device.createPipeline(SkyShader.pipeline());
		var v = SkyShader.vertexBytes([
			{pos: new hxmc.gfx.shader.Vec2(-1, -1)}, {pos: new hxmc.gfx.shader.Vec2(1, -1)}, {pos: new hxmc.gfx.shader.Vec2(-1, 1)},
			{pos: new hxmc.gfx.shader.Vec2(-1, 1)}, {pos: new hxmc.gfx.shader.Vec2(1, -1)}, {pos: new hxmc.gfx.shader.Vec2(1, 1)}
		]);
		quad = device.createBuffer({size: v.length, usage: Vertex, data: v});
	}

	public function attach(renderer:Renderer)
		renderer.inject(BeforeOpaque, (enc, frame) -> draw(enc, frame, renderer));

	function draw(enc:Encoder, frame:Renderer.FrameInfo, renderer:Renderer) {
		var e = frame.eye, l = frame.toLight;
		SkyShader.writeSkyParams({
			invViewProj: MathTools.inverse(frame.viewProj),
			eye: new Vec4(e.x, e.y, e.z, 1),
			zenith: new Vec4(zenith.x, zenith.y, zenith.z, 0),
			horizon: new Vec4(horizon.x, horizon.y, horizon.z, 0),
			ground: new Vec4(ground.x, ground.y, ground.z, 0),
			sun: new Vec4(l.x, l.y, l.z, renderer.exposure),
			sunColor: new Vec4(sunColor.x, sunColor.y, sunColor.z, 0)
		}, bytes);
		enc.setPipeline(pipeline);
		enc.setUniforms(0, bytes);
		enc.setVertexBuffer(0, quad);
		enc.draw(6);
	}
}
