package hxmc.physics;

import hxmc.gfx.shader.Vec3;

// Two bodies touching at a point: the normal from a to b, how deep they
// overlap, and the solver's state (the impulses so far, the bounce)
class Contact {
	public final a:Body;
	public final b:Body;
	public final normal:Vec3;
	public final point:Vec3;
	public final depth:Float;
	@:allow(hxmc.physics) var normalImpulse = 0.0;
	@:allow(hxmc.physics) var tangentImpulse1 = 0.0;
	@:allow(hxmc.physics) var tangentImpulse2 = 0.0;
	@:allow(hxmc.physics) var bounce = 0.0;

	public function new(a:Body, b:Body, normal:Vec3, point:Vec3, depth:Float) {
		this.a = a;
		this.b = b;
		this.normal = normal;
		this.point = point;
		this.depth = depth;
	}
}
