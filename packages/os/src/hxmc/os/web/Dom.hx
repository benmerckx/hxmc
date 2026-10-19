package hxmc.os.web;

import hxmc.unsafe.*;

// The browser's side of hxmc.os (WebAssembly): imports of the module
// "hxmc_os", which packages/os/imports.mjs provides (loaded by
// packages/os/browser.mjs). Canvases are handles into the loader's table of
// JavaScript objects (0: none); sizes are in pixels of the drawing buffer.
@:hxmc.c @:hxmc.lib("hxmc_os") extern class Dom {
	// a canvas for a new window (the loader's `canvas` option, else a new
	// element at the end of the page), its buffer width x height CSS pixels
	static function window_open(title:CString, width:Int, height:Int):Int;
	static function window_close(canvas:Int):Void;
	// the canvas element of that id (0: none)
	static function canvas(id:CString):Int;
	static function width(canvas:Int):Int;
	static function height(canvas:Int):Int;
	// device pixels per CSS pixel
	static function scale():Float;
	// the page's prefers-color-scheme: dark (1) or not (0)
	static function prefers_dark():Int;
	// the next pending event into ev (seven Int32: canvas, EventKind, key (a
	// TextInput's code point, a TextEditing's string handle, 0 for none), x,
	// y, button, mods); 0: none
	static function next_event(ev:Ptr<Int32>):Int;
	// the clipboard: write; read (its text comes back as an event of kind 100,
	// key: a string handle, 0 for none)
	static function clipboard_write(text:CString):Void;
	static function clipboard_read():Void;
	// a string handle's UTF-8 length; its bytes into p (the handle freed)
	static function text_length(h:Int):Int;
	static function text_take(h:Int, p:Ptr):Void;
	// text input on (its input element focused, at that area in buffer
	// pixels) or off (the canvas focused again)
	static function text_input(canvas:Int, on:Int, x:Int, y:Int, width:Int, height:Int):Void;
	// the canvas's CSS cursor, by Cursor
	static function set_cursor(canvas:Int, cursor:Int):Void;
	// the page's title; the canvas's CSS size (min: its minimum)
	static function set_title(title:Ptr):Void;
	static function set_size(canvas:Int, width:Int, height:Int, min:Int):Void;
	// a touch drag's question (Window.scrollsAt): the page calls query (a
	// @:hxmc.callback (canvas, x, y, dx, dy):Int, buffer pixels; 1 yes, 0
	// no, -1 not asked) when it would pan the page otherwise
	static function scrolls_at(query:Ptr):Void;
	// requestAnimationFrame calls frame (a @:hxmc.callback ():Int) until it returns 0
	static function start(frame:Ptr):Void;
	// a fetch of url (relative to the page) started: its handle; its state (0
	// loading, 1 done, -1 failed), its body's length, the body into p (the
	// handle freed; also fetch_free without taking it)
	// gamepad i's buttons (17 Float32: their values, 0 to 1) then axes (4
	// Float32) into p, the standard mapping's; 1 when it is there, else 0
	static function gamepad_state(i:Int, p:Ptr):Int;
	static function fetch_start(url:CString):Int;
	static function fetch_state(h:Int):Int;
	static function fetch_length(h:Int):Int;
	static function fetch_take(h:Int, p:Ptr):Void;
	static function fetch_free(h:Int):Void;
}
