package hxmc.os.win32;

import hxmc.unsafe.*;

// XInput (Windows 8 and later's xinput1_4.dll): Gamepads' Windows back end
@:hxmc.c @:hxmc.lib("xinput1_4") extern class XInput {
	// pad user (0 to 3)'s XINPUT_STATE (16 bytes: packet, buttons, two
	// triggers, four stick axes) into state; 0 when it is there
	static function XInputGetState(user:Int, state:Ptr):Int;
}
