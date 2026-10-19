package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;
import hxmc.scene.render.PbrShader;

// The shadow map's pass (Shadows): each caster seen from the light, its
// depth (0 near the light, 1 far) written to an R32F target.
@:structInit @:publicFields class ShadowVaryings {
	@:position var clip:Vec4;
	var depth:Float;
}

@:structInit @:publicFields class ShadowCaster {
	var mvp:Mat4; // the light's view-projection times the node's world matrix
}

class ShadowShader implements Shaders {
	@:vertex static function vs(v:PbrVertex, caster:ShadowCaster):ShadowVaryings {
		var clip = caster.mvp * vec4(v.pos, 1);
		return {clip: clip, depth: clip.z / clip.w};
	}

	@:fragment static function fs(i:ShadowVaryings):Vec4
		return vec4(i.depth, 0, 0, 1);
}
