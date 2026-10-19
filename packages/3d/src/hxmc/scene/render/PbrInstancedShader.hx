package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;
import hxmc.scene.render.PbrShader;

// The standard material drawn many times in one call (Renderer: the
// primitives of a frame that share a mesh and a material): the vertex as
// PbrShader's, then each instance's world matrix by columns from a second
// buffer that steps per instance (layout); normals turned by the matrix's
// upper 3x3 (exact for rotations and uniform scales; a non-uniform scale
// is drawn without instancing). The fragment is PbrShader.shadeAt's.
@:structInit @:publicFields class PbrInstanceVertex {
	var pos:Vec3;
	var normal:Vec3;
	var uv:Vec2;
	// per instance: the world matrix's columns
	var m0:Vec4;
	var m1:Vec4;
	var m2:Vec4;
	var m3:Vec4;
}

class PbrInstancedShader implements Shaders {
	@:vertex static function vs(v:PbrInstanceVertex, frame:PbrFrame):PbrVaryings {
		var model = mat4(v.m0, v.m1, v.m2, v.m3);
		var world = model * vec4(v.pos, 1);
		return {
			clip: frame.viewProj * world,
			world: world.xyz,
			normal: (model * vec4(v.normal, 0)).xyz,
			uv: v.uv
		};
	}

	@:fragment static function fs(i:PbrVaryings, frame:PbrFrame, material:PbrMaterial, baseColorTexture:Texture2D, metallicRoughnessTexture:Texture2D,
			emissiveTexture:Texture2D, occlusionTexture:Texture2D, shadowMap:Texture2D, shadowMapFar:Texture2D, environmentMap:Texture2D):Vec4
		return PbrShader.shadeAt(normalize(i.normal), i.world, i.uv, frame, material, baseColorTexture, metallicRoughnessTexture, emissiveTexture,
			occlusionTexture, shadowMap, shadowMapFar, environmentMap);

}
