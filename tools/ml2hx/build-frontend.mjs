#!/usr/bin/env node
// Build the ml2hx frontend (tools/ml2hx/frontend/main.ml) with the OCaml of
// the opam switch the pinned Haxe tag builds with, so its compiler-libs read
// the tag's typed trees.
//   node tools/ml2hx/build-frontend.mjs          native (ocamlopt), else bytecode
//   node tools/ml2hx/build-frontend.mjs --js     also a js_of_ocaml build (optional)
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const dir = path.join(root, 'bin/ml2hx/build');
fs.mkdirSync(dir, {recursive: true});
function run(cmd, args) {
  const p = spawnSync(cmd, args, {cwd: dir, encoding: 'utf8'});
  if (p.error) throw new Error(`${cmd}: ${p.error.message}`);
  if (p.status !== 0) throw new Error(`${cmd} ${args.join(' ')}\n${p.stderr}${p.stdout}`);
  return p.stdout.trim();
}
// The OCaml version the pinned tag's CI uses.
export function pinnedOcaml() {
  const wf = path.join(root, 'haxe/upstream/.github/workflows/main.yml');
  const m = fs.existsSync(wf) && fs.readFileSync(wf, 'utf8').match(/OCAML_VERSION:\s*([\d.]+)/);
  return m ? m[1] : null;
}
const want = pinnedOcaml();
const version = run('ocamlfind', ['ocamlc', '-version']);
if (want && version !== want && !process.env.ML2HX_ANY_OCAML)
  throw new Error(`the pinned Haxe tag builds with OCaml ${want}; found ${version} (opam switch create ${want}, or set ML2HX_ANY_OCAML=1)`);
fs.copyFileSync(path.join(root, 'tools/ml2hx/frontend/main.ml'), path.join(dir, 'main.ml'));
for (const f of ['frontend.exe', 'frontend.byte']) fs.rmSync(path.join(dir, f), {force: true});
const pkg = ['-package', 'compiler-libs.common', '-linkpkg'];
let built;
try { run('ocamlfind', ['ocamlopt', ...pkg, 'main.ml', '-o', 'frontend.exe']); built = 'frontend.exe'; }
catch (e) { run('ocamlfind', ['ocamlc', ...pkg, 'main.ml', '-o', 'frontend.byte']); built = 'frontend.byte'; }
console.log(`Built bin/ml2hx/build/${built} with OCaml ${version}`);
if (process.argv.includes('--js')) {
  // Optional: a JS build for hosts without OCaml. Typing .ml files needs the
  // standard library's .cmi files embedded; reading .cmt files needs 63-bit ints.
  run('ocamlfind', ['ocamlc', ...pkg, 'main.ml', '-o', 'frontend.byte']);
  const stdlib = run('ocamlfind', ['ocamlc', '-where']);
  run('js_of_ocaml', ['compile', '--target-env', 'nodejs', '--file', `${stdlib}:/static/stdlib`, 'frontend.byte', '-o', 'frontend.js']);
  console.log('Built bin/ml2hx/build/frontend.js');
}
