package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.math.MathTools;
import hxmc.scene.render.EnvironmentShader;

// An environment, opted in (renderer.use(new Environment(device,
// texture))): an equirectangular image (longitude across, latitude down;
// sRGB, mip-mapped) drawn behind the scene (at the renderer's BeforeOpaque
// point, as the sky) and lighting it: the standard material's ambient
// from it, diffuse from a small mip level along the normal, specular
// along the reflection from a level by roughness (mip levels standing in
// for a filtered map: a cheap image-based light). A program without one
// keeps the sky-and-ground ambient and links none of this.
//   var env = Environment.fromImage(device, "image/png", Asset.embed("sky.png")); // with Images.decode set
class Environment implements RenderFeature {
	public final device:Device;
	public final texture:Texture;
	// the mip levels below the first (the map's width 2^levels)
	public final levels:Int;
	// how bright the environment is, as light (1: its colours)
	public var intensity = 1.0;
	// whether it is drawn behind the scene (false: it only lights it)
	public var background = true;

	final pipeline:Pipeline;
	final quad:Buffer;
	final sampler:Sampler;
	final bytes = Bytes.alloc(EnvironmentShader.uniforms[0].size);

	// texture: mip-mapped (Images.mipmapped's), width twice its height
	public function new(device:Device, texture:Texture, width:Int) {
		this.device = device;
		this.texture = texture;
		var l = 0;
		while ((1 << (l + 1)) <= width)
			l++;
		levels = l;
		pipeline = device.createPipeline(EnvironmentShader.pipeline());
		var v = EnvironmentShader.vertexBytes([
			{pos: new hxmc.gfx.shader.Vec2(-1, -1)}, {pos: new hxmc.gfx.shader.Vec2(1, -1)}, {pos: new hxmc.gfx.shader.Vec2(-1, 1)},
			{pos: new hxmc.gfx.shader.Vec2(-1, 1)}, {pos: new hxmc.gfx.shader.Vec2(1, -1)}, {pos: new hxmc.gfx.shader.Vec2(1, 1)}
		]);
		quad = device.createBuffer({size: v.length, usage: Vertex, data: v});
		sampler = device.createSampler({filter: Linear, mipFilter: Linear, wrap: Repeat});
	}

	// an encoded image's environment (Images.decode must read it); null when it cannot
	public static function fromImage(device:Device, mime:String, bytes:Bytes):Null<Environment> {
		if (Images.decode == null) return null;
		var image = Images.decode(mime, bytes);
		if (image == null) return null;
		return new Environment(device, Images.mipmapped(device, image.width, image.height, image.rgba), image.width);
	}

	public function attach(renderer:Renderer) {
		@:privateAccess renderer.environment = this;
		renderer.inject(BeforeOpaque, (enc, frame) -> if (background) draw(enc, frame, renderer));
	}

	// (the standard material's binding)
	@:allow(hxmc.scene.render.Renderer) function bind(enc:Encoder, slot:Int)
		enc.setTexture(slot, texture, sampler);

	function draw(enc:Encoder, frame:Renderer.FrameInfo, renderer:Renderer) {
		var e = frame.eye;
		EnvironmentShader.writeEnvironmentParams({
			invViewProj: MathTools.inverse(frame.viewProj),
			eye: new Vec4(e.x, e.y, e.z, 1),
			params: new Vec4(intensity * renderer.exposure, 0, 0, 0)
		}, bytes);
		enc.setPipeline(pipeline);
		enc.setUniforms(0, bytes);
		enc.setTexture(EnvironmentShader.textures[0].binding, texture, sampler);
		enc.setVertexBuffer(0, quad);
		enc.draw(6);
	}

	public function dispose() {
		device.destroyTexture(texture);
		device.destroyBuffer(quad);
	}
}
