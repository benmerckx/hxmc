#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const dir=path.join(root,'bin/ml2hx/build');fs.mkdirSync(dir,{recursive:true});
const ocamlc=process.env.OCAMLC??'ocamlc';
function run(args) {
  const p=spawnSync(ocamlc,args,{cwd:dir,encoding:'utf8'});
  if(p.status!==0)throw new Error(p.error?.message??p.stderr);
  return p.stdout.trim();
}
const version=run(['-version']);
if(!version.startsWith('5.3.'))throw new Error('native frontend requires compiler-libs 5.3.x; found '+version);
const lib=path.join(run(['-where']),'compiler-libs');
fs.copyFileSync(path.join(root,'tools/ml2hx/frontend/native.ml'),path.join(dir,'native.ml'));
run(['-I',lib,path.join(lib,'ocamlcommon.cma'),'native.ml','-o','frontend-native.byte']);
console.log('Built native frontend with OCaml '+version);
