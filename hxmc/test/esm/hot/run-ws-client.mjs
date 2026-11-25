// Load an ESM hot build, wait for a dev-server patch, apply without manual applyHotPatch.
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { connectHotWs } from './ws-min.mjs';

const [outDir, portStr] = process.argv.slice(2);
const port = Number(portStr ?? 8765);
const root = path.resolve(outDir);
const hx = pathToFileURL(path.join(root, '__hx_esm_runtime.mjs')).href;

await import(pathToFileURL(path.join(root, 'hx/SwapTarget.mjs')).href);
await import(pathToFileURL(path.join(root, 'hx/Main.mjs')).href);
const $hx = await import(hx);

const before = $hx.$h.SwapTarget.version();
if (before !== 'v1') throw new Error('before patch: expected v1, got ' + before);

let done = false;
const finish = (ok, err) => {
	if (done) return;
	done = true;
	clearTimeout(timer);
	if (err) {
		console.error(err);
		process.exit(1);
	}
	const after = $hx.$h.SwapTarget.version();
	if (after !== 'v2') throw new Error('after patch: expected v2, got ' + after);
	console.log('esm-hot-ws: ok');
	process.exit(ok ? 0 : 1);
};

const timer = setTimeout(() => finish(false, new Error('timeout waiting for hot-patch')), 120_000);

const send = await connectHotWs(port, '127.0.0.1', async (raw) => {
	const msg = JSON.parse(raw);
	if (msg.type === 'hot-patch') {
		const patchUrl = pathToFileURL(msg.patchFile).href + '?t=' + msg.patchMtime;
		const patch = await import(patchUrl);
		if (typeof patch.applyHotPatchFromDev !== 'function')
			return finish(false, new Error('patch module missing applyHotPatchFromDev'));
		patch.applyHotPatchFromDev();
		finish(true);
	}
	if (msg.type === 'error') finish(false, new Error(msg.message));
});
send(JSON.stringify({ type: 'hello' }));