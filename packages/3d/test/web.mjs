// packages/3d's scenes (Scenes.hx; SCENES=a,b for some) on WebGPU, then on
// WebGL2 (forced), in headless Chromium (make 3d-web-check), against
// <scene>.png by packages/gfx's rule (its compare.mjs): SceneWebTest.wasm
// headless, then in a 256x192 canvas drawn by the browser's loop.
// Chromium renders with WebGPU on SwiftShader and WebGL2 on ANGLE's
// SwiftShader, as in packages/gfx/test/web.mjs.
//   node packages/3d/test/web.mjs <SceneWebTest.wasm> [out dir]
import { createServer } from 'node:http';
import { readFile, writeFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
let pw;
try { pw = require('playwright'); } catch { pw = require(path.join(process.execPath, '../../lib/node_modules/playwright')); }
const here = path.dirname(fileURLToPath(import.meta.url));
const [wasm, out] = process.argv.slice(2);
if (!wasm) {
	console.error('usage: node web.mjs <SceneWebTest.wasm> [out dir]');
	process.exit(2);
}
const CHROMIUM_ARGS = ['--enable-unsafe-webgpu', '--enable-features=Vulkan', '--use-vulkan=swiftshader', '--use-angle=swiftshader'];
const scenes = process.env.SCENES ? process.env.SCENES.split(',') : ['gltf', 'orbits', 'shadows', 'physics', 'instances', 'skin', 'overlay', 'textured', 'packed', 'spot', 'sky', 'lazy', 'particles', 'normals', 'blend', 'walker', 'packedskin', 'packednormals', 'cascades', 'environment', 'morph', 'chains', 'packedmorph'];
const files = {
	'/test.wasm': wasm,
	'/os/browser.mjs': path.join(here, '../../os/browser.mjs'),
	'/os/imports.mjs': path.join(here, '../../os/imports.mjs'),
	'/gfx/imports.mjs': path.join(here, '../../gfx/imports.mjs'),
	'/compare.mjs': path.join(here, '../../gfx/test/compare.mjs'),
};
// (the packed samples draw the glTF ones' frames)
for (const s of scenes) files[`/${s}.png`] = path.join(here, `${s === 'packed' ? 'gltf' : s === 'lazy' || s === 'packedskin' ? 'skin' : s === 'packednormals' ? 'normals' : s === 'packedmorph' ? 'morph' : s}.png`);
// (the files the build put beside the module, Model.of's: fetched by browser.mjs before main)
const manifest = wasm + '.assets.json';
let assets = false;
try {
	const list = JSON.parse(await readFile(manifest, 'utf8'));
	files['/test.wasm.assets.json'] = manifest;
	for (const p of list) files['/' + p] = path.join(path.dirname(wasm), p);
	// (and the files a program loads itself: Model.of(path, Lazy), fetched at run time)
	for (const n of await readdir(path.join(path.dirname(wasm), 'assets')).catch(() => [])) files['/assets/' + n] = path.join(path.dirname(wasm), 'assets', n);
	assets = true;
	console.log(`web.mjs: ${list.length} files fetched before main: ${list.join(', ')}`);
} catch {}
const types = { '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.png': 'image/png', '.json': 'application/json', '.glb': 'model/gltf-binary' };
const page = `<!doctype html><title>SceneWebTest</title>
<canvas id="c" style="width: 256px; height: 192px; display: block"></canvas>
<script type="module">
import { run } from './os/browser.mjs';
import { decode, compare } from './compare.mjs';
const log = [];
window.log = log;
window.start = async (gfx, mode, scene) => {
	const golden = await decode(scene + '.png');
	const r = await run('test.wasm', { imports: ['os/imports.mjs', 'gfx/imports.mjs'], canvas: 'c', gfx, args: [mode, scene], ${assets ? "assets: 'test.wasm.assets.json'," : ''} stdout: (s) => log.push(s), stderr: (s) => log.push('stderr: ' + s) });
	log.push('exit ' + r.exitCode);
	if (r.host.gfx.backend !== gfx) return { ok: false, text: gfx + ' ' + mode + ': on ' + r.host.gfx.backend };
	if (mode === 'window') {
		const t0 = performance.now();
		while (!log.some((l) => l.startsWith('SceneWebTest: window:')) && performance.now() - t0 < 10000) await new Promise((f) => setTimeout(f, 50));
	}
	const px = await r.host.gfx.readPixels();
	window.pixels = Array.from(px.data);
	return compare(scene + ' ' + gfx + ' ' + mode, px, golden);
};
</script>`;
const server = createServer(async (req, res) => {
	const p = new URL(req.url, 'http://x').pathname;
	try {
		const b = p === '/' ? Buffer.from(page) : await readFile(files[p]);
		res.writeHead(200, { 'content-type': p === '/' ? 'text/html' : types[path.extname(p)] });
		res.end(b);
	} catch {
		res.writeHead(404);
		res.end();
	}
}).listen(0);
const url = `http://localhost:${server.address().port}/`;
const browser = await pw.chromium.launch({ args: CHROMIUM_ARGS });
console.log(`web.mjs: chromium ${browser.version()}`);
let failed = 0;
// (a lazy scene in a window only: headless, main draws once, before its files load)
for (const [scene, gfx, mode] of scenes.flatMap((s) => [[s, 'webgpu', 'headless'], [s, 'webgpu', 'window'], [s, 'webgl2', 'headless'], [s, 'webgl2', 'window']]).filter(([s, , m]) => s !== 'lazy' || m === 'window')) {
	const p = await browser.newPage({ viewport: { width: 400, height: 300 } });
	const errors = [];
	p.on('pageerror', (e) => errors.push(e.message));
	p.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
	await p.goto(url);
	const r = await p.evaluate(([g, m, s]) => window.start(g, m, s), [gfx, mode, scene]).catch((e) => ({ ok: false, text: e.message.split('\n')[0] }));
	const api = gfx === 'webgpu' ? 'WebGPU' : 'WebGL2';
	const expect = [mode === 'window' ? `SceneWebTest: window: 3 frames (${api})` : `SceneWebTest: headless: 256x192 (${api})`];
	const log = await p.evaluate(() => window.log);
	if (out) {
		const png = await p.evaluate(async () => {
			const c = new OffscreenCanvas(256, 192), g = c.getContext('2d');
			g.putImageData(new ImageData(new Uint8ClampedArray(window.pixels ?? new Array(256 * 192 * 4).fill(0)), 256, 192), 0, 0);
			return Array.from(new Uint8Array(await (await c.convertToBlob()).arrayBuffer()));
		});
		await writeFile(path.join(out, `${scene}-${gfx}-${mode}.png`), Buffer.from(png));
	}
	const missing = expect.filter((e) => !log.some((l) => l.startsWith(e)));
	const ok = r.ok && missing.length === 0 && errors.length === 0 && log.includes('exit 0');
	if (!ok) failed++;
	console.log(`web.mjs: ${r.text}${ok ? '' : ' FAILED'}`);
	for (const l of log) console.log('  ' + l);
	for (const m of missing) console.log('  missing: ' + m);
	for (const e of errors) console.log('  error: ' + e);
	await p.close();
}
await browser.close();
server.close();
process.exit(failed ? 1 : 0);
