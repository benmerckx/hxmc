#!/usr/bin/env node
// Sequential, alternating fresh-process measurements. Both binaries compile the
// same inputs after complete generation and a successful compiler build.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {performance} from 'node:perf_hooks';
import {root} from './generate.mjs';
if(fs.readFileSync(path.join(root,'bin/ml2hx/generated/.status'),'utf8')!=='complete\n')throw new Error('full generation must succeed before benchmarking');
const dir=path.join(root,'bin/ml2hx/bench');fs.mkdirSync(dir,{recursive:true});
const rounds=Number(process.env.ML2HX_BENCH_N??5);
if(!Number.isInteger(rounds)||rounds<3)throw new Error('at least three benchmark samples are required');
const time=process.env.ML2HX_TIME??'/usr/bin/time';
if(!fs.existsSync(time))throw new Error('GNU time is required (set ML2HX_TIME to its path)');
const env={...process.env,HAXE_STD_PATH:path.join(root,'haxe/upstream/std'),HXMC_MODULE_CACHE:'0'};
const binaries={current:path.resolve(process.env.ML2HX_BASELINE??path.join(root,'bin/port/haxe')),generated:path.resolve(process.env.ML2HX_GENERATED??path.join(root,'bin/ml2hx/haxe'))};
for(const exe of Object.values(binaries))if(!fs.existsSync(exe))throw new Error(`build ${exe} first`);
const common=['-D','disable-parallelism','--interp','--no-output'];
const cases=[
  {name:'small program to HXB',args:['-cp','tools/ml2hx/test','-main','BenchmarkInput',...common]},
  {name:'compiler sources to HXB',args:['-cp','haxe/src','-main','haxe.Main',...common]}
];
const median=xs=>[...xs].sort((a,b)=>a-b)[Math.floor(xs.length/2)];
function measured(exe,args) {
  const result=path.join(dir,'time.txt'),start=performance.now();
  const p=spawnSync(time,['-f','%e %U %S %M','-o',result,exe,...args],{cwd:root,env,encoding:'utf8',maxBuffer:16*1024*1024,timeout:180000});
  if(p.status!==0)throw new Error(p.error?.message??p.stderr??p.stdout);
  const [wall,user,sys,rss]=fs.readFileSync(result,'utf8').trim().split(/\s+/).map(Number);
  return {wallSeconds:(performance.now()-start)/1000,cpuSeconds:user+sys,peakRssMiB:rss/1024,timeWallSeconds:wall};
}
const rows=[];
for(const c of cases) {
  const samples={current:[],generated:[]};
  // Warm filesystem caches equally; every measured compiler is a fresh process.
  for(const [label,exe] of Object.entries(binaries))measured(exe,[...c.args,'--hxb',path.join(dir,`${label}.hxb`)]);
  for(let i=0;i<rounds;i++) for(const label of i%2?['generated','current']:['current','generated']) samples[label].push(measured(binaries[label],[...c.args,'--hxb',path.join(dir,`${label}.hxb`)]));
  // ZIP metadata may differ; the established HXB comparator handles payloads.
  const values=Object.fromEntries(Object.entries(samples).map(([k,x])=>[k,{wallSeconds:median(x.map(v=>v.wallSeconds)),cpuSeconds:median(x.map(v=>v.cpuSeconds)),peakRssMiB:median(x.map(v=>v.peakRssMiB))}]));
  const row={name:c.name,rounds,values,wallRatio:values.generated.wallSeconds/values.current.wallSeconds,samples};rows.push(row);
  console.log(`${c.name}: current ${values.current.wallSeconds.toFixed(3)}s/${values.current.peakRssMiB.toFixed(1)} MiB; generated ${values.generated.wallSeconds.toFixed(3)}s/${values.generated.peakRssMiB.toFixed(1)} MiB (${row.wallRatio.toFixed(3)}x)`);
}
