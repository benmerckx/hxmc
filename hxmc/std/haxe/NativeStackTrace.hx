// hxmc: haxe/upstream/std/hl/_std/haxe/NativeStackTrace.hx, the stacks of
// the runtime (hxmc.rt.Stacks: walked through the frame records, named
// through the program's table of functions and lines, hxmc/src/hxmc/StackTable.hx).
// A native stack is the bytes of its return addresses, innermost first; empty
// on WebAssembly (no frame records) and with -D hxmc.no-stacks.

package haxe;

import haxe.CallStack.StackItem;

@:noCompletion
class NativeStackTrace {
	@:ifFeature('haxe.NativeStackTrace.exceptionStack')
	static public inline function saveStack(exception:Any):Void {}

	static public function callStack():Any {
		#if hxmc.wasm_gc
		return null;
		#else
		return hxmc.rt.Stacks.capture();
		#end
	}

	static public function exceptionStack():Any {
		#if hxmc.wasm_gc
		return null;
		#else
		return hxmc.rt.Stacks.lastThrow();
		#end
	}

	// the stack's items from its frame `skip` (the frames of the runtime, of
	// this class and haxe.CallStack at the top, and the functions without a
	// name are not frames of the program: left out)
	static public function toHaxe(native:Any, skip:Int = 0):Array<StackItem>
		return toHaxeSkipping(native, skip, null);

	// toHaxe, also leaving out the top frames named in `top` (an exception's
	// constructors: haxe.Exception.get_stack)
	@:allow(haxe.Exception)
	static function toHaxeSkipping(native:Any, skip:Int, top:Null<Array<String>>):Array<StackItem> {
		var stack:Array<StackItem> = [];
		#if !hxmc.wasm_gc
		if (native == null) return stack;
		var b:haxe.io.Bytes = native;
		var leading = true;
		for (k in 0...(b.length >> 3)) {
			var d = hxmc.rt.Stacks.describe(hxmc.rt.Stacks.at(b, k));
			// (glue without lines: the closures forwarding to a function, adapters)
			if (d == null || d.file == null || hxmc.rt.Stacks.internal(d.name)) continue;
			var name:String = d.name;
			if (leading) {
				if (StringTools.startsWith(name, "haxe.NativeStackTrace.") || StringTools.startsWith(name, "haxe.CallStack.")
					|| (top != null && top.indexOf(name) >= 0))
					continue;
				leading = false;
			}
			if (skip > 0) {
				skip--;
				continue;
			}
			// (a local function: its owner's name, `$` and its number, Lower.lambdaName)
			var local = name.lastIndexOf("$");
			var dot = name.lastIndexOf(".");
			var item = local > 0 ? LocalFunction(Std.parseInt(name.substr(local + 1))) : dot > 0 ? Method(name.substr(0, dot),
				name.substr(dot + 1)) : Module(name);
			stack.push(FilePos(item, d.file, d.line));
		}
		#end
		return stack;
	}
}
