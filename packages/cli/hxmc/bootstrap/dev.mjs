// `haxe --dev` router (docs/dev.md, docs/plans/esm-dev.md): hxmc vs ESM hot Js.
//
//   node dev.mjs <compiler> [--port <n>] [--host <address>] [--quiet] [--dev-browser] <haxe arguments>
import process from 'node:process';
import { defineTruthy, hxmcOutput, jsEntry, words } from './dev-shared.mjs';
import { runDevEsm } from './dev-esm.mjs';
import { runDevHxmc } from './dev-hxmc.mjs';

function usage(msg) {
	if (msg) console.error('hxmc dev: ' + msg);
	console.error('usage: haxe --dev [--port <n>] [--host <address>] [--quiet] [--dev-browser] <build.hxml | haxe arguments>');
	console.error('  --custom-target hxmc=<out>   native / wasm dev (hxmc snapshot reload)');
	console.error('  -js <entry.mjs> -D esm      ESM hot dev (patch reload via WebSocket)');
	process.exit(2);
}

const argv = process.argv.slice(2);
const compiler = argv.shift();
if (!compiler) usage('no compiler');
let port = Number(process.env.HXMC_DEV_PORT ?? 4321);
let host = process.env.HXMC_DEV_HOST ?? '127.0.0.1';
let quiet = false;
let browser = false;
const args = [];
for (let i = 0; i < argv.length; i++) {
	if (argv[i] === '--port') port = Number(argv[++i]);
	else if (argv[i] === '--host') host = argv[++i];
	else if (argv[i] === '--quiet') quiet = true;
	else if (argv[i] === '--dev-browser') browser = true;
	else args.push(argv[i]);
}
if (args.length === 0) usage();
const cwd = process.cwd();
const all = words(args);
const hxOut = hxmcOutput(all);
const js = jsEntry(all);
const hasEsm = defineTruthy(all, 'esm');
const hasEsmProd = defineTruthy(all, 'esm.prod');
const hasEsmHot = defineTruthy(all, 'esm.hot');

if (hasEsmProd) usage('-D esm.prod is not supported with --dev (use release `haxe -js … -D esm`)');
if (hxOut && js && hasEsm) usage('cannot combine --custom-target hxmc=… with -js -D esm');
if (js && !hasEsm) usage('Js --dev requires -D esm (or use plain `haxe` without --dev)');
if (!hxOut && !(js && hasEsm)) usage('name --custom-target hxmc=<out> or -js <entry> with -D esm');

const common = { port, host, quiet, cwd, args };

if (js && hasEsm) {
	if (hasEsmHot && !quiet)
		console.log('esm dev: -D esm.hot is injected automatically; user -D esm.hot is optional');
	await runDevEsm(compiler, { ...common, browser });
} else {
	await runDevHxmc(compiler, common);
}