package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;

// The sky (Sky): a quad over the whole target behind everything (no depth
// written), each pixel's colour from its view direction (the inverse view
// projection's ray): the ground below the horizon, a glow at it, the
// zenith above, a sun's disc and halo; tone mapped and encoded as the
// standard material is (PbrShader.aces, encode).
@:structInit @:publicFields class SkyVertex {
	var pos:Vec2; // clip space
}

@:structInit @:publicFields class SkyVaryings {
	@:position var clip:Vec4;
	var ndc:Vec2;
}

@:structInit @:publicFields class SkyParams {
	var invViewProj:Mat4;
	var eye:Vec4;
	var zenith:Vec4;
	var horizon:Vec4;
	var ground:Vec4;
	var sun:Vec4; // xyz: towards the sun; w: exposure
	var sunColor:Vec4;
}

class SkyShader implements Shaders {
	@:vertex static function vs(v:SkyVertex):SkyVaryings
		return {clip: vec4(v.pos, 0.9999, 1), ndc: v.pos};

	@:fragment static function fs(i:SkyVaryings, sky:SkyParams):Vec4 {
		var far = sky.invViewProj * vec4(i.ndc, 1, 1);
		var d = normalize(far.xyz / far.w - sky.eye.xyz);
		var up = d.y;
		var above = mix(sky.horizon.xyz, sky.zenith.xyz, pow(clamp(up, 0, 1), 0.5));
		var below = mix(sky.horizon.xyz, sky.ground.xyz, pow(clamp(-up, 0, 1), 0.4));
		var color = up > 0 ? above : below;
		var s = max(dot(d, sky.sun.xyz), 0);
		color += sky.sunColor.xyz * (pow(s, 600) * 8 + pow(s, 12) * 0.25);
		return vec4(PbrShader.encode(PbrShader.aces(color * sky.sun.w)), 1);
	}
}
