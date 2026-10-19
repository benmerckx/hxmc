package hxmc.scene.gltf;

// glTF's samplers as gfx's (GltfScene, PackedModel)
class GltfSamplers {
	// glTF's sampler (filters and wraps: WebGL's constants) as gfx's, or null
	// where it reads as the renderer's own (linear, trilinear between mip
	// levels, repeating); wrapS and wrapT differing: wrapS's (gfx wraps both
	// directions alike)
	public static function desc(magFilter:Int, minFilter:Int, wrapS:Int, wrapT:Int):Null<hxmc.gfx.SamplerDesc> {
		var filter:hxmc.gfx.Filter = magFilter == 9728 ? Nearest : Linear;
		var mip:Null<hxmc.gfx.Filter> = switch minFilter {
			case 9728 | 9729: null; // (no mip levels)
			case 9984 | 9985: Nearest;
			default: Linear;
		}
		var wrap:hxmc.gfx.Wrap = switch wrapS {
			case 33071: Clamp;
			case 33648: Mirror;
			default: Repeat;
		}
		if (filter == Linear && mip == Linear && wrap == Repeat) return null;
		return mip == null ? {filter: filter, wrap: wrap} : {filter: filter, mipFilter: mip, wrap: wrap};
	}
}
