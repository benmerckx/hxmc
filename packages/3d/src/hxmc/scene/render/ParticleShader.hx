package hxmc.scene.render;

import hxmc.gfx.shader.*;
import hxmc.gfx.shader.ShaderMath.*;

// Particles (Particles): each a camera-facing quad, instanced: the corner
// per vertex, the particle (position, size, colour and opacity) per
// instance; a soft round spot, added to what is behind it (additive
// blending), depth-tested against the scene but not written.
@:structInit @:publicFields class ParticleVertex {
	var corner:Vec2; // per vertex: -1 to 1
	var center:Vec3; // per instance
	var size:Float;
	var color:Vec4; // linear colour, w: opacity
}

@:structInit @:publicFields class ParticleVaryings {
	@:position var clip:Vec4;
	var corner:Vec2;
	var color:Vec4;
}

@:structInit @:publicFields class ParticleView {
	var viewProj:Mat4;
	var right:Vec4; // the camera's right and up in the world
	var up:Vec4;
}

class ParticleShader implements Shaders {
	@:vertex static function vs(v:ParticleVertex, view:ParticleView):ParticleVaryings {
		var p = v.center + (view.right.xyz * v.corner.x + view.up.xyz * v.corner.y) * v.size;
		return {clip: view.viewProj * vec4(p, 1), corner: v.corner, color: v.color};
	}

	@:fragment static function fs(i:ParticleVaryings):Vec4 {
		var d = 1 - smoothstep(0.2, 1, length(i.corner));
		var c = i.color.xyz * (i.color.w * d);
		return vec4(PbrShader.encode(PbrShader.aces(c)), 1);
	}
}
