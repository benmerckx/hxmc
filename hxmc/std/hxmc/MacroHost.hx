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
	// a macro's working directory, Eval's (the compiler's core.Vfs): Sys.getCwd,
	// Sys.setCwd (an error thrown as Eval's, a string), a path of the file system
	// API taken relative to it, a path written dropped from the compilation
	// server's view of the files
	@:native("hxmc_mir_macro_get_cwd") static function getCwd():String;
	@:native("hxmc_mir_macro_set_cwd") static function setCwd(dir:String):Void;
	@:native("hxmc_mir_macro_resolve") static function resolve(path:String):String;
	@:native("hxmc_mir_macro_invalidate") static function invalidate(path:String):Void;
	// sys.io.Process as Eval's: the compiler's process (in the macro's working
	// directory), and its natives (Eval's NativeProcess)
	@:native("hxmc_mir_macro_process") static function process(cmd:String, args:Null<Array<String>>):Dynamic;
	@:native("hxmc_mir_macro_process_read") static function processRead(p:Dynamic, stdout:Bool, bytes:haxe.io.Bytes, pos:Int, len:Int):Int;
	@:native("hxmc_mir_macro_process_write") static function processWrite(p:Dynamic, bytes:haxe.io.Bytes, pos:Int, len:Int):Int;
	@:native("hxmc_mir_macro_process_close_stdin") static function processCloseStdin(p:Dynamic):Void;
	@:native("hxmc_mir_macro_process_exit") static function processExit(p:Dynamic):Int;
	@:native("hxmc_mir_macro_process_pid") static function processPid(p:Dynamic):Int;
	@:native("hxmc_mir_macro_process_close") static function processClose(p:Dynamic):Void;
	@:native("hxmc_mir_macro_process_kill") static function processKill(p:Dynamic):Void;
}
