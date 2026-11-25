// hxmc: haxe/upstream/std/sys/io/Process.hx over hxmc.NativeSys

package sys.io;

import hxmc.NativeSys;

class Process {
	/**
		Standard output. The output stream where a process writes its output data.
	**/
	public var stdout(default, null):haxe.io.Input;
	/**
		Standard error. The output stream to output error messages or diagnostics.
	**/
	public var stderr(default, null):haxe.io.Input;
	/**
		Standard input. The stream data going into a process.
	**/
	public var stdin(default, null):haxe.io.Output;

	var pid:Int;
	var code:Null<Int>;
	#if macro
	// hxmc: in macro code (-D hxmc.macros=mir), Eval's Process
	// (haxe/upstream/std/eval/_std/sys/io/Process.hx) over the compiler's
	// process, which starts in the macro's working directory
	var proc:Dynamic;
	#end

	/**
		Construct a `Process` object, which run the given command immediately.

		Command arguments can be passed in two ways: 1. using `args`, 2. appending to `cmd` and leaving `args` as `null`.

		 1. When using `args` to pass command arguments, each argument will be automatically quoted, and shell meta-characters will be escaped if needed.
		`cmd` should be an executable name that can be located in the `PATH` environment variable, or a path to an executable.

		 2. When `args` is not given or is `null`, command arguments can be appended to `cmd`. No automatic quoting/escaping will be performed. `cmd` should be formatted exactly as it would be when typed at the command line.
		It can run executables, as well as shell commands that are not executables (e.g. on Windows: `dir`, `cd`, `echo` etc).

		`detached` allows the created process to be standalone. You cannot communicate with it but you can look at its exit code. Not supported on php.

		`close()` should be called when the `Process` is no longer used.
	**/
	public function new(cmd:String, ?args:Array<String>, ?detached:Bool):Void {
		#if macro
		if (detached) {
			throw "Detached process is not supported on this platform";
		}
		proc = hxmc.MacroHost.process(cmd, args);
		stdout = new MacroStdout(proc, true);
		stderr = new MacroStdout(proc, false);
		stdin = new MacroStdin(proc);
		return;
		#end
		var fds = [0, 0, 0];
		pid = NativeSys.processRun(cmd, args, fds);
		if (pid < 0) throw "Process creation failure : " + cmd;
		stdin = @:privateAccess new FileOutput(fds[0]);
		stdout = @:privateAccess new FileInput(fds[1]);
		stderr = @:privateAccess new FileInput(fds[2]);
	}

	/**
		Return the process ID.
	**/
	public function getPid():Int
		return #if macro hxmc.MacroHost.processPid(proc) #else pid #end;

	/**
		Query the exit code of the process.
		If `block` is true or not specified, it will block until the process terminates.
		If `block` is false, it will return either the process exit code if it's already terminated or null if it's still running.
		If the process has already exited, return the exit code immediately.
	**/
	public function exitCode(block:Bool = true):Null<Int> {
		#if macro
		if (block == false)
			throw "Non blocking exitCode() not supported on this platform";
		return hxmc.MacroHost.processExit(proc);
		#end
		if (code == null) {
			var c = NativeSys.processWait(pid, block);
			// Windows: a blocking wait returns the exit code, which may be negative (32 bits)
			if (c >= 0 || (block && Sys.systemName() == "Windows")) code = c;
		}
		return code;
	}

	/**
		Close the process handle and release the associated resources.
		All `Process` fields should not be used after `close()` is called.
	**/
	public function close():Void {
		#if macro
		hxmc.MacroHost.processClose(proc);
		return;
		#end
		stdin.close();
		stdout.close();
		stderr.close();
	}

	/**
		Kill the process.
	**/
	public function kill():Void
		#if macro hxmc.MacroHost.processKill(proc) #else NativeSys.processKill(pid) #end;
}

#if macro
private class MacroStdin extends haxe.io.Output {
	var proc:Dynamic;
	var buf:haxe.io.Bytes;

	public function new(proc:Dynamic) {
		this.proc = proc;
		buf = haxe.io.Bytes.alloc(1);
	}

	public override function close() {
		super.close();
		hxmc.MacroHost.processCloseStdin(proc);
	}

	public override function writeByte(c:Int) {
		buf.set(0, c);
		writeBytes(buf, 0, 1);
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int) {
		try {
			return hxmc.MacroHost.processWrite(proc, buf, pos, len);
		} catch (e:Dynamic) {
			throw new haxe.io.Eof();
		}
	}
}

private class MacroStdout extends haxe.io.Input {
	var proc:Dynamic;
	var out:Bool;
	var buf:haxe.io.Bytes;

	public function new(proc:Dynamic, out:Bool) {
		this.proc = proc;
		this.out = out;
		buf = haxe.io.Bytes.alloc(1);
	}

	public override function readByte() {
		if (readBytes(buf, 0, 1) == 0)
			throw haxe.io.Error.Blocked;
		return buf.get(0);
	}

	public override function readBytes(bytes:haxe.io.Bytes, pos:Int, len:Int):Int {
		try {
			return hxmc.MacroHost.processRead(proc, out, bytes, pos, len);
		} catch (e:Dynamic) {
			throw new haxe.io.Eof();
		}
	}
}
#end
