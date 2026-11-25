// ESM hot dev: watch sources, rebuild, WebSocket-push patch chunk path.
//   node esm-dev.mjs --port 8765 --out bin/test/esm/hot/watch-patch --watch hxmc/test/esm/hot/body-swap -- <haxe> ...
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { createHotWsServer } from './ws-min.mjs';

function usage(msg) {
	if (msg) console.error('esm-dev: ' + msg);
	console.error('usage: node esm-dev.mjs --port <n> --out <dir> --watch <dir> -- <compiler> [haxe args...]');
	process.exit(2);
}

const argv = process.argv.slice(2);
let port = 8765;
let outDir = null;
const watchDirs = [];
const compileArgs = [];
for (let i = 0; i < argv.length; i++) {
	if (argv[i] === '--port') port = Number(argv[++i]);
	else if (argv[i] === '--out') outDir = path.resolve(argv[++i]);
	else if (argv[i] === '--watch') watchDirs.push(path.resolve(argv[++i]));
	else if (argv[i] === '--') {
		compileArgs.push(...argv.slice(i + 1));
		break;
	} else usage('unknown option ' + argv[i]);
}
if (!outDir || watchDirs.length === 0 || compileArgs.length === 0) usage('missing --out, --watch, or compile args');

const patchFile = path.join(outDir, '__hx_hot_patch.mjs');
let building = false;
let pending = false;
let lastPush = '';

/** @type {null | ((text: string) => void)} */
let broadcast = null;

function pushPatch() {
	if (!fs.existsSync(patchFile)) return;
	const st = fs.statSync(patchFile);
	const token = String(st.mtimeMs);
	if (token === lastPush) return;
	lastPush = token;
	const envelope = JSON.stringify({
		type: 'hot-patch',
		outDir,
		patchFile,
		patchMtime: st.mtimeMs,
	});
	if (broadcast) broadcast(envelope);
	else process.stdout.write('esm-dev: patch ready (no clients)\n');
}

function compileOnce() {
	if (building) {
		pending = true;
		return;
	}
	building = true;
	pending = false;
	const log = path.join(outDir, 'esm-dev-build.log');
	fs.mkdirSync(outDir, {recursive: true});
	const child = spawn(compileArgs[0], compileArgs.slice(1), {stdio: ['ignore', 'pipe', 'pipe']});
	let out = '';
	child.stdout.on('data', (d) => (out += d));
	child.stderr.on('data', (d) => (out += d));
	child.on('close', (code) => {
		building = false;
		fs.writeFileSync(log, out);
		if (code !== 0) {
			process.stderr.write('esm-dev: compile failed\n' + out.slice(-1500));
			if (broadcast) broadcast(JSON.stringify({type: 'error', message: out.slice(-2000)}));
		} else pushPatch();
		if (pending) compileOnce();
	});
}

for (const d of watchDirs) {
	if (!fs.existsSync(d)) continue;
	fs.watch(d, {recursive: true}, (_, f) => {
		if (!f || !f.endsWith('.hx')) return;
		compileOnce();
	});
}
compileOnce();

const srv = await createHotWsServer(port);
broadcast = srv.broadcast;
process.stdout.write(`esm-dev: ws://127.0.0.1:${port}/__esm_hot/ws (out ${outDir})\n`);

process.on('SIGINT', () => {
	srv.close();
	process.exit(0);
});