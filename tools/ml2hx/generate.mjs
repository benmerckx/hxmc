#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {brotliDecompressSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {Emitter} from './emit.mjs';
import {format} from './format.mjs';

export const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const home=path.join(root,'tools/ml2hx');
function run(cmd,args,options={}) {
  const r=spawnSync(cmd,args,{cwd:root,encoding:'utf8',maxBuffer:128*1024*1024,...options});
  if(r.error) throw r.error;
  if(r.status!==0) throw new Error(`${path.basename(cmd)} failed (${r.status}):\n${r.stderr||r.stdout}`);
  return r.stdout;
}
export function frontend(args) {
  // An executable wrapper can select native OCaml, wasm_of_ocaml/WASI, or a
  // different compiler-libs version without changing the emitter protocol.
  if(process.env.ML2HX_FRONTEND) {const result=JSON.parse(run(process.env.ML2HX_FRONTEND,args));if(result.protocol!==1)throw new Error(`unsupported frontend protocol ${result.protocol}`);return result;}
  const boot=path.join(home,'bootstrap/frontend.cjs.br');
  const metadata=JSON.parse(fs.readFileSync(path.join(home,'bootstrap/manifest.json'),'utf8'));
  if(metadata.sourceSha256!==hash(fs.readFileSync(path.join(home,'frontend/main.ml')))||metadata.compressedSha256!==hash(fs.readFileSync(boot)))throw new Error('frontend bootstrap is stale or damaged; rebuild with tools/ml2hx/build.mjs');
  const cache=path.join(root,'bin/ml2hx/bootstrap'); fs.mkdirSync(cache,{recursive:true});
  const js=path.join(cache,'frontend.cjs');
  const bytes=brotliDecompressSync(fs.readFileSync(boot));
  if(!fs.existsSync(js)||!fs.readFileSync(js).equals(bytes)) fs.writeFileSync(js,bytes);
  const result=JSON.parse(run(process.execPath,['--stack-size=4096',js,'--stdlib','/static/stdlib',...args]));
  if(result.protocol!==1) throw new Error(`unsupported frontend protocol ${result.protocol}`);
  return result;
}
function relative(p) { if(typeof p!=='string'||path.isAbsolute(p)||p.split(/[\\/]/).some(s=>s==='..'||s===''))throw new Error(`unsafe generated path: ${p}`);return p; }
const hash=b=>createHash('sha256').update(b).digest('hex');
export function generate({upstream=path.join(root,'haxe/upstream'),out=path.join(root,'generated/compiler'),selected=null,check=false,profile="port"}={}) {
  upstream=path.resolve(upstream); out=path.resolve(out);
  if(out===root||out.startsWith(path.join(root,'haxe')+path.sep)||out===upstream||out.startsWith(upstream+path.sep)||upstream.startsWith(out+path.sep)) throw new Error('output must be separate from handwritten and upstream sources');
  if(!['port','history'].includes(profile))throw new Error('unknown generation profile');
  const config=JSON.parse(fs.readFileSync(path.join(home,profile==='port'?'modules.json':'history.json'),'utf8'));
  const configs=config.modules.filter(m=>!selected||selected.includes(m.source));
  if(selected?.some(s=>!configs.some(c=>c.source===s))) throw new Error('unknown module selection');
  const files=new Map(), modules=[], skipped=[];
  for(const original of configs) {
    const candidates=(original.sources??[original.source]).filter(s=>fs.existsSync(path.join(upstream,s)));
    if(candidates.length!==1) { if(original.optional&&!candidates.length) {skipped.push({source:original.source,reason:'absent in this upstream revision'});continue;} throw new Error(`expected one source for ${original.output}, found ${candidates.length}`); }
    const c={...original,source:candidates[0]};
    const source=path.join(upstream,c.source);
    const ir=frontend([source]);
    const normalize=n=>{ if(!n||typeof n!=='object')return; for(const [k,v] of Object.entries(n)) { if(k==='file'&&v===source)n[k]=c.source; else normalize(v); } };
    normalize(ir.files[0]);
    let code=new Emitter(c).emit(ir.files[0]);
    if(c.append) code+='\n'+fs.readFileSync(path.join(home,c.append),'utf8');
    files.set(relative(c.output),format(code));
    if(c.shadow) files.set(relative(c.shadow.replace(/^adapters\//,'')),fs.readFileSync(path.join(home,c.shadow),'utf8'));
    modules.push({source:c.source,sha256:hash(fs.readFileSync(source)),output:c.output,values:ir.files[0].items.filter(i=>i.kind==='value').flatMap(i=>i.bindings.map(b=>b.pattern.name))});
  }
  const copy=(dir,prefix)=>{for(const entry of fs.readdirSync(dir,{withFileTypes:true})) {const p=path.join(dir,entry.name),rel=path.posix.join(prefix,entry.name); if(entry.isDirectory())copy(p,rel);else files.set(rel,fs.readFileSync(p,'utf8'));}};
  copy(path.join(home,'runtime'),'');
  const commit=run('git',['-C',upstream,'rev-parse','HEAD']).trim();
  const dirty=run('git',['-C',upstream,'status','--porcelain','--untracked-files=no']).trim();
  if(dirty) throw new Error('upstream has tracked changes; generation requires a clean pin');
  const generator={frontendSource:hash(fs.readFileSync(path.join(home,'frontend/main.ml'))),frontendBootstrap:hash(fs.readFileSync(path.join(home,'bootstrap/frontend.cjs.br'))),emitter:hash(fs.readFileSync(path.join(home,'emit.mjs'))),formatter:hash(fs.readFileSync(path.join(home,'format.mjs')))};
  const manifest={format:1,profile,upstream:commit,generator,modules,skipped,files:Object.fromEntries([...files].sort(([a],[b])=>a.localeCompare(b)).map(([p,s])=>[p,hash(s)]))};
  files.set('manifest.json',JSON.stringify(manifest,null,2)+'\n');
  // Render everything before publishing anything. A failed module leaves the
  // last successful output untouched; no partial generation or silent fallback.
  if(check) {
    for(const [p,s] of files) if(!fs.existsSync(path.join(out,p))||fs.readFileSync(path.join(out,p),'utf8')!==s) throw new Error(`generated drift: ${p}`);
    const prior=JSON.parse(fs.readFileSync(path.join(out,'manifest.json'),'utf8'));
    if(Object.keys(prior.files).some(p=>!files.has(p))) throw new Error('generated drift: stale output');
  } else {
    fs.mkdirSync(out,{recursive:true});
    const prior=fs.existsSync(path.join(out,'manifest.json'))?JSON.parse(fs.readFileSync(path.join(out,'manifest.json'),'utf8')):null;
    for(const [p,s] of files) {const dest=path.join(out,p);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,s);}
    for(const p of Object.keys(prior?.files??{})) if(!files.has(p)) fs.unlinkSync(path.join(out,relative(p)));
  }
  return manifest;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const args=process.argv.slice(2),options={};
    for(let i=0;i<args.length;i++) {
      if(args[i]==='--upstream'||args[i]==='--out'||args[i]==='--profile') {const key=args[i].slice(2);if(!args[i+1])throw new Error(`missing ${key}`);options[key]=args[++i];}
      else if(args[i]==='--module') (options.selected??=[]).push(args[++i]);
      else if(args[i]==='--check') options.check=true;
      else throw new Error(`unknown argument ${args[i]}`);
    }
    if(options.profile==='history'&&!options.out)throw new Error('history profile requires a separate --out directory');
    const m=generate(options); console.log(`${options.check?'Verified':'Generated'} ${m.modules.length} modules from ${m.upstream}`);
  } catch(e) {console.error(e.message);process.exitCode=1;}
}
