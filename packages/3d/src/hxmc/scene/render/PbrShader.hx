package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;

// The renderer's shader (Renderer): glTF's metallic-roughness model lit by
// a directional light, up to four point lights and a sky-and-ground
// ambient, in linear light,
// tone mapped (ACES, Narkowicz's fit) and encoded to sRGB for an 8-bit
// target. The specular term is Cook-Torrance: GGX's distribution, the
// height-correlated Smith visibility and Schlick's Fresnel; the ambient's
// specular part is the environment's colour along the reflection,
// weighted by an analytic fit of the split-sum's lookup (Karis'), so
// metals are not black without an environment map.
@:structInit @:publicFields class PbrVertex {
	var pos:Vec3;
	var normal:Vec3;
	var uv:Vec2;
}

@:structInit @:publicFields class PbrVaryings {
	@:position var clip:Vec4;
	var world:Vec3;
	var normal:Vec3;
	var uv:Vec2;
}

// per frame: the camera and the lights
@:structInit @:publicFields class PbrFrame {
	var viewProj:Mat4;
	var eye:Vec4; // xyz: the camera's position
	var lightDir:Vec4; // xyz: towards the light, normalized
	var lightColor:Vec4; // rgb: colour times intensity
	var sky:Vec4; // the ambient from above, rgb
	var ground:Vec4; // the ambient from below, rgb
	var exposure:Vec4; // x: exposure
	var lightViewProj:Mat4; // the shadow map's view-projection (Shadows)
	var shadow:Vec4; // x: strength (0: no shadows), y: bias, z: a texel of the map
	// up to four point lights: position (w: range, 0 for none), colour times intensity
	var point0:Vec4;
	var point1:Vec4;
	var point2:Vec4;
	var point3:Vec4;
	var pointColor0:Vec4;
	var pointColor1:Vec4;
	var pointColor2:Vec4;
	var pointColor3:Vec4;
	// spot lights: the direction they shine (xyz) and the cosine of the outer
	// cone (w; below -1 for a point light); pointColor's w the inner cone's
	var spot0:Vec4;
	var spot1:Vec4;
	var spot2:Vec4;
	var spot3:Vec4;
	// the second shadow cascade (Shadows with two: the whole scene's map,
	// read where the first, near the camera, does not reach; else the first's)
	var lightViewProjFar:Mat4;
	var shadowFar:Vec4;
	// the environment's light (Environment): x its intensity (0: none, the
	// sky and the ground instead), y its map's mip levels below the first
	var environment:Vec4;
}

// per draw: the node's matrices
@:structInit @:publicFields class PbrObject {
	var model:Mat4;
	var normalMatrix:Mat4;
}

// per draw: the material
@:structInit @:publicFields class PbrMaterial {
	var baseColor:Vec4;
	var params:Vec4; // x: metallic, y: roughness
	var emissive:Vec4; // rgb
}

class PbrShader implements Shaders {
	@:vertex static function vs(v:PbrVertex, frame:PbrFrame, object:PbrObject):PbrVaryings {
		var world = object.model * vec4(v.pos, 1);
		return {
			clip: frame.viewProj * world,
			world: world.xyz,
			normal: (object.normalMatrix * vec4(v.normal, 0)).xyz,
			uv: v.uv
		};
	}

	@:fragment static function fs(i:PbrVaryings, frame:PbrFrame, material:PbrMaterial, baseColorTexture:Texture2D, metallicRoughnessTexture:Texture2D,
			emissiveTexture:Texture2D, occlusionTexture:Texture2D, shadowMap:Texture2D, shadowMapFar:Texture2D, environmentMap:Texture2D):Vec4
		return shadeAt(normalize(i.normal), i.world, i.uv, frame, material, baseColorTexture, metallicRoughnessTexture, emissiveTexture,
			occlusionTexture, shadowMap, shadowMapFar, environmentMap);

	// the fragment's colour at a point of the world with a unit normal n
	// (also the instanced, skinned and normal-mapped shaders')
	public static function shadeAt(n:Vec3, world:Vec3, uv:Vec2, frame:PbrFrame, material:PbrMaterial, baseColorTexture:Texture2D,
			metallicRoughnessTexture:Texture2D, emissiveTexture:Texture2D, occlusionTexture:Texture2D, shadowMap:Texture2D, shadowMapFar:Texture2D, environmentMap:Texture2D):Vec4 {
		var texel = sample(baseColorTexture, uv);
		// (the texture's sRGB decoded)
		var base = material.baseColor.xyz * pow(texel.xyz, vec3(2.2));
		// (glTF's: roughness in green, metallic in blue, linear)
		var mr = sample(metallicRoughnessTexture, uv);
		var metallic = clamp(material.params.x * mr.z, 0, 1);
		var rough = clamp(material.params.y * mr.y, 0.04, 1);
		var v = normalize(frame.eye.xyz - world);
		var l = frame.lightDir.xyz;
		var nv = max(dot(n, v), 0.0001);
		var a = rough * rough;
		var a2 = a * a;
		var f0 = mix(vec3(0.04), base, metallic);
		var direct = brdf(n, v, l, base, metallic, a2, f0) * frame.lightColor.xyz * shadowed(frame, shadowMap, shadowMapFar, world, max(dot(n, l), 0));
		direct += point(n, v, world, base, metallic, a2, f0, frame.point0, frame.pointColor0, frame.spot0)
			+ point(n, v, world, base, metallic, a2, f0, frame.point1, frame.pointColor1, frame.spot1)
			+ point(n, v, world, base, metallic, a2, f0, frame.point2, frame.pointColor2, frame.spot2)
			+ point(n, v, world, base, metallic, a2, f0, frame.point3, frame.pointColor3, frame.spot3);
		// the ambient: the sky and the ground blended by the normal (diffuse)
		// and by the reflection (specular, Karis' fit of the split sum)
		var up = n.y * 0.5 + 0.5;
		var irradiance = mix(frame.ground.xyz, frame.sky.xyz, up);
		var r = reflect(-v, n);
		var env = mix(frame.ground.xyz, frame.sky.xyz, smoothstep(-0.2, 0.2, r.y));
		if (frame.environment.x > 0) {
			// (an environment map: its small levels along the normal, its
			// sharper ones along the reflection by roughness)
			var top = frame.environment.y;
			irradiance = pow(sampleLevel(environmentMap, EnvironmentShader.equirect(n), max(top - 2, 0)).xyz, vec3(2.2)) * frame.environment.x;
			env = pow(sampleLevel(environmentMap, EnvironmentShader.equirect(r), rough * max(top - 1, 0)).xyz, vec3(2.2)) * frame.environment.x;
		}
		var c0 = vec4(-1, -0.0275, -0.572, 0.022);
		var c1 = vec4(1, 0.0425, 1.04, -0.04);
		var rr = c0 * rough + c1;
		var a004 = min(rr.x * rr.x, pow(2, -9.28 * nv)) * rr.x + rr.y;
		var ab = vec2(-1.04, 1.04) * a004 + rr.zw;
		var specularAmbient = env * (f0 * ab.x + ab.y);
		// (occlusion, in red, darkens the ambient only)
		var occlusion = sample(occlusionTexture, uv).x;
		var ambient = (irradiance * base * (1 - metallic) + specularAmbient) * occlusion;
		var emitted = material.emissive.xyz * pow(sample(emissiveTexture, uv).xyz, vec3(2.2));
		var color = (direct + ambient + emitted) * frame.exposure.x;
		return vec4(encode(aces(color)), material.baseColor.w * texel.w);
	}

	// the light reflected towards v from a unit light along l, times n.l:
	// Lambert's diffuse and Cook-Torrance's specular (GGX, height-correlated
	// Smith, Schlick)
	static function brdf(n:Vec3, v:Vec3, l:Vec3, base:Vec3, metallic:Float, a2:Float, f0:Vec3):Vec3 {
		var h = normalize(l + v);
		var nl = max(dot(n, l), 0);
		var nv = max(dot(n, v), 0.0001);
		var nh = max(dot(n, h), 0);
		var vh = max(dot(v, h), 0);
		var fresnel = f0 + (1 - f0) * pow(1 - vh, 5);
		var dd = nh * nh * (a2 - 1) + 1;
		var distribution = a2 / (3.14159265 * dd * dd);
		var visibility = 0.5 / max(nl * sqrt(nv * nv * (1 - a2) + a2) + nv * sqrt(nl * nl * (1 - a2) + a2), 0.0001);
		var diffuse = (1 - fresnel) * (1 - metallic) * base / 3.14159265;
		return (diffuse + fresnel * (distribution * visibility)) * nl;
	}

	// a point or spot light at pos.xyz (pos.w: its range, 0 for no light): the
	// inverse square falloff windowed to reach 0 at the range (glTF's
	// KHR_lights_punctual)
	static function point(n:Vec3, v:Vec3, world:Vec3, base:Vec3, metallic:Float, a2:Float, f0:Vec3, pos:Vec4, color:Vec4, spot:Vec4):Vec3 {
		var result = vec3(0);
		if (pos.w > 0) {
			var d = pos.xyz - world;
			var dist2 = max(dot(d, d), 0.0001);
			var dist = sqrt(dist2);
			var q = dist / pos.w;
			var window = clamp(1 - q * q * q * q, 0, 1);
			// (a spot light: full inside the inner cone, nothing outside the outer)
			var cone = 1.0;
			if (spot.w > -1.5) cone = smoothstep(spot.w, color.w, dot(-d / dist, spot.xyz));
			result = brdf(n, v, d / dist, base, metallic, a2, f0) * color.xyz * (window * window / dist2 * cone);
		}
		return result;
	}

	// the direct light's share at a point (1: lit) from the shadow maps: the
	// first cascade's where it reaches, else the second's; a 3x3
	// percentage-closer filter; 1 outside them or without shadows
	static function shadowed(frame:PbrFrame, map:Texture2D, far:Texture2D, world:Vec3, nl:Float):Float {
		var strength = frame.shadow.x;
		var result = 1.0;
		if (strength > 0) {
			var lit = cascade(map, frame.lightViewProj, frame.shadow, world, nl);
			if (lit < 0) lit = cascade(far, frame.lightViewProjFar, frame.shadowFar, world, nl);
			if (lit >= 0) result = 1 - strength * (1 - lit / 9);
		}
		return result;
	}

	// a cascade's lit taps (0 to 9) at a point, or -1 where its map does not
	// reach (params: y the bias, z a texel of the map)
	static function cascade(map:Texture2D, viewProj:Mat4, params:Vec4, world:Vec3, nl:Float):Float {
		var result = -1.0;
		var ls = viewProj * vec4(world, 1);
		var p = ls.xyz / ls.w;
		var uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
		if (uv.x > 0 && uv.x < 1 && uv.y > 0 && uv.y < 1 && p.z < 1) {
			// (more bias where the light grazes the surface)
			var depth = p.z - params.y * (1 + 2 * (1 - nl));
			var t = params.z;
			result = tap(map, uv, depth, -t, -t) + tap(map, uv, depth, 0, -t) + tap(map, uv, depth, t, -t) + tap(map, uv, depth, -t, 0)
				+ tap(map, uv, depth, 0, 0) + tap(map, uv, depth, t, 0) + tap(map, uv, depth, -t, t) + tap(map, uv, depth, 0, t)
				+ tap(map, uv, depth, t, t);
		}
		return result;
	}

	// 1 where the map's depth at uv + (dx, dy) is not nearer than depth
	static function tap(map:Texture2D, uv:Vec2, depth:Float, dx:Float, dy:Float):Float
		return step(depth, sampleLevel(map, uv + vec2(dx, dy), 0).x);

	// ACES filmic tone mapping (Narkowicz's fit), to 0..1
	public static function aces(x:Vec3):Vec3
		return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0, 1);

	// linear to sRGB (the 2.2 power: the frame's format is not an sRGB one)
	public static function encode(c:Vec3):Vec3
		return pow(c, vec3(1 / 2.2));
}
