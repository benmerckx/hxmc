#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {generate,frontend,root} from './generate.mjs';
const args=process.argv.slice(2), refs=args.length?args:['4.0.5','4.1.5','4.2.5','4.3.7'];
if(refs.some(r=>!/^4\.\d+\.\d+$/.test(r)))throw new Error('matrix refs must be explicit Haxe 4.x release tags');
const base=path.join(root,'bin/ml2hx/matrix');fs.mkdirSync(base,{recursive:true});
function run(cmd,args,env={}){const p=spawnSync(cmd,args,{cwd:root,encoding:'utf8',env:{...process.env,...env},timeout:240000,maxBuffer:64*1024*1024});if(p.status!==0)throw new Error(p.error?.message??p.stderr??p.stdout);return p.stdout;}
const files=dir=>fs.readdirSync(dir,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(e=>e.isDirectory()?files(path.join(dir,e.name)):e.name.endsWith('.ml')?[path.join(dir,e.name)]:[]);
const results=[];
for(const ref of refs) {
  const row={tag:ref};
  try {
    const source=path.join(base,`upstream-${ref}`);
    if(!fs.existsSync(source))run('git',['clone','--depth','1','--branch',ref,'https://github.com/HaxeFoundation/haxe.git',source]);
    row.commit=run('git',['-C',source,'rev-parse','HEAD']).trim();
    const sources=files(path.join(source,'src'));let parsed=0,failures=[];
    // Parse in one process in the common case; isolate failures if necessary.
    try {parsed=frontend(['--parse',...sources]).files.length;}
    catch {for(const f of sources){try{frontend(['--parse',f]);parsed++;}catch(e){failures.push({file:path.relative(source,f),error:e.message});}}}
    row.parsing={total:sources.length,parsed,failures};
    const out=path.join(base,`generated-${ref}`);
    const manifest=generate({upstream:source,out,profile:'history'});
    row.generated=manifest.modules.map(m=>m.source);row.absent=manifest.skipped;
    const haxeArgs=['-cp','haxe/src','-cp',out,'-cp','tools/ml2hx/test','-main','HistoricalTest'];
    if(manifest.modules.some(m=>m.source.endsWith('/ring.ml')))haxeArgs.push('-D','history_ring');
    if(manifest.modules.some(m=>m.values.includes('find')))haxeArgs.push('-D','history_ring_find');
    if(manifest.modules.some(m=>m.values.includes('legacy_completion')))haxeArgs.push('-D','history_legacy');
    const env={HAXE_STD_PATH:path.join(root,'haxe/upstream/std')};
    const compiler=process.env.ML2HX_HAXE??(fs.existsSync(path.join(root,'bin/port/haxe'))?path.join(root,'bin/port/haxe'):null);
    if(compiler) {
      row.eval=run(compiler,[...haxeArgs,'--interp'],env).trim();
      const js=path.join(base,`test-${ref}.js`);run(compiler,[...haxeArgs,'-js',js],env);row.js=run(process.execPath,[js]).trim();
    } else row.eval=run(process.execPath,['--stack-size=4096','hxmc/bootstrap/wasi.mjs','hxmc/bootstrap/stage0.wasm.br',...haxeArgs,'--interp'],env).trim();
    row.ok=failures.length===0;
  }catch(e){row.ok=false;row.error=e.message;}
  results.push(row);
  fs.writeFileSync(path.join(base,'results.json'),JSON.stringify({scope:'parser corpus and generated server configuration/ring modules; not a full historical compiler port',results},null,2)+'\n');
  console.log(`${ref}: ${row.parsing?.parsed??0}/${row.parsing?.total??0} parsed, ${row.generated?.length??0} generated, ${row.ok?'PASS':'FAIL'}`);
}
if(results.some(r=>!r.ok))process.exitCode=1;
