// hxmc.NativeSys.processRun's working directory and environment: the child
// runs in the directory given and sees exactly the variables given (a full
// replacement; NativeSys.environment() is a copy of the current ones to
// start from). On Linux and macOS the child is /bin/sh (also under
// qemu-user, which cannot start the program itself without binfmt); on
// Windows the program itself, which prints what the shell would. The lines
// printed are the parent's checks, the same everywhere.
import hxmc.NativeSys;
import sys.FileSystem;

class ProcessCwdEnv {
	static final DIR = "processcwdenv.tmp";

	static function main() {
		var args = Sys.args();
		if (args.length > 0 && args[0] == "child") {
			Sys.println(Sys.getCwd());
			Sys.println(Sys.getEnv("HXMC_PCE_VAR") ?? "unset");
			Sys.println(Sys.getEnv("HXMC_PCE_PARENT") ?? "unset");
			Sys.println(Sys.getEnv("HXMC_PCE_ONLY") ?? "unset");
			return;
		}
		var win = Sys.systemName() == "Windows";
		if (!FileSystem.exists(DIR)) FileSystem.createDirectory(DIR);
		Sys.putEnv("HXMC_PCE_PARENT", "1");
		// a copy of the environment, changed: the child sees the copy only
		var env = NativeSys.environment();
		Sys.println(env.get("HXMC_PCE_PARENT"));
		env.remove("HXMC_PCE_PARENT");
		env.set("HXMC_PCE_VAR", "hello wörld = 2");
		var lines = run(win, env, DIR);
		var cwd = lines[0];
		// (pwd: no separator at the end; Sys.getCwd: one, on Windows a slash after backslashes)
		if (StringTools.endsWith(cwd, "/") || StringTools.endsWith(cwd, "\\")) cwd = cwd.substr(0, cwd.length - 1);
		Sys.println("cwd: " + (StringTools.endsWith(cwd, "/" + DIR) || StringTools.endsWith(cwd, "\\" + DIR)));
		Sys.println("var: " + lines[1]);
		Sys.println("removed: " + lines[2]);
		// the parent's own directory and environment are unchanged
		Sys.println("parent: " + !StringTools.endsWith(Sys.getCwd(), DIR + "/") + " " + Sys.getEnv("HXMC_PCE_PARENT") + " " + Sys.getEnv("HXMC_PCE_VAR"));
		// no directory and no environment given: the parent's
		var lines = run(win, null, null);
		Sys.println("inherited: " + (lines[0] == Sys.getCwd() || lines[0] + "/" == Sys.getCwd()) + " " + lines[1] + " " + lines[2]);
		// only the variables given (Windows keeps SystemRoot, which programs need)
		var only = ["HXMC_PCE_ONLY" => "alone"];
		if (win) only.set("SystemRoot", Sys.getEnv("SystemRoot"));
		var lines = run(win, only, null);
		Sys.println("only: " + lines[1] + " " + lines[2] + " " + lines[3]);
		// a directory that does not exist: the process is not created
		try {
			run(win, null, DIR + "/missing");
			Sys.println("missing directory: ran");
		} catch (e:Dynamic) {
			Sys.println("missing directory: an exception");
		}
		FileSystem.deleteDirectory(DIR);
	}

	static function run(win:Bool, env:Null<Map<String, String>>, cwd:Null<String>):Array<String> {
		var fds = [0, 0, 0];
		var pid = win ? NativeSys.processRun(Sys.programPath(), ["child"], fds, cwd, env) : NativeSys.processRun("/bin/sh",
			["-c", "pwd; echo \"${HXMC_PCE_VAR-unset}\"; echo \"${HXMC_PCE_PARENT-unset}\"; echo \"${HXMC_PCE_ONLY-unset}\""], fds, cwd, env);
		if (pid < 0) throw "Process creation failure";
		var out = @:privateAccess new sys.io.FileInput(fds[1]);
		var err = @:privateAccess new sys.io.FileInput(fds[2]);
		@:privateAccess new sys.io.FileOutput(fds[0]).close();
		var s = out.readAll().toString();
		err.readAll();
		out.close();
		err.close();
		var code = NativeSys.processWait(pid, true);
		if (code != 0) Sys.println("exit " + code);
		return [for (l in s.split("\n")) StringTools.trim(l)];
	}
}
