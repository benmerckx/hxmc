package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;
import hxmc.scene.render.PbrShader;
import hxmc.scene.render.PbrSkinnedShader;
import hxmc.scene.render.ShadowShader;

// A skinned caster in the shadow map's pass (Skinning with Shadows): the
// vertex moved by its joints as PbrSkinnedShader moves it, then seen from
// the light; its depth written as ShadowShader writes it.
class ShadowSkinnedShader implements Shaders {
	@:vertex static function vs(v:PbrSkinVertex, caster:ShadowCaster, skin:PbrSkinInfo, jointMatrices:Texture2D):ShadowVaryings {
		var j0 = PbrSkinnedShader.joint(jointMatrices, v.joints.x, skin.rows.x), j1 = PbrSkinnedShader.joint(jointMatrices, v.joints.y, skin.rows.x);
		var j2 = PbrSkinnedShader.joint(jointMatrices, v.joints.z, skin.rows.x), j3 = PbrSkinnedShader.joint(jointMatrices, v.joints.w, skin.rows.x);
		var p = vec4(v.pos, 1);
		var pos = (j0 * p) * v.weights.x + (j1 * p) * v.weights.y + (j2 * p) * v.weights.z + (j3 * p) * v.weights.w;
		var clip = caster.mvp * vec4(pos.xyz, 1);
		return {clip: clip, depth: clip.z / clip.w};
	}

	@:fragment static function fs(i:ShadowVaryings):Vec4
		return vec4(i.depth, 0, 0, 1);
}
