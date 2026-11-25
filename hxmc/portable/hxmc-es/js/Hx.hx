package js;

import js.lib.Symbol;

// The runtime of -D hxmc.js=es (hxmc.es.Runtime): the symbols reflection's data is under, the registries, the
// base of enums' values. The generator writes a field of it as the runtime's part it uses.
@:native("$hx") extern class Hx {
	// a class's or enum's path
	static final name:Symbol;
	// the interfaces a class implements (their values)
	static final interfaces:Symbol;
	// an instance's and a class's properties: their accessor methods by name
	static final properties:Symbol;
	static final staticProperties:Symbol;
	// on an interface's value
	static final isInterface:Symbol;
	// a class's variables (Type.getInstanceFields), an interface's fields
	static final fields:Symbol;
	// an enum value's index (on its constructor's prototype), an enum's constructors' names
	static final index:Symbol;
	static final constructs:Symbol;
	// an enum value's enum (on its constructor's prototype)
	static final enumOf:Symbol;
	static final classes:haxe.DynamicAccess<Dynamic>;
	static final enums:haxe.DynamicAccess<Dynamic>;
	static final EnumValue:Dynamic;

	// o[s]
	static inline function get(o:Dynamic, s:Symbol):Dynamic return untyped o[s];

	// o's own o[s], or null
	static inline function own(o:Dynamic, s:Symbol):Dynamic return js.lib.Object.prototype.hasOwnProperty.call(o, s) ? get(o, s) : null;
}
