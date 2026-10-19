package ml2hx.std;

import ml2hx.rt.*;

enum DynlinkLinkingError {
	Undefined_global(v0:String);
	Unavailable_primitive(v0:String);
	Uninitialized_global(v0:String);
}

enum DynlinkError {
	Not_a_bytecode_file(v0:String);
	Inconsistent_import(v0:String);
	Unavailable_unit(v0:String);
	Unsafe_file;
	Linking_error(v0:String, v1:DynlinkLinkingError);
	Corrupted_interface(v0:String);
	Cannot_open_dynamic_library(v0:MlException);
	Library_s_module_initializers_failed(v0:MlException);
	Inconsistent_implementation(v0:String);
	Module_already_loaded(v0:String);
	Private_library_cannot_implement_interface(v0:String);
}

class DynlinkErrorExn extends MlException {
	public final v0:DynlinkError;
	public function new(v0:DynlinkError) {
		super();
		this.v0 = v0;
	}
	override public function exnArity():Int return 1;
	override public function exnArg(i:Int):Dynamic return i == 0 ? v0 : super.exnArg(i);
	override public function exnName():String return "Dynlink.Error";
}

// Dynlink: the generated program cannot load OCaml object files, as a native
// program on a platform without dynamic loading: every load fails with the
// library unopenable.
class Dynlink {
	public static final isNative = true;
	public static function adaptFilename(f:String):String {
		return StringTools.endsWith(f, ".cmo") ? f.substr(0, f.length - 4) + ".cmxs" : StringTools.endsWith(f, ".cma") ? f.substr(0, f.length - 4) + ".cmxs" : f;
	}
	public static function loadfile(f:String):Unit
		throw new DynlinkErrorExn(Cannot_open_dynamic_library(new Failure(f + ": dynamic loading is not supported")));
	public static function loadfilePrivate(f:String):Unit return loadfile(f);
	public static function errorMessage(e:DynlinkError):String {
		return switch e {
			case Not_a_bytecode_file(n): n + " is not an object file";
			case Inconsistent_import(n): "interface mismatch on " + n;
			case Unavailable_unit(n): "no implementation available for " + n;
			case Unsafe_file: "this object file uses unsafe features";
			case Linking_error(n, Undefined_global(s)): "error while linking " + n + ".\nReference to undefined global " + s;
			case Linking_error(n, Unavailable_primitive(s)): "error while linking " + n + ".\nThe external function `" + s + "' is not available";
			case Linking_error(n, Uninitialized_global(s)): "error while linking " + n + ".\nThe module `" + s + "' is not yet initialized";
			case Corrupted_interface(n): "corrupted interface file " + n;
			case Cannot_open_dynamic_library(exn): "error loading shared library: " + exn.toString();
			case Library_s_module_initializers_failed(exn): "execution of module initializers in the shared library failed: " + exn.toString();
			case Inconsistent_implementation(n): "implementation mismatch on " + n;
			case Module_already_loaded(n): "The module `" + n + "' is already loaded (either by the main program or a previously-dynlinked library)";
			case Private_library_cannot_implement_interface(n): "The module `" + n + "' is already loaded (either by the main program or a previously-dynlinked library)";
		}
	}
}
