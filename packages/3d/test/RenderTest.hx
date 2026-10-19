import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.os.*;

// packages/3d's frames natively against golden images (make 3d-check), by
// packages/gfx's rule (GfxTest.compareBytes: a pixel matches within 2 of
// each channel, at most 0.5% of them off), headless (Linux: an EGL pbuffer
// on llvmpipe; macOS: Metal; Windows: D3D11):
//
//   RenderTest <scene> <golden.png> <out.png> [--bless]
class RenderTest {
	static inline var WIDTH = 256;
	static inline var HEIGHT = 192;

	static function main() {
		var args = Sys.args();
		if (args.length < 3 || !Scenes.NAMES.contains(args[0])) {
			Sys.println("usage: RenderTest " + Scenes.NAMES.join("|") + " <golden.png> <out.png> [--bless]");
			Sys.exit(2);
		}
		var name = args[0], golden = args[1], out = args[2];
		var device = try Device.create(Surface.headless(WIDTH, HEIGHT)) catch (e:String) {
			// (macOS virtual machines may have no GPU: check.sh skips, as gfx's)
			if (e != "hxmc.gfx: no Metal device") throw e;
			Sys.println("RenderTest: skipped: no Metal device");
			Sys.exit(3);
			null;
		}
		var draw = Scenes.make(name, device);
		// (natively a lazy scene's files are read at once)
		if (!Scenes.ready()) throw 'RenderTest: $name not ready';
		var pixels = Bytes.alloc(WIDTH * HEIGHT * 4);
		var enc = device.beginFrame();
		draw(enc);
		device.readPixels(pixels);
		device.endFrame();
		var stats = Scenes.renderer;
		var drawsOk = true;
		if (stats != null) {
			Sys.println('RenderTest: $name: ${stats.draws} draws, ${stats.instanced} instances in instanced draws, ${stats.culled} culled');
			// (169 nodes of two meshes: two instanced draws, unless culled)
			if (name == "instances" && (stats.draws > 2 || stats.instanced + stats.culled != 169)) drawsOk = false;
		}
		if (Scenes.probe != null) {
			var wrong = Scenes.probe();
			if (wrong != null) {
				Sys.println('RenderTest: $name: FAIL: $wrong');
				drawsOk = false;
			} else
				Sys.println('RenderTest: $name: its checks ok');
		}
		device.dispose();
		sys.io.File.saveBytes(out, Png.encode(pixels, WIDTH, HEIGHT));
		if (args[3] == "--bless") {
			sys.io.File.saveBytes(golden, Png.encode(pixels, WIDTH, HEIGHT));
			Sys.println('RenderTest: blessed $golden');
			return;
		}
		var png = sys.io.File.getBytes(golden);
		// (HXMC_3D_TOLERANCE=n: channels within n levels of the golden's taken
		// as equal, then GfxTest's rule; check.sh sets 3 on ARM64's llvmpipe,
		// whose filtering and arithmetic land up to 3 levels apart, gfx's own
		// frames there too)
		var tolerance = Std.parseInt(Sys.getEnv("HXMC_3D_TOLERANCE") ?? "");
		if (tolerance != null && tolerance > 0) {
			var g = Png.decode(png);
			if (g.width == WIDTH && g.height == HEIGHT)
				for (k in 0...WIDTH * HEIGHT * 4)
					if (Math.abs(pixels.get(k) - g.rgba.get(k)) <= tolerance) pixels.set(k, g.rgba.get(k));
			Sys.println('RenderTest: $name: within $tolerance levels taken as equal');
		}
		Sys.exit(GfxTest.compareBytes('$name, headless', pixels, png) && drawsOk ? 0 : 1);
	}
}
