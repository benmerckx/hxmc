import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {generate,frontend,root} from '../generate.mjs';
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

test('the committed compiler sources regenerate without drift',()=>generate({check:true}));
test('generation is deterministic and leaves upstream untouched',()=>{
  const before=execute('git',['-C','haxe/upstream','status','--porcelain']);
  const out=path.join(dir,'deterministic');const a=generate({out});const b=generate({out,check:true});
  assert.deepEqual(a,b);assert.equal(execute('git',['-C','haxe/upstream','status','--porcelain']),before);
  fs.appendFileSync(path.join(out,'core/ds/RingModule.hx'),'// changed\n');
  assert.throws(()=>generate({out,check:true}),/generated drift/);
});
test('generated upstream algorithms and ABI adapters run on Eval',()=>{
  assert.match(haxe(['-cp','haxe/src','-cp','generated/compiler','-cp','tools/ml2hx/test','-main','GeneratedTest','--interp']),/generated modules: pass/);
});
test('OCaml evaluation order, sharing, currying, tail calls, patterns, bytes and 63-bit ints',()=>{
  const source=fs.readFileSync(path.join(root,'tools/ml2hx/test/semantics.ml'),'utf8');
  const output=path.join(dir,'semantics/Semantics.hx');fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,emit(source,'Semantics'));
  const args=['-cp','haxe/src','-cp','generated/compiler','-cp',dir,'-cp','tools/ml2hx/test','-main','SemanticsTest'];
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
  const cmt=path.join(dir,'semantics.cmt');
  const byte=path.join(root,'bin/ml2hx/build/frontend.byte');
  if(fs.existsSync(byte)) {
    const ir=JSON.parse(execute(process.env.ML2HX_OCAMLRUN??'ocamlrun',[byte,'--cmt',cmt]));
    const config={source:'semantics.ml',package:'semantics',class:'Semantics'};
    assert.equal(format(new Emitter(config).emit(ir.files[0])),format(new Emitter(config).emit(frontend([path.join(dir,'semantics.ml')]).files[0])));
    if(!process.env.ML2HX_FRONTEND)assert.throws(()=>frontend(['--cmt',cmt]),/native 64-bit frontend/);
  }
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
