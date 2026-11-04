// `haxe --wait` on Node.js (haxe/nodejs/NodeServer.hx) against the reference's server,
// the reference as the client. make test-node-server, or after make node-server:
//   HAXE_REFERENCE=bin/reference/haxe node --test haxe/test/node-server.mjs
// HAXE_NODE_SERVER selects the server (default bin/node/haxe-server.cjs). No npm dependencies.
import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const out = path.join(root, 'bin/test/node-server');
const reference = [path.resolve(root, process.env.HAXE_REFERENCE ?? 'bin/reference/haxe')];
const node = [process.execPath, '--stack-size=65500', path.resolve(root, process.env.HAXE_NODE_SERVER ?? 'bin/node/haxe-server.cjs')];
const std = path.join(root, 'haxe/upstream/std');
const env = { ...process.env, HAXE_STD_PATH: std, HAXE_IN_HAXE_STD_PATH: std };
const servers = [];
let ref, nod;

function child(cmd, args, timeoutMs = 60_000) {
	const proc = spawn(cmd[0], [...cmd.slice(1), ...args], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
	const stdout = [], stderr = [];
	proc.stdout.on('data', b => stdout.push(b));
	proc.stderr.on('data', b => stderr.push(b));
	const timeout = timeoutMs > 0 ? setTimeout(() => proc.kill('SIGKILL'), timeoutMs) : null;
	const result = new Promise((resolve, reject) => {
		proc.once('error', reject);
		proc.once('close', (code, signal) => {
			clearTimeout(timeout);
			resolve({ code, signal, out: Buffer.concat(stdout), err: Buffer.concat(stderr) });
		});
	});
	return { proc, result };
}

const client = (srv, args) => child(reference, ['--connect', String(srv.port), ...args]).result;
const comparable = r => ({ code: r.code, out: r.out.toString(), err: r.err.toString() });
const normalizeJson = data => JSON.parse(data.toString().replace(/"timestamp":[0-9.e+-]+/g, '"timestamp":0'));

async function freePort() {
	const listener = net.createServer().listen(0, '127.0.0.1');
	await once(listener, 'listening');
	const { port } = listener.address();
	await new Promise(resolve => listener.close(resolve));
	return port;
}

async function startServer(name, cmd, args) {
	const port = await freePort();
	const p = child(cmd, args(port), 0);
	const srv = { ...p, name, port };
	servers.push(srv);
	for (let i = 0; i < 200; i++) {
		if (p.proc.exitCode != null) throw new Error(`${name} exited: ${(await p.result).err}`);
		// (the reference's server ends on a connection that closes without a request)
		if (process.platform === 'linux') {
			const hex = port.toString(16).padStart(4, '0').toUpperCase();
			if (fs.readFileSync('/proc/net/tcp', 'utf8').split('\n').some(line => {
				const f = line.trim().split(/\s+/);
				return f[1]?.endsWith(':' + hex) && f[3] === '0A';
			})) return srv;
		} else {
			const r = await child(reference, ['--connect', String(port), '--version']).result;
			if (r.code === 0) return srv;
		}
		await delay(50);
	}
	throw new Error(`${name} failed to listen`);
}

const startReference = name => startServer(name, reference, port => ['--wait', String(port)]);
const startNode = name => startServer(name, node, port => [String(port)]);

function readAll(socket) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		socket.on('data', b => chunks.push(b));
		socket.once('end', () => resolve(Buffer.concat(chunks)));
		socket.once('error', reject);
	});
}

before(async () => {
	fs.mkdirSync(out, { recursive: true });
	fs.writeFileSync(path.join(out, 'Main.hx'), 'class Main { static function main() { trace("héllo 世界 😀"); Sys.println([for (i in 0...5) i * i]); } }\n');
	fs.writeFileSync(path.join(out, 'JsMain.hx'), 'class JsMain { static function main() { trace([for (i in 0...5) "héllo " + i * i]); } }\n');
	fs.writeFileSync(path.join(out, 'Broken.hx'), 'class Broken { static function main() { var s:Int = "a"; } }\n');
	fs.writeFileSync(path.join(out, 'TransportMacro.hx'), `class TransportMacro {
		public static function read() { Sys.stdin().readByte(); }
		public static function bytes() {
			var o = Sys.stdout();
			for (i in 0...1023) o.writeByte(120);
			o.writeByte(0xe2); o.flush();
			o.writeByte(0x82); o.writeByte(0xac); o.flush();
		}
		public static function string() {
			var o = Sys.stdout();
			for (i in 0...1023) o.writeByte(120);
			o.writeString("€" + [for (i in 0...1000) "ü😀"].join(""));
		}
	}`);
	fs.writeFileSync(path.join(out, 'UnsupportedThread.hx'), `class UnsupportedThread {
		static function main() { sys.thread.Thread.create(() -> {}); }
	}`);
	ref = await startReference('reference');
	nod = await startNode('node');
});

after(async () => {
	for (const srv of servers) {
		srv.proc.kill();
		const result = await srv.result;
		fs.writeFileSync(path.join(out, srv.name + '.log'), Buffer.concat([result.out, result.err]));
	}
});

test('requests answer as the reference server does', async () => {
	const requests = [
		['--version'],
		['-cp', out, '-main', 'Main', '--no-output', '--macro', "Sys.println('héllo 世界 😀')"],
		['-main', 'MissingClass', '--no-output'],
		['-cp', out, '-main', 'Broken', '--no-output'],
		['-cp', out, '-main', 'Main', '--interp'],
		['-cp', out, '-main', 'Main', '--interp'],
		['--display', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })],
	];
	for (const args of requests) {
		const expected = await client(ref, args), actual = await client(nod, args);
		assert.equal(actual.code, expected.code, args.join(' '));
		assert.deepEqual(actual.out.toString(), expected.out.toString(), args.join(' '));
		if (args.includes('--display')) assert.deepEqual(normalizeJson(actual.err), normalizeJson(expected.err));
		else assert.deepEqual(actual.err.toString(), expected.err.toString(), args.join(' '));
	}
});

test('a JavaScript build writes what the reference server writes', async () => {
	const outputs = [];
	for (const srv of [ref, nod]) {
		const file = path.join(out, `main-${srv.name}.js`);
		const result = await client(srv, ['-cp', out, '-main', 'JsMain', '--js', file]);
		assert.equal(result.code, 0, result.err.toString());
		outputs.push(fs.readFileSync(file, 'utf8'));
	}
	assert.equal(outputs[1], outputs[0]);
});

test('output keeps UTF-8 across flushes and chunk boundaries', async () => {
	for (const macro of ['bytes', 'string']) {
		const args = ['-cp', out, '--macro', `TransportMacro.${macro}()`];
		const expected = await client(ref, args), actual = await client(nod, args);
		assert.equal(actual.code, 0, actual.err.toString());
		assert.deepEqual(actual.out, expected.out);
	}
});

test('requests may arrive byte by byte; incomplete ones are dropped', async () => {
	const socket = net.connect(nod.port, '127.0.0.1');
	await once(socket, 'connect');
	socket.end('--vers');
	await delay(100);
	socket.destroy();
	const conn = net.connect(nod.port, '127.0.0.1');
	const result = readAll(conn);
	await once(conn, 'connect');
	for (const byte of Buffer.from("--macro\nSys.println('héllo 世界 😀')\n\0")) {
		conn.write(Buffer.from([byte]));
		await delay(1);
	}
	const data = (await result).toString();
	assert.ok(data.includes('\x01héllo 世界 😀\x01\n'), JSON.stringify(data));
	assert.ok(!data.includes('\x02'));
});

test('display hover reads unsaved source from the request', async () => {
	const file = path.join(out, 'Unsaved.hx');
	fs.writeFileSync(file, 'class Unsaved {}\n');
	const source = 'class Unsaved { static function main() { var uniqueName = "unsaved"; uniqueName; } }';
	const rpc = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'display/hover', params: { file, offset: source.lastIndexOf('uniqueName') + 2 } });
	const payload = ['--cwd', out, '-cp', out, '-D', 'display-stdin', '--no-output', '--display', rpc].join('\n') + '\n\x01' + source + '\0';
	const replies = [];
	// fresh servers: the IDs of variables depend on what the server compiled before
	for (const srv of [await startReference('reference-display'), await startNode('node-display')]) {
		const socket = net.connect(srv.port, '127.0.0.1');
		const result = readAll(socket);
		socket.end(payload);
		replies.push(normalizeJson(await result));
	}
	assert.deepEqual(replies[1], replies[0]);
	assert.match(JSON.stringify(replies[1]), /String/);
});

test('unsupported stdin and threads fail the request, not the server', async () => {
	const stdin = await client(nod, ['-cp', out, '--macro', 'TransportMacro.read()']);
	assert.notEqual(stdin.code, 0);
	const thread = await client(nod, ['-cp', out, '-main', 'UnsupportedThread', '--interp']);
	assert.notEqual(thread.code, 0);
	assert.match(thread.err.toString(), /Thread.create is not supported/);
	assert.deepEqual(comparable(await client(nod, ['--version'])), comparable(await client(ref, ['--version'])));
});

test('simultaneous clients all receive responses', async () => {
	const expected = await client(ref, ['-cp', out, '-main', 'Main', '--interp']);
	const results = await Promise.all(Array.from({ length: 8 }, () => client(nod, ['-cp', out, '-main', 'Main', '--interp'])));
	for (const result of results) assert.deepEqual(comparable(result), comparable(expected));
});

test('a client that goes away does not stop the server', async () => {
	const socket = net.connect(nod.port, '127.0.0.1');
	await once(socket, 'connect');
	socket.write(`-cp\n${out}\n-main\nMain\n--interp\n\0`);
	socket.destroy();
	await delay(200);
	assert.equal((await client(nod, ['--version'])).code, 0);
});
