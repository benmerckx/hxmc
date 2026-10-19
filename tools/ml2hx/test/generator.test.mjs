import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {generate,frontend,root,discover} from '../generate.mjs';
import {Emitter,Unsupported} from '../emit.mjs';
import {format} from '../format.mjs';
const dir=path.join(root,'bin/ml2hx/tests');fs.mkdirSync(dir,{recursive:true});
const env={...process.env,HAXE_STD_PATH:path.join(root,'haxe/upstream/std')};
const execute=(cmd,args,extra={})=>{
  const p=spawnSync(cmd,args,{cwd:root,env,encoding:'utf8',timeout:180000,maxBuffer:16*1024*1024,...extra});
  assert.equal(p.status,0,p.error?.message??`${p.stdout}\n${p.stderr}`);return p.stdout;
};
const compiler=process.env.ML2HX_HAXE??(fs.existsSync(path.join(root,'bin/port/haxe'))?'bin/port/haxe':null);
function haxe(args) {
  if(compiler)return execute(compiler,args);
  return execute(process.execPath,['--stack-size=4096','hxmc/bootstrap/wasi.mjs','hxmc/bootstrap/stage0.wasm.br',...args]);
}
function emit(source,name='Probe') {
  const file=path.join(dir,`${name.toLowerCase()}.ml`);fs.writeFileSync(file,source);
  return format(new Emitter({source:path.basename(file),package:'semantics',class:name}).emit(frontend([file]).files[0]));
}

test('OCaml evaluation order, sharing, currying, tail calls, patterns, bytes and 63-bit ints',()=>{
  const source=fs.readFileSync(path.join(root,'tools/ml2hx/test/semantics.ml'),'utf8');
  const output=path.join(dir,'semantics/Semantics.hx');fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,emit(source,'Semantics'));
  const args=['-cp','tools/ml2hx/runtime','-cp',dir,'-cp','tools/ml2hx/test','-main','SemanticsTest'];
  const expected=fs.readFileSync(path.join(root,'tools/ml2hx/test/semantics.expected'),'utf8');
  assert.equal(haxe([...args,'--interp']),expected);
  // stage0 deliberately omits the other generators; a built port exercises JS.
  if(compiler){const js=path.join(dir,'semantics.js');haxe([...args,'-js',js]);assert.equal(execute(process.execPath,[js]),expected);}
});
test('the semantic golden agrees with native OCaml', {skip:!process.env.ML2HX_OCAMLC},()=>{
  for(const file of ['semantics.ml','reference.ml'])fs.copyFileSync(path.join(root,'tools/ml2hx/test',file),path.join(dir,file));
  const out=path.join(dir,'reference.byte');
  execute(process.env.ML2HX_OCAMLC,['-bin-annot','-I',dir,'-o',out,path.join(dir,'semantics.ml'),path.join(dir,'reference.ml')]);
  assert.equal(execute(process.env.ML2HX_OCAMLRUN??'ocamlrun',[out]),fs.readFileSync(path.join(root,'tools/ml2hx/test/semantics.expected'),'utf8'));

});
test('unsupported language features fail explicitly',()=>{
  assert.throws(()=>emit('module M = struct let x = 1 end\n'),e=>e instanceof Unsupported&&/structure unsupported/.test(e.message));
  assert.throws(()=>emit('let f x = x\nlet g () = f == f\n'),/comparison/);
  assert.throws(()=>emit('let x = 4611686018427387904\n'),/outside OCaml.s native 63-bit range/);
  assert.throws(()=>emit('let f x = lazy x\n'),/lazy/);
  assert.throws(()=>emit('let rec xs = 1 :: xs\n'),/recursive values/);
  assert.throws(()=>emit('open struct let x = ref 1 end\n'),/evaluated module/);
  assert.throws(()=>emit('let f (x:float) y = x == y\n'),/physical equality/);
});
test('byte string formatting preserves delimiters and comments',()=>{
  const code=emit('let x = "{;}(*)\\000\\255"\n');
  assert.match(code,/"\{;\}\(\*\)\\u0000ÿ"/);
});

test('bulk generation processes every discovered source in one invocation',()=>{
  const sources=discover(path.join(root,'haxe/upstream'));
  assert.ok(sources.length>300);
  let calls=0;
  const source=path.join(dir,'bulk.ml');fs.writeFileSync(source,'let answer = 42\n');
  const item=frontend([source]).files[0];
  const result=generate({files:sources,out:path.join(dir,'bulk'),readFrontend:inputs=>{
    calls++;assert.equal(inputs.length,sources.length);
    return {protocol:1,files:inputs.map((file,i)=>i===0?{...item,file}:{file,error:'intentional missing dependency'})};
  }});
  assert.equal(calls,1);assert.equal(result.sources,sources.length);assert.equal(result.emitted,1);
  assert.equal(result.complete,false);assert.equal(result.failures.length,sources.length-1);
  assert.equal(fs.readFileSync(path.join(dir,'bulk/.status'),'utf8'),'incomplete\n');
});
