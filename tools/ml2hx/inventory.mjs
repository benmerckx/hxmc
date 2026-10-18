#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {frontend,root} from './generate.mjs';
export function inventory(upstream=path.join(root,'haxe/upstream')) {
  const walk=d=>fs.readdirSync(d,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(e=>e.isDirectory()?walk(path.join(d,e.name)):e.name.endsWith('.ml')?[path.join(d,e.name)]:[]);
  const paths=walk(path.join(upstream,'src')), files=[],failures=[];
  try { files.push(...frontend(['--parse',...paths]).files); }
  catch {for(const p of paths)try{files.push(...frontend(['--parse',p]).files);}catch(e){failures.push({file:path.relative(upstream,p),error:e.message});}}
  const features={};for(const f of files)for(const [k,n] of Object.entries(f.features))features[k]=(features[k]??0)+n;
  return {scope:'Parsing only; this does not assert typechecking or translation coverage.',total:paths.length,parsed:files.length,failures,features:Object.fromEntries(Object.entries(features).sort(([a],[b])=>a.localeCompare(b))),files:files.map(f=>({file:path.relative(upstream,f.file),features:f.features}))};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {const r=inventory(path.resolve(process.argv[2]??path.join(root,'haxe/upstream')));console.log(JSON.stringify(r,null,2));if(r.failures.length)process.exitCode=1;}
