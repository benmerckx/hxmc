// hxmc: haxe/upstream/std/hl/_std/haxe/Exception.hx, the stacks of the
// runtime (haxe.NativeStackTrace, hxmc.rt.Stacks): an exception records the
// stack where it is made, or for a value caught the stack of its throw, when
// the program reads exception stacks (hxmc.rt.Stacks.flags); the frames of
// its constructors and of thrown/caught are left out by their names (hl
// counts them: __skipStack)

package haxe;

class Exception {
	public var message(get, never):String;
	public var stack(get, set):CallStack;
	public var previous(get, never):Null<Exception>;
	public var native(get, never):Any;

	@:noCompletion var __exceptionMessage:String;
	@:noCompletion var __previousException:Null<Exception>;
	@:noCompletion var __exceptionStack:Null<CallStack>;
	@:noCompletion var __nativeStack:Any;
	@:noCompletion var __nativeException:Any;

	// hxmc: caught/thrown are called by the backend for each catch and throw of a
	// haxe.Exception (FnLower.tryStmt, TThrow), not by typed code: keep them
	// under -dce full
	@:keep static function caught(value:Any):Exception {
		var e:Null<Exception> = Std.downcast(cast value, Exception);
		return e != null ? e : new ValueException(value, null, value);
	}

	@:keep static function thrown(value:Any):Any {
		var ex:Null<Exception> = Std.downcast(cast value, Exception);
		return ex != null ? ex.native : new ValueException(value);
	}

	public function new(message:String, ?previous:Exception, ?native:Any) {
		__exceptionMessage = message;
		__previousException = previous;
		#if !hxmc.wasm_gc
		recordStack(this, native != null);
		#end
		__nativeException = native != null ? native : this;
	}

	#if !hxmc.wasm_gc
	// (left out of a program without the table of its functions and lines)
	@:hxmc.withStacks static function recordStack(e:Exception, caught:Bool) {
		if ((hxmc.rt.Stacks.flags() & hxmc.rt.Stacks.STACKS) != 0)
			e.__nativeStack = caught ? hxmc.rt.Stacks.lastThrow() : hxmc.rt.Stacks.capture();
	}
	#end

	function unwrap():Any
		return __nativeException;

	public function toString():String
		return message;

	public function details():String
		return inline CallStack.exceptionToString(this);

	function get_message():String
		return __exceptionMessage;

	function get_previous():Null<Exception>
		return __previousException;

	final function get_native():Any
		return __nativeException;

	// (hxcoro copies stacks between exceptions: set_stack)
	function get_stack():CallStack {
		if (__exceptionStack == null) {
			#if hxmc.wasm_gc
			__exceptionStack = [];
			#else
			var top = hxmc.rt.Stacks.constructors(this);
			top.push("haxe.Exception.recordStack");
			top.push("haxe.Exception.thrown");
			top.push("haxe.Exception.caught");
			__exceptionStack = NativeStackTrace.toHaxeSkipping(__nativeStack, 0, top);
			#end
		}
		return __exceptionStack;
	}

	function set_stack(stack:CallStack):CallStack
		return __exceptionStack = stack;
}
