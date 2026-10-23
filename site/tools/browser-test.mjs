// The site in real browsers (Playwright: chromium, firefox, webkit), after
// `make site` (make site-check):
// - links: every page's links, scripts and stylesheets point at files of the
//   site (or outside it), and every #anchor at an element of its page;
// - pages: every page at a desktop's width and at a phone's (390 px): no
//   script error, no console error, no failed request, no horizontal
//   scrolling;
// - the playground's compiler: its worker (site/client/Worker.hx) runs a
//   program with --interp, compiles it to HXB, answers diagnostics and a
//   completion, with each module (hih.wasm: exnref; hih-legacy.wasm: the
//   legacy instructions), and in Chromium runs a request again after a
//   fault of the engine (fault-worker.js); the playground page (Monaco
//   blocked: its plain editor) picks its module (?eh=legacy, and a Chromium
//   without exnref) and runs its first example;
// - the benchmarks page: the compiler's and the Programs' charts (each
//   series charted from 10 runs on, the section's charts hidden before) with
//   a tooltip (hover, or a tap on a phone), and the latest runs' tables;
//   light and dark, and at a phone's width.
// Screenshots into $SCREENSHOTS when set.
//   node site/tools/browser-test.mjs bin/site [chromium firefox webkit]
import { createServer } from 'node:http';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
let pw;
try { pw = require('playwright'); } catch { pw = require(path.join(process.execPath, '../../lib/node_modules/playwright')); }
const dir = process.argv[2];
const names = process.argv.length > 3 ? process.argv.slice(3) : ['chromium', 'firefox', 'webkit'];
const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html', '.css': 'text/css',
	'.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf' };
const modules = ['hih.wasm', 'hih-legacy.wasm'].filter((m) => existsSync(path.join(dir, m)));
const toolsDir = path.dirname(fileURLToPath(import.meta.url));
const server = createServer(async (req, res) => {
	let u = decodeURIComponent(new URL(req.url, 'http://x').pathname);
	if (u.endsWith('/') && u !== '/') u += 'index.html';
	const p = u === '/fault-worker.js' ? path.join(toolsDir, 'fault-worker.js') : path.join(dir, u);
	try {
		const b = u === '/' ? Buffer.from('<!doctype html><title>test</title>') : await readFile(p);
		res.writeHead(200, { 'content-type': u === '/' ? 'text/html' : types[path.extname(p)] || 'application/octet-stream' });
		res.end(b);
	} catch {
		res.writeHead(404);
		res.end();
	}
}).listen(0);
const port = server.address().port;
const url = (p) => `http://localhost:${port}/${p}`;
const shots = process.env.SCREENSHOTS;
let failed = 0;
const check = (ok, what) => {
	console.log(`  ${ok ? 'ok' : 'FAILED'}: ${what}`);
	if (!ok) failed++;
	return ok;
};

// --- links ---

function htmlPages(rel = '') {
	const out = [];
	for (const n of readdirSync(path.join(dir, rel)).sort()) {
		const r = rel ? `${rel}/${n}` : n;
		if (statSync(path.join(dir, r)).isDirectory()) out.push(...htmlPages(r));
		else if (n.endsWith('.html')) out.push(r);
	}
	return out;
}
const PAGES = htmlPages();

function linkCheck() {
	const ids = new Map();
	const idsOf = (page) => {
		if (!ids.has(page)) ids.set(page, new Set([...readFileSync(path.join(dir, page), 'utf8').matchAll(/\sid="([^"]*)"/g)].map((m) => m[1])));
		return ids.get(page);
	};
	// (files the site's build adds only with LIX_DIR or BENCH_DATA)
	const optional = (f) => f.startsWith('tools/lix-') || f.startsWith('bench/');
	const broken = [];
	let n = 0;
	for (const page of PAGES) {
		const html = readFileSync(path.join(dir, page), 'utf8');
		const refs = [];
		for (const m of html.matchAll(/\s(?:href|src|data-src|data-wasm|data-runner)="([^"]*)"/g)) refs.push(m[1]);
		for (const m of html.matchAll(/\sdata-(?:imports|fonts)="([^"]*)"/g)) refs.push(...JSON.parse(m[1].replace(/&quot;/g, '"')));
		for (let ref of refs) {
			ref = ref.replace(/&amp;/g, '&');
			if (/^(https?:|mailto:|data:)/.test(ref)) continue;
			n++;
			const [p, hash] = ref.split('#');
			const file = p === '' ? page : path.posix.normalize(path.posix.join(path.posix.dirname(page), p.split('?')[0])).replace(/\/$/, '/index.html');
			if (optional(file)) continue;
			if (!existsSync(path.join(dir, file)) || statSync(path.join(dir, file)).isDirectory()) broken.push(`${page}: ${ref} (no ${file})`);
			else if (hash && file.endsWith('.html') && !idsOf(file).has(decodeURIComponent(hash))) broken.push(`${page}: ${ref} (no #${hash})`);
		}
		// (and each id once)
		const seen = new Set();
		for (const m of html.matchAll(/\sid="([^"]*)"/g)) {
			if (seen.has(m[1])) broken.push(`${page}: id ${m[1]} twice`);
			seen.add(m[1]);
		}
	}
	for (const b of broken.slice(0, 40)) console.log('    ' + b);
	check(broken.length === 0, `links: ${n} links of ${PAGES.length} pages, ${broken.length} broken`);
}

// --- pages ---

const optionalUrl = (u) => /\/bench\/[^/]*\.json/.test(new URL(u).pathname);

// an uncaught error's stack as the page sees it, WebAssembly frames included
// (a pageerror's stack has only the JavaScript ones), as a console error
const stacks = () => addEventListener('error', (e) => e.error?.stack && console.error('stack: ' + e.error.stack.split('\n').slice(0, 24).join(' < ')));

// a page loaded and scrolled through; {errors, scroll}
async function visit(page, p) {
	const errors = [];
	page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
	page.on('crash', () => errors.push('the page crashed'));
	await page.addInitScript(stacks);
	// (a missing file by its address, not the console's message; the editor
	// from the CDN is blocked, the benchmark history optional)
	page.on('console', (m) => m.type() === 'error' && !m.text().startsWith('Failed to load resource') && errors.push(m.text()));
	page.on('response', (r) => r.status() >= 400 && !optionalUrl(r.url()) && errors.push(`${r.status()} ${r.url()}`));
	page.on('requestfailed', (r) => !/cdn\.jsdelivr\.net/.test(r.url()) && !optionalUrl(r.url()) && errors.push(`failed ${r.url()}`));
	await page.route(/^https:\/\/cdn\.jsdelivr\.net\//, (r) => r.abort());
	await page.goto(url(p));
	const h = await page.evaluate(() => document.documentElement.scrollHeight);
	for (let y = 0; y < h; y += 500) {
		await page.evaluate((y) => scrollTo(0, y), y);
		await page.waitForTimeout(60);
	}
	await page.waitForTimeout(300);
	const scroll = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
	return { errors, scroll };
}

async function pagesTest(browser, name) {
	for (const width of [1280, 390]) {
		const context = await browser.newContext({ viewport: { width, height: width < 600 ? 844 : 900 }, ...(width < 600 && name !== 'firefox' ? { isMobile: true, hasTouch: true } : {}) });
		const bad = [];
		for (const p of PAGES) {
			const page = await context.newPage();
			let r;
			try {
				r = await visit(page, p);
			} catch (e) {
				r = { errors: [e.message.split('\n')[0]], scroll: 0 };
			}
			if (r.errors.length > 0 || r.scroll > 0) bad.push(`${p}: ${JSON.stringify(r)}`);
			if (shots) await page.screenshot({ path: path.join(shots, `page-${name}-${width}-${p.replace(/\//g, '_')}.png`), fullPage: true });
			await page.close();
		}
		for (const b of bad) console.log('    ' + b.slice(0, 2000));
		check(bad.length === 0, `pages at ${width} px: ${PAGES.length - bad.length} of ${PAGES.length} without errors or horizontal scrolling`);
		await context.close();
	}
}

// --- the playground ---

const code = 'class Main {\n\tstatic function main() {\n\t\tvar a = [for (i in 0...5) i * i];\n\t\ttrace("Hello " + a);\n\t\ttry throw "oops" catch (e:String) Sys.println("caught " + e);\n\t\tSys.println(haxe.Json.stringify({ok: true}));\n\t}\n}\n';

async function inPage([code, wasm]) {
	const w = new Worker('worker.js');
	const replies = [];
	let wake = null;
	w.onmessage = (e) => { replies.push(e.data); if (wake) wake(); };
	w.onerror = (e) => { replies.push({ type: 'failed', message: e.message }); if (wake) wake(); };
	async function until(pred) {
		while (true) {
			const i = replies.findIndex(pred);
			if (i >= 0) return replies.splice(i, 1)[0];
			await new Promise((r) => (wake = r));
		}
	}
	const log = [];
	const t0 = performance.now();
	w.postMessage({ type: 'module', module: await WebAssembly.compileStreaming(fetch(wasm)) });
	w.postMessage({ type: 'warmup' });
	const ready = await until((r) => r.type === 'ready' || r.type === 'failed');
	log.push(`ready ${ready.type} ${ready.message ?? ''} ${Math.round(performance.now() - t0)} ms`);
	if (ready.type === 'failed') return log;
	// (three times: the engines optimize the module's code while it runs)
	for (let k = 0; k < 3; k++) {
		w.postMessage({ type: 'compile', id: 1, mode: 'run', main: 'Main', file: 'Main.hx', code });
		const done = await until((r) => r.type === 'done' || r.type === 'failed');
		for (const r of replies.splice(0)) if (k == 0) log.push(`${r.type} ${r.text}`);
		log.push(`run ${done.status} ${Math.round(done.ms)} ms ${done.message ?? ''}`);
	}
	w.postMessage({ type: 'compile', id: 2, mode: 'hxb', main: 'Main', file: 'Main.hx', code });
	const hxb = await until((r) => r.type === 'done' || r.type === 'failed');
	replies.splice(0);
	log.push(`hxb ${hxb.status} ${hxb.zip ? hxb.zip.byteLength + ' bytes' : hxb.message} ${Math.round(hxb.ms)} ms`);
	w.postMessage({ type: 'check', id: 3, main: 'Main', file: 'Main.hx', code: code.replace('trace(', 'trace(undefinedThing + ') });
	const check = await until((r) => r.type === 'check' || r.type === 'failed');
	log.push(`check ${check.status} ${JSON.stringify(check.output)}`);
	const at = code.indexOf(' + a') + 4;
	const dcode = code.slice(0, at) + '.' + code.slice(at);
	w.postMessage({ type: 'display', id: 4, main: 'Main', file: 'Main.hx', code: dcode,
		request: { jsonrpc: '2.0', id: 1, method: 'display/completion', params: { file: '/work/Main.hx', offset: at + 1, wasAutoTriggered: true } } });
	const disp = await until((r) => r.type === 'display' || r.type === 'failed');
	log.push(`display ${disp.status} ${(disp.output ?? disp.message).slice(0, 120)}`);
	w.terminate();
	return log;
}

// the worker after a fault of the engine (WebKit 26.0 at times faults in
// correct code; fault-worker.js fakes one): the request runs again in a
// fresh instance, and its reply is the second run's
async function faultTest(browser, wasm) {
	const page = await browser.newPage();
	await page.goto(url(''));
	const r = await page.evaluate(async ([code, wasm]) => {
		const w = new Worker('fault-worker.js');
		const replies = [];
		let wake = null;
		w.onmessage = (e) => { replies.push(e.data); if (wake) wake(); };
		const until = async (pred) => { for (;;) { const i = replies.findIndex(pred); if (i >= 0) return replies.splice(i, 1)[0]; await new Promise((r) => (wake = r)); } };
		w.postMessage({ type: 'module', module: await WebAssembly.compileStreaming(fetch(wasm)) });
		w.postMessage({ type: 'warmup' });
		await until((r) => r.type === 'ready' || r.type === 'failed');
		w.postMessage({ type: 'compile', id: 1, mode: 'run', main: 'Main', file: 'Main.hx', code });
		const done = await until((r) => r.type === 'done' || r.type === 'failed');
		w.terminate();
		return { type: done.type, status: done.status, message: done.message, out: replies.filter((r) => r.type === 'out').map((r) => r.text) };
	}, [code, wasm]).catch((e) => ({ message: e.message.split('\n')[0] }));
	await page.close();
	check(r.type === 'done' && r.status === 0 && r.out?.[0]?.startsWith('Main.hx:4: Hello'), `the worker after a fault of the engine (${wasm}): ${JSON.stringify(r).slice(0, 300)}`);
}

// the playground page: the module it fetches, then a Run of the example it loads
async function pageTest(browser, query, expect) {
	const page = await browser.newPage();
	const fetched = [];
	// (what the page and its workers said: on a failure, with where it stood)
	const said = [];
	page.on('request', (r) => { const p = new URL(r.url()).pathname; if (/^\/hih(-legacy)?\.wasm$/.test(p)) fetched.push(path.basename(p)); });
	page.on('pageerror', (e) => said.push('pageerror: ' + e.message));
	page.on('console', (m) => said.push(`console.${m.type()}: ${m.text()}`));
	page.on('crash', () => said.push('the page crashed'));
	page.on('worker', (w) => w.on('close', () => said.push('a worker closed')));
	await page.addInitScript(stacks);
	await page.route(/^https:\/\/cdn\.jsdelivr\.net\//, (r) => r.abort());
	let ready = '', run = '', stage = 'loading';
	try {
		await page.goto(url('playground.html' + query));
		await page.waitForFunction(() => /^Ready|cannot|could not/.test(document.getElementById('state').textContent), null, { timeout: 180000 });
		ready = await page.evaluate(() => document.getElementById('state').textContent);
		if (ready.startsWith('Ready')) {
			stage = 'the example';
			await page.waitForFunction(() => document.querySelector('textarea[aria-label="Haxe source"]')?.value, null, { timeout: 30000 });
			stage = 'running';
			await page.click('#run');
			// (its exit, or the compiler instance failing: Playground.hx prints that and starts a new one)
			await page.waitForFunction(() => /^exit/.test(document.getElementById('timing').textContent) || /The compiler instance failed/.test(document.getElementById('out').textContent), null, { timeout: 180000 });
			run = await page.evaluate(() => {
				const timing = document.getElementById('timing').textContent, out = document.getElementById('out').textContent.trim();
				return /^exit/.test(timing) ? timing + ': ' + out.split('\n')[0] : 'failed: ' + out.slice(0, 3000);
			});
			if (!run.startsWith('exit')) for (const l of said) console.log('    ' + l.slice(0, 2000));
		}
	} catch (e) {
		const at = await page.evaluate(() => ['state', 'timing', 'out'].map((id) => `${id}: ${JSON.stringify((document.getElementById(id)?.textContent ?? "").slice(0, 3000))}`).join(', ')).catch(() => 'the page is gone');
		run = `${e.message.split('\n')[0]} (${stage}; ${at})`;
		for (const l of said) console.log('    ' + l.slice(0, 2000));
	}
	await page.close().catch(() => {});
	return check(fetched.length === 1 && fetched[0] === expect && run.startsWith('exit 0'), `playground.html${query}: fetched ${fetched.join(', ') || 'nothing'} (expected ${expect}); ${ready}; ${run}`);
}

// the benchmarks page: the compiler's charts (hxmc over its runs, from
// bench/compile-history.json or the committed compile-history.json) and the
// Programs' (bench/history.json), one per series with 10 runs or more, none
// (the section's table only, no empty heading) before; the first chart's
// tooltip on hover or tap; the latest runs' tables; light and dark, and at a
// phone's width (one Programs chart at a time), no horizontal scrolling
async function benchTest(browser, name) {
	let ok = true;
	const latest = existsSync(path.join(dir, 'bench/latest.json'));
	// the charts expected: the series (hxmc per workload or case) with MIN_POINTS runs
	// (HistoryChart.hx); a section without any shows its table only
	const MIN_POINTS = 10;
	const readJson = (...fs) => {
		for (const f of fs) if (existsSync(path.join(dir, f))) return JSON.parse(readFileSync(path.join(dir, f), 'utf8'));
		return null;
	};
	const series = (h, field) => {
		if (!h) return 0;
		const i = h.fields ? h.fields.indexOf(field) : 0;
		const names = new Set(h.runs.flatMap((r) => Object.keys(r.results)));
		return [...names].filter((n) => h.runs.filter((r) => r.results[n]?.hxmc?.[i] != null).length >= MIN_POINTS).length;
	};
	const wantCompiler = series(readJson('bench/compile-history.json', 'compile-history.json'), 'wall_median');
	const wantPrograms = series(readJson('bench/history.json'), 'median');
	const views = [
		{ colorScheme: 'light', width: 1100 },
		{ colorScheme: 'dark', width: 1100 },
		{ colorScheme: 'light', width: 375 },
	];
	for (const { colorScheme, width } of views) {
		const view = `${colorScheme}, ${width} px`;
		let pass = true;
		const phone = width < 600;
		const page = await browser.newPage({ colorScheme, viewport: { width, height: 900 }, ...(phone && name !== 'firefox' ? { isMobile: true, hasTouch: true } : {}) });
		const errors = [];
		page.on('pageerror', (e) => errors.push(e.message));
		await page.route(/^https:\/\/cdn\.jsdelivr\.net\//, (r) => r.abort());
		await page.goto(`http://localhost:${port}/benchmarks.html`);
		let facts = '';
		try {
			await page.waitForSelector('#compiler-results table', { timeout: 30000 });
			if (latest) await page.waitForSelector('#programs-results table', { timeout: 30000 });
			if (wantCompiler) await page.waitForSelector('#compiler-history .plot svg', { timeout: 30000 });
			if (wantPrograms) await page.waitForSelector('#programs-history .plot svg', { timeout: 30000 });
			// (the histories would have been fetched and drawn by now)
			await page.waitForTimeout(500);
			// the tooltip of the first chart: a hover, or a tap on a phone
			const first = page.locator(wantCompiler ? '#compiler-history .plot svg' : '#programs-history .plot svg').first();
			if (wantCompiler || wantPrograms) {
				await first.evaluate((e) => e.scrollIntoView({ block: 'center' }));
				const box = await first.boundingBox();
				if (phone && name !== 'firefox') await page.touchscreen.tap(box.x + box.width * 0.95, box.y + box.height / 2);
				else await page.mouse.move(box.x + box.width * 0.95, box.y + box.height / 2);
				await page.waitForSelector('.plot .tip:not([hidden])', { timeout: 5000 });
			}
			facts = await page.evaluate(() => {
				const q = (s) => document.querySelectorAll(s).length;
				const visible = (s) => [...document.querySelectorAll(s)].filter((e) => e.getClientRects().length > 0).length;
				return {
					compilerShown: visible('#compiler-history'),
					programsShown: visible('#programs-history'),
					compilerCharts: q('#compiler-history .plot svg'),
					compilerRows: q('#compiler-results tbody tr'),
					tip: document.querySelector('.plot .tip:not([hidden])')?.textContent.slice(0, 60) ?? '',
					tipLink: document.querySelector('.plot .tip:not([hidden]) a')?.href ?? '',
					emptyHeadings: [...document.querySelectorAll('#main h2, #main h3')].filter((h) => h.getClientRects().length > 0 && !h.nextElementSibling?.getClientRects().length).length,
					programCharts: q('#programs-history .plot svg'),
					programChartsVisible: visible('#programs-history .plot svg'),
					rows: q('#programs-results tbody tr'),
					tabs: [...document.querySelectorAll('#programs-results .tabs button')].map((b) => b.textContent).join(','),
					series: getComputedStyle(document.documentElement).getPropertyValue('--s1').trim(),
					pageScroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
				};
			});
			Object.assign(facts, { wantCompiler, wantPrograms });
			if (facts.compilerRows < 1 || facts.compilerCharts !== wantCompiler || facts.compilerShown !== (wantCompiler ? 1 : 0)) pass = false;
			if (facts.programCharts !== wantPrograms || facts.programsShown !== (wantPrograms ? 1 : 0) || facts.programChartsVisible !== (phone ? Math.min(1, wantPrograms) : wantPrograms)) pass = false;
			if ((wantCompiler || wantPrograms) && !/\/commit\/[0-9a-f]+$/.test(facts.tipLink)) pass = false;
			if (latest && (facts.rows < 1 || !/Compile/.test(facts.tabs))) pass = false;
			if (facts.emptyHeadings > 0) pass = false;
			if (facts.pageScroll > 0) pass = false;
			if (process.env.SCREENSHOTS) {
				await page.screenshot({ path: path.join(process.env.SCREENSHOTS, `bench-${name}-${colorScheme}-${width}.png`), fullPage: true });
			}
		} catch (e) {
			pass = false;
			facts = e.message.split('\n')[0];
		}
		if (errors.length) pass = false;
		if (!pass) ok = false;
		console.log(`  benchmarks (${view}) ${pass ? 'ok' : 'FAILED'}: ${JSON.stringify(facts)}${errors.length ? '; errors: ' + errors.join('; ') : ''}`);
		await page.close();
	}
	return ok;
}

// --- the browsers ---

linkCheck();
const launches = names.map((name) => ({ name, label: name, opts: {} }));
// (a Chromium without exnref: the playground falls back to the legacy module by itself)
if (names.includes('chromium') && modules.includes('hih-legacy.wasm'))
	launches.push({ name: 'chromium', label: 'chromium without exnref', opts: { args: ['--js-flags=--no-experimental-wasm-exnref'] }, noExnref: true });
for (const { name, label, opts, noExnref } of launches) {
	let browser;
	try {
		browser = await pw[name].launch(opts);
		console.log(`== ${label} ${browser.version()}`);
		if (noExnref) {
			const page = await browser.newPage();
			await page.goto(url(''));
			const err = await page.evaluate(async () => {
				try { await WebAssembly.compileStreaming(fetch('hih.wasm')); return 'compiled'; } catch (e) { return e.message; }
			});
			await page.close();
			check(err !== 'compiled', `hih.wasm does not compile: ${err}`);
			await pageTest(browser, '', 'hih-legacy.wasm');
			continue;
		}
		for (const wasm of modules) {
			const page = await browser.newPage();
			const said = [];
			page.on('crash', () => said.push('the page crashed'));
			page.on('console', (m) => said.push(`console.${m.type()}: ${m.text()}`));
			await page.goto(url(''));
			const log = await page.evaluate(inPage, [code, wasm]).catch((e) => [e.message.split('\n')[0], ...said]);
			await page.close().catch(() => {});
			console.log(`  ${wasm}`);
			for (const l of log) console.log('    ' + l);
			check(log.some((l) => l.startsWith('run 0')) && log.some((l) => l.startsWith('hxb 0')), `the worker with ${wasm}`);
		}
		if (name === 'chromium' && modules.length) await faultTest(browser, modules[0]);
		await pagesTest(browser, name);
		if (!(await benchTest(browser, name))) failed++;
		if (modules.length) {
			await pageTest(browser, '', 'hih.wasm');
			if (modules.includes('hih-legacy.wasm')) await pageTest(browser, '?eh=legacy', 'hih-legacy.wasm');
		}
	} catch (e) {
		check(false, `${label}: ${e.message.split('\n')[0]}`);
	} finally {
		if (browser) await browser.close();
	}
}
server.close();
console.log(failed ? `${failed} checks FAILED` : 'all checks passed');
process.exit(failed ? 1 : 0);
