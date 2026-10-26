// The compiler as a WebAssembly module (@hxmc/haxe-wasm: haxe.wasm and its
// WASI runner wasi.mjs), for machines where no native compiler runs: the
// installed package (npm i @hxmc/haxe-wasm, e.g. in WebContainers), else the
// one downloaded into the cache (<cache>/npm/<version>/wasm/), else downloaded
// now (registry.mjs), checked against the integrity pack.mjs pinned in
// @hxmc/haxe's package.json ("hxmc": {"wasmIntegrity"}). HXMC_WASM_TARBALL (a
// path or a URL) replaces the registry's tarball (tests).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { npmCache, pkgJson, version } from './launcher.mjs';
import { download, tarballUrl } from './registry.mjs';

const NAME = '@hxmc/haxe-wasm';

// the directory of a @hxmc/haxe-wasm of this version (haxe.wasm, wasi.mjs)
export async function wasmPackage() {
	try {
		const p = createRequire(import.meta.url).resolve(`${NAME}/package.json`);
		if (JSON.parse(fs.readFileSync(p, 'utf8')).version === version) return path.dirname(p);
	} catch {}
	const dir = path.join(npmCache(), 'wasm');
	if (fs.existsSync(path.join(dir, 'haxe.wasm'))) return dir;
	await download({
		name: NAME, integrity: pkgJson.hxmc?.wasmIntegrity, dir, check: 'haxe.wasm',
		url: process.env.HXMC_WASM_TARBALL || tarballUrl(NAME),
		why: 'no native compiler runs here', how: `install it (npm i ${NAME}@${version})`, pinner: '@hxmc/haxe',
	});
	return dir;
}
