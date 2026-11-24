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
		return pid;

	/**
		Query the exit code of the process.
		If `block` is true or not specified, it will block until the process terminates.
		If `block` is false, it will return either the process exit code if it's already terminated or null if it's still running.
		If the process has already exited, return the exit code immediately.
	**/
	public function exitCode(block:Bool = true):Null<Int> {
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
		stdin.close();
		stdout.close();
		stderr.close();
	}

	/**
		Kill the process.
	**/
	public function kill():Void
		NativeSys.processKill(pid);
}
