// Runs the playground's worker (bin/site/worker.js) under node, as a page
// would: the module compiled and posted, then requests, each reply printed.
// A check of the browser glue (site/client/WasiHost.hx) without a browser:
//   node --experimental-wasm-exnref site/tools/worker-test.mjs bin/site [Main.hx]
// (node 22: exception handling with exnref is behind the flag; browsers ship it)
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import path from 'node:path';

const dir = process.argv[2];
const file = process.argv[3];
const code = file ? await readFile(file, 'utf8')
	: 'class Main {\n\tstatic function main() {\n\t\tvar a = [for (i in 0...5) i * i];\n\t\ttrace("Hello " + a);\n\t\tSys.println(haxe.Json.stringify({ok: true}));\n\t}\n}\n';
const replies = [];
let wake = null;
const self = {
	fetch: async (url) => {
		const b = await readFile(path.join(dir, url.split('?')[0]));
		return { ok: true, status: 200, arrayBuffer: async () => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) };
	},
	postMessage: (m) => { replies.push(m); if (wake) wake(); },
	performance,
	crypto: globalThis.crypto,
};
self.self = self;
const ctx = vm.createContext({ ...globalThis, self, WebAssembly, TextDecoder, TextEncoder, console, performance, crypto: globalThis.crypto, Promise, Date, Math });
vm.runInContext(await readFile(path.join(dir, 'worker.js'), 'utf8'), ctx);
const send = (m) => self.onmessage({ data: m });
async function until(pred) {
	while (true) {
		const i = replies.findIndex(pred);
		if (i >= 0) return replies.splice(i, 1)[0];
		await new Promise((r) => (wake = r));
	}
}
const t0 = performance.now();
send({ type: 'module', module: await WebAssembly.compile(await readFile(path.join(dir, 'hih.wasm'))) });
send({ type: 'warmup' });
console.log('ready', JSON.stringify(await until((r) => r.type === 'ready' || r.type === 'failed')), Math.round(performance.now() - t0), 'ms');
const main = 'Main';
// --interp
send({ type: 'compile', id: 1, mode: 'run', main, file: 'Main.hx', code });
const done = await until((r) => r.type === 'done' || r.type === 'failed');
for (const r of replies.splice(0)) console.log(r.type, r.text);
console.log('run', done.status, Math.round(done.ms), 'ms', done.message ?? '');
// HXB
send({ type: 'compile', id: 2, mode: 'hxb', main, file: 'Main.hx', code });
const hxb = await until((r) => r.type === 'done' || r.type === 'failed');
replies.splice(0);
console.log('hxb', hxb.status, hxb.zip ? hxb.zip.byteLength + ' bytes' : hxb.message, Math.round(hxb.ms), 'ms');
// diagnostics, and completion after `a.`
send({ type: 'check', id: 3, main, file: 'Main.hx', code: code.replace('trace(', 'trace(undefinedThing + ') });
const check = await until((r) => r.type === 'check' || r.type === 'failed');
console.log('check', check.status, JSON.stringify(check.output));
const at = code.indexOf(' + a') + 4;
const dcode = code.slice(0, at) + '.' + code.slice(at);
send({ type: 'display', id: 4, main, file: 'Main.hx', code: dcode,
	request: { jsonrpc: '2.0', id: 1, method: 'display/completion', params: { file: '/work/Main.hx', offset: Buffer.byteLength(dcode.slice(0, at + 1)), wasAutoTriggered: true } } });
const disp = await until((r) => r.type === 'display' || r.type === 'failed');
console.log('display', disp.status, disp.output.slice(0, 200));
