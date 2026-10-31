// A compilation server's builds of small programs are fresh builds (make
// dev-check): each case is a program a
// server of its own builds, then builds again after each edit, its typed
// modules kept in memory (as `hxmc dev` asks) and then read back from HXB
// (the default); each build's output must be the bytes a one-shot build of
// the same sources makes (and on macOS, an Objective-C program built for the
// machine runs as the fresh one does). What it checks is an edit that makes
// the program use code it did not use before while hxmc's LowerCache replays
// the bodies of the modules not typed again.
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
	// a dispatched call leaving out an argument gets the default of the
	// override the receiver runs (FnLower.receiverDefault): Lib's body,
	// replayed (Lib does not depend on Sub, so it is not typed again), has
	// Sub's default value, which the edit of Sub changes (LowerQueries.fieldDefaults)
	"an override's default value, in a replayed dispatched call": [
		{
			'Lib.hx': 'class Base {\n\tpublic function new() {}\n\tpublic function f(x:Int = 1):Int\n\t\treturn x;\n}\n\nclass Lib {\n\tpublic static function call(b:Base):Int\n\t\treturn b.f();\n}\n',
			'Sub.hx': 'class Sub extends Lib.Base {\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\toverride public function f(x:Int = 2):Int\n\t\treturn x * 10;\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call(new Sub()) + Lib.call(new Lib.Base()));\n\t}\n}\n',
		},
		{ 'Sub.hx': 'class Sub extends Lib.Base {\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\toverride public function f(x:Int = 3):Int\n\t\treturn x * 10;\n}\n' },
	],
	// a C function's declaration (CInterop.declare: its signature, whether
	// its calls stay outside the safe region) is the program's: an edit of
	// it is the new one, not checked against the previous build's, and a
	// replayed body calling it declares it again (LowerQueries.cExtern)
	'a C function declared again, @:hxmc.fast, called by a replayed body': [
		{
			'CLib.hx': 'extern class CLib {\n\t@:hxmc.c("getpid") static function getpid():Int;\n}\n',
			'Lib.hx': 'class Lib {\n\tpublic static function pid():Int\n\t\treturn CLib.getpid();\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.pid() > 0);\n\t}\n}\n',
		},
		{ 'CLib.hx': 'extern class CLib {\n\t@:hxmc.c("getpid") @:hxmc.fast static function getpid():Int;\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.pid() != 0);\n\t}\n}\n' },
		{ 'CLib.hx': 'extern class CLib {\n\t@:hxmc.c("getpid") static function getpid():Int;\n}\n' },
	],
};

// the cases built for this machine and run (their arguments), the server's
// output as the fresh one
const runs = new Map();
// Objective-C (macOS only): what Lib's bodies declare for the link (a
// message's C function, libobjc's functions, a class's framework, a
// category's: LowerQueries.objcDeclare) and read of a Haxe class extending
// an Objective-C one (its registration, its id fields: LowerQueries.objcPeer
// and idFields), replayed after an edit of Main alone
if (process.platform === 'darwin' && !web) {
	const name = 'Objective-C messages and a Haxe subclass, in replayed bodies';
	runs.set(name, ['-D', 'hxmc.target=macos-' + (process.arch === 'arm64' ? 'arm64' : 'x86_64')]);
	cases[name] = [
		{
			'Lib.hx': `import hxmc.unsafe.CString;

@:hxmc.struct class Rect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:hxmc.framework("Foundation") function description():NSString;
}
@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	var UTF8String(get, never):CString;
	function get_UTF8String():CString;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
	static function alloc():NSView;
	function initWithFrame(frame:Rect):NSView;
	var flipped(get, never):Bool;
	@:selector("isFlipped") function get_flipped():Bool;
	function addSubview(v:NSView):Void;
}
class Flipped extends NSView {
	public var child:Null<NSView>;
	public function new(r:Rect) super.initWithFrame(r);
	override function get_flipped() return true;
}
class Lib {
	public static function run():String {
		var f = new Flipped(new Rect(0, 0, 10, 10));
		f.child = NSView.alloc().initWithFrame(new Rect(0, 1, 2, 2));
		f.addSubview(f.child);
		return NSObject.alloc().init().description().UTF8String.toString().substr(0, 10) + " " + (f : NSView).flipped;
	}
}
`,
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.run());\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace("again " + Lib.run());\n\t}\n}\n' },
	];
}

const out = web ? 'out/app.wasm' : process.platform === 'win32' ? 'out/app.exe' : 'out/app';
const ref = 'ref/' + path.basename(out);
const args = (o, more = []) => [...more, '-cp', 'src', '-main', 'Main', ...(web ? ['-D', 'hxmc.target=wasm32-wasi'] : process.platform === 'linux' ? ['-D', 'hxmc.libc=glibc'] : []),
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
				const answer = await request(work, [...args(out, runs.get(name)), ...(hxb ? [] : ['-D', 'disable-hxb-cache'])]);
				const fresh = spawnSync(compiler, args(ref, runs.get(name)), { cwd: work, env, encoding: 'utf8' });
				let same = !answer.includes('\x02') && fresh.status === 0 && Buffer.compare(fs.readFileSync(path.join(work, out)), fs.readFileSync(path.join(work, ref))) === 0;
				// (and the server's output runs as the fresh one does)
				const ran = same && runs.has(name) ? [out, ref].map((o) => spawnSync(path.join(work, o), { cwd: work, encoding: 'utf8' })) : null;
				if (ran) same = ran[0].status === 0 && ran[0].stdout === ran[1].stdout;
				const what = `${name} (${mode}${hxb ? ', HXB' : ''}): ` + (i === 0 ? 'the first build' : `edit ${i}`);
				console.log((same ? 'ok   ' : 'FAIL ') + what);
				if (!same) {
					failures++;
					console.log(answer.includes('\x02') ? answer + serverOutput() : fresh.status !== 0 ? fresh.stdout + fresh.stderr : ran ? `the run: exit ${ran[0].status}\n${ran[0].stdout}${ran[0].stderr}` : 'the outputs differ');
				}
			}
		});
		fs.rmSync(work, { recursive: true, force: true });
	}
console.log(failures === 0 ? 'server-verify: ok' : `server-verify: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
