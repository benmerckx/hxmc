package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.World;
import hxmc.scene.math.Aabb;
import hxmc.scene.math.MathTools;
import hxmc.scene.render.ShadowShader;

// Shadow maps for the directional light, opted in (renderer.use(new
// Shadows(device))): before the frame's pass, every shown mesh drawn from
// the light into size x size R32F targets, which the standard material
// then reads with a 3x3 percentage-closer filter. One cascade: an
// orthographic view fitted to the casters' bounds. Two (Shadows.cascaded,
// whose fitting code a program without it does not link):
// the first fitted to the camera's view up to split metres (its bounding
// sphere, moved by whole texels: steady as the camera moves), sharp near
// the camera, the second the whole scene's, read beyond the first. A
// program that never makes a Shadows links none of this but the
// material's lookup of a 1x1 map that shadows nothing.
class Shadows implements RenderFeature implements RenderFeature.ShadowSource {
	public final device:Device;
	public final size:Int;
	// 1, or 2 (Shadows.cascaded)
	public var cascades(default, null) = 1;
	// how far from the camera the first of two cascades reaches (metres)
	public var split = 10.0;
	// the depth offset against shadow acne (in the whole scene's map's 0..1
	// depth; the first of two cascades', as many of its texels)
	public var bias = 0.004;
	// the shadows' strength, 0 (none) to 1 (no direct light at all)
	public var strength = 0.85;
	// the first cascade's map (one cascade: the only one), the second's
	public final map:Texture;
	public var mapFar(default, null):Texture;

	final depth:Texture;
	final pipeline:Pipeline;
	final casterBytes = Bytes.alloc(ShadowShader.uniforms[0].size);
	final pass:PassDesc;
	var passFar:PassDesc;
	// the last frame's light view-projections (the first cascade's, the second's)
	public var viewProj(default, null):Mat4 = Mat4.identity();
	public var viewProjFar(default, null):Mat4 = Mat4.identity();
	// (the first of two cascades' bias in its depth)
	var nearBias = 0.004;
	// (two cascades: the first's fitting, set by cascaded)
	var fit:Null<(Renderer.FrameInfo, Vec3, Vec3, Vec3, Float) -> Mat4>;

	// one cascade
	public function new(device:Device, size = 1024) {
		this.device = device;
		this.size = size;
		map = device.createTexture({width: size, height: size, format: R32F, renderTarget: true});
		mapFar = map;
		depth = device.createTexture({width: size, height: size, format: Depth32F});
		var d = ShadowShader.pipeline({cull: None, depthCompare: Less, depthWrite: true});
		d.colorFormat = R32F;
		d.depthFormat = Depth32F;
		pipeline = device.createPipeline(d);
		pass = {colors: [{load: Clear, clear: new Color(1, 1, 1, 1), texture: map}], depth: {load: Clear, texture: depth}};
		passFar = pass;
	}

	// two cascades, the first reaching split metres from the camera
	public static function cascaded(device:Device, size = 1024, split = 10.0):Shadows {
		var s = new Shadows(device, size);
		s.cascades = 2;
		s.split = split;
		s.mapFar = device.createTexture({width: size, height: size, format: R32F, renderTarget: true});
		s.passFar = {colors: [{load: Clear, clear: new Color(1, 1, 1, 1), texture: s.mapFar}], depth: {load: Clear, texture: s.depth}};
		s.fit = s.fitNear;
		return s;
	}

	public function attach(renderer:Renderer)
		@:privateAccess renderer.shadowSource = this;

	final frame = new RenderFeature.ShadowFrame();

	public function shadowFrame():RenderFeature.ShadowFrame {
		frame.map = map;
		frame.viewProj = viewProj;
		frame.params = new Vec4(strength, cascades == 2 ? nearBias : bias, 1 / size, 0);
		frame.mapFar = mapFar;
		frame.viewProjFar = viewProjFar;
		frame.paramsFar = cascades == 2 ? new Vec4(strength, bias, 1 / size, 0) : frame.params;
		return frame;
	}

	// the maps' passes: the world's shown meshes seen from a light shining along -toLight
	public function render(enc:Encoder, world:World, toLight:Vec3, skins:Null<RenderFeature.SkinSource>, view:Renderer.FrameInfo) {
		var meshes = world.store(MeshRenderer.KIND);
		var bounds = Aabb.empty();
		for (k in 0...meshes.length) {
			var n = meshes.nodeAt(k);
			if (n.shown() && world.inTree(n)) bounds = bounds.union(meshes.valueAt(k).bounds.transform(n.worldMatrix()));
		}
		if (bounds.isEmpty()) bounds = new Aabb(new Vec3(-1, -1, -1), new Vec3(1, 1, 1));
		var c = bounds.center(), e = bounds.size();
		var r = Math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / 2 + 0.01;
		// (up: any direction not along the light's)
		var up = Math.abs(toLight.y) > 0.99 ? new Vec3(0, 0, 1) : new Vec3(0, 1, 0);
		var whole = Mat4.orthographic(-r, r, -r, r, r * 0.5, r * 3.5) * MathTools.lookAt(c + toLight * (2 * r), c, up);
		if (fit == null || view.camera == null) {
			viewProj = viewProjFar = whole;
			draw(enc, pass, meshes, world, skins, viewProj);
			return;
		}
		viewProjFar = whole;
		viewProj = fit(view, toLight, up, c, r);
		draw(enc, pass, meshes, world, skins, viewProj);
		draw(enc, passFar, meshes, world, skins, viewProjFar);
	}

	// the first cascade: the bounding sphere of the camera's view from its
	// near plane to split, as deep towards the light as the scene (its
	// sphere: centre c, radius r)
	function fitNear(view:Renderer.FrameInfo, toLight:Vec3, up:Vec3, c:Vec3, r:Float):Mat4 {
		var cam = view.camera, inv = MathTools.inverse(view.viewProj);
		var f = Math.min(Math.max((split - cam.near) / (cam.far - cam.near), 0), 1);
		var corners = [];
		for (k in 0...4) {
			var x = (k & 1) == 0 ? -1.0 : 1.0, y = (k & 2) == 0 ? -1.0 : 1.0;
			var a = MathTools.transformPoint(inv, new Vec3(x, y, 0)), b = MathTools.transformPoint(inv, new Vec3(x, y, 1));
			corners.push(a);
			// (along the corner's edge: linear in the view's depth)
			corners.push(a + (b - a) * f);
		}
		var centre = new Vec3(0, 0, 0);
		for (p in corners)
			centre = centre + p * (1 / 8);
		var radius = 0.0;
		for (p in corners) {
			var d = p - centre;
			radius = Math.max(radius, Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z));
		}
		radius += 0.01;
		// (the centre moved by whole texels in the light's view: shadows do not crawl)
		var lightView = MathTools.lookAt(new Vec3(0, 0, 0), toLight * -1, up);
		var lc = MathTools.transformPoint(lightView, centre), texel = 2 * radius / size;
		lc = new Vec3(Math.floor(lc.x / texel) * texel, Math.floor(lc.y / texel) * texel, lc.z);
		var snapped = MathTools.transformPoint(MathTools.inverse(lightView), lc);
		// (back towards the light past every caster: the scene's sphere)
		var toCentre = c - snapped, back = Math.sqrt(toCentre.x * toCentre.x + toCentre.y * toCentre.y + toCentre.z * toCentre.z) + r;
		// (the bias: as many of this map's texels as the whole map's, in its depth)
		nearBias = bias * (3 * r / (back + radius + r)) * (radius / r);
		return Mat4.orthographic(-radius, radius, -radius, radius, 0.01, back + radius + r) * MathTools.lookAt(snapped + toLight * back, snapped, up);
	}

	function draw(enc:Encoder, pass:PassDesc, meshes:Store<Mesh>, world:World, skins:Null<RenderFeature.SkinSource>, viewProj:Mat4) {
		enc.beginPass(pass);
		enc.setPipeline(pipeline);
		for (k in 0...meshes.length) {
			var n = meshes.nodeAt(k);
			if (!n.shown() || !world.inTree(n)) continue;
			ShadowShader.writeShadowCaster({mvp: viewProj * n.worldMatrix()}, casterBytes);
			var prims = meshes.valueAt(k).primitives;
			// (a skinned mesh: drawn by the skinning's shadow pipeline, its joints bound)
			if (prims.length > 0 && prims[0].skinned) {
				if (skins == null) continue;
				enc.setPipeline(skins.shadowPipeline());
				var slots = skins.shadowSlots();
				enc.setUniforms(slots[0], casterBytes);
				skins.bind(enc, slots, n);
				for (p in prims) {
					enc.setVertexBuffer(0, p.vertices);
					enc.setIndexBuffer(p.indices, p.indexFormat);
					enc.drawIndexed(p.count);
				}
				enc.setPipeline(pipeline);
				continue;
			}
			enc.setUniforms(0, casterBytes);
			for (p in prims) {
				enc.setVertexBuffer(0, p.vertices);
				enc.setIndexBuffer(p.indices, p.indexFormat);
				enc.drawIndexed(p.count);
			}
		}
		enc.endPass();
	}

	public function dispose() {
		device.destroyTexture(map);
		if (mapFar != map) device.destroyTexture(mapFar);
		device.destroyTexture(depth);
	}
}
