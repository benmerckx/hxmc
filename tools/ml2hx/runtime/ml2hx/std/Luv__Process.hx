package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Process (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvProcessRedirection {
	function new() {}
}

class LuvProcessT {
	function new() {}
}

class Luv__Process {
	public static function disableStdioInheritance(a0:ml2hx.rt.Unit):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function inheritFd(fd:ml2hx.rt.Int63, fromParentFd:ml2hx.rt.Int63, a2:ml2hx.rt.Unit):ml2hx.std.Luv__Process.LuvProcessRedirection { throw new Failure("luv: not available in the generated compiler"); }
	public static function inheritStream<T0>(fd:ml2hx.rt.Int63, fromParentStream:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, a2:ml2hx.rt.Unit):ml2hx.std.Luv__Process.LuvProcessRedirection { throw new Failure("luv: not available in the generated compiler"); }
	public static function killPid(pid:ml2hx.rt.Int63, a1:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function pid(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Int63 { throw new Failure("luv: not available in the generated compiler"); }
	public static function spawn(a13:String, a14:ml2hx.rt.MlList<String>, ?loop:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?onExit:(ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>) -> ((haxe.Int64) -> ((ml2hx.rt.Int63) -> (ml2hx.rt.Unit))), ?environment:ml2hx.rt.MlList<ml2hx.rt.Tuple2<String, String>>, ?workingDirectory:String, ?redirect:ml2hx.rt.MlList<ml2hx.std.Luv__Process.LuvProcessRedirection>, ?uid:ml2hx.rt.Int63, ?gid:ml2hx.rt.Int63, ?windowsVerbatimArguments:Bool, ?detached:Bool, ?windowsHide:Bool, ?windowsHideConsole:Bool, ?windowsHideGui:Bool, ?windowsFilePathExactName:Bool):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static final stderr:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(2);
	public static final stdin:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(0);
	public static final stdout:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(1);
	public static function toParentPipe(fd:ml2hx.rt.Int63, parentPipe:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, a5:ml2hx.rt.Unit, ?readableInChild:Bool, ?writableInChild:Bool, ?overlapped:Bool):ml2hx.std.Luv__Process.LuvProcessRedirection { throw new Failure("luv: not available in the generated compiler"); }
}
