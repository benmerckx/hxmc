#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {brotliDecompressSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {Emitter,camel} from './emit.mjs';
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
  if(process.env.ML2HX_FRONTEND) {const result=JSON.parse(run(process.env.ML2HX_FRONTEND,args));if(result.protocol!==1)throw new Error(`unsupported frontend protocol ${result.protocol}`);if(result.files.some(f=>f.error))throw new Error(result.files.find(f=>f.error).error);return result;}
  const boot=path.join(home,'bootstrap/frontend.cjs.br');
  const metadata=JSON.parse(fs.readFileSync(path.join(home,'bootstrap/manifest.json'),'utf8'));
  if(metadata.sourceSha256!==hash(fs.readFileSync(path.join(home,'frontend/main.ml')))||metadata.compressedSha256!==hash(fs.readFileSync(boot)))throw new Error('frontend bootstrap is stale or damaged; rebuild with tools/ml2hx/build.mjs');
  const cache=path.join(root,'bin/ml2hx/bootstrap'); fs.mkdirSync(cache,{recursive:true});
  const js=path.join(cache,'frontend.cjs');
  const bytes=brotliDecompressSync(fs.readFileSync(boot));
  if(!fs.existsSync(js)||!fs.readFileSync(js).equals(bytes)) fs.writeFileSync(js,bytes);
  const result=JSON.parse(run(process.execPath,['--stack-size=65500',js,'--stdlib','/static/stdlib',...args]));
  if(result.protocol!==1) throw new Error(`unsupported frontend protocol ${result.protocol}`);
  return result;
}
const hash=b=>createHash('sha256').update(b).digest('hex');
export function discover(upstream) {
  return run('git',['-C',upstream,'ls-files','*.ml']).trim().split('\n').filter(Boolean).sort();
}
function config(source) {
  const pieces=source.replace(/^src\//,'').replace(/\.ml$/,'').split('/');
  const module=pieces.pop(),name=module[0].toUpperCase()+module.slice(1);
  const packageName=['upstream',...pieces.map(x=>x==='macro'?'macros':x.replaceAll('-','_').toLowerCase())].join('.');
  return {source,module:name,class:name+'Module',package:packageName,output:packageName.replaceAll('.','/')+'/'+name+'Module.hx'};
}
function walk(dir,visit) {
  for(const e of fs.readdirSync(dir,{withFileTypes:true})) {
    const p=path.join(dir,e.name);
    if(e.isDirectory())walk(p,visit);else if(e.isFile())visit(p);
  }
}
export function prepare(upstream) {
  const commit=run('git',['-C',upstream,'rev-parse','HEAD']).trim();
  if(run('git',['-C',upstream,'status','--porcelain','--untracked-files=no']).trim())throw new Error('upstream must be clean');
  const build=path.join(root,'bin/ml2hx/checkouts',commit);
  if(!fs.existsSync(build)) {
    fs.mkdirSync(path.dirname(build),{recursive:true});
    run('git',['clone','--shared','--no-checkout',upstream,build]);
    run('git',['-C',build,'checkout','--detach',commit]);
  }
  if(run('git',['-C',build,'rev-parse','HEAD']).trim()!==commit || run('git',['-C',build,'status','--porcelain','--untracked-files=no']).trim())
    throw new Error('cached upstream checkout does not match the clean pin');
  run('dune',['build','--root',build,'--profile','release','@check'],{env:{...process.env,STATICLINK:'0',LIB_PARAMS:''}});
  return build;
}
export function generate({upstream=path.join(root,'haxe/upstream'),out=path.join(root,'bin/ml2hx/generated'),buildDir=null,files=null,readFrontend=null}={}) {
  upstream=path.resolve(upstream);out=path.resolve(out);
  const sources=files??discover(upstream);
  if(!sources.length)throw new Error('no tracked OCaml sources');
  if(buildDir&&!files) {
    const expected=run('git',['-C',upstream,'rev-parse','HEAD']).trim();
    if(run('git',['-C',buildDir,'rev-parse','HEAD']).trim()!==expected || run('git',['-C',buildDir,'status','--porcelain','--untracked-files=no']).trim())
      throw new Error('CMT build must come from the clean pinned upstream commit');
  }
  if(out!==path.join(root,'bin/ml2hx/generated') && !out.startsWith(path.join(root,'bin/ml2hx/tests')+path.sep))
    throw new Error('generated output must be bin/ml2hx/generated or an isolated bin/ml2hx/tests directory');
  fs.mkdirSync(out,{recursive:true});
  fs.writeFileSync(path.join(out,'.status'),'incomplete\n');
  const configs=sources.map(config);
  const cmts=[],includeDirs=new Set();
  if(buildDir)walk(path.join(buildDir,'_build/default'),p=>{
    if(p.endsWith('.cmt'))cmts.push(p);
    if(p.endsWith('.cmi'))includeDirs.add(path.dirname(p));
  });
  const inputs=configs.map(c=>{
    const matches=cmts.filter(p=>path.basename(p,'.cmt').split('__').at(-1).toLowerCase()===path.basename(c.source,'.ml').toLowerCase());
    const closest=matches.filter(p=>p.includes('/'+path.dirname(c.source)+'/'));
    return closest.length===1?closest[0]:matches.length===1?matches[0]:path.join(upstream,c.source);
  });
  const read=readFrontend??(args=>{
    const native=process.env.ML2HX_FRONTEND??path.join(root,'bin/ml2hx/build/frontend-native.byte');
    const spool=fs.mkdtempSync(path.join(root,'bin/ml2hx/ir-'));
    if(args.some(p=>p.endsWith('.ml'))) {
      const packages=spawnSync('ocamlfind',['printconf','path'],{encoding:'utf8'});
      if(packages.status===0)for(const dir of packages.stdout.trim().split('\n').filter(Boolean))if(fs.existsSync(dir))
        walk(dir,p=>{if(p.endsWith('.cmi'))includeDirs.add(path.dirname(p));});
    }
    return JSON.parse(run(native,['--out-dir',spool,...[...includeDirs].sort().flatMap(dir=>['-I',dir]),...args]));
  });
  // Exactly one frontend invocation for all discovered sources. CMTs preserve
  // Dune's PPX expansions, interfaces and wrapped-library module identities.
  const ir=read(inputs);
  if(ir.protocol!==1||ir.files.length!==sources.length)throw new Error('frontend protocol or source count mismatch');
  const units=ir.files.map((f,i)=>({...f,config:configs[i]})),types={},values={},constructors={},failures=[];
  const load=f=>f.ir?{...JSON.parse(fs.readFileSync(f.ir,'utf8')),config:f.config}:f;
  for(const unit of units) {
    const f=load(unit);
    if(f.error){failures.push({source:f.config.source,stage:'typing',error:f.error});continue;}
    const c=f.config;
    for(const d of f.items.filter(i=>i.kind==='type').flatMap(i=>i.declarations)) {
      const name=d.name==='t'?c.module+'Data':d.name[0].toUpperCase()+camel(d.name).slice(1);
      types[c.module+'.'+d.name]=c.package+'.'+c.class+'.'+name;
      if(d.kind==='enum')for(const k of d.constructors)constructors[c.module+'.'+d.name+'.'+k.name]=types[c.module+'.'+d.name]+'.'+k.name;
    }
    for(const b of f.items.filter(i=>i.kind==='value').flatMap(i=>i.bindings))if(b.pattern.kind==='var')
      values[c.module+'.'+b.pattern.name]=c.package+'.'+c.class+'.'+camel(b.pattern.name)+(b.expr.kind==='function'?'()':'');
  }
  const output=new Map();
  for(const unit of units) {
    const f=load(unit);
    if(f.error)continue;
    const c=f.config,local={...types};
    for(const d of f.items.filter(i=>i.kind==='type').flatMap(i=>i.declarations))local[d.name]=types[c.module+'.'+d.name].split('.').at(-1);
    const localConstructors={...constructors};
    for(const d of f.items.filter(i=>i.kind==='type').flatMap(i=>i.declarations))if(d.kind==='enum')
      for(const k of d.constructors)localConstructors[d.name+'.'+k.name]=local[d.name]+'.'+k.name;
    try {output.set(c.output,format(new Emitter({...c,types:local,values,constructors:localConstructors}).emit(f)));}
    catch(e){failures.push({source:c.source,stage:'lowering',error:e.message});}
  }
  const emitted=output.size;
  walk(path.join(home,'runtime'),p=>output.set(path.relative(path.join(home,'runtime'),p),fs.readFileSync(p,'utf8')));
  fs.mkdirSync(out,{recursive:true});
  const owned=path.join(out,'.ml2hx-files');
  const previous=fs.existsSync(owned)?fs.readFileSync(owned,'utf8').trim().split('\n').filter(Boolean):[];
  for(const p of previous) {
    const dest=path.resolve(out,p);
    if(!dest.startsWith(out+path.sep))throw new Error('unsafe previous output');
    if(!output.has(p)&&fs.existsSync(dest))fs.unlinkSync(dest);
  }
  for(const [p,code] of output){const dest=path.join(out,p);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,code);}
  fs.writeFileSync(owned,[...output.keys()].sort().join('\n')+'\n');
  const complete=failures.length===0&&emitted===sources.length;
  fs.writeFileSync(path.join(out,'.status'),complete?'complete\n':'incomplete\n');
  failures.forEach(f=>{f.error=f.error.split(upstream+path.sep).join('').split(root+path.sep).join('');});
  return {sources:sources.length,typed:units.filter(f=>!f.error).length,emitted,complete,failures};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const args=process.argv.slice(2),options={};let verbose=false;
    for(let i=0;i<args.length;i++) {
      if(args[i]==='--upstream'||args[i]==='--build-dir'){if(!args[i+1])throw new Error('missing argument');options[args[i].slice(2).replace('-d','D')]=args[++i];}
      else if(args[i]==='--verbose')verbose=true;
      else throw new Error('unknown argument '+args[i]);
    }
    options.upstream=path.resolve(options.upstream??path.join(root,'haxe/upstream'));
    options.buildDir??=prepare(options.upstream);
    const result=generate(options);
    console.log('ML sources: '+result.sources+'; typed: '+result.typed+'; emitted: '+result.emitted+'; failed: '+result.failures.length);
    for(const f of verbose?result.failures:result.failures.slice(0,15))console.error(f.source+' ['+f.stage+']: '+f.error.replace(/\s+/g,' ').trim());
    if(!result.complete){console.error('Incomplete generation; compiler build and benchmark are blocked. Use --verbose for every failure.');process.exitCode=1;}
  } catch(e){console.error(e.message);process.exitCode=1;}
}
