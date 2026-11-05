package hxmc.com;

// COM's root interface (docs/interop.md, "COM"): every @:hxmc.com interface
// extends it. Its three methods (QueryInterface, AddRef, Release: vtable
// slots 0 to 2) are not declared: hxmc counts references itself (a value
// holds one) and QueryInterface is Com.query, Com.as and Std.downcast.
@:hxmc.com("{00000000-0000-0000-C000-000000000046}")
extern interface IUnknown {}
