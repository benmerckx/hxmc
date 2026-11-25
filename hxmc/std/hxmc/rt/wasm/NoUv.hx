package hxmc.rt.wasm;

import haxe.io.Bytes;
import hxmc.rt.C;

// hxmc.NativeUv on WebAssembly (docs/hxmc.md, "WebAssembly"): libuv is not
// there, so every call throws, as native builds without libuv would, except
// those EvalLuv calls while it builds its field lists (available is false,
// constants and the version are 0 and ""). Typed only for the programs that
// use the API.
class NoUv {
	static function noUv():Void
		Rt.rt_throw("libuv (eval.luv) is not supported on WebAssembly");

	public static function available():Bool return false;
	public static function lastError():Int { noUv(); return 0; }
	public static function i64Hi():Int { noUv(); return 0; }
	public static function i64Lo():Int { noUv(); return 0; }
	public static function errIndex(code:Int):Int { noUv(); return 0; }
	public static function errCode(index:Int):Int { noUv(); return 0; }
	public static function strerror(code:Int):String { noUv(); return null; }
	public static function errName(code:Int):String { noUv(); return null; }
	public static function translateSysError(sysError:Int):Int { noUv(); return 0; }
	// (read while EvalLuv's field lists are built)
	public static function constant(group:Int, index:Int):Int return 0;
	public static function versionString():String return "";
	public static function versionSuffix():String return "";
	public static function loopDefault():Int { noUv(); return 0; }
	public static function loopInit():Int { noUv(); return 0; }
	public static function loopRun(loop:Int, mode:Int, dispatcher:(id:Int, event:Int, a:Int, b:Dynamic) -> Void):Bool { noUv(); return false; }
	public static function loopStop(loop:Int):Void { noUv(); }
	public static function loopClose(loop:Int):Int { noUv(); return 0; }
	public static function loopAlive(loop:Int):Bool { noUv(); return false; }
	public static function loopNow(loop:Int):Void { noUv(); }
	public static function loopUpdateTime(loop:Int):Void { noUv(); }
	public static function libraryShutdown():Void { noUv(); }
	public static function metricsIdleTime(loop:Int):Void { noUv(); }
	public static function handleInit(kind:Int, loop:Int, arg:Int, arg2:Int):Int { noUv(); return 0; }
	public static function handleClose(handle:Int):Bool { noUv(); return false; }
	public static function handleIsActive(handle:Int):Bool { noUv(); return false; }
	public static function handleIsClosing(handle:Int):Bool { noUv(); return false; }
	public static function handleRef(handle:Int):Void { noUv(); }
	public static function handleUnref(handle:Int):Void { noUv(); }
	public static function handleHasRef(handle:Int):Bool { noUv(); return false; }
	public static function bufferSize(handle:Int, send:Bool, size:Int):Int { noUv(); return 0; }
	public static function watcherStart(handle:Int):Int { noUv(); return 0; }
	public static function watcherStop(handle:Int):Int { noUv(); return 0; }
	public static function timerStart(handle:Int, timeout:Int, repeat:Int):Int { noUv(); return 0; }
	public static function timerStop(handle:Int):Int { noUv(); return 0; }
	public static function timerAgain(handle:Int):Int { noUv(); return 0; }
	public static function timerSetRepeat(handle:Int, repeat:Int):Void { noUv(); }
	public static function timerGetRepeat(handle:Int):Int { noUv(); return 0; }
	public static function timerGetDueIn(handle:Int):Int { noUv(); return 0; }
	public static function asyncSend(handle:Int):Int { noUv(); return 0; }
	public static function signalStart(handle:Int, signum:Int, oneshot:Bool):Int { noUv(); return 0; }
	public static function signalStop(handle:Int):Int { noUv(); return 0; }
	public static function signalSignum(handle:Int):Int { noUv(); return 0; }
	public static function reqNew():Int { noUv(); return 0; }
	public static function reqFree(req:Int):Void { noUv(); }
	public static function reqCancel(req:Int):Int { noUv(); return 0; }
	public static function reqCopyOut(req:Int, b:Bytes, pos:Int, src:Int, len:Int):Void { noUv(); }
	public static function sockaddrSize():Int { noUv(); return 0; }
	public static function sockaddrIp(host:String, port:Int, v6:Bool, out:Bytes):Int { noUv(); return 0; }
	public static function sockaddrPort(sa:Bytes):Int { noUv(); return 0; }
	public static function sockaddrToString(sa:Bytes):Null<String> { noUv(); return null; }
	public static function tcpNoDelay(handle:Int, b:Bool):Int { noUv(); return 0; }
	public static function tcpKeepAlive(handle:Int, enable:Bool, delay:Int):Int { noUv(); return 0; }
	public static function tcpSimultaneousAccepts(handle:Int, b:Bool):Int { noUv(); return 0; }
	public static function tcpBind(handle:Int, sa:Bytes, ipv6only:Bool):Int { noUv(); return 0; }
	public static function sockName(handle:Int, peer:Bool, out:Bytes):Int { noUv(); return 0; }
	public static function tcpConnect(handle:Int, sa:Bytes, req:Int):Int { noUv(); return 0; }
	public static function tcpCloseReset(handle:Int, req:Int):Int { noUv(); return 0; }
	public static function allocSize(n:Int):Void { noUv(); }
	public static function streamShutdown(handle:Int, req:Int):Int { noUv(); return 0; }
	public static function streamListen(handle:Int, backlog:Int):Int { noUv(); return 0; }
	public static function streamAccept(server:Int, client:Int):Int { noUv(); return 0; }
	public static function readStart(handle:Int):Int { noUv(); return 0; }
	public static function readStop(handle:Int):Int { noUv(); return 0; }
	public static function streamWrite(handle:Int, req:Int, data:Bytes, sizes:Array<Int>, sendHandle:Int):Int { noUv(); return 0; }
	public static function streamTryWrite(handle:Int, data:Bytes, sizes:Array<Int>):Int { noUv(); return 0; }
	public static function streamWriteQueueSize(handle:Int):Int { noUv(); return 0; }
	public static function streamIsReadable(handle:Int):Bool { noUv(); return false; }
	public static function streamIsWritable(handle:Int):Bool { noUv(); return false; }
	public static function streamSetBlocking(handle:Int, b:Bool):Int { noUv(); return 0; }
	public static function pipeBind(handle:Int, name:Bytes):Int { noUv(); return 0; }
	public static function pipeOpen(handle:Int, fd:Int):Int { noUv(); return 0; }
	public static function pipeConnect(handle:Int, name:Bytes, req:Int):Void { noUv(); }
	public static function pipeName(handle:Int, peer:Bool):Null<Bytes> { noUv(); return null; }
	public static function pipePendingInstances(handle:Int, n:Int):Void { noUv(); }
	public static function pipePendingType(handle:Int):Int { noUv(); return 0; }
	public static function pipeChmod(handle:Int, mode:Int):Int { noUv(); return 0; }
	public static function ttySetMode(handle:Int, mode:Int):Int { noUv(); return 0; }
	public static function ttyResetMode():Int { noUv(); return 0; }
	public static function ttyGetWinSize(handle:Int):Null<Array<Int>> { noUv(); return null; }
	public static function ttySetVTermState(state:Int):Void { noUv(); }
	public static function ttyGetVTermState():Int { noUv(); return 0; }
	public static function udpBind(handle:Int, sa:Bytes, flags:Int):Int { noUv(); return 0; }
	public static function udpConnect(handle:Int, sa:Null<Bytes>):Int { noUv(); return 0; }
	public static function udpSetMembership(handle:Int, group:String, iface:String, source:Null<String>, join:Bool):Int { noUv(); return 0; }
	public static function udpSetOption(handle:Int, option:Int, value:Int):Int { noUv(); return 0; }
	public static function udpSetMulticastInterface(handle:Int, iface:String):Int { noUv(); return 0; }
	public static function udpSend(handle:Int, req:Int, data:Bytes, sizes:Array<Int>, sa:Null<Bytes>):Int { noUv(); return 0; }
	public static function udpTrySend(handle:Int, data:Bytes, sizes:Array<Int>, sa:Null<Bytes>):Int { noUv(); return 0; }
	public static function udpRecvStart(handle:Int):Int { noUv(); return 0; }
	public static function udpRecvStop(handle:Int):Int { noUv(); return 0; }
	public static function udpSendQueue(handle:Int, count:Bool):Int { noUv(); return 0; }
	public static function processSpawn(loop:Int, cmd:Bytes, args:Array<Bytes>, env:Null<Array<Bytes>>, cwd:Null<Bytes>, flags:Int, uid:Int, gid:Int, redirect:Array<Int>, onExit:Bool):Int { noUv(); return 0; }
	public static function disableStdioInheritance():Void { noUv(); }
	public static function killPid(pid:Int, signum:Int):Int { noUv(); return 0; }
	public static function processPid(handle:Int):Int { noUv(); return 0; }
	public static function processKill(handle:Int, sig:Int):Int { noUv(); return 0; }
	public static function pipe(readFlags:Int, writeFlags:Int, out:Array<Int>):Int { noUv(); return 0; }
	public static function getAddrInfo(loop:Int, req:Int, node:Null<String>, service:Null<String>, family:Int, socktype:Int, protocol:Int, flags:Int, hasHints:Bool):Int { noUv(); return 0; }
	public static function addrInfoResult(req:Int):Array<Dynamic> { noUv(); return null; }
	public static function getNameInfo(loop:Int, req:Int, sa:Bytes, flags:Int):Int { noUv(); return 0; }
	public static function nameInfoResult(req:Int):Array<String> { noUv(); return null; }
	public static function fs(op:Int, loop:Int, req:Int, p1:Null<Bytes>, p2:Null<Bytes>, i1:Int, i2:Int, i3:Int, f1:Float, f2:Float, data:Null<Bytes>, sizes:Null<Array<Int>>):Int { noUv(); return 0; }
	public static function fsResult(req:Int):Int { noUv(); return 0; }
	public static function fsCleanup(req:Int):Void { noUv(); }
	public static function fsPath(req:Int):Null<Bytes> { noUv(); return null; }
	public static function fsPtrString(req:Int):Null<Bytes> { noUv(); return null; }
	public static function fsStat(req:Int, out:Bytes):Void { noUv(); }
	public static function fsStatfs(req:Int, out:Bytes):Void { noUv(); }
	public static function fsDir(req:Int):Int { noUv(); return 0; }
	public static function fsDirents(req:Int):Array<Dynamic> { noUv(); return null; }
	public static function fsScandirNext(req:Int):Null<Array<Dynamic>> { noUv(); return null; }
	public static function fsEventStart(handle:Int, path:Bytes, flags:Int):Int { noUv(); return 0; }
	public static function fsEventStop(handle:Int):Int { noUv(); return 0; }
	public static function fsPollStart(handle:Int, path:Bytes, interval:Int):Int { noUv(); return 0; }
	public static function fsPollStop(handle:Int):Int { noUv(); return 0; }
	public static function random(loop:Int, req:Int, len:Int):Int { noUv(); return 0; }
	public static function getEnv(name:String):Null<Bytes> { noUv(); return null; }
	public static function setEnv(name:String, value:Null<Bytes>):Int { noUv(); return 0; }
	public static function environ():Null<Array<Dynamic>> { noUv(); return null; }
	public static function getTimeOfDay():Int { noUv(); return 0; }
	public static function hrTime():Void { noUv(); }
	public static function sleep(ms:Int):Void { noUv(); }
	public static function path(which:Int):Null<Bytes> { noUv(); return null; }
	public static function chdir(dir:Bytes):Int { noUv(); return 0; }
	public static function interfaceAddresses():Null<Array<Dynamic>> { noUv(); return null; }
	public static function netName(which:Int, index:Int):Null<String> { noUv(); return null; }
	public static function uptime():Float { noUv(); return 0.0; }
	public static function loadAvg():Array<Float> { noUv(); return null; }
	public static function memory(which:Int):Void { noUv(); }
	public static function getPriority(pid:Int):Int { noUv(); return 0; }
	public static function setPriority(pid:Int, priority:Int):Int { noUv(); return 0; }
	public static function getRUsage(out:Bytes):Int { noUv(); return 0; }
	public static function cpuInfo():Null<Array<Dynamic>> { noUv(); return null; }
	public static function uname():Null<Array<String>> { noUv(); return null; }
	public static function getPid():Int { noUv(); return 0; }
	public static function getPPid():Int { noUv(); return 0; }
	public static function getPasswd():Null<Array<Dynamic>> { noUv(); return null; }
	public static function guessHandle(fd:Int):Int { noUv(); return 0; }
}
