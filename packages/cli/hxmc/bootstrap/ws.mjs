// Minimal WebSocket (RFC 6455) text frames for ESM hot dev (no npm deps).
import crypto from 'node:crypto';
import http from 'node:http';
import net from 'node:net';

export function wsEncode(text) {
	const b = Buffer.from(text, 'utf8');
	const head = b.length < 126
		? Buffer.from([0x81, b.length])
		: b.length < 65536
			? Buffer.from([0x81, 126, b.length >> 8, b.length & 255])
			: Buffer.concat([Buffer.from([0x81, 127]), (() => {
				const x = Buffer.alloc(8);
				x.writeBigUInt64BE(BigInt(b.length));
				return x;
			})()]);
	return Buffer.concat([head, b]);
}

function decodeFrames(buf, onText) {
	let at = 0;
	while (at + 2 <= buf.length) {
		const op = buf[at] & 15;
		let len = buf[at + 1] & 127;
		let header = 2;
		if (len === 126) {
			if (at + 4 > buf.length) break;
			len = buf.readUInt16BE(at + 2);
			header = 4;
		} else if (len === 127) {
			if (at + 10 > buf.length) break;
			len = Number(buf.readBigUInt64BE(at + 2));
			header = 10;
		}
		const masked = buf[at + 1] & 128;
		const need = header + (masked ? 4 : 0) + len;
		if (at + need > buf.length) break;
		let payloadAt = at + header;
		if (masked) {
			const mask = buf.subarray(payloadAt, payloadAt + 4);
			payloadAt += 4;
			const data = Buffer.from(buf.subarray(payloadAt, payloadAt + len));
			for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
			if (op === 1) onText(data.toString('utf8'));
		} else if (op === 1) {
			onText(buf.toString('utf8', payloadAt, payloadAt + len));
		}
		at += need;
	}
	return buf.subarray(at);
}

/** @returns {Promise<{ close: () => void, broadcast: (text: string) => void, attachUpgrade: (handler) => void, httpServer: http.Server, clients: Set }>} */
export async function createHotWsServer(port, host = '127.0.0.1', { existingServer = null } = {}) {
	const clients = new Set();
	const server = existingServer ?? http.createServer((_req, res) => {
		res.writeHead(404);
		res.end();
	});
	const onUpgrade = (req, sock) => {
		if (new URL(req.url, 'http://x').pathname !== '/__esm_hot/ws') return sock.destroy();
		const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
		sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
		let buf = Buffer.alloc(0);
		const send = (text) => {
			if (!sock.destroyed) sock.write(wsEncode(text));
		};
		sock.on('data', (d) => {
			buf = decodeFrames(Buffer.concat([buf, d]), (text) => {
				try {
					const m = JSON.parse(text);
					if (m.type === 'log') console.log(m.text);
					if (m.type === 'frame') { /* timing in dev-esm */ }
				} catch {}
			});
		});
		clients.add({ sock, send });
		const gone = () => {
			for (const c of clients) if (c.sock === sock) clients.delete(c);
		};
		sock.on('close', gone);
		sock.on('error', gone);
	};
	server.on('upgrade', onUpgrade);
	const api = {
		close: () => server.close(),
		broadcast: (text) => {
			const frame = wsEncode(text);
			for (const c of clients) if (!c.sock.destroyed) c.sock.write(frame);
		},
		httpServer: server,
		clients,
	};
	if (existingServer) return api;
	return new Promise((resolve, reject) => {
		server.listen(port, host, () => resolve(api));
		server.on('error', reject);
	});
}

/** @returns {Promise<(text: string) => void>} */
export function connectHotWs(port, host = '127.0.0.1', onMessage) {
	return new Promise((resolve, reject) => {
		const key = crypto.randomBytes(16).toString('base64');
		const req = [
			'GET /__esm_hot/ws HTTP/1.1',
			`Host: ${host}:${port}`,
			'Upgrade: websocket',
			'Connection: Upgrade',
			`Sec-WebSocket-Key: ${key}`,
			'Sec-WebSocket-Version: 13',
			'',
			'',
		].join('\r\n');
		const sock = net.connect(port, host, () => sock.write(req));
		let upgraded = false;
		let buf = Buffer.alloc(0);
		let send = null;
		const onData = (d) => {
			buf = Buffer.concat([buf, d]);
			if (!upgraded) {
				const headerEnd = buf.indexOf('\r\n\r\n');
				if (headerEnd < 0) return;
				if (!buf.toString('utf8', 0, headerEnd).includes('101')) {
					reject(new Error('WebSocket upgrade failed'));
					sock.destroy();
					return;
				}
				upgraded = true;
				const rest = buf.subarray(headerEnd + 4);
				buf = Buffer.alloc(0);
				send = (text) => {
					if (!sock.destroyed) sock.write(wsEncode(text));
				};
				sock.removeListener('data', onData);
				sock.on('data', (chunk) => {
					buf = decodeFrames(Buffer.concat([buf, chunk]), (text) => onMessage && onMessage(text));
				});
				resolve(send);
				if (rest.length) buf = decodeFrames(rest, (text) => onMessage && onMessage(text));
			}
		};
		sock.on('data', onData);
		sock.on('error', reject);
	});
}