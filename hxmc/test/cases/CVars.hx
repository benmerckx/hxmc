import hxmc.unsafe.*;

// C variables (docs/interop.md, "C variables"): statics of @:hxmc.c extern
// classes, read and written at their addresses, of an object linked
// statically (CVars.c) and of a dynamic library (CVars_dyn.c: a DLL on
// Windows, a dylib on macOS, statically linked on Linux): scalars of every
// width, a CString, a struct (read as a copy, its fields written in place).
@:hxmc.struct @:publicFields class Pt {
	var x:Int32;
	var y:Float;
}

@:hxmc.c extern class Vars {
	static var v_counter:Int;
	@:native("v_ratio") static var ratio:Float;
	static var v_small:Int8;
	static var v_wide:UInt16;
	static var v_flag:Bool;
	static var v_quarter:Float32;
	static var v_big:Int64;
	static final v_label:CString;
	static var v_origin:Pt;
	static function v_get_counter():Int;
	static function v_origin_y():Float;
}

@:hxmc.c @:hxmc.lib("cvarsdyn") extern class DynVars {
	static var dyn_count:Int;
	static final dyn_title:CString;
	static function dyn_get_count():Int;
}

class CVars {
	static function main() {
		trace(Vars.v_counter, Vars.ratio, Vars.v_small, Vars.v_wide, Vars.v_flag, Vars.v_quarter, Vars.v_big, Vars.v_label.toString());
		// writes C sees
		Vars.v_counter = 100;
		Vars.v_counter += 2;
		Vars.ratio *= 2;
		Vars.v_flag = !Vars.v_flag;
		Vars.v_small--;
		trace(Vars.v_counter, Vars.v_get_counter(), Vars.ratio, Vars.v_flag, Vars.v_small);
		// a struct: a copy when read, its fields in place, written whole
		var o = Vars.v_origin;
		o.y = 0;
		trace(o.x, o.y, Vars.v_origin.y);
		Vars.v_origin.y = 3.25;
		trace(Vars.v_origin.x, Vars.v_origin.y, Vars.v_origin_y());
		o.x = 1;
		Vars.v_origin = o;
		trace(Vars.v_origin.x, Vars.v_origin_y());
		// a dynamic library's
		trace(DynVars.dyn_count, DynVars.dyn_title.toString());
		DynVars.dyn_count *= 3;
		trace(DynVars.dyn_count, DynVars.dyn_get_count());
	}
}
