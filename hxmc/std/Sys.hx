// hxmc: haxe/upstream/std/Sys.hx over hxmc.NativeSys

import hxmc.NativeSys;

/**
	This class provides access to various base functions of system platforms.
	Look in the `sys` package for more system APIs.
**/
class Sys {
	/**
		Prints any value to the standard output.
	**/
	public static function print(v:Dynamic):Void
		NativeSys.print(Std.string(v));

	/**
		Prints any value to the standard output, followed by a newline.
		On Windows, this function outputs a CRLF newline.
		LF newlines are printed on all other platforms.
	**/
	public static function println(v:Dynamic):Void
		NativeSys.print(Std.string(v) + "\n");

	/**
		Returns all the arguments that were passed in the command line.
		This does not include the interpreter or the name of the program file.

		(java)(eval) On Windows, non-ASCII Unicode arguments will not work correctly.
	**/
	public static function args():Array<String>
		return NativeSys.args();

	/**
		Returns the value of the given environment variable, or `null` if it
		doesn't exist.
	**/
	public static function getEnv(s:String):Null<String>
		return NativeSys.getEnv(s);

	/**
		Sets the value of the given environment variable.

		If `v` is `null`, the environment variable is removed.

		(java) This functionality is not available on Java; calling this function will throw.
	**/
	public static function putEnv(s:String, v:Null<String>):Void
		NativeSys.putEnv(s, v);

	/**
		Returns a map of the current environment variables and their values
		as of the invocation of the function.

		(python) On Windows, the variable names are always in upper case.

		(cpp)(hl)(neko) On Windows, the variable names match the last capitalization used when modifying
		the variable if the variable has been modified, otherwise they match their capitalization at
		the start of the process.

		On Windows on remaining targets, variable name capitalization matches however they were capitalized
		at the start of the process or at the moment of their creation.
	**/
	public static function environment():Map<String, String> {
		var m = new Map<String, String>();
		for (kv in NativeSys.environ()) {
			var i = kv.indexOf("=");
			if (i > 0) m.set(kv.substr(0, i), kv.substr(i + 1));
		}
		return m;
	}

	/**
		Suspends execution for the given length of time (in seconds).
	**/
	public static function sleep(seconds:Float):Void
		NativeSys.sleep(seconds);

	/**
		Changes the current time locale, which will affect `DateTools.format` date formatting.
		Returns `true` if the locale was successfully changed.
	**/
	public static function setTimeLocale(loc:String):Bool
		return false;

	/**
		Gets the current working directory (usually the one in which the program was started).
	**/
	public static function getCwd():String
		return NativeSys.getCwd();

	/**
		Changes the current working directory.

		(java) This functionality is not available on Java; calling this function will throw.
	**/
	public static function setCwd(s:String):Void
		if (!NativeSys.setCwd(s)) throw "Could not change directory to " + s;

	/**
		Returns the type of the current system. Possible values are:
		 - `"Windows"`
		 - `"Linux"`
		 - `"BSD"`
		 - `"Mac"`
	**/
	public static function systemName():String
		return NativeSys.systemName();

	static function quote(a:String):String {
		var b = new StringBuf();
		b.add("'");
		for (i in 0...a.length) {
			var c = a.charAt(i);
			b.add(c == "'" ? "'\\''" : c);
		}
		b.add("'");
		return b.toString();
	}

	/**
		Runs the given command. The command output will be printed to the same output as the current process.
		The current process will block until the command terminates.
		The return value is the exit code of the command (usually `0` indicates no error).

		Command arguments can be passed in two ways:

		 1. Using `args` to pass command arguments. Each argument will be automatically quoted and shell meta-characters will be escaped if needed.
		`cmd` should be an executable name that can be located in the `PATH` environment variable, or a full path to an executable.

		 2. When `args` is not given or is `null`, command arguments can be appended to `cmd`. No automatic quoting/escaping will be performed. `cmd` should be formatted exactly as it would be when typed at the command line.
		It can run executables, as well as shell commands that are not executables (e.g. on Windows: `dir`, `cd`, `echo` etc).

		Use the `sys.io.Process` API for more complex tasks, such as background processes, or providing input to the command.
	**/
	public static function command(cmd:String, ?args:Array<String>):Int {
		if (args != null) {
			// Windows (Cosmopolitan builds): run without a shell; -2 elsewhere
			var r = NativeSys.commandArgs(cmd, args);
			if (r != -2)
				return r;
			if (systemName() == "Windows") {
				// native Windows builds: quoted for cmd.exe, as the std of the other sys targets does
				cmd = [
					for (a in [StringTools.replace(cmd, "/", "\\")].concat(args))
						haxe.SysTools.quoteWinArg(a, true)
				].join(" ");
			} else {
				cmd = quote(cmd);
				for (a in args)
					cmd += " " + quote(a);
			}
		}
		return NativeSys.command(cmd);
	}

	/**
		Exits the current process with the given exit code.

		(macro)(eval) Being invoked in a macro or eval context (e.g. with `-x` or `--run`) immediately terminates
		the compilation process, which also prevents the execution of any `--next` sections of compilation arguments.
	**/
	public static function exit(code:Int):Void
		NativeSys.exit(code);

	/**
		Gives the most precise timestamp value available (in seconds).
	**/
	public static function time():Float
		return NativeSys.time();

	/**
	Returns CPU time consumed by the current process or thread, measured in seconds.
		This value only includes the actual time the CPU has actively spent executing 
		instructions for the process/thread and excludes idle or sleep time. The precision 
		and behavior may vary depending on the platform and underlying implementation.
	**/
	public static function cpuTime():Float
		return NativeSys.cpuTime();

	/**
		Returns the path to the current executable that we are running.
	**/
	@:deprecated("Use programPath instead") public static function executablePath():String
		return #if macro programPath() #else NativeSys.programPath() #end;

	/**
		Returns the absolute path to the current program file that we are running.
		Concretely, for an executable binary, it returns the path to the binary.
		For a script (e.g. a PHP file), it returns the path to the script.
	**/
	public static function programPath():String
		return #if macro hxmc.MacroHost.programPath() #else NativeSys.programPath() #end;

	/**
		Reads a single input character from the standard input and returns it.
		Setting `echo` to `true` will also display the character on the output.
	**/
	public static function getChar(echo:Bool):Int
		return NativeSys.getChar(echo);

	static var _stdin:haxe.io.Input;
	static var _stdout:haxe.io.Output;
	static var _stderr:haxe.io.Output;

	/**
		Returns the standard input of the process, from which user input can be read.
		Usually it will block until the user sends a full input line.
		See `getChar` for an alternative.
	**/
	public static function stdin():haxe.io.Input {
		if (_stdin == null) _stdin = @:privateAccess new sys.io.FileInput(0);
		return _stdin;
	}

	/**
		Returns the standard output of the process, to which program output can be written.
	**/
	public static function stdout():haxe.io.Output {
		if (_stdout == null) _stdout = @:privateAccess new sys.io.FileOutput(1);
		return _stdout;
	}

	/**
		Returns the standard error of the process, to which program errors can be written.
	**/
	public static function stderr():haxe.io.Output {
		if (_stderr == null) _stderr = @:privateAccess new sys.io.FileOutput(2);
		return _stderr;
	}
}
