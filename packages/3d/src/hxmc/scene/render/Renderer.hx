package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.Camera;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.math.MathTools;
import hxmc.scene.render.PbrShader;

// Draws a world's meshes (MeshRenderer) as seen by a camera, lit by its
// first directional Light and up to four point Lights (a world without
// lights: the renderer's sun) and an ambient from the sky and the ground,
// with PbrShader. Two stages:
//
//   extract   the world's meshes into a flat draw list: the nodes shown,
//             their bounds inside the camera's view, a draw per primitive
//             sorted by pipeline, material and primitive; runs of one
//             primitive become one instanced draw (PbrInstancedShader:
//             the matrices in an instance buffer); the seam for threads
//             and GPU culling later
//   record    the list as one depth-tested pass into the caller's encoder
//             (see-through materials last, farthest first, blended),
//             each draw's matrices and material in uniform blocks through
//             gfx's uniform ring (nothing allocated per frame: the list's
//             entries are kept)
//
// It is ordinary gfx code: draw records into the caller's encoder, so a
// program adds its own passes before or after; each camera of a world
// (split screens, XR's eyes) is a draw of its own.
class Renderer {
	public final device:Device;
	// the instanced pipelines' two buffers: the mesh's vertices, the instances' matrices
	static final INSTANCED_LAYOUT:Array<VertexBufferLayout> = [
		{
			stride: 32,
			attributes: [{location: 0, format: Float3, offset: 0}, {location: 1, format: Float3, offset: 12}, {location: 2, format: Float2, offset: 24}]
		},
		{
			stride: 64,
			step: Instance,
			attributes: [
				{location: 3, format: Float4, offset: 0}, {location: 4, format: Float4, offset: 16}, {location: 5, format: Float4, offset: 32},
				{location: 6, format: Float4, offset: 48}
			]
		}
	];
	// without a Light in the world: towards the light (normalized when
	// drawn), and its colour times intensity
	public var sunDirection = new Vec3(-0.4, 0.8, 0.45);
	public var sunColor = new Vec3(2.1, 1.95, 1.8);
	public var sky = new Vec3(0.3, 0.36, 0.48);
	public var ground = new Vec3(0.12, 0.1, 0.09);
	public var exposure = 1.0;
	public var clearColor = new Color(0.07, 0.08, 0.1);
	// the last draw's draws and primitives culled (statistics)
	public var draws(default, null) = 0;
	public var culled(default, null) = 0;

	final pipeline:Pipeline;
	final doubleSided:Pipeline;
	// (see-through materials: made when first drawn)
	var blendPipeline:Null<Pipeline>;
	var blendDoubleSided:Null<Pipeline>;
	var instancedPipeline:Pipeline;
	var instancedDoubleSided:Pipeline;
	final plainSlots:Array<Int>;
	var skinSource:Null<RenderFeature.SkinSource>;
	var normalSource:Null<RenderFeature.NormalSource>;
	var environment:Null<Environment>;
	final instancedSlots:Array<Int>;
	// whether runs of one primitive are drawn instanced (on by default)
	public var instancing = true;
	// the last draw's instances drawn by instanced draws (statistics)
	public var instanced(default, null) = 0;
	// (the batches: a start in the list, a size, an offset in the instance buffer)
	final batchStart:Array<Int> = [];
	final batchSize:Array<Int> = [];
	final batchOffset:Array<Int> = [];
	var batchCount = 0;
	var instanceBytes = Bytes.alloc(64 * 64);
	var instanceBuffer:Buffer = Buffer.NONE;
	var instanceCapacity = 0;
	final white:Texture;
	final sampler:Sampler;
	final nearest:Sampler;
	// (no shadows: a 1x1 map, never read)
	final noShadow:Texture;
	var shadowSource:Null<RenderFeature.ShadowSource>;
	final frameBytes = Bytes.alloc(PbrShader.uniforms[0].size);
	final objectBytes = Bytes.alloc(PbrShader.uniforms[1].size);
	final materialBytes = Bytes.alloc(PbrShader.uniforms[2].size);
	final pass:PassDesc;
	// the draw list: entries kept between frames, count of them in use
	final list:Array<DrawItem> = [];
	// (the frame's point lights: position and range, colour)
	final pointLights:Array<Vec4> = [for (_ in 0...4) new Vec4(0, 0, 0, 0)];
	final pointColors:Array<Vec4> = [for (_ in 0...4) new Vec4(0, 0, 0, 0)];
	final spots:Array<Vec4> = [for (_ in 0...4) new Vec4(0, 0, 0, -2)];
	var count = 0;

	public function new(device:Device) {
		this.device = device;
		pipeline = device.createPipeline(PbrShader.pipeline({cull: Back, depthCompare: Less, depthWrite: true}));
		doubleSided = device.createPipeline(PbrShader.pipeline({cull: None, depthCompare: Less, depthWrite: true}));
		for (cull in [hxmc.gfx.Cull.Back, hxmc.gfx.Cull.None]) {
			var d = PbrInstancedShader.pipeline({cull: cull, depthCompare: Less, depthWrite: true});
			d.layout = INSTANCED_LAYOUT;
			if (cull == Back) instancedPipeline = device.createPipeline(d) else instancedDoubleSided = device.createPipeline(d);
		}
		plainSlots = slotsOf(PbrShader.uniforms, PbrShader.textures);
		instancedSlots = slotsOf(PbrInstancedShader.uniforms, PbrInstancedShader.textures);
		var w = Bytes.alloc(4);
		w.fill(0, 4, 255);
		white = device.createTexture({width: 1, height: 1, data: w});
		sampler = device.createSampler({filter: Linear, mipFilter: Linear, wrap: Repeat});
		nearest = device.createSampler({filter: Nearest, wrap: Clamp});
		var one = Bytes.alloc(4);
		one.setFloat(0, 1);
		noShadow = device.createTexture({width: 1, height: 1, format: R32F, data: one});
		pass = {colors: [{load: Clear, clear: clearColor}], depth: {load: Clear}};
	}

	// what the frame's hooks get: the camera's view, the light (FrameInfo)
	public final frame = new FrameInfo();
	final hooks:Array<Array<(Encoder, FrameInfo) -> Void>> = [[], [], []];

	// f runs at a point of each frame: BeforeOpaque and AfterOpaque inside
	// the frame's pass (draw with your own pipelines, depth-tested against
	// the scene), AfterPass after it (passes of your own: an overlay)
	public function inject(point:InjectionPoint, f:(Encoder, FrameInfo) -> Void)
		hooks[point].push(f);

	// turns on an optional feature (Shadows, Skinning, NormalMaps, Sky, Environment); returns the renderer
	public function use(feature:RenderFeature):Renderer {
		feature.attach(this);
		return this;
	}

	// records the frame's pass: world seen by camera (aspect: the target's,
	// by default the device's)
	public function draw(enc:Encoder, world:World, camera:Camera, ?aspect:Float) {
		if (aspect == null) aspect = device.width / device.height;
		var viewProj = camera.viewProjection(aspect);
		// (morph targets blended where their weights changed: Morph)
		if (Morph.updateWorld != null) Morph.updateWorld(world);
		extract(world, viewProj);
		var toLight = writeFrame(world, camera, viewProj, false);
		frame.world = world;
		frame.camera = camera;
		frame.aspect = aspect;
		frame.viewProj = viewProj;
		frame.eye = camera.eye();
		frame.toLight = toLight;
		if (shadowSource != null) {
			shadowSource.render(enc, world, toLight, skinSource, frame);
			writeFrame(world, camera, viewProj, true);
		}
		record(enc);
		for (f in hooks[AfterPass])
			f(enc, frame);
	}

	// the draw list: each shown mesh inside the view, a draw per primitive, sorted
	public function extract(world:World, viewProj:Mat4) {
		count = 0;
		culled = 0;
		var meshes = world.store(MeshRenderer.KIND);
		for (k in 0...meshes.length) {
			var node = meshes.nodeAt(k), mesh = meshes.valueAt(k);
			if (!node.shown() || !world.inTree(node)) continue;
			var model = node.worldMatrix();
			var skinned = mesh.primitives.length > 0 && mesh.primitives[0].skinned;
			// (skinned: drawn only with Skinning, its bounds its rest pose's: not culled)
			if (skinned && (skinSource == null || !skinSource.prepare(node))) continue;
			if (!skinned && !visible(viewProj * model, mesh)) {
				culled += mesh.primitives.length;
				continue;
			}
			for (p in mesh.primitives) {
				if (count == list.length) list.push(new DrawItem());
				var d = list[count++];
				d.node = node;
				d.primitive = p;
				// (the pipeline, then the material)
				d.key = (p.material.blend ? 1 << 26 : 0) | (mapped(p) ? 1 << 25 : 0) | (p.material.doubleSided ? 1 << 24 : 0) | (p.material.id & 0xFFFFFF);
				if (p.material.blend) {
					// (how far: the bounds' centre's depth in clip space)
					var b = p.bounds, c = viewProj * (model * new Vec4((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2, 1));
					d.depth = c.w != 0 ? c.z / c.w : c.z;
				}
			}
		}
		// (insertion sort: a scene's order changes little from frame to frame)
		for (i in 1...count) {
			var d = list[i], j = i - 1;
			while (j >= 0 && (list[j].key > d.key || list[j].key == d.key && list[j].primitive.id > d.primitive.id)) {
				list[j + 1] = list[j];
				j--;
			}
			list[j + 1] = d;
		}
		// (the see-through draws, last in the list: farthest first)
		var first = count;
		while (first > 0 && list[first - 1].primitive.material.blend)
			first--;
		for (i in first + 1...count) {
			var d = list[i], j = i - 1;
			while (j >= first && list[j].depth < d.depth) {
				list[j + 1] = list[j];
				j--;
			}
			list[j + 1] = d;
		}
		batch();
	}

	// (the frame's block; returns the direction towards the light)
	function writeFrame(world:World, camera:Camera, viewProj:Mat4, shadowed:Bool):Vec3 {
		var eye = camera.eye();
		var l = sunDirection, c = sunColor;
		var lights = world.store(Light.KIND);
		var sun = false, points = 0;
		for (k in 0...4) {
			pointLights[k] = pointColors[k] = new Vec4(0, 0, 0, 0);
			spots[k] = new Vec4(0, 0, 0, -2);
		}
		for (k in 0...lights.length) {
			var node = lights.nodeAt(k), light = lights.valueAt(k);
			if (!node.shown() || !world.inTree(node)) continue;
			if (light.point) {
				if (points == 4) continue;
				var p = node.worldPosition(), q = light.color * light.intensity;
				pointLights[points] = new Vec4(p.x, p.y, p.z, light.range);
				if (light.outerCone > 0) {
					var dir = MathTools.transformDir(node.worldMatrix(), new Vec3(0, 0, -1));
					dir = dir / Math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
					spots[points] = new Vec4(dir.x, dir.y, dir.z, Math.cos(light.outerCone));
					pointColors[points++] = new Vec4(q.x, q.y, q.z, Math.cos(light.innerCone));
				} else
					pointColors[points++] = new Vec4(q.x, q.y, q.z, 0);
			} else if (!sun) {
				// (it shines down its node's -z: the light is towards +z)
				l = MathTools.transformDir(node.worldMatrix(), new Vec3(0, 0, 1));
				c = light.color * light.intensity;
				sun = true;
			}
		}
		// (lights in the world but no directional one: no sun)
		if (!sun && lights.length > 0) c = new Vec3(0, 0, 0);
		l = l / Math.sqrt(l.x * l.x + l.y * l.y + l.z * l.z);
		var lightViewProj:Mat4 = Mat4.identity(), lightViewProjFar:Mat4 = Mat4.identity();
		var shadow:Vec4 = new Vec4(0, 0, 0, 0), shadowFar:Vec4 = new Vec4(0, 0, 0, 0);
		if (shadowed) {
			var f = shadowSource.shadowFrame();
			lightViewProj = f.viewProj;
			shadow = f.params;
			lightViewProjFar = f.viewProjFar;
			shadowFar = f.paramsFar;
		}
		PbrShader.writePbrFrame({
			viewProj: viewProj,
			eye: new Vec4(eye.x, eye.y, eye.z, 1),
			lightDir: new Vec4(l.x, l.y, l.z, 0),
			lightColor: new Vec4(c.x, c.y, c.z, 0),
			sky: new Vec4(sky.x, sky.y, sky.z, 0),
			ground: new Vec4(ground.x, ground.y, ground.z, 0),
			exposure: new Vec4(exposure, 0, 0, 0),
			lightViewProj: lightViewProj,
			shadow: shadow,
			point0: pointLights[0],
			point1: pointLights[1],
			point2: pointLights[2],
			point3: pointLights[3],
			pointColor0: pointColors[0],
			pointColor1: pointColors[1],
			pointColor2: pointColors[2],
			pointColor3: pointColors[3],
			spot0: spots[0],
			spot1: spots[1],
			spot2: spots[2],
			spot3: spots[3],
			lightViewProjFar: lightViewProjFar,
			shadowFar: shadowFar,
			environment: environment != null ? new Vec4(environment.intensity, environment.levels, 0, 0) : new Vec4(0, 0, 0, 0)
		}, frameBytes);
		return l;
	}

	function record(enc:Encoder) {
		pass.colors[0].clear = clearColor;
		enc.beginPass(pass);
		for (f in hooks[BeforeOpaque])
			f(enc, frame);
		var current:Null<Pipeline> = null, material:Null<Material> = null, node = Node.NONE;
		var slots = plainSlots;
		draws = 0;
		instanced = 0;
		var opaque = true;
		for (b in 0...batchCount) {
			var start = batchStart[b], n = batchSize[b];
			var d = list[start], p = d.primitive, m = p.material;
			if (opaque && m.blend) {
				// (the hooks after the opaque surfaces, the sky's among them,
				// before the see-through ones; their pipelines are theirs)
				opaque = false;
				for (f in hooks[AfterOpaque])
					f(enc, frame);
				current = null;
			}
			var many = n > 1;
			var skin = p.skinned ? skinSource : null;
			var normals = !many && skin == null && mapped(p) ? normalSource : null;
			var want = many ? (m.doubleSided ? instancedDoubleSided : instancedPipeline) : skin != null ? skin.pipeline(m.doubleSided) : normals != null ? normals.pipeline(m.doubleSided) : m.blend ? blended(m.doubleSided) : (m.doubleSided ? doubleSided : pipeline);
			if (want != current) {
				enc.setPipeline(want);
				slots = many ? instancedSlots : skin != null ? skin.slots() : normals != null ? normals.slots() : plainSlots;
				enc.setUniforms(slots[0], frameBytes);
				current = want;
				material = null;
				node = Node.NONE;
			}
			if (!many && d.node != node) {
				var model = d.node.worldMatrix();
				PbrShader.writePbrObject({model: model, normalMatrix: MathTools.normalMatrix(model)}, objectBytes);
				enc.setUniforms(slots[1], objectBytes);
				node = d.node;
			}
			if (skin != null) skin.bind(enc, slots, d.node);
			if (m != material) {
				PbrShader.writePbrMaterial({
					baseColor: m.baseColor,
					params: new Vec4(m.metallic, m.roughness, m.normalScale, 0),
					emissive: new Vec4(m.emissive.x, m.emissive.y, m.emissive.z, 0)
				}, materialBytes);
				enc.setUniforms(slots[2], materialBytes);
				var ms = m.sampler != null ? m.sampler : sampler;
				enc.setTexture(slots[3], m.baseColorTexture != null ? m.baseColorTexture : white, ms);
				enc.setTexture(slots[7], m.metallicRoughnessTexture != null ? m.metallicRoughnessTexture : white, ms);
				enc.setTexture(slots[8], m.emissiveTexture != null ? m.emissiveTexture : white, ms);
				enc.setTexture(slots[9], m.occlusionTexture != null ? m.occlusionTexture : white, ms);
				var sf = shadowSource != null ? shadowSource.shadowFrame() : null;
				enc.setTexture(slots[4], sf != null ? sf.map : noShadow, nearest);
				enc.setTexture(slots[11], sf != null ? sf.mapFar : noShadow, nearest);
				if (environment != null) environment.bind(enc, slots[12]) else enc.setTexture(slots[12], white, sampler);
				if (normals != null) enc.setTexture(slots[10], m.normalTexture, ms);
				material = m;
			}
			enc.setVertexBuffer(0, p.vertices);
			if (many) enc.setVertexBuffer(1, instanceBuffer, batchOffset[b]);
			if (normals != null) enc.setVertexBuffer(1, p.tangents);
			enc.setIndexBuffer(p.indices, p.indexFormat);
			enc.drawIndexed(p.count, n);
			draws++;
			if (many) instanced += n;
		}
		if (opaque)
			for (f in hooks[AfterOpaque])
				f(enc, frame);
		enc.endPass();
	}

	// the draw list cut into batches: a run of draws of one primitive (one
	// mesh, one material) is one instanced draw, its matrices written to the
	// instance buffer (before the pass: gfx writes buffers between passes)
	function batch() {
		batchCount = 0;
		var bytes = 0, i = 0;
		while (i < count) {
			var j = i + 1;
			if (instancing && !list[i].primitive.skinned && !list[i].primitive.material.blend && !mapped(list[i].primitive) && uniformScale(list[i].node))
				while (j < count && list[j].primitive == list[i].primitive && uniformScale(list[j].node))
					j++;
			if (batchCount == batchStart.length) {
				batchStart.push(0);
				batchSize.push(0);
				batchOffset.push(0);
			}
			batchStart[batchCount] = i;
			batchSize[batchCount] = j - i;
			batchOffset[batchCount] = bytes;
			if (j - i > 1) {
				if (bytes + 64 * (j - i) > instanceBytes.length) {
					var grown = Bytes.alloc(Std.int(Math.max(instanceBytes.length * 2, bytes + 64 * (j - i))));
					grown.blit(0, instanceBytes, 0, bytes);
					instanceBytes = grown;
				}
				for (k in i...j) {
					var m = list[k].node.worldMatrix();
					for (c in 0...4) {
						var col = MathTools.col(m, c);
						instanceBytes.setFloat(bytes, col.x);
						instanceBytes.setFloat(bytes + 4, col.y);
						instanceBytes.setFloat(bytes + 8, col.z);
						instanceBytes.setFloat(bytes + 12, col.w);
						bytes += 16;
					}
				}
			}
			batchCount++;
			i = j;
		}
		if (bytes > 0) {
			if (bytes > instanceCapacity) {
				if (instanceCapacity > 0) device.destroyBuffer(instanceBuffer);
				instanceCapacity = instanceBytes.length;
				instanceBuffer = device.createBuffer({size: instanceCapacity, usage: Vertex});
			}
			device.writeBuffer(instanceBuffer, 0, instanceBytes, 0, bytes);
		}
	}

	// the standard shader blended, depth tested but not written
	function blended(doubleSided:Bool):Pipeline {
		if (blendPipeline == null) {
			blendPipeline = device.createPipeline(PbrShader.pipeline({cull: Back, depthCompare: Less, depthWrite: false, blend: Alpha}));
			blendDoubleSided = device.createPipeline(PbrShader.pipeline({cull: None, depthCompare: Less, depthWrite: false, blend: Alpha}));
		}
		return doubleSided ? blendDoubleSided : blendPipeline;
	}

	// whether a primitive is drawn with its normal map (NormalMaps on, its
	// tangents and its material's map there)
	inline function mapped(p:Mesh.Primitive):Bool
		return normalSource != null && p.tangents != null && p.material.normalTexture != null && !p.skinned;

	// whether a node's world matrix scales alike on every axis (instanced
	// normals are turned by its upper 3x3)
	static function uniformScale(n:Node):Bool {
		var m = n.worldMatrix();
		var x = m.c0.x * m.c0.x + m.c0.y * m.c0.y + m.c0.z * m.c0.z, y = m.c1.x * m.c1.x + m.c1.y * m.c1.y + m.c1.z * m.c1.z,
			z = m.c2.x * m.c2.x + m.c2.y * m.c2.y + m.c2.z * m.c2.z;
		return Math.abs(x - y) <= 1e-6 * x && Math.abs(x - z) <= 1e-6 * x;
	}

	// a shader's slots for its blocks and textures, in the renderer's order:
	// frame, object (-1: none), material, base colour, shadow map, skin,
	// joints, metallic-roughness, emissive, occlusion, normal, the far shadow
	// map, the environment map
	public static function slotsOf(uniforms:Array<hxmc.gfx.shader.Shaders.UniformBlock>, textures:Array<hxmc.gfx.shader.Shaders.TextureBinding>):Array<Int> {
		function u(name:String):Int {
			for (b in uniforms)
				if (b.name == name) return b.binding;
			return -1;
		}
		function t(name:String):Int {
			for (b in textures)
				if (b.name == name) return b.binding;
			return -1;
		}
		return [u("PbrFrame"), u("PbrObject"), u("PbrMaterial"), t("baseColorTexture"), t("shadowMap"), u("PbrSkinInfo"), t("jointMatrices"),
			t("metallicRoughnessTexture"), t("emissiveTexture"), t("occlusionTexture"), t("normalTexture"), t("shadowMapFar"), t("environmentMap")];
	}

	// whether a mesh's bounds, through mvp, reach the view: not all eight
	// corners beyond one of the clip space's planes
	static function visible(mvp:Mat4, mesh:Mesh):Bool {
		var b = mesh.bounds;
		if (b.isEmpty()) return false;
		var o0 = 0, o1 = 0, o2 = 0, o3 = 0, o4 = 0, o5 = 0;
		for (k in 0...8) {
			var c = mvp * new Vec4((k & 1) == 0 ? b.min.x : b.max.x, (k & 2) == 0 ? b.min.y : b.max.y, (k & 4) == 0 ? b.min.z : b.max.z, 1);
			if (c.x < -c.w) o0++;
			if (c.x > c.w) o1++;
			if (c.y < -c.w) o2++;
			if (c.y > c.w) o3++;
			if (c.z < 0) o4++;
			if (c.z > c.w) o5++;
		}
		return o0 < 8 && o1 < 8 && o2 < 8 && o3 < 8 && o4 < 8 && o5 < 8;
	}

	public function dispose() {
		device.destroyTexture(white);
		device.destroyTexture(noShadow);
		if (instanceCapacity > 0) device.destroyBuffer(instanceBuffer);
	}
}

// the points of a frame where programs and features draw (Renderer.inject)
enum abstract InjectionPoint(Int) to Int {
	var BeforeOpaque;
	var AfterOpaque;
	var AfterPass;
}

// the frame being drawn, for the hooks
class FrameInfo {
	public var world:Null<World>;
	public var camera:Null<Camera>;
	public var aspect = 1.0;
	public var viewProj:Mat4 = Mat4.identity();
	public var eye:Vec3 = new Vec3(0, 0, 0);
	// towards the light (the world's sun or the renderer's)
	public var toLight:Vec3 = new Vec3(0, 1, 0);

	public function new() {}
}

// an entry of the draw list
class DrawItem {
	public var node:Node = Node.NONE;
	public var primitive:Null<Mesh.Primitive>;
	public var key = 0;
	// (see-through draws: the depth they sort by, farthest first)
	public var depth = 0.0;

	public function new() {}
}
