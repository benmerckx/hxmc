package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.Device;
import hxmc.gfx.Texture;

// Models' images made textures (GltfScene, PackedModel): decoded by the
// decoder the program gives (no decoder is linked unless named): mime
// type and bytes to RGBA8 pixels, rows top to bottom, or null for a format
// it does not read. @hxmc/ui's:
//   Images.decode = (mime, b) -> mime == "image/jpeg" ? hxmc.ui.JpegDecoder.decode(b) : hxmc.ui.PngDecoder.decode(b);
// Without one, textures are left out (materials keep their factors).
class Images {
	public static var decode(default, set):Null<(String, Bytes) -> Null<{width:Int, height:Int, rgba:Bytes}>>;

	// (made when a decoder is given: without one, no texture making, mip
	// levels included, is linked)
	static var make:Null<(Device, String, Bytes) -> Null<Texture>>;

	static function set_decode(f) {
		make = f != null ? made : null;
		return decode = f;
	}

	// an encoded image's texture, mip-mapped (mipmapped; sRGB colours:
	// decoded by the shader); null without a decoder or for a format it does not read
	public static function texture(device:Device, mime:String, bytes:Null<Bytes>):Null<Texture>
		return make != null && bytes != null ? make(device, mime, bytes) : null;

	static function made(device:Device, mime:String, bytes:Bytes):Null<Texture> {
		var image = decode(mime, bytes);
		if (image == null) return null;
		return mipmapped(device, image.width, image.height, image.rgba);
	}

	// an RGBA8 image's texture with its mip levels made here (2x2 boxes,
	// down to 1x1): the same texels on every GPU, whose own mip making
	// differs, and an environment's small levels are its light
	public static function mipmapped(device:Device, width:Int, height:Int, rgba:Bytes):Texture {
		var t = device.createTexture({width: width, height: height, data: rgba, mipLevels: 0});
		var w = width, h = height, level = 0, src = rgba;
		while (w > 1 || h > 1) {
			var nw = w > 1 ? w >> 1 : 1, nh = h > 1 ? h >> 1 : 1;
			var dst = Bytes.alloc(nw * nh * 4);
			for (y in 0...nh)
				for (x in 0...nw) {
					var x0 = w > 1 ? 2 * x : 0, y0 = h > 1 ? 2 * y : 0, x1 = w > 1 ? x0 + 1 : x0, y1 = h > 1 ? y0 + 1 : y0;
					for (c in 0...4) {
						var sum = src.get(4 * (y0 * w + x0) + c) + src.get(4 * (y0 * w + x1) + c) + src.get(4 * (y1 * w + x0) + c) + src.get(4 * (y1 * w + x1) + c);
						dst.set(4 * (y * nw + x) + c, (sum + 2) >> 2);
					}
				}
			level++;
			device.writeTexture(t, dst, 0, 0, nw, nh, 0, level);
			w = nw;
			h = nh;
			src = dst;
		}
		return t;
	}

}
