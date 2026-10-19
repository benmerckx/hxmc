package hxmc.scene.input;

// What drives an action (Actions.bind): a key (hxmc.os's KeySym: a Latin-1
// key's unshifted character, 0xFF51..0xFF54 the arrows, 0x20 Space), a
// mouse button (1 left, 2 middle, 3 right; a tap on a touch screen is the
// left button), a region of the window held down by the mouse or a finger
// (x0, y0, x1, y1 from 0 to 1 of its width and height: on-screen
// buttons), keys as an axis's two directions (negative, positive), a
// gamepad's button or one of its sticks' axes, times scale (any pad;
// hxmc.os.Gamepads' standard layout: PadButton(0) is A, PadAxis(1, -1) the
// left stick up), past a dead zone.
enum Binding {
	Key(key:Int);
	Mouse(button:Int);
	Region(x0:Float, y0:Float, x1:Float, y1:Float);
	KeyAxis(negative:Int, positive:Int);
	PadButton(button:Int);
	PadAxis(axis:Int, scale:Float);
}
