package hxmc;

// The compiler's side of the macro API for macro code compiled for hxmc
// (-D hxmc.macros=mir: hxmc/src/hxmc/interp/MirMacros.hx exports these from
// the compiler that loads the macro code)
@:keep @:hxmc.rt extern class MacroHost {
	// the API function `name` (haxe.macro.Context.load): a closure of the compiler's
	@:native("hxmc_mir_macro_load") static function load(name:String, nargs:Int):Dynamic;
	// a position of the macro code's source (reification's `$__mk_pos__`)
	@:native("hxmc_mir_macro_pos") static function pos(file:String, min:Int, max:Int):Dynamic;
	// Sys.programPath as macros see it (Eval's: the full path of the compilation's main file, or null)
	@:native("hxmc_mir_macro_program_path") static function programPath():Null<String>;
	// Sys as macros see it, Eval's (EvalStdLibB.StdSys): the request's streams (the
	// client's under the compilation server), the compilation's arguments, its
	// commands, its end
	@:native("hxmc_mir_macro_stdout") static function stdout():haxe.io.Output;
	@:native("hxmc_mir_macro_stderr") static function stderr():haxe.io.Output;
	@:native("hxmc_mir_macro_stdin") static function stdin():haxe.io.Input;
	@:native("hxmc_mir_macro_print") static function print(s:String):Void;
	@:native("hxmc_mir_macro_get_char") static function getChar(echo:Bool):Int;
	@:native("hxmc_mir_macro_args") static function args():Array<String>;
	@:native("hxmc_mir_macro_command") static function command(cmd:String):Int;
	@:native("hxmc_mir_macro_exit") static function exit(code:Int):Void;
}
