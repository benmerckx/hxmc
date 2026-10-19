package hxmc.scene.render;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.Node;
import hxmc.scene.World;

// A light, a component of a node, as glTF's KHR_lights_punctual: a
// directional light shines down its node's -z; a point light shines from
// its node's position, falling off with the inverse square of the
// distance, windowed to nothing at its range; a spot light is a point
// light within a cone down its node's -z. Its colour (linear) times its
// intensity.
class Light {
	public static final KIND = new StoreKind<Light>("light");

	public var point(default, null):Bool;
	public var color:Vec3;
	public var intensity:Float;
	// a point light's reach (scene units)
	public var range:Float;
	// a spot light's cones (radians from its axis; outer 0: a point light)
	public var innerCone = 0.0;
	public var outerCone = 0.0;

	function new(point:Bool, color:Vec3, intensity:Float, range:Float) {
		this.point = point;
		this.color = color;
		this.intensity = intensity;
		this.range = range;
	}

	public static function directional(color:Vec3, intensity:Float):Light
		return new Light(false, color, intensity, 0);

	public static function pointLight(color:Vec3, intensity:Float, range:Float):Light
		return new Light(true, color, intensity, range);

	// a point light shining down its node's -z within a cone: full inside
	// inner, fading to nothing at outer (radians from the axis)
	public static function spot(color:Vec3, intensity:Float, range:Float, inner:Float, outer:Float):Light {
		var l = new Light(true, color, intensity, range);
		l.innerCone = inner;
		l.outerCone = outer;
		return l;
	}

	public static inline function attach(node:Node, light:Light):Light
		return node.world.store(KIND).set(node, light);

	public static inline function of(node:Node):Null<Light>
		return node.world.store(KIND).get(node);
}
