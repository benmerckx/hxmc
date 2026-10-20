package compiler.server;

import core.Globals;
import core.ds.Hashtbl;
import core.ds.TaskPool;
import context.Parallel;
import compiler.CompilationCache;

@:structInit class ServerCompilationContext {
	public var isServer:Bool;
	public var version:core.Globals.CompilerVersion;
	/* If true, prints some debug information */
	public var verbose:Bool;
	/* The list of changed directories per-signature */
	public var changedDirectories:Hashtbl<String, Array<CachedDirectory>>;
	/* A reference to the compilation server instance */
	public var cs:Cache;
	/* A list of class paths per-signature */
	public var classPaths:Hashtbl<String, Array<String>>;
	/* Increased for each compilation */
	public var compilationStep:Int;
	/* A list of delays which are run after compilation */
	public var delays:Array<Void->Void>;
	/* True if it's an actual compilation, false if it's a display operation */
	public var wasCompilation:Bool;
	/* True if the macro context has been set up */
	public var macroContextSetup:Bool;
	/* Stdin content for the current display request */
	public var currentStdin:Null<String>;
	/* Persistent working directory set via server/setCwd, applied before each request */
	public var persistentCwd:Null<String>;
	/* The server's domain pool. */
	public var pool:ManagedPoolData;

	public inline function new(isServer:Bool, version:core.Globals.CompilerVersion, verbose:Bool,
			changedDirectories:Hashtbl<String, Array<CachedDirectory>>, cs:Cache, classPaths:Hashtbl<String, Array<String>>,
			compilationStep:Int, delays:Array<Void->Void>, wasCompilation:Bool, macroContextSetup:Bool, currentStdin:Null<String>,
			persistentCwd:Null<String>, pool:ManagedPoolData) {
		this.isServer = isServer;
		this.version = version;
		this.verbose = verbose;
		this.changedDirectories = changedDirectories;
		this.cs = cs;
		this.classPaths = classPaths;
		this.compilationStep = compilationStep;
		this.delays = delays;
		this.wasCompilation = wasCompilation;
		this.macroContextSetup = macroContextSetup;
		this.currentStdin = currentStdin;
		this.persistentCwd = persistentCwd;
		this.pool = pool;
	}

	public static function createVersion():core.Globals.CompilerVersion {
		return {
			version: Globals.version,
			major: Globals.versionMajor,
			minor: Globals.versionMinor,
			revision: Globals.versionRevision,
			pre: Globals.versionPre,
			// port: Version.version_extra is generated at build time from Git (prebuild.ml,
			// ADD_REVISION); the reference is the nightly build of the pinned upstream commit
			// (build.haxe.org, branch development): moving the pin updates the hash
			extra: {name: "git build development", build: "066bd83"}
		};
	}

	public static function create(verbose:Bool, isServer:Bool):ServerCompilationContext {
		var pool = ManagedPool.create(function() return new TaskPool(TaskPool.recommendedDomainCount() - 1));
		return {
			isServer: isServer,
			version: createVersion(),
			verbose: verbose,
			cs: new Cache(),
			classPaths: new Hashtbl(0),
			changedDirectories: new Hashtbl(0),
			compilationStep: 0,
			delays: [],
			wasCompilation: false,
			macroContextSetup: false,
			currentStdin: null,
			persistentCwd: null,
			pool: pool
		};
	}

	public static function dispose(sctx:ServerCompilationContext):Void {
		ManagedPool.release(sctx.pool);
	}

	public static function addDelay(sctx:ServerCompilationContext, f:Void->Void):Void {
		sctx.delays.unshift(f);
	}

	public static function runDelays(sctx:ServerCompilationContext):Void {
		var fl = sctx.delays;
		sctx.delays = [];
		for (f in fl) f();
	}

	/* Resets the state for a new compilation */
	public static function reset(sctx:ServerCompilationContext):Void {
		sctx.changedDirectories.clear();
		sctx.wasCompilation = false;
		syntax.Parser.resetState();
	}
}
