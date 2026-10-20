// `hxmc dev` on a program without a window or a library (make dev-check;
// docs/dev.md): the dev server builds a console program that prints a line
// and keeps running, then on each save builds it again and starts the new
// build in place of the old one (a cold start: the program never talks to
// the server):
// - the first build runs;
// - an edit: the old process stopped, the new build runs (another process);
// - a compile error: the program keeps running, the error in the terminal;
//   fixed: the new build runs;
//   node hxmc/test/dev/dev-console.mjs <compiler> [work dir]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const compiler = path.resolve(process.argv[2] ?? 'bin/hxmc/hxmc');
const work = path.resolve(process.argv[3] ?? fs.mkdtempSync(path.join(os.tmpdir(), 'hxmc-dev-console-')));

let failures = 0;
const check = (what, ok, detail = '') => {
	console.log((ok ? 'ok   ' : 'FAIL ') + what + (ok || !detail ? '' : ': ' + detail));
	if (!ok) failures++;
};

fs.rmSync(work, { recursive: true, force: true });
fs.mkdirSync(path.join(work, 'src'), { recursive: true });
const main = path.join(work, 'src', 'Main.hx');
const source = (version) => `class Main {
	static function main() {
		var pid = Std.int((Sys.time() * 1000) % 1000000000);
		Sys.println("${version} pid=" + pid + " dev=" + (Sys.getEnv("HXMC_DEV") != null));
		while (true) Sys.sleep(0.1);
	}
}
`;
fs.writeFileSync(main, source('v1'));
fs.writeFileSync(path.join(work, 'build.hxml'), ['-cp src', '-main Main', `--custom-target hxmc=out/app${process.platform === 'win32' ? '.exe' : ''}`].join('\n') + '\n');

const lines = [];
const waiters = [];
const dev = spawn(process.execPath, [path.join(repo, 'packages/cli/hxmc/bootstrap/dev.mjs'), compiler, 'build.hxml'],
	{ cwd: work, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, HAXE_STD_PATH: process.env.HAXE_STD_PATH ?? path.join(repo, 'haxe/upstream/std') } });
const onLine = (l) => {
	lines.push(l);
	if (process.env.DEV_VERBOSE) console.log('  | ' + l);
	for (const w of [...waiters]) if (w.re.test(l)) {
		waiters.splice(waiters.indexOf(w), 1);
		w.resolve(l);
	}
};
for (const s of [dev.stdout, dev.stderr]) {
	let buf = '';
	s.on('data', (d) => {
		buf += d;
		let nl;
		while ((nl = buf.indexOf('\n')) >= 0) {
			onLine(buf.slice(0, nl));
			buf = buf.slice(nl + 1);
		}
	});
}
// the next line matching re (or one already printed, with past)
const line = (re, ms = 120000, past = false) => {
	if (past) {
		const l = lines.find((x) => re.test(x));
		if (l) return Promise.resolve(l);
	}
	const pr = new Promise((resolve, reject) => {
		const t = setTimeout(() => reject(new Error('timed out waiting for ' + re + '; the last lines:\n' + lines.slice(-30).join('\n'))), ms);
		waiters.push({ re, resolve: (l) => { clearTimeout(t); resolve(l); } });
	});
	pr.catch(() => {});
	return pr;
};
// (each build prints a stamp of its start: another build, another stamp)
const pidOf = (l) => /pid=(\d+)/.exec(l)?.[1];

try {
	const first = await line(/^v1 pid=\d+ dev=true/, 240000, true);
	check('the first build runs, with HXMC_DEV set', !!first);

	const v2 = line(/^v2 pid=/);
	fs.writeFileSync(main, source('v2'));
	const second = await v2;
	check('an edit: the new build runs, a new process', pidOf(second) !== pidOf(first), `${first} / ${second}`);
	check('an edit: the old build printed nothing after it', lines.filter((l) => l.startsWith('v1 ')).length === 1);

	const failed = line(/error|Error|Unexpected/);
	fs.writeFileSync(main, source('v3').replace('Sys.println(', 'Sys.println(undefinedThing + '));
	const err = await failed;
	check('a compile error: shown', /undefinedThing|Unknown identifier/.test(lines.slice(-20).join('\n')), err);
	await new Promise((r) => setTimeout(r, 1500));
	check('a compile error: no new build started', !lines.some((l) => l.startsWith('v3 ')));

	const v4 = line(/^v4 pid=/);
	fs.writeFileSync(main, source('v4'));
	const fourth = await v4;
	check('fixed: the new build runs', pidOf(fourth) !== pidOf(second), fourth);
} catch (e) {
	check('the dev loop', false, e.message);
}
const exited = new Promise((r) => dev.once('exit', r));
dev.kill('SIGINT');
await Promise.race([exited, new Promise((r) => setTimeout(r, 10000))]);
if (dev.exitCode === null && dev.signalCode === null) dev.kill('SIGKILL');
console.log(failures ? `dev-console: ${failures} failed` : 'dev-console: ok');
process.exit(failures ? 1 : 0);
