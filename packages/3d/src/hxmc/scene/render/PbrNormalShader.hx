package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;
import hxmc.scene.render.PbrShader;

// The standard material with a tangent-space normal map (NormalMaps): the
// vertex as PbrShader's and its tangent from a second buffer (the
// primitive's tangents: x, y, z and the bitangent's sign), turned by the
// node's matrix; the fragment's normal read from the map (glTF's: x and y
// scaled by the material's normal scale, the bitangent n x t times the
// sign, green up the image), then PbrShader.shadeAt.
@:structInit @:publicFields class PbrNormalVertex {
	var pos:Vec3;
	var normal:Vec3;
	var uv:Vec2;
	var tangent:Vec4;
}

@:structInit @:publicFields class PbrNormalVaryings {
	@:position var clip:Vec4;
	var world:Vec3;
	var normal:Vec3;
	var uv:Vec2;
	var tangent:Vec4;
}

class PbrNormalShader implements Shaders {
	@:vertex static function vs(v:PbrNormalVertex, frame:PbrFrame, object:PbrObject):PbrNormalVaryings {
		var world = object.model * vec4(v.pos, 1);
		return {
			clip: frame.viewProj * world,
			world: world.xyz,
			normal: (object.normalMatrix * vec4(v.normal, 0)).xyz,
			uv: v.uv,
			tangent: vec4((object.model * vec4(v.tangent.xyz, 0)).xyz, v.tangent.w)
		};
	}

	@:fragment static function fs(i:PbrNormalVaryings, frame:PbrFrame, material:PbrMaterial, baseColorTexture:Texture2D,
			metallicRoughnessTexture:Texture2D, emissiveTexture:Texture2D, occlusionTexture:Texture2D, shadowMap:Texture2D, shadowMapFar:Texture2D, environmentMap:Texture2D, normalTexture:Texture2D):Vec4 {
		var ng = normalize(i.normal);
		// (the tangent made at right angles to the interpolated normal)
		var t = normalize(i.tangent.xyz - ng * dot(ng, i.tangent.xyz));
		var b = cross(ng, t) * i.tangent.w;
		var m = sample(normalTexture, i.uv).xyz * 2 - 1;
		var scale = material.params.z;
		var n = normalize(t * (m.x * scale) + b * (m.y * scale) + ng * m.z);
		return PbrShader.shadeAt(n, i.world, i.uv, frame, material, baseColorTexture, metallicRoughnessTexture, emissiveTexture, occlusionTexture,
			shadowMap, shadowMapFar, environmentMap);
	}
}
