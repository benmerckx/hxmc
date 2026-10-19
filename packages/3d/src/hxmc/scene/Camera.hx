package hxmc.scene;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.scene.math.MathTools;

// A camera, a component of a node (Camera.attach(node, camera)): it looks
// down the node's -z, its up the node's +y. Projections are gfx's
// (Mat4.perspective, Mat4.orthographic: clip space y up, z from 0 at the
// near plane). Several cameras may look at one world (split screens,
// shadow views, XR's two eyes): each is drawn by its own Renderer.draw.
class Camera {
	public static final KIND = new StoreKind<Camera>("camera");

	public var isPerspective:Bool;
	// perspective: the vertical field of view (radians); orthographic: the
	// height of the view (scene units)
	public var fovY:Float;
	public var height:Float;
	public var near:Float;
	public var far:Float;
	public var node(default, null):Node = Node.NONE;

	function new(perspective:Bool, fovY:Float, height:Float, near:Float, far:Float) {
		this.isPerspective = perspective;
		this.fovY = fovY;
		this.height = height;
		this.near = near;
		this.far = far;
	}

	public static function perspective(fovY:Float, near:Float, far:Float):Camera
		return new Camera(true, fovY, 0, near, far);

	public static function orthographic(height:Float, near:Float, far:Float):Camera
		return new Camera(false, 0, height, near, far);

	// camera on node (a camera is on one node at a time; node had one: replaced)
	public static function attach(node:Node, camera:Camera):Camera {
		if (!camera.node.isNone && camera.node.valid) camera.node.world.store(KIND).remove(camera.node);
		var store = node.world.store(KIND), old = store.get(node);
		if (old != null) old.node = Node.NONE;
		camera.node = node;
		return store.set(node, camera);
	}

	// node's camera, or null
	public static inline function of(node:Node):Null<Camera>
		return node.world.store(KIND).get(node);

	// the first camera of a world (in the order they were attached), or null
	public static function first(world:World):Null<Camera> {
		var s = world.store(KIND);
		return s.length > 0 ? s.valueAt(0) : null;
	}

	// the scene's space to the camera's (its node's world matrix inverted)
	public function view():Mat4
		return node.isNone ? Mat4.identity() : MathTools.inverse(node.worldMatrix());

	public function projection(aspect:Float):Mat4 {
		if (isPerspective) return Mat4.perspective(fovY, aspect, near, far);
		var h = height / 2, w = h * aspect;
		return Mat4.orthographic(-w, w, -h, h, near, far);
	}

	public inline function viewProjection(aspect:Float):Mat4
		return projection(aspect) * view();

	// the camera's position in the scene
	public function eye():Vec3
		return node.isNone ? new Vec3(0, 0, 0) : node.worldPosition();

	// the ray through a point of the view (x, y from -1 to 1, y up), in the
	// scene's space: from the near plane, dir of unit length
	public function ray(x:Float, y:Float, aspect:Float):{origin:Vec3, dir:Vec3} {
		var inv = MathTools.inverse(viewProjection(aspect));
		var a = MathTools.transformPoint(inv, new Vec3(x, y, 0)), b = MathTools.transformPoint(inv, new Vec3(x, y, 1));
		var d = b - a;
		return {origin: a, dir: d / Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)};
	}
}
