package hxmc.scene.render;

// An optional part of the renderer, turned on by the program
// (renderer.use(new Shadows(device))): the renderer core reaches it only
// through the interfaces it fills (ShadowSource, SkinSource, NormalSource), so a program
// that never makes one links none of its code or shaders.
interface RenderFeature {
	function attach(renderer:Renderer):Void;
}

// what the renderer asks of a shadow map (Shadows)
interface ShadowSource {
	// the map's pass, before the frame's
	// (skins: the renderer's skinning, for skinned casters; null without it)
	// (frame: the camera's view, for cascades fitted to it)
	function render(enc:hxmc.gfx.Encoder, world:hxmc.scene.World, toLight:hxmc.gfx.shader.Vec3, skins:Null<SkinSource>, frame:Renderer.FrameInfo):Void;
	// the last pass's map and how to read it (an object: hxmc passes struct
	// values through interface calls wrongly for now)
	function shadowFrame():ShadowFrame;
}

class ShadowFrame {
	public var map:hxmc.gfx.Texture = cast 0;
	public var viewProj:hxmc.gfx.shader.Mat4 = hxmc.gfx.shader.Mat4.identity();
	// x: strength, y: bias, z: a texel of the map
	public var params:hxmc.gfx.shader.Vec4 = new hxmc.gfx.shader.Vec4(0, 0, 0, 0);
	// the second cascade's (one cascade: the first's)
	public var mapFar:hxmc.gfx.Texture = cast 0;
	public var viewProjFar:hxmc.gfx.shader.Mat4 = hxmc.gfx.shader.Mat4.identity();
	public var paramsFar:hxmc.gfx.shader.Vec4 = new hxmc.gfx.shader.Vec4(0, 0, 0, 0);

	public function new() {}
}

// what the renderer asks of skinning (Skinning)
interface SkinSource {
	// the node's skin brought up to date; false when it has none
	function prepare(node:hxmc.scene.Node):Bool;
	function pipeline(doubleSided:Bool):hxmc.gfx.Pipeline;
	// the skinned shader's slots, in Renderer.slotsOf's order
	function slots():Array<Int>;
	// the node's skin bound for a draw
	function bind(enc:hxmc.gfx.Encoder, slots:Array<Int>, node:hxmc.scene.Node):Void;
	// the shadow pass's skinned pipeline (made when first asked: only with
	// Shadows) and its slots (caster, skin, joints)
	function shadowPipeline():hxmc.gfx.Pipeline;
	function shadowSlots():Array<Int>;
}

// what the renderer asks of normal mapping (NormalMaps)
interface NormalSource {
	function pipeline(doubleSided:Bool):hxmc.gfx.Pipeline;
	// the normal-mapped shader's slots, in Renderer.slotsOf's order
	function slots():Array<Int>;
}
