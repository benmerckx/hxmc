package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;

// The Unix library over Haxe's sys APIs: files, directories, processes
// (sys.io.Process), TCP sockets (sys.net.Socket), time. What the host APIs
// cannot do raises Unix_error (ENOSYS, function, "") naming the call.
enum UnixError {
	E2BIG;
	EACCES;
	EAGAIN;
	EBADF;
	EBUSY;
	ECHILD;
	EDEADLK;
	EDOM;
	EEXIST;
	EFAULT;
	EFBIG;
	EINTR;
	EINVAL;
	EIO;
	EISDIR;
	EMFILE;
	EMLINK;
	ENAMETOOLONG;
	ENFILE;
	ENODEV;
	ENOENT;
	ENOEXEC;
	ENOLCK;
	ENOMEM;
	ENOSPC;
	ENOSYS;
	ENOTDIR;
	ENOTEMPTY;
	ENOTTY;
	ENXIO;
	EPERM;
	EPIPE;
	ERANGE;
	EROFS;
	ESPIPE;
	ESRCH;
	EXDEV;
	EWOULDBLOCK;
	EINPROGRESS;
	EALREADY;
	ENOTSOCK;
	EDESTADDRREQ;
	EMSGSIZE;
	EPROTOTYPE;
	ENOPROTOOPT;
	EPROTONOSUPPORT;
	ESOCKTNOSUPPORT;
	EOPNOTSUPP;
	EPFNOSUPPORT;
	EAFNOSUPPORT;
	EADDRINUSE;
	EADDRNOTAVAIL;
	ENETDOWN;
	ENETUNREACH;
	ENETRESET;
	ECONNABORTED;
	ECONNRESET;
	ENOBUFS;
	EISCONN;
	ENOTCONN;
	ESHUTDOWN;
	ETOOMANYREFS;
	ETIMEDOUT;
	ECONNREFUSED;
	EHOSTDOWN;
	EHOSTUNREACH;
	ELOOP;
	EOVERFLOW;
	EUNKNOWNERR(v0:Int63);
}

class UnixUnixError extends MlException {
	public final v0:UnixError;
	public final v1:String;
	public final v2:String;
	public function new(v0:UnixError, v1:String, v2:String) {
		super();
		this.v0 = v0;
		this.v1 = v1;
		this.v2 = v2;
	}
	override public function exnName():String return "Unix.Unix_error";
	override public function exnArity():Int return 3;
	override public function exnArg(i:Int):Dynamic return switch i { case 0: v0; case 1: v1; case 2: v2; case _: super.exnArg(i); };
}

enum UnixFileKind { S_REG; S_DIR; S_CHR; S_BLK; S_LNK; S_FIFO; S_SOCK; }
enum UnixProcessStatus { WEXITED(v0:Int63); WSIGNALED(v0:Int63); WSTOPPED(v0:Int63); }
enum UnixWaitFlag { WNOHANG; WUNTRACED; }
enum UnixOpenFlag { O_RDONLY; O_WRONLY; O_RDWR; O_NONBLOCK; O_APPEND; O_CREAT; O_TRUNC; O_EXCL; O_NOCTTY; O_DSYNC; O_SYNC; O_RSYNC; O_SHARE_DELETE; O_CLOEXEC; O_KEEPEXEC; }
enum UnixSocketDomain { PF_UNIX; PF_INET; PF_INET6; }
enum UnixSocketType { SOCK_STREAM; SOCK_DGRAM; SOCK_RAW; SOCK_SEQPACKET; }
enum UnixMsgFlag { MSG_OOB; MSG_DONTROUTE; MSG_PEEK; }
enum UnixShutdownCommand { SHUTDOWN_RECEIVE; SHUTDOWN_SEND; SHUTDOWN_ALL; }
enum UnixSockaddr { ADDR_UNIX(v0:String); ADDR_INET(v0:UnixInetAddr, v1:Int63); }
typedef UnixFilePerm = Int63;

class UnixInetAddr {
	public final host:String;
	public function new(host:String) this.host = host;
}

class UnixStats implements Block {
	public final stDev:Int63; public final stIno:Int63; public final stKind:UnixFileKind; public final stPerm:Int63;
	public final stNlink:Int63; public final stUid:Int63; public final stGid:Int63; public final stRdev:Int63;
	public final stSize:Int63; public final stAtime:Float; public final stMtime:Float; public final stCtime:Float;
	public function new(a:Int63, b:Int63, c:UnixFileKind, d:Int63, e:Int63, f:Int63, g:Int63, h:Int63, i:Int63, j:Float, k:Float, l:Float) {
		stDev = a; stIno = b; stKind = c; stPerm = d; stNlink = e; stUid = f; stGid = g; stRdev = h; stSize = i; stAtime = j; stMtime = k; stCtime = l;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 12;
	public function blockField(i:Int):Dynamic return ([stDev, stIno, stKind, stPerm, stNlink, stUid, stGid, stRdev, stSize, stAtime, stMtime, stCtime] : std.Array<Dynamic>)[i];
}

class UnixTm implements Block {
	public final tmSec:Int63; public final tmMin:Int63; public final tmHour:Int63; public final tmMday:Int63; public final tmMon:Int63;
	public final tmYear:Int63; public final tmWday:Int63; public final tmYday:Int63; public final tmIsdst:Bool;
	public function new(a:Int63, b:Int63, c:Int63, d:Int63, e:Int63, f:Int63, g:Int63, h:Int63, i:Bool) {
		tmSec = a; tmMin = b; tmHour = c; tmMday = d; tmMon = e; tmYear = f; tmWday = g; tmYday = h; tmIsdst = i;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 9;
	public function blockField(i:Int):Dynamic return ([tmSec, tmMin, tmHour, tmMday, tmMon, tmYear, tmWday, tmYday, tmIsdst] : std.Array<Dynamic>)[i];
}

// A file descriptor: what the host gives for it.
class UnixFileDescr {
	public var input:Null<haxe.io.Input>;
	public var output:Null<haxe.io.Output>;
	#if sys
	public var socket:Null<sys.net.Socket>;
	public var process:Null<sys.io.Process>;
	#end
	public final id:Int;
	static var next = 3;
	public function new(?id:Int) this.id = id ?? next++;
}

class UnixDirHandle {
	public final entries:HArray<String>;
	public var pos = 0;
	public function new(e:HArray<String>) entries = e;
}

// An in-memory pipe (one thread: written before read).
private class PipeBuffer {
	public final data = new haxe.io.BytesBuffer();
	public var readPos = 0;
	public var closed = false;
	public var bytes:Null<haxe.io.Bytes>;
	public function new() {}
}
private class PipeInput extends haxe.io.Input {
	final p:PipeBuffer;
	public function new(p:PipeBuffer) this.p = p;
	override public function readByte():Int {
		var b = p.data.getBytes();
		// getBytes empties the buffer: keep what is unread
		var all = (p.bytes == null ? haxe.io.Bytes.alloc(0) : p.bytes);
		var merged = haxe.io.Bytes.alloc(all.length + b.length);
		merged.blit(0, all, 0, all.length);
		merged.blit(all.length, b, 0, b.length);
		p.bytes = merged;
		if (p.readPos >= merged.length) throw new haxe.io.Eof();
		return merged.get(p.readPos++);
	}
}
private class PipeOutput extends haxe.io.Output {
	final p:PipeBuffer;
	public function new(p:PipeBuffer) this.p = p;
	override public function writeByte(c:Int) p.data.addByte(c);
}

class Unix {
	static inline function native(s:String):String return ByteString.toNative(s);
	static inline function ocaml(s:String):String return ByteString.ofNative(s);
	static function fail(e:UnixError, fn:String, arg:String):Dynamic throw new UnixUnixError(e, fn, arg);
	static function unsupported(fn:String):Dynamic throw new UnixUnixError(ENOSYS, fn, "");

	public static final stdin = mk(0, true);
	public static final stdout = mk(1, false);
	public static final stderr = mk(2, false);
	static function mk(id:Int, input:Bool):UnixFileDescr {
		var d = new UnixFileDescr(id);
		#if sys
		if (input) d.input = std.Sys.stdin(); else d.output = id == 1 ? std.Sys.stdout() : std.Sys.stderr();
		#end
		return d;
	}

	public static function errorMessage(e:UnixError):String {
		return switch e {
			case E2BIG: "Argument list too long";
			case EACCES: "Permission denied";
			case EAGAIN: "Resource temporarily unavailable";
			case EBADF: "Bad file descriptor";
			case EBUSY: "Device or resource busy";
			case ECHILD: "No child processes";
			case EDEADLK: "Resource deadlock avoided";
			case EDOM: "Numerical argument out of domain";
			case EEXIST: "File exists";
			case EFAULT: "Bad address";
			case EFBIG: "File too large";
			case EINTR: "Interrupted system call";
			case EINVAL: "Invalid argument";
			case EIO: "Input/output error";
			case EISDIR: "Is a directory";
			case EMFILE: "Too many open files";
			case EMLINK: "Too many links";
			case ENAMETOOLONG: "File name too long";
			case ENFILE: "Too many open files in system";
			case ENODEV: "No such device";
			case ENOENT: "No such file or directory";
			case ENOEXEC: "Exec format error";
			case ENOLCK: "No locks available";
			case ENOMEM: "Cannot allocate memory";
			case ENOSPC: "No space left on device";
			case ENOSYS: "Function not implemented";
			case ENOTDIR: "Not a directory";
			case ENOTEMPTY: "Directory not empty";
			case ENOTTY: "Inappropriate ioctl for device";
			case ENXIO: "No such device or address";
			case EPERM: "Operation not permitted";
			case EPIPE: "Broken pipe";
			case ERANGE: "Numerical result out of range";
			case EROFS: "Read-only file system";
			case ESPIPE: "Illegal seek";
			case ESRCH: "No such process";
			case EXDEV: "Invalid cross-device link";
			case EWOULDBLOCK: "Resource temporarily unavailable";
			case EINPROGRESS: "Operation now in progress";
			case EALREADY: "Operation already in progress";
			case ENOTSOCK: "Socket operation on non-socket";
			case EDESTADDRREQ: "Destination address required";
			case EMSGSIZE: "Message too long";
			case EPROTOTYPE: "Protocol wrong type for socket";
			case ENOPROTOOPT: "Protocol not available";
			case EPROTONOSUPPORT: "Protocol not supported";
			case ESOCKTNOSUPPORT: "Socket type not supported";
			case EOPNOTSUPP: "Operation not supported";
			case EPFNOSUPPORT: "Protocol family not supported";
			case EAFNOSUPPORT: "Address family not supported by protocol";
			case EADDRINUSE: "Address already in use";
			case EADDRNOTAVAIL: "Cannot assign requested address";
			case ENETDOWN: "Network is down";
			case ENETUNREACH: "Network is unreachable";
			case ENETRESET: "Network dropped connection on reset";
			case ECONNABORTED: "Software caused connection abort";
			case ECONNRESET: "Connection reset by peer";
			case ENOBUFS: "No buffer space available";
			case EISCONN: "Transport endpoint is already connected";
			case ENOTCONN: "Transport endpoint is not connected";
			case ESHUTDOWN: "Cannot send after transport endpoint shutdown";
			case ETOOMANYREFS: "Too many references: cannot splice";
			case ETIMEDOUT: "Connection timed out";
			case ECONNREFUSED: "Connection refused";
			case EHOSTDOWN: "Host is down";
			case EHOSTUNREACH: "No route to host";
			case ELOOP: "Too many levels of symbolic links";
			case EOVERFLOW: "Value too large for defined data type";
			case EUNKNOWNERR(n): "Unknown error " + n.toString();
		}
	}

	// ---------------------------------------------------------------- time
	public static function time(_:Unit):Float return Date.now().getTime() / 1000;
	public static function gettimeofday(_:Unit):Float return haxe.Timer.stamp() + offset;
	static final offset = Date.now().getTime() / 1000 - haxe.Timer.stamp();
	public static function localtime(t:Float):UnixTm {
		var d = Date.fromTime(t * 1000);
		var start = new Date(d.getFullYear(), 0, 1, 0, 0, 0);
		var yday = Std.int((new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0).getTime() - start.getTime()) / 86400000 + 0.5);
		return new UnixTm(Int63.ofInt(d.getSeconds()), Int63.ofInt(d.getMinutes()), Int63.ofInt(d.getHours()), Int63.ofInt(d.getDate()), Int63.ofInt(d.getMonth()),
			Int63.ofInt(d.getFullYear() - 1900), Int63.ofInt(d.getDay()), Int63.ofInt(yday), false);
	}
	public static function gmtime(t:Float):UnixTm {
		var d = Date.fromTime(t * 1000);
		var u = DateTools.delta(d, d.getTimezoneOffset() * 60000.0);
		return localtime(u.getTime() / 1000);
	}
	public static function mktime(tm:UnixTm):Tuple2<Float, UnixTm> {
		var d = new Date(tm.tmYear.toInt() + 1900, tm.tmMon.toInt(), tm.tmMday.toInt(), tm.tmHour.toInt(), tm.tmMin.toInt(), tm.tmSec.toInt());
		var t = Math.ffloor(d.getTime() / 1000);
		return new Tuple2(t, localtime(t));
	}
	public static function sleepf(s:Float):Unit { #if sys std.Sys.sleep(s); #end return Unit.value; }
	public static function sleep(s:Int63):Unit return sleepf(s.toInt());

	#if sys
	// ---------------------------------------------------------------- environment, directories
	public static function environment(_:Unit):HArray<String> return [for (k => v in std.Sys.environment()) ocaml(k + "=" + v)];
	public static function getenv(n:String):String {
		var v = std.Sys.getEnv(native(n));
		if (v == null) throw NotFound.instance;
		return ocaml(v);
	}
	public static function getcwd(_:Unit):String return ml2hx.prim.Sys.camlSysGetcwd(Unit.value);
	public static function chdir(p:String):Unit {
		try std.Sys.setCwd(native(p)) catch (e:Dynamic) fail(ENOENT, "chdir", p);
		return Unit.value;
	}
	public static function mkdir(p:String, perm:Int63):Unit {
		if (sys.FileSystem.exists(native(p))) fail(EEXIST, "mkdir", p);
		try sys.FileSystem.createDirectory(native(p)) catch (e:Dynamic) fail(ENOENT, "mkdir", p);
		return Unit.value;
	}
	public static function rmdir(p:String):Unit {
		try sys.FileSystem.deleteDirectory(native(p)) catch (e:Dynamic) fail(ENOTEMPTY, "rmdir", p);
		return Unit.value;
	}
	public static function unlink(p:String):Unit {
		try sys.FileSystem.deleteFile(native(p)) catch (e:Dynamic) fail(ENOENT, "unlink", p);
		return Unit.value;
	}
	public static function rename(a:String, b:String):Unit {
		try sys.FileSystem.rename(native(a), native(b)) catch (e:Dynamic) fail(ENOENT, "rename", a);
		return Unit.value;
	}
	public static function opendir(p:String):UnixDirHandle {
		if (!sys.FileSystem.exists(native(p))) fail(ENOENT, "opendir", p);
		if (!sys.FileSystem.isDirectory(native(p))) fail(ENOTDIR, "opendir", p);
		return new UnixDirHandle([".", ".."].concat([for (e in sys.FileSystem.readDirectory(native(p))) ocaml(e)]));
	}
	public static function readdir(d:UnixDirHandle):String {
		if (d.pos >= d.entries.length) throw EndOfFile.instance;
		return d.entries[d.pos++];
	}
	public static function rewinddir(d:UnixDirHandle):Unit { d.pos = 0; return Unit.value; }
	public static function closedir(d:UnixDirHandle):Unit return Unit.value;
	public static function stat(p:String):UnixStats {
		var n = native(p);
		if (!sys.FileSystem.exists(n)) fail(ENOENT, "stat", p);
		var s = sys.FileSystem.stat(n);
		var mode = s.mode;
		var kind = switch (mode & 0xF000) {
			case 0x4000: S_DIR; case 0x2000: S_CHR; case 0x6000: S_BLK; case 0xA000: S_LNK; case 0x1000: S_FIFO; case 0xC000: S_SOCK; case _: S_REG;
		};
		return new UnixStats(Int63.ofInt(s.dev), Int63.ofInt(s.ino), kind, Int63.ofInt(mode & 0xFFF), Int63.ofInt(s.nlink), Int63.ofInt(s.uid), Int63.ofInt(s.gid),
			Int63.ofInt(s.rdev), Int63.ofInt(s.size), s.atime.getTime() / 1000, s.mtime.getTime() / 1000, s.ctime.getTime() / 1000);
	}
	public static function lstat(p:String):UnixStats return stat(p);
	public static function utimes(p:String, a:Float, m:Float):Unit return unsupported("utimes");

	// ---------------------------------------------------------------- files
	public static function openfile(p:String, flags:MlList<UnixOpenFlag>, perm:Int63):UnixFileDescr {
		var fl = [];
		var l = flags;
		while (true) switch l { case Nil: break; case Cons(h, t): fl.push(h); l = t; }
		var n = native(p);
		var d = new UnixFileDescr();
		var write = fl.contains(O_WRONLY) || fl.contains(O_RDWR);
		if (fl.contains(O_EXCL) && fl.contains(O_CREAT) && sys.FileSystem.exists(n)) fail(EEXIST, "open", p);
		if (!write) {
			if (!sys.FileSystem.exists(n)) fail(ENOENT, "open", p);
			d.input = sys.io.File.read(n, true);
		} else {
			if (!fl.contains(O_CREAT) && !sys.FileSystem.exists(n)) fail(ENOENT, "open", p);
			d.output = fl.contains(O_APPEND) ? sys.io.File.append(n, true) : (fl.contains(O_TRUNC) || !sys.FileSystem.exists(n) ? sys.io.File.write(n, true) : sys.io.File.update(n, true));
		}
		return d;
	}
	public static function close(d:UnixFileDescr):Unit {
		try {
			if (d.input != null) d.input.close();
			if (d.output != null) d.output.close();
			if (d.socket != null) d.socket.close();
		} catch (e:Dynamic) fail(EBADF, "close", "");
		return Unit.value;
	}
	public static function read(d:UnixFileDescr, b:haxe.io.Bytes, ofs:Int63, len:Int63):Int63 {
		if (d.input == null && d.socket == null) fail(EBADF, "read", "");
		var i = d.socket != null ? d.socket.input : d.input;
		try return Int63.ofInt(i.readBytes(b, ofs.toInt(), len.toInt())) catch (e:haxe.io.Eof) return Int63.zero;
	}
	public static function write(d:UnixFileDescr, b:haxe.io.Bytes, ofs:Int63, len:Int63):Int63 {
		if (d.output == null && d.socket == null) fail(EBADF, "write", "");
		var o = d.socket != null ? d.socket.output : d.output;
		o.writeFullBytes(b, ofs.toInt(), len.toInt());
		o.flush();
		return len;
	}
	public static function singleWrite(d:UnixFileDescr, b:haxe.io.Bytes, ofs:Int63, len:Int63):Int63 return write(d, b, ofs, len);
	public static function writeSubstring(d:UnixFileDescr, s:String, ofs:Int63, len:Int63):Int63
		return write(d, ByteString.toBytes(s.substr(ofs.toInt(), len.toInt())), Int63.zero, len);
	static final channelDescr = new haxe.ds.ObjectMap<Dynamic, UnixFileDescr>();
	public static function inChannelOfDescr(d:UnixFileDescr):ml2hx.prim.Io.InChannel {
		var c = ml2hx.prim.Io.inOfInput(d.socket != null ? d.socket.input : d.input);
		channelDescr.set(c, d);
		return c;
	}
	public static function outChannelOfDescr(d:UnixFileDescr):ml2hx.prim.Io.OutChannel {
		var c = ml2hx.prim.Io.outOfOutput(d.socket != null ? d.socket.output : d.output);
		channelDescr.set(c, d);
		return c;
	}
	public static function descrOfInChannel(c:ml2hx.prim.Io.InChannel):UnixFileDescr {
		if (c.fd == 0) return stdin;
		var d = channelDescr.get(c);
		return d != null ? d : fail(EBADF, "descr_of_in_channel", "");
	}
	public static function descrOfOutChannel(c:ml2hx.prim.Io.OutChannel):UnixFileDescr {
		if (c.fd == 1) return stdout;
		if (c.fd == 2) return stderr;
		var d = channelDescr.get(c);
		return d != null ? d : fail(EBADF, "descr_of_out_channel", "");
	}
	public static function dup(d:UnixFileDescr, ?cloexec:Bool):UnixFileDescr return d;
	public static function setNonblock(d:UnixFileDescr):Unit return Unit.value;
	public static function clearNonblock(d:UnixFileDescr):Unit return Unit.value;
	public static function setCloseOnExec(d:UnixFileDescr):Unit return Unit.value;
	public static function pipe(_:Unit, ?cloexec:Bool):Tuple2<UnixFileDescr, UnixFileDescr> {
		var p = new PipeBuffer();
		var r = new UnixFileDescr(), w = new UnixFileDescr();
		r.input = new PipeInput(p);
		w.output = new PipeOutput(p);
		return new Tuple2(r, w);
	}

	// ---------------------------------------------------------------- processes
	static final processes = new haxe.ds.IntMap<sys.io.Process>();
	static function spawn(prog:String, args:Null<HArray<String>>):sys.io.Process {
		var p = try new sys.io.Process(native(prog), args == null ? null : [for (a in args) native(a)]) catch (e:Dynamic) fail(ENOENT, "create_process", prog);
		processes.set(p.getPid(), p);
		return p;
	}
	static function status(code:Int):UnixProcessStatus return WEXITED(Int63.ofInt(code));
	public static function openProcessIn(cmd:String):ml2hx.prim.Io.InChannel {
		var p = spawn(cmd, null);
		var c = ml2hx.prim.Io.inOfInput(p.stdout);
		procChannels.set(c, p);
		return c;
	}
	public static function openProcessArgsIn(prog:String, args:HArray<String>):ml2hx.prim.Io.InChannel {
		var p = spawn(prog, args.slice(1));
		var c = ml2hx.prim.Io.inOfInput(p.stdout);
		procChannels.set(c, p);
		return c;
	}
	static final procChannels = new haxe.ds.ObjectMap<Dynamic, sys.io.Process>();
	public static function closeProcessIn(c:ml2hx.prim.Io.InChannel):UnixProcessStatus {
		var p = procChannels.get(c);
		if (p == null) fail(EINVAL, "close_process_in", "");
		return status(p.exitCode());
	}
	static function full(p:sys.io.Process):Tuple3<ml2hx.prim.Io.InChannel, ml2hx.prim.Io.OutChannel, ml2hx.prim.Io.InChannel> {
		var t = new Tuple3(ml2hx.prim.Io.inOfInput(p.stdout), ml2hx.prim.Io.outOfOutput(p.stdin), ml2hx.prim.Io.inOfInput(p.stderr));
		procChannels.set(t.v0, p);
		return t;
	}
	public static function openProcessFull(cmd:String, env:HArray<String>):Tuple3<ml2hx.prim.Io.InChannel, ml2hx.prim.Io.OutChannel, ml2hx.prim.Io.InChannel> return full(spawn(cmd, null));
	public static function openProcessArgsFull(prog:String, args:HArray<String>, env:HArray<String>):Tuple3<ml2hx.prim.Io.InChannel, ml2hx.prim.Io.OutChannel, ml2hx.prim.Io.InChannel>
		return full(spawn(prog, args.slice(1)));
	public static function processFullPid(t:Tuple3<ml2hx.prim.Io.InChannel, ml2hx.prim.Io.OutChannel, ml2hx.prim.Io.InChannel>):Int63 {
		var p = procChannels.get(t.v0);
		if (p == null) fail(EINVAL, "process_full_pid", "");
		return Int63.ofInt(p.getPid());
	}
	public static function closeProcessFull(t:Tuple3<ml2hx.prim.Io.InChannel, ml2hx.prim.Io.OutChannel, ml2hx.prim.Io.InChannel>):UnixProcessStatus {
		var p = procChannels.get(t.v0);
		if (p == null) fail(EINVAL, "close_process_full", "");
		try p.stdin.close() catch (e:Dynamic) {}
		return status(p.exitCode());
	}
	// create_process: the child's standard streams are copied to the given
	// descriptors when it is waited for (one thread: no concurrent pumping).
	static final pending = new haxe.ds.IntMap<{out:UnixFileDescr, err:UnixFileDescr}>();
	public static function createProcess(prog:String, args:HArray<String>, sin:UnixFileDescr, sout:UnixFileDescr, serr:UnixFileDescr):Int63 {
		var p = spawn(prog, args.slice(1));
		if (sin != stdin && sin.input != null) { try p.stdin.write(sin.input.readAll()) catch (e:Dynamic) {} }
		try p.stdin.close() catch (e:Dynamic) {}
		pending.set(p.getPid(), {out: sout, err: serr});
		return Int63.ofInt(p.getPid());
	}
	public static function createProcessEnv(prog:String, args:HArray<String>, env:HArray<String>, sin:UnixFileDescr, sout:UnixFileDescr, serr:UnixFileDescr):Int63
		return createProcess(prog, args, sin, sout, serr);
	public static function waitpid(flags:MlList<UnixWaitFlag>, pid:Int63):Tuple2<Int63, UnixProcessStatus> {
		var p = processes.get(pid.toInt());
		if (p == null) fail(ECHILD, "waitpid", "");
		var target = pending.get(pid.toInt());
		if (target != null) {
			var o = p.stdout.readAll(), e = p.stderr.readAll();
			if (target.out.output != null) { target.out.output.write(o); target.out.output.flush(); }
			if (target.err.output != null) { target.err.output.write(e); target.err.output.flush(); }
			pending.remove(pid.toInt());
		}
		var code = p.exitCode();
		processes.remove(pid.toInt());
		return new Tuple2(pid, status(code));
	}
	public static function wait(_:Unit):Tuple2<Int63, UnixProcessStatus> {
		for (pid in processes.keys()) return waitpid(Nil, Int63.ofInt(pid));
		return fail(ECHILD, "wait", "");
	}
	public static function kill(pid:Int63, sig:Int63):Unit {
		var p = processes.get(pid.toInt());
		if (p == null) fail(ESRCH, "kill", "");
		p.kill();
		return Unit.value;
	}
	public static function getpid(_:Unit):Int63 return Int63.ofInt(0);

	// ---------------------------------------------------------------- sockets
	public static function inetAddrOfString(s:String):UnixInetAddr return new UnixInetAddr(s);
	public static function stringOfInetAddr(a:UnixInetAddr):String return a.host;
	public static final inetAddrAny = new UnixInetAddr("0.0.0.0");
	public static final inetAddrLoopback = new UnixInetAddr("127.0.0.1");
	public static function socket(dom:UnixSocketDomain, ty:UnixSocketType, proto:Int63, ?cloexec:Bool):UnixFileDescr {
		if (ty != SOCK_STREAM || dom == PF_UNIX) return unsupported("socket");
		var d = new UnixFileDescr();
		d.socket = new sys.net.Socket();
		return d;
	}
	public static function connect(d:UnixFileDescr, a:UnixSockaddr):Unit {
		switch a {
			case ADDR_INET(h, port):
				try d.socket.connect(new sys.net.Host(h.host), port.toInt()) catch (e:Dynamic) fail(ECONNREFUSED, "connect", "");
			case ADDR_UNIX(_): unsupported("connect");
		}
		return Unit.value;
	}
	public static function bind(d:UnixFileDescr, a:UnixSockaddr):Unit {
		switch a {
			case ADDR_INET(h, port): try d.socket.bind(new sys.net.Host(h.host), port.toInt()) catch (e:Dynamic) fail(EADDRINUSE, "bind", "");
			case ADDR_UNIX(_): unsupported("bind");
		}
		return Unit.value;
	}
	public static function listen(d:UnixFileDescr, n:Int63):Unit { d.socket.listen(n.toInt()); return Unit.value; }
	public static function accept(d:UnixFileDescr, ?cloexec:Bool):Tuple2<UnixFileDescr, UnixSockaddr> {
		var c = new UnixFileDescr();
		c.socket = d.socket.accept();
		var peer = c.socket.peer();
		return new Tuple2(c, ADDR_INET(new UnixInetAddr(peer.host.toString()), Int63.ofInt(peer.port)));
	}
	public static function send(d:UnixFileDescr, b:haxe.io.Bytes, ofs:Int63, len:Int63, flags:MlList<UnixMsgFlag>):Int63 return write(d, b, ofs, len);
	public static function sendSubstring(d:UnixFileDescr, s:String, ofs:Int63, len:Int63, flags:MlList<UnixMsgFlag>):Int63 return writeSubstring(d, s, ofs, len);
	public static function recv(d:UnixFileDescr, b:haxe.io.Bytes, ofs:Int63, len:Int63, flags:MlList<UnixMsgFlag>):Int63 return read(d, b, ofs, len);
	public static function shutdown(d:UnixFileDescr, c:UnixShutdownCommand):Unit {
		d.socket.shutdown(c != SHUTDOWN_SEND, c != SHUTDOWN_RECEIVE);
		return Unit.value;
	}
	public static function select(r:MlList<UnixFileDescr>, w:MlList<UnixFileDescr>, e:MlList<UnixFileDescr>, timeout:Float):Tuple3<MlList<UnixFileDescr>, MlList<UnixFileDescr>, MlList<UnixFileDescr>> {
		// Descriptors that are not sockets are always ready.
		function arr(l:MlList<UnixFileDescr>) { var a = []; while (true) switch l { case Nil: return a; case Cons(h, t): a.push(h); l = t; } }
		function list(a:HArray<UnixFileDescr>):MlList<UnixFileDescr> { var l:MlList<UnixFileDescr> = Nil, i = a.length; while (i > 0) l = Cons(a[--i], l); return l; }
		var rs = arr(r), ws = arr(w);
		var socks = [for (d in rs) if (d.socket != null) d.socket];
		var wsocks = [for (d in ws) if (d.socket != null) d.socket];
		var res = sys.net.Socket.select(socks, wsocks, [], timeout < 0 ? null : timeout);
		return new Tuple3(list([for (d in rs) if (d.socket == null || res.read.contains(d.socket)) d]), list([for (d in ws) if (d.socket == null || res.write.contains(d.socket)) d]), Nil);
	}
	#end
}
