#!/usr/bin/env node
// Executable JSON-protocol wrapper for ML2HX_FRONTEND. Build with build.mjs native.
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
let stdlib=process.env.OCAMLLIB;
if(!stdlib) {
  const p=spawnSync(process.env.OCAMLC??'ocamlc',['-where'],{encoding:'utf8'});
  if(p.status!==0)throw new Error('OCAMLLIB or a working ocamlc is required');
  stdlib=p.stdout.trim();
}
const p=spawnSync(process.env.OCAMLRUN??'ocamlrun',[path.join(root,'bin/ml2hx/build/frontend.byte'),'--stdlib',stdlib,...process.argv.slice(2)],{stdio:'inherit'});
if(p.error)console.error(p.error.message);
process.exitCode=p.status??1;
