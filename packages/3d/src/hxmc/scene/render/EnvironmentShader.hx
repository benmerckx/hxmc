package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;
import hxmc.scene.render.SkyShader;

// The environment's background (Environment): as the sky's quad, each
// pixel the environment map's colour along its view direction (an
// equirectangular image: longitude across, latitude down), times the
// environment's intensity, tone mapped and encoded as the standard
// material is. equirect is also the standard material's lookup.
@:structInit @:publicFields class EnvironmentParams {
	var invViewProj:Mat4;
	var eye:Vec4;
	var params:Vec4; // x: intensity times exposure
}

class EnvironmentShader implements Shaders {
	@:vertex static function vs(v:SkyVertex):SkyVaryings
		return {clip: vec4(v.pos, 0.9999, 1), ndc: v.pos};

	@:fragment static function fs(i:SkyVaryings, env:EnvironmentParams, environmentMap:Texture2D):Vec4 {
		var far = env.invViewProj * vec4(i.ndc, 1, 1);
		var d = normalize(far.xyz / far.w - env.eye.xyz);
		var color = pow(sampleLevel(environmentMap, equirect(d), 0).xyz, vec3(2.2)) * env.params.x;
		return vec4(PbrShader.encode(PbrShader.aces(color)), 1);
	}

	// a unit direction's place in an equirectangular map (-z at its centre,
	// up at its top)
	public static function equirect(d:Vec3):Vec2
		return vec2(arcTan2(d.x, -d.z) * 0.15915494 + 0.5, arcCos(clamp(d.y, -1, 1)) * 0.31830989);

	// (the shaders have no inverse trigonometry: polynomial fits, within
	// 2e-5 radians of atan2 and 7e-5 of acos)
	static function arcTan2(y:Float, x:Float):Float {
		var ax = abs(x), ay = abs(y);
		var a = min(ax, ay) / max(max(ax, ay), 0.000001);
		var s = a * a;
		var r = a * (0.999866 + s * (-0.3302995 + s * (0.180141 + s * (-0.085133 + s * 0.0208351))));
		if (ay > ax) r = 1.5707964 - r;
		if (x < 0) r = 3.1415927 - r;
		if (y < 0) r = -r;
		return r;
	}

	static function arcCos(x:Float):Float {
		var ax = abs(x);
		var r = sqrt(1 - ax) * (1.5707288 + ax * (-0.2121144 + ax * (0.074261 - 0.0187293 * ax)));
		if (x < 0) r = 3.1415927 - r;
		return r;
	}
}
