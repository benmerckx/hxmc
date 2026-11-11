package unit;

import core.ds.AtomicLazy;
import core.ds.Hashtbl;
import core.ds.NotFound;
import core.ds.OcamlInt;
import core.ds.OcamlInt.IntParseFailure;
import core.ds.OcamlInt32;
import core.ds.OcamlInt64;
import core.ds.PersistentMap;
import core.ds.Record;
import core.ds.TaskPool;
import haxe.Int64;

/** Runtime contracts used by the newly translated typer and HXB save path. */
class PortRuntimeTest {
 public static function main():Void {
  persistentBindings();
  recordIdentity();
  integerBoundaries();
  parallelCompletion();
  deferredTypes();
  var missingNative=false;
  try core.Native.getNativeName(new haxe.ds.Vector(0)) catch(_:NotFound) missingNative=true;
  check(missingNative,"Absent native metadata must raise the canonical lookup exception used by override checking");
 }
 static function check(condition:Bool,message:String):Void {if(!condition) throw message;}
 static function persistentBindings():Void {
  var empty:PersistentMap<String,Int>=PersistentMap.empty();
  var first=empty.add("z",1).add("a",2),next=first.add("z",3).remove("a");
  check(!empty.mem("z")&&first.find("z")==1&&first.find("a")==2,"Persistent map updates mutated an earlier binding set");
  check(next.find("z")==3&&!next.mem("a"),"Persistent map update/remove failed");
  check([for(k in first.keys())k].join(",")=="a,z","Ordered map traversal must follow key order");
  var table=new Hashtbl<{pack:Array<String>,name:String},Int>();
  table.add({pack:["pkg"],name:"M"},1);
  table.add({pack:["pkg"],name:"M"},2);
  check(table.find({pack:["pkg"],name:"M"})==2,"Structural keys did not find the newest binding");
  table.replace({pack:["pkg"],name:"M"},3);
  table.remove({pack:["pkg"],name:"M"});
  check(table.find({pack:["pkg"],name:"M"})==1,"Removing the newest binding must reveal the older binding");
  table.remove({pack:["pkg"],name:"M"});
  var missing=false;try table.find({pack:["pkg"],name:"M"}) catch(_:NotFound) missing=true;
  check(missing,"Missing lookup must raise the canonical NotFound exception");
 }
 static function recordIdentity():Void {
  var child={value:7},before={name:"old",child:child},after=Record.withFields(before,{name:"new"});
  check(before.name=="old"&&after.name=="new"&&before!=after,"Record update must copy its outer record");
  check(before.child==after.child,"Record update must preserve nested object identity");
  after.child.value=8;check(before.child.value==8,"Record update unexpectedly deep-copied a reference");
 }
 static function integerBoundaries():Void {
  var max=Int64.make(0x7fffffff,-1),min=Int64.make(0x80000000,0);
  check(OcamlInt64.ofString("9223372036854775807")==max,"Int64 signed maximum failed");
  check(OcamlInt64.ofString("-9223372036854775808")==min,"Int64 signed minimum failed");
  check(OcamlInt64.ofString("0xffffffffffffffff")==Int64.ofInt(-1),"Int64 unsigned hexadecimal failed");
  check(OcamlInt64.ofString("0u18446744073709551615")==Int64.ofInt(-1),"Int64 unsigned decimal failed");
  check(OcamlInt64.ofString("-0xffffffffffffffff")==Int64.ofInt(1),"Int64 prefixed negation failed");
  check(OcamlInt32.ofString("2147483647")==0x7fffffff&&OcamlInt32.ofString("-2147483648")==(-2147483647-1),"Int32 signed boundaries failed");
  check(OcamlInt32.ofString("0xffffffff")==-1&&OcamlInt32.ofString("0u4294967295")==-1,"Int32 unsigned boundaries failed");
  check(OcamlInt32.ofString("0b1010_0011")==163&&OcamlInt32.ofString("0o377")==255,"Prefixed literal parsing failed");
  check(OcamlInt.parse("4611686018427387903")==Int64.make(0x3fffffff,-1),"OCaml tagged integer signed maximum failed");
  check(OcamlInt.parse("0x7fffffffffffffff")==Int64.ofInt(-1),"OCaml tagged integer unsigned range failed");
  for(value in ["9223372036854775808","-9223372036854775809","0x10000000000000000","0u18446744073709551616","","_1","0x_1","1z"])
   rejects(()->OcamlInt64.ofString(value),value);
  for(value in ["2147483648","-2147483649","0x100000000","0u4294967296"])
   rejects(()->OcamlInt32.ofString(value),value);
 }
 static function rejects(f:Void->Dynamic,value:String):Void {
  var rejected=false;try f() catch(_:IntParseFailure) rejected=true;
  check(rejected,"Out-of-range or malformed integer was accepted: "+value);
 }
 static function parallelCompletion():Void {
  var pool=new TaskPool(2),lock=new sys.thread.Mutex();
  var visits=[for(_ in 0...31)0];
  var evaluations=0,lazy=AtomicLazy.fromFun(function(){lock.acquire();evaluations++;lock.release();return {value:42};});
  var values=new Array<Dynamic>();values.resize(31);
  pool.parallelFor(0,30,function(i){values[i]=lazy.force();lock.acquire();visits[i]++;lock.release();},2);
  check(evaluations==1,"Concurrent lazy access evaluated the value more than once");
  for(i in 0...31) check(visits[i]==1&&values[i]==values[0],"Parallel work must complete exactly once and retain shared identity");
  var failure=new haxe.Exception("worker failure"),received:Dynamic=null;
  try pool.parallelFor(0,30,i->{if(i==7)throw failure;}) catch(e:Dynamic) received=e;
  check(received==failure,"Worker exception must propagate to the caller");
  var emptyCalls=0;pool.parallelFor(1,0,_ -> emptyCalls++);check(emptyCalls==0,"Empty work range ran callbacks");
  pool.close();
 }
 static function deferredTypes():Void {
  var calls=0,r=context.Common.makeUnforcedLazy(core.TFunctions.tDynamic,function(){calls++;return core.TFunctions.tDynamic;},"runtime-test");
  var proxy:core.TType.T=TLazy(new core.TType.TLazy(LWait(()->core.TFunctions.lazyType(r))));
  core.TFunctions.follow(proxy);core.TFunctions.follow(proxy);
  check(calls==1,"Deferred typer evaluation was not cached through its shared reference");
  check(core.TFunctions.nullModule.mExtra.mSign==haxe.crypto.Md5.encode(""),"Empty module signature must use the port's hexadecimal digest representation");
 }
}
