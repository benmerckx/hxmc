package hxmc;

// The compiler's side of the macro API for macro code compiled for hxmc
// (-D hxmc.mir-macros: hxmc/src/hxmc/interp/MirMacros.hx exports these from
// the compiler that loads the macro code)
@:keep @:hxmc.rt extern class MacroHost {
	// the API function `name` (haxe.macro.Context.load): a closure of the compiler's
	@:native("hxmc_mir_macro_load") static function load(name:String, nargs:Int):Dynamic;
	// a position of the macro code's source (reification's `$__mk_pos__`)
	@:native("hxmc_mir_macro_pos") static function pos(file:String, min:Int, max:Int):Dynamic;
	// Sys.programPath as macros see it (Eval's: the full path of the compilation's main file, or null)
	@:native("hxmc_mir_macro_program_path") static function programPath():Null<String>;
}
