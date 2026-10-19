package hxmc.scene.render;

import hxmc.gfx.Texture;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;

// A surface of glTF's metallic-roughness model: base colour (linear,
// times the texture's sRGB colour when there is one), metallic and
// roughness from 0 to 1, emitted light (linear); double-sided ones are
// drawn without back-face culling.
class Material {
	static var count = 0;

	// the material's index (draws sort by it; an index into a material buffer later)
	public final id:Int = count++;

	public var name:String;
	public var baseColor:Vec4;
	public var metallic:Float;
	public var roughness:Float;
	public var emissive:Vec3;
	public var baseColorTexture:Null<Texture>;
	// glTF's other maps: roughness (green) and metallic (blue), times the
	// factors; emitted colour (sRGB), times emissive; ambient occlusion (red)
	public var metallicRoughnessTexture:Null<Texture>;
	public var emissiveTexture:Null<Texture>;
	public var occlusionTexture:Null<Texture>;
	// a tangent-space normal map (drawn with NormalMaps, on primitives with
	// tangents), its x and y scaled by normalScale
	public var normalTexture:Null<Texture>;
	public var normalScale = 1.0;
	public var doubleSided:Bool;
	// how its textures are read (null: the renderer's: linear, mip-mapped,
	// repeating; glTF's samplers otherwise)
	public var sampler:Null<hxmc.gfx.Sampler>;
	// see-through (glTF's alphaMode BLEND): blended over what is behind by
	// the base colour's alpha, drawn after the opaque surfaces, farthest
	// first, without writing depth
	public var blend = false;

	public function new(?name:String, ?baseColor:Vec4, metallic = 0.0, roughness = 0.5, ?emissive:Vec3, doubleSided = false) {
		this.name = name != null ? name : "";
		this.baseColor = baseColor != null ? baseColor : new Vec4(1, 1, 1, 1);
		this.metallic = metallic;
		this.roughness = roughness;
		this.emissive = emissive != null ? emissive : new Vec3(0, 0, 0);
		this.doubleSided = doubleSided;
	}
}
