// ESM hot dev backend (`haxe --dev -js … -D esm`; docs/esm.md, docs/plans/esm-dev.md).
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import {
	collectWatchClassPaths,
	createCompilationServer,
	esmHotBuildExtra,
	invalidateHx,
	jsEntry,
	parsePathsFromAll,
	resolveHxmcStd,
	setupSourceWatch,
	words,
} from './dev-shared.mjs';
import { createHotWsServer, wsEncode } from './ws.mjs';

export async function runDevEsm(compiler, { port, host, quiet, cwd, args, browser = false }) {
	const all = words(args);
	const entryRel = jsEntry(all);
	if (!entryRel) {
		console.error('esm dev: missing -js output path');
		process.exit(2);
	}
	const entry = path.resolve(cwd, entryRel);
	const outDir = path.dirname(entry);
	const patchFile = path.join(outDir, '__hx_hot_patch.mjs');
	const devClient = path.join(outDir, '__hx_esm_dev_client.mjs');
	const hxmls = args.filter((a) => a.endsWith('.hxml')).map((a) => path.resolve(a));
	const { classPaths, libs } = parsePathsFromAll(all, cwd);
	const watchPaths = collectWatchClassPaths(cwd, classPaths, libs);
	const hxmcStd = resolveHxmcStd(compiler);
	const hotExtra = esmHotBuildExtra(all);
	const log = (s) => {
		if (!quiet) console.log(s);
	};

	let building = false;
	let again = false;
	let lastError = null;
	let lastPatch = '';
	let child = null;
	let patchTiming = null;
	let pendingInvalidations = [];

	const httpServer = http.createServer();
	const wsApi = await createHotWsServer(port, host, { existingServer: httpServer });

	function broadcastHot(msg) {
		const text = JSON.stringify(msg);
		const frame = wsEncode(text);
		for (const c of wsApi.clients) if (!c.sock.destroyed) c.sock.write(frame);
	}

	const { request, server } = await createCompilationServer(compiler, {
		cwd,
		progress: false,
		onFatalExit: (code, tail) => {
			console.error('esm dev: the compilation server stopped (' + code + ')\n' + tail);
			process.exit(1);
		},
	});

	const stop = () => {
		server.kill();
		if (child) child.kill();
		wsApi.close();
		process.exit(0);
	};
	process.on('SIGINT', stop);
	process.on('SIGTERM', stop);

	async function build() {
		const files = pendingInvalidations;
		pendingInvalidations = [];
		await invalidateHx({ request }, files);
		return request([...args, ...hotExtra, ...(hxmcStd ? ['-cp', hxmcStd] : [])]);
	}

	function pushPatch(seen, buildMs) {
		if (!fs.existsSync(patchFile)) return;
		const st = fs.statSync(patchFile);
		const token = String(st.mtimeMs);
		if (token === lastPatch) return;
		lastPatch = token;
		broadcastHot({ type: 'hot-patch', outDir, patchFile, patchMtime: st.mtimeMs });
		if (seen !== null) {
			patchTiming = { seen, build: buildMs, pushed: performance.now() };
		}
	}

	function startProgram() {
		if (child) return;
		const env = { ...process.env, HXMC_ESM_DEV: `${host}:${port}` };
		const preload = fs.existsSync(devClient) ? ['--import', devClient] : [];
		child = spawn(process.execPath, [...preload, entry], { env, cwd: outDir, stdio: 'inherit' });
		child.on('exit', (code, signal) => {
			if (child) {
				child = null;
				log(`esm dev: the program ended (${signal ?? code}); it starts again with the next good build`);
			}
		});
	}

	const types = { '.mjs': 'text/javascript', '.js': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
	function serveFile(res, file) {
		fs.readFile(file, (err, b) => {
			if (err) {
				res.writeHead(404);
				res.end();
				return;
			}
			res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
			res.end(b);
		});
	}

	const overlayPage = () => `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${path.basename(entry)} (esm dev)</title>
<style>
body { margin: 0; background: #fff; }
@media (prefers-color-scheme: dark) { body { background: #0b0b0c; } }
#hxmc-dev-overlay { position: fixed; inset: 0; z-index: 2147483647; display: none; overflow: auto; margin: 0; padding: 16px;
	background: rgba(20, 0, 0, .9); color: #ffd7d7; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; white-space: pre-wrap; }
#hxmc-dev-overlay b { color: #fff; }
</style></head><body>
<pre id="hxmc-dev-overlay" role="alert"></pre>
<script type="module">
const overlay = document.getElementById('hxmc-dev-overlay');
const show = (text) => {
	overlay.innerHTML = '';
	const b = document.createElement('b');
	b.textContent = 'esm dev: the build failed; the last good build keeps running\\n\\n';
	overlay.append(b, text);
	overlay.style.display = 'block';
};
const rel = ${JSON.stringify(path.relative(outDir, entry).replace(/\\/g, '/'))};
const devRel = ${JSON.stringify(path.relative(outDir, devClient).replace(/\\/g, '/'))};
await import('./' + devRel);
await import('./' + rel);
let ws = null;
const pending = [];
const send = (m) => (ws && ws.readyState === 1 ? ws.send(JSON.stringify(m)) : pending.push(m));
function connect() {
	ws = new WebSocket((location.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + location.host + '/__esm_hot/ws');
	ws.onopen = () => { for (const m of pending.splice(0)) ws.send(JSON.stringify(m)); send({ type: 'hello' }); };
	ws.onmessage = (e) => {
		const m = JSON.parse(e.data);
		if (m.type === 'error') show(m.message);
		if (m.type === 'ok') overlay.style.display = 'none';
	};
	ws.onclose = () => setTimeout(connect, 1000);
}
connect();
</script></body></html>`;

	const relOut = path.relative(cwd, outDir);
	if (browser) {
		httpServer.on('request', (req, res) => {
			const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
			if (p === '/' || p === '/index.html') {
				res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
				res.end(overlayPage());
				return;
			}
			const rel = p.startsWith('/') ? p.slice(1) : p;
			const file = path.join(outDir, rel);
			if (file.startsWith(outDir + path.sep) && fs.existsSync(file)) serveFile(res, file);
			else if (file.startsWith(outDir + path.sep)) {
				res.writeHead(404);
				res.end();
			} else {
				res.writeHead(404);
				res.end();
			}
		});
		await new Promise((resolve, reject) => {
			httpServer.once('error', (e) => (e.code === 'EADDRINUSE' ? httpServer.listen(++port, host, resolve) : reject(e)));
			httpServer.listen(port, host, resolve);
		});
		log(`esm dev: http://${host === '0.0.0.0' ? 'localhost' : host}:${port}/ (${relOut}/${path.basename(entry)}; watching ${watchPaths.length} class paths)`);
	} else {
		await new Promise((resolve, reject) => {
			httpServer.on('request', (_req, res) => {
				res.writeHead(404);
				res.end();
			});
			httpServer.once('error', (e) => (e.code === 'EADDRINUSE' ? httpServer.listen(++port, host, resolve) : reject(e)));
			httpServer.listen(port, host, resolve);
		});
		log(`esm dev: ws://${host}:${port}/__esm_hot/ws — ${relOut}/${path.basename(entry)} (watching ${watchPaths.length} class paths)`);
	}

	async function rebuild(seen) {
		if (building) {
			again = true;
			return;
		}
		building = true;
		const t0 = performance.now();
		const r = await build();
		const ms = Math.round(performance.now() - t0);
		if (r.messages) (r.ok ? console.log : console.error)(r.messages);
		if (!r.ok) {
			lastError = r.messages || 'the build failed';
			log(`esm dev: error (build ${ms} ms); the last good build keeps running`);
			broadcastHot({ type: 'error', message: lastError });
		} else {
			const wasError = lastError !== null;
			lastError = null;
			if (wasError) broadcastHot({ type: 'ok' });
			pushPatch(seen, ms);
			if (!browser) startProgram();
			if (seen === null) log(`esm dev: built in ${ms} ms`);
			else if (seen !== null && patchTiming) {
				const t = patchTiming;
				patchTiming = null;
				log(`esm dev: patched in ${Math.round(performance.now() - t.seen)} ms (build ${t.build} ms)`);
			}
		}
		building = false;
		if (again) {
			again = false;
			rebuild(performance.now());
		}
	}

	setupSourceWatch({
		classPaths: watchPaths,
		hxmls,
		skip: (full) => full.startsWith(outDir + path.sep) && path.basename(full).startsWith('__hx_'),
		onChange: (files, seen) => {
			pendingInvalidations = files;
			rebuild(seen);
		},
	});

	await rebuild(null);
}