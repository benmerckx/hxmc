/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
// hxmc: upstream's std/js/_std/Reflect.hx for -D hxmc.js=es: a property's accessor methods are in its class's
// metadata (js.Boot); a property that is a JavaScript accessor has none
@:coreApi class Reflect {
	@:pure
	public inline static function hasField(o:Dynamic, field:String):Bool {
		return js.lib.Object.prototype.hasOwnProperty.call(o, field);
	}

	@:pure
	public static function field(o:Dynamic, field:String):Dynamic {
		try
			return callable(o[cast field])
		catch (e:Dynamic)
			return null;
	}

	public inline static function setField(o:Dynamic, field:String, value:Dynamic):Void {
		o[cast field] = value;
	}

	public static function getProperty(o:Dynamic, field:String):Dynamic untyped {
		var tmp;
		return if (o == null) __define_feature__("Reflect.getProperty",
			null) else if ((tmp = accessor(o, "get_" + field)) != null) o[tmp]() else callable(o[field]);
	}

	// (an enum's constructor, which only `new` constructs: a function constructing, as Haxe calls it)
	static function callable(v:Dynamic):Dynamic {
		return js.Syntax.typeof(v) == "function" && js.Syntax.instanceof(v.prototype, js.Hx.EnumValue) ? js.Syntax.code("(...a) => new {0}(...a)", v) : v;
	}

	public static function setProperty(o:Dynamic, field:String, value:Dynamic):Void untyped {
		var tmp;
		if ((tmp = accessor(o, "set_" + field)) != null)
			o[tmp](value)
		else
			o[field] = __define_feature__("Reflect.setProperty", value);
	}

	// the method of a class's static property (o a class), or of an instance's (o an instance)
	static function accessor(o:Dynamic, name:String):Null<String> {
		var m = js.Boot.__meta(o);
		if (m != null)
			return m.statics == null ? null : m.statics[cast name];
		var c:Dynamic = js.Syntax.typeof(o) == "object" ? o.constructor : null;
		while (c != null) {
			m = js.Boot.__meta(c);
			if (m != null && m.properties != null && m.properties[cast name] != null)
				return m.properties[cast name];
			c = js.Boot.__super(c);
		}
		return null;
	}

	// (an enum's constructor: constructed)
	public static function callMethod(o:Dynamic, func:haxe.Constraints.Function, args:Array<Dynamic>):Dynamic {
		if (js.Syntax.instanceof((cast func).prototype, js.Hx.EnumValue))
			return js.Syntax.code("new {0}(...{1})", func, args);
		return (cast func : js.lib.Function).apply(o, args);
	}

	// (own enumerable fields: the runtime's are under symbols, which it skips)
	public static function fields(o:Dynamic):Array<String> {
		return o == null ? [] : js.lib.Object.keys(o);
	}

	@:access(js.Boot)
	public static function isFunction(f:Dynamic):Bool {
		return js.Syntax.typeof(f) == "function" && !(js.Boot.isClass(f) || js.Boot.isEnum(f));
	}

	public static function compare<T>(a:T, b:T):Int {
		return (a == b) ? 0 : (((cast a) > (cast b)) ? 1 : -1);
	}

	public static inline function compareMethods(f1:Dynamic, f2:Dynamic):Bool {
		return f1 == f2;
	}

	@:access(js.Boot)
	public static function isObject(v:Dynamic):Bool {
		if (v == null)
			return false;
		var t = js.Syntax.typeof(v);
		return (t == "string" || (t == "object" && !js.Boot.__isEnumValue(v)))
			|| (t == "function" && (js.Boot.isClass(v) || js.Boot.isEnum(v)));
	}

	public static function isEnumValue(v:Dynamic):Bool {
		return js.Boot.__isEnumValue(v);
	}

	public static function deleteField(o:Dynamic, field:String):Bool {
		if (!hasField(o, field))
			return false;
		js.Syntax.delete(o, field);
		return true;
	}

	public static function copy<T>(o:Null<T>):Null<T> {
		if (o == null)
			return null;
		var o2:Dynamic = {};
		for (f in Reflect.fields(o))
			Reflect.setField(o2, f, Reflect.field(o, f));
		return o2;
	}

	public static function makeVarArgs<T>(f:Array<Dynamic>->T):Dynamic {
		return js.Syntax.code("(...a) => {0}(a)", f);
	}
}
