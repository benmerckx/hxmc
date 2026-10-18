#!/usr/bin/env node
// Rebuild the parser/typechecker bootstrap. Routine generation needs only node.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {brotliCompressSync, constants} from 'node:zlib';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const dir=path.join(root,'bin/ml2hx/build'); fs.mkdirSync(dir,{recursive:true});
function run(cmd,args,options={}) {const p=spawnSync(cmd,args,{cwd:root,encoding:'utf8',...options});if(p.status!==0)throw new Error(p.error?.message??p.stderr??`${cmd} failed`);return p.stdout.trim();}
const ocaml=process.env.OCAMLC??'ocamlc', jsoo=process.env.JS_OF_OCAML??'js_of_ocaml';
const version=run(ocaml,['-version']);
if(version!=='4.14.1')throw new Error(`frontend targets compiler-libs 4.14.1; found ${version}`);
fs.copyFileSync(path.join(root,'tools/ml2hx/frontend/main.ml'),path.join(dir,'main.ml'));
run(ocaml,['-I','+compiler-libs','ocamlcommon.cma','-o','frontend.byte','main.ml'],{cwd:dir});
const stdlib=run(ocaml,['-where']);
const embedded=path.join(dir,'stdlib');fs.mkdirSync(embedded,{recursive:true});
for(const file of fs.readdirSync(embedded))fs.unlinkSync(path.join(embedded,file));
for(const file of fs.readdirSync(stdlib).sort())if(file.endsWith('.cmi'))fs.copyFileSync(path.join(stdlib,file),path.join(embedded,file));
const mode=process.argv[2]??'js';
if(mode==='js') {
  if(run(jsoo,['--version'])!=='5.6.0')throw new Error('JS bootstrap targets js_of_ocaml 5.6.0');
  run(jsoo,['compile','--target-env','nodejs','--file',`${embedded}:/static/stdlib`,path.join(dir,'frontend.byte'),'-o',path.join(dir,'frontend.cjs')]);
  const dest=path.join(root,'tools/ml2hx/bootstrap/frontend.cjs.br');
  fs.writeFileSync(dest,brotliCompressSync(fs.readFileSync(path.join(dir,'frontend.cjs')),{params:{[constants.BROTLI_PARAM_QUALITY]:11}}));
  const hash=b=>createHash('sha256').update(b).digest('hex');
  const manifest={protocol:1,ocaml:version,jsOfOcaml:'5.6.0',sourceSha256:hash(fs.readFileSync(path.join(root,'tools/ml2hx/frontend/main.ml'))),compressedSha256:hash(fs.readFileSync(dest)),javascriptSha256:hash(fs.readFileSync(path.join(dir,'frontend.cjs')))};
  fs.writeFileSync(path.join(root,'tools/ml2hx/bootstrap/manifest.json'),JSON.stringify(manifest,null,2)+'\n');
  console.log(`Rebuilt ${path.relative(root,dest)}`);
} else if(mode==='wasi') {
  // wasm_of_ocaml >=6.4 supports standalone WASI with GC and exception handling.
  // Run with its generated node launcher or a compatible standalone Wasm engine.
  const wasm=process.env.WASM_OF_OCAML??'wasm_of_ocaml';
  run(wasm,['--enable','wasi','--effects=cps','--file',`${embedded}:/static/stdlib`,path.join(dir,'frontend.byte'),'-o',path.join(dir,'frontend-wasi.js')]);
  console.log(`Built ${path.relative(root,path.join(dir,'frontend-wasi.js'))}`);
} else if(mode!=='native')throw new Error(`unknown frontend target ${mode}`);
