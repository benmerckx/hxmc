package hxmc.scene.view;

import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.Camera;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.math.Quat;
import hxmc.scene.render.Light;
import hxmc.scene.render.Material;
import hxmc.scene.render.MeshRenderer;
import hxmc.scene.render.Shapes;

// @hxmc/view's renderer for @hxmc/3d (-D hxmc.view.renderer.scene=hxmc.scene.view.SceneRenderer):
// markup makes nodes of a World, and a property bound to a signal sets the
// node's value when the signal changes (no reconciliation, no re-render):
//
//   Render.render(<node name="spinner" position={pos} rotation={turn}>
//     <mesh shape="box" color={new Vec4(1, 0.5, 0.1, 1)}/>
//   </node>, SceneRenderer.root(world));
//
// Elements: node (position, rotation, scale: Vec3, Quat, Vec3; name,
// visible), mesh (a node with a shape made in code: shape box | sphere |
// plane, size, color, metallic, roughness; SceneRenderer.device must be
// set), light (kind directional | point, color, intensity, range), camera
// (fov, near, far). Texts and markers are hidden nodes. A prototype of the
// plan's reactive layer (docs/plans/3d.md): properties go through
// setProperty by name here; typed constructors per tag come next.
class SceneRenderer implements hxmc.view.Renders<SceneNode> {
	// the device meshes are made on
	public static var device:Null<hxmc.gfx.Device>;
	// the world elements are made in (root sets it)
	public static var world:Null<World>;

	// the node of world's root, to render into
	public static function root(w:World):SceneNode {
		world = w;
		return new SceneNode(w.root, "root");
	}

	public static function createElement(tag:String):SceneNode {
		if (world == null) throw "SceneRenderer: no world (render into SceneRenderer.root(world))";
		var n = new SceneNode(world.node(tag), tag);
		n.node.detach();
		return n;
	}

	public static function createText(text:String):SceneNode
		return createMarker("#text");

	public static function createMarker(name:String):SceneNode {
		var n = createElement(name);
		n.node.visible = false;
		return n;
	}

	public static function setText(node:SceneNode, text:String) {}

	public static function holdsText(el:SceneNode):Bool
		return false;

	public static function setProperty(el:SceneNode, name:String, value:Dynamic) {
		var n = el.node;
		switch name {
			case "name": n.name = value;
			case "position": n.position = (value : Vec3);
			case "rotation": n.rotation = (value : Quat);
			case "scale": n.scale = (value : Vec3);
			case "visible": n.visible = value;
			case _:
				// (a component's property: the component made again from them)
				el.props.set(name, value);
				switch el.tag {
					case "mesh": el.remesh();
					case "light": el.relight();
					case "camera": el.recamera();
					case _:
				}
		}
	}

	public static function setStyle(el:SceneNode, value:Dynamic) {}

	public static function listen(el:SceneNode, name:String, handler:Dynamic)
		el.props.set(name, handler);

	public static function insert(parent:SceneNode, node:SceneNode, before:Null<SceneNode>) {
		parent.node.add(node.node);
		if (before != null) {
			// (the scene graph appends: move the ones from before on after it)
			var after = false, move = [];
			for (c in parent.node.children()) {
				if (c == before.node) after = true;
				if (after && c != node.node) move.push(c);
			}
			for (c in move)
				parent.node.add(c);
		}
		node.parent = parent;
	}

	public static function remove(parent:SceneNode, node:SceneNode) {
		node.node.detach();
		node.parent = null;
	}

	public static function parentOf(node:SceneNode):Null<SceneNode>
		return node.parent;

	public static function arrange(parent:SceneNode, nodes:Array<SceneNode>, before:SceneNode)
		for (n in nodes)
			insert(parent, n, before);

	public static function isNode(v:Dynamic):Bool
		return Std.isOfType(v, SceneNode);
}

// a node of the scene as markup sees it: the World's node, its tag, the
// properties that make its components
class SceneNode {
	public final node:Node;
	public final tag:String;
	public var parent:Null<SceneNode>;
	public final props = new Map<String, Dynamic>();

	public function new(node:Node, tag:String) {
		this.node = node;
		this.tag = tag;
		if (tag == "light") relight();
		if (tag == "camera") recamera();
	}

	function get(name:String, def:Dynamic):Dynamic
		return props.exists(name) ? props.get(name) : def;

	@:allow(hxmc.scene.view.SceneRenderer) function remesh() {
		var device = SceneRenderer.device;
		if (device == null) return;
		var c:Vec4 = get("color", new Vec4(0.8, 0.8, 0.8, 1));
		var m = new Material(tag, c, get("metallic", 0.0), get("roughness", 0.5));
		var size:Float = get("size", 1.0);
		MeshRenderer.attach(node, switch (get("shape", "box") : String) {
			case "sphere": Shapes.sphere(device, m, size / 2);
			case "plane": Shapes.plane(device, m, size);
			case _: Shapes.box(device, m, size, size, size);
		});
	}

	@:allow(hxmc.scene.view.SceneRenderer) function relight() {
		var c:Vec3 = get("color", new Vec3(1, 1, 1));
		var i:Float = get("intensity", 1.0);
		Light.attach(node, get("kind", "directional") == "point" ? Light.pointLight(c, i, get("range", 10.0)) : Light.directional(c, i));
	}

	@:allow(hxmc.scene.view.SceneRenderer) function recamera() {
		var cam = Camera.of(node);
		if (cam == null) cam = Camera.attach(node, Camera.perspective(get("fov", 1.0), get("near", 0.1), get("far", 100.0)));
		else {
			cam.fovY = get("fov", 1.0);
			cam.near = get("near", 0.1);
			cam.far = get("far", 100.0);
		}
	}
}
