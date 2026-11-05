package compiler;

// port: not upstream: upstream assigns these forward references during OCaml module
// ... initialization. Static initialization order differs between Haxe targets, so
// ... they are (re)assigned once all statics are initialized, by whatever starts the
// ... compiler (haxe.Main, a CompilerInstance).
class Init {
	public static function initHooks():Void {
		core.Type.initialize();
		core.TUnification.initHooks();
		context.AbstractCast.install(); // port: the JVM initializes classes lazily
		typing.Typer.initialize();
		typing.TyperEntry.initHooks();
		typing.TypeloadFunction.initHooks();
		typing.Generic.initHooks();
		optimization.Analyzer.initHooks();
	}
}
