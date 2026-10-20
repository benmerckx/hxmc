// A compilation server's builds of small programs are fresh builds (make
// dev-check): each case is a program a
// server of its own builds, then builds again after each edit, its typed
// modules kept in memory (as `hxmc dev` asks) and then read back from HXB
// (the default); each build's output must be the bytes a one-shot build of
// the same sources makes. What it checks is an edit that makes the program
// use code it did not use before while hxmc's LowerCache replays the bodies
// of the modules not typed again.
//   node hxmc/test/dev/server-verify.mjs <compiler> [native|web]
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const [compilerArg, mode = 'native'] = process.argv.slice(2);
const compiler = path.resolve(compilerArg ?? 'bin/hxmc/hxmc');
const web = mode === 'web';

// name: [the first sources, then each edit (the files it writes)]
const cases = {
	// a Dynamic called as a function goes through an adapter per signature
	// (Lower.dynAdapter): Lib's body, replayed, asks for the one of Int->Int,
	// and Main's, lowered anew, for the same one, which the program has once
	'a Dynamic as a function, in a replayed body and a new one': [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function call(d:Dynamic):Int {\n\t\tvar f:Int->Int = d;\n\t\treturn f(1);\n\t}\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call((x:Int) -> x + 1));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\tvar d:Dynamic = (x:Int) -> x * 2;\n\t\tvar g:Int->Int = d;\n\t\ttrace(Lib.call((x:Int) -> x + 1) + g(3));\n\t}\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call((x:Int) -> x + 1));\n\t}\n}\n' },
	],
	// (and a closure converted to another signature: Lower.adapter)
	'a function as one of another signature, in a replayed body and a new one': [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function call(f:Int->Int):Null<Int> {\n\t\tvar g:Int->Null<Int> = f;\n\t\treturn g(1);\n\t}\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call(x -> x + 1));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\tvar f:Int->Int = x -> x * 2;\n\t\tvar g:Int->Null<Int> = f;\n\t\ttrace(Lib.call(x -> x + 1) + g(3));\n\t}\n}\n' },
	],
};

const out = web ? 'out/app.wasm' : process.platform === 'win32' ? 'out/app.exe' : 'out/app';
const ref = 'ref/' + path.basename(out);
const args = (o) => ['-cp', 'src', '-main', 'Main', ...(web ? ['-D', 'hxmc.target=wasm32-wasi'] : process.platform === 'linux' ? ['-D', 'hxmc.libc=glibc'] : []),
	'--custom-target', 'hxmc=' + o, ...(fs.existsSync(path.join(path.dirname(compiler), 'std')) ? ['-cp', path.join(path.dirname(compiler), 'std')] : [])];
const env = { ...process.env, HXMC_MODULE_CACHE: '0', HAXE_STD_PATH: process.env.HAXE_STD_PATH ?? path.join(repo, 'haxe/upstream/std') };

// a compilation server per case (its modules by path: a case's Main is not another's)
async function serve(run) {
	const port = await new Promise((r) => {
		const s = net.createServer().listen(0, '127.0.0.1', () => {
			const p = s.address().port;
			s.close(() => r(p));
		});
	});
	const server = spawn(compiler, ['--wait', String(port)], { env, stdio: ['ignore', 'pipe', 'pipe'] });
	let output = '';
	server.stdout.on('data', (d) => (output += d));
	server.stderr.on('data', (d) => (output += d));
	const request = (cwd, words) => new Promise((resolve) => {
		const go = (n) => {
			const s = net.connect(port, '127.0.0.1');
			const chunks = [];
			s.on('error', () => (n > 0 ? setTimeout(() => go(n - 1), 50) : resolve('\x02 no compilation server')));
			s.on('connect', () => s.write(['--cwd', cwd, ...words].map((a) => a + '\n').join('') + '\0'));
			s.on('data', (d) => chunks.push(d));
			s.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
		};
		go(100);
	});
	try {
		await run(request, () => output.slice(-2000));
	} finally {
		server.kill();
	}
}

let failures = 0;
// (the server's typed modules kept in memory, as `hxmc dev` asks, and read back from HXB, its default)
for (const hxb of [false, true])
	for (const [name, steps] of Object.entries(cases)) {
		const work = fs.mkdtempSync(path.join(os.tmpdir(), 'hxmc-server-verify-'));
		fs.mkdirSync(path.join(work, 'src'));
		await serve(async (request, serverOutput) => {
			for (let i = 0; i < steps.length; i++) {
				for (const [f, text] of Object.entries(steps[i])) {
					fs.writeFileSync(path.join(work, 'src', f), text);
					await request(work, ['--display', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'server/invalidate', params: { file: path.join(work, 'src', f) } })]);
				}
				const answer = await request(work, [...args(out), ...(hxb ? [] : ['-D', 'disable-hxb-cache'])]);
				const fresh = spawnSync(compiler, args(ref), { cwd: work, env, encoding: 'utf8' });
				const same = !answer.includes('\x02') && fresh.status === 0 && Buffer.compare(fs.readFileSync(path.join(work, out)), fs.readFileSync(path.join(work, ref))) === 0;
				const what = `${name} (${mode}${hxb ? ', HXB' : ''}): ` + (i === 0 ? 'the first build' : `edit ${i}`);
				console.log((same ? 'ok   ' : 'FAIL ') + what);
				if (!same) {
					failures++;
					console.log(answer.includes('\x02') ? answer + serverOutput() : fresh.status !== 0 ? fresh.stdout + fresh.stderr : 'the outputs differ');
				}
			}
		});
		fs.rmSync(work, { recursive: true, force: true });
	}
console.log(failures === 0 ? 'server-verify: ok' : `server-verify: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
