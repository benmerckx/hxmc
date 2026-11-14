// The build's entry: node (22+) and git are all it needs, on Linux, macOS and
// Windows alike (docs/development.md):
//   node make.mjs <target>... [NAME=value]...     node make.mjs help: the targets
// It runs tools/make/Make.hx on the tool's Eval (bin/hxmc/hxmc). Without a
// tool yet, first the stage-1 compiler from the committed stage0, all under
// node: the runtime objects (hxmc/bootstrap/rt.mjs fetch), the std
// (hxmc.MkStd) and bin/hxmc/boot/hxmc1 (--stage1 alone: that, which Make's
// bootstrap runs again); Make then builds the tool with it.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
process.chdir(root);

// the machine the tool runs on (Make.host's)
const HOST = `${{ win32: 'windows', darwin: 'macos' }[process.platform] ?? 'linux'}-${os.arch() === 'arm64' ? 'arm64' : 'x86_64'}`;
const EXE = HOST.startsWith('windows') ? '.exe' : '';
const TOOL = `bin/hxmc/hxmc${EXE}`, BOOT = `bin/hxmc/boot/hxmc1${EXE}`;
const STAGE0 = 'hxmc/bootstrap/stage0.wasm.br';
// (Make.TOOL_ARGS)
const TOOL_ARGS = ['-cp', 'haxe/src', '-cp', 'hxmc/src', '-main', 'hxmc.Main', '-D', 'disable-parallelism', '-D', 'hih_no_generators', '-cp', 'bin/hxmc/std', '-D', 'hxmc.gc-prefault', '--custom-target', 'hxmc'];

const env = { ...process.env, HAXE_STD_PATH: path.join(root, 'haxe/upstream/std'), HXMC_RT_DIR: path.join(root, 'bin/hxmc/rt') };

function run(cmd, args, log) {
	console.log([cmd, ...args].join(' '));
	const fd = log ? fs.openSync(log, 'w') : null;
	const r = spawnSync(cmd, args, { env, stdio: log ? ['ignore', fd, fd] : 'inherit' });
	if (fd !== null) fs.closeSync(fd);
	if (r.status !== 0) {
		if (log) process.stdout.write(fs.readFileSync(log));
		console.error(`make.mjs: ${cmd} failed${r.error ? `: ${r.error.message}` : ''}`);
		process.exit(r.status || 1);
	}
}

// the stage0 module under node, on a thread with a stack for the compiler's
// recursion (hxmc/bootstrap/wasi.mjs)
const stage0 = (args, log) => run(process.execPath, ['--stack-size=65500', 'hxmc/bootstrap/wasi.mjs', STAGE0, ...args], log);

// the host's runtime objects: the release of this hxmc/deps, else (Linux
// x86-64, with zig and a POSIX shell) built here as Make's rt-build starts
// (true: built)
function hostRt() {
	if (fs.existsSync(`bin/hxmc/rt/${HOST}/rt.o`)) return false;
	const r = spawnSync(process.execPath, ['hxmc/bootstrap/rt.mjs', 'fetch', 'bin/hxmc/rt'], { env, stdio: 'inherit' });
	if (r.status === 0) return false;
	if (r.status !== 2) process.exit(r.status || 1);
	if (HOST !== 'linux-x86_64') {
		console.error('make.mjs: no release of these runtime objects: build them on Linux x86-64 (node make.mjs rt-build, with zig)');
		process.exit(1);
	}
	run('sh', ['hxmc/deps/deps.sh', HOST, `bin/hxmc/deps/${HOST}`]);
	const stamp = `bin/hxmc/deps/${HOST}/VERSIONS`;
	fs.closeSync(fs.openSync(stamp, 'a'));
	fs.utimesSync(stamp, new Date(), new Date());
	run('sh', ['hxmc/deps/mkrt.sh', HOST]);
	return true;
}

function stage1() {
	stage0(['-cp', 'hxmc/src', '--run', 'hxmc.MkStd']);
	fs.mkdirSync('bin/hxmc/boot', { recursive: true });
	// (written beside a stage-1 compiler that may be running, then moved over it)
	const out = fs.existsSync(BOOT) ? `bin/hxmc/boot/hxmc1.new${EXE}` : BOOT;
	stage0([out, ...TOOL_ARGS, '-D', `hxmc.target=${HOST}`], 'bin/hxmc/boot/hxmc1.log');
	if (out !== BOOT) {
		const gone = `${BOOT}.old`;
		fs.rmSync(gone, { force: true });
		fs.renameSync(BOOT, gone);
		try { fs.rmSync(gone, { force: true }); } catch { }
		fs.renameSync(out, BOOT);
	}
	if (!EXE) fs.chmodSync(BOOT, 0o755);
	console.log(`${BOOT}: ${fs.statSync(BOOT).size} bytes`);
}

const args = process.argv.slice(2);
if (args[0] === '--stage1') {
	stage1();
	process.exit(0);
}
const fresh = [];
if (!fs.existsSync(TOOL) && !fs.existsSync(BOOT)) {
	if (hostRt()) fresh.push('--fresh-rt');
	stage1();
	fresh.push('--fresh-stage1');
}
const evalTool = fs.existsSync(TOOL) ? TOOL : BOOT;
const make = [evalTool, '-cp', 'tools/make', '-cp', 'haxe/test', '--run', 'Make', ...fresh, ...args];
// (Linux and macOS: the stack limit lifted for what Make runs, as the
// Makefile's recipes had it: the reference compiler's deep recursion; node's
// is wasi.mjs's thread's. The tool and the port reserve their own.)
const r = EXE ? spawnSync(make[0], make.slice(1), { env, stdio: 'inherit' })
	: spawnSync('/bin/sh', ['-c', 'ulimit -s unlimited 2>/dev/null || true; exec "$0" "$@"', ...make], { env, stdio: 'inherit' });
if (r.error) console.error(`make.mjs: ${evalTool}: ${r.error.message}`);
process.exit(r.status ?? 1);
