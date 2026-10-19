package hxmc.os;

import haxe.io.Bytes;
#if !eval
import hxmc.unsafe.*;
#end

// Gamepads, polled (a game reads them once a step: @hxmc/3d's Actions do):
// up to four, each its buttons and sticks in the browser's standard
// layout (the W3C's "standard" mapping): buttons 0 A (south), 1 B (east),
// 2 X (west), 3 Y (north), 4 and 5 the shoulders, 6 and 7 the triggers
// (pressed past half way), 8 back, 9 start, 10 and 11 the sticks pressed,
// 12 to 15 the pad (up, down, left, right), 16 the guide; axes 0 and 1
// the left stick (x right, y down), 2 and 3 the right stick, -1 to 1.
//
// Back ends: the browser's Gamepad API (navigator.getGamepads, in that
// layout already); Linux's joystick devices (/dev/input/js0 to js3, read
// without waiting; the xpad driver's numbering, an Xbox pad's, mapped to
// the standard one); XInput on Windows (xinput1_4.dll). Elsewhere (macOS,
// Android, iOS) none yet:
// count() is 0. set() feeds a pad from a program (an on-screen stick, a
// test), which poll then leaves alone.
class Gamepads {
	public static inline var MAX = 4;
	public static inline var BUTTONS = 17;
	public static inline var AXES = 4;

	static final buttons:Array<Array<Bool>> = [for (_ in 0...MAX) [for (_ in 0...BUTTONS) false]];
	static final axes:Array<Array<Float>> = [for (_ in 0...MAX) [for (_ in 0...AXES) 0.0]];
	static final live:Array<Bool> = [for (_ in 0...MAX) false];
	static final virtual:Array<Bool> = [for (_ in 0...MAX) false];

	// whether pad i is there (as of the last poll)
	public static function connected(i:Int):Bool
		return i >= 0 && i < MAX && live[i];

	// the pads there
	public static function count():Int {
		var n = 0;
		for (i in 0...MAX)
			if (live[i]) n++;
		return n;
	}

	public static function button(i:Int, b:Int):Bool
		return i >= 0 && i < MAX && b >= 0 && b < BUTTONS && buttons[i][b];

	public static function axis(i:Int, a:Int):Float
		return i >= 0 && i < MAX && a >= 0 && a < AXES ? axes[i][a] : 0;

	// pad i fed by the program (null: given back to the device)
	public static function set(i:Int, ?pressed:Array<Bool>, ?sticks:Array<Float>) {
		if (i < 0 || i >= MAX) return;
		virtual[i] = pressed != null || sticks != null;
		live[i] = virtual[i];
		for (b in 0...BUTTONS)
			buttons[i][b] = pressed != null && b < pressed.length && pressed[b];
		for (a in 0...AXES)
			axes[i][a] = sticks != null && a < sticks.length ? sticks[a] : 0;
	}

	// the devices read again, once enabled (a program that never calls
	// enable links no device code: a few tens of KB, and in the browser
	// imports a test under node's WASI does not have)
	public static function poll() {
		if (devices != null) devices();
	}

	static var devices:Null<Void->Void>;

	// the devices read from now on (a program reading gamepads calls it once)
	public static function enable()
		devices = pollDevices;

	static function pollDevices() {
		#if (hxmc.target == "wasm32-wasi")
		pollWeb();
		#elseif !eval
		if (Mem.os() == 0) pollLinux() else if (Mem.os() == 2) pollWindows();
		#end
	}

	#if (hxmc.target == "wasm32-wasi")
	static final state = Bytes.alloc(4 * (BUTTONS + AXES));

	static function pollWeb() {
		for (i in 0...MAX) {
			if (virtual[i]) continue;
			var there = Arena.scopedValue(a -> {
				var p = a.alloc(state.length, 4);
				var r = hxmc.os.web.Dom.gamepad_state(i, p);
				if (r == 1) BytesPtr.copyIn(state, 0, p, state.length);
				r;
			}) == 1;
			live[i] = there;
			for (b in 0...BUTTONS)
				buttons[i][b] = there && state.getFloat(4 * b) > 0.5;
			for (a in 0...AXES)
				axes[i][a] = there ? state.getFloat(4 * (BUTTONS + a)) : 0;
		}
	}
	#elseif !eval
	// (Linux: each pad's device, -1 closed; the polls until it is tried again)
	static final fds:Array<Int> = [for (_ in 0...MAX) -1];
	static final retry:Array<Int> = [for (_ in 0...MAX) 0];
	static final events = Bytes.alloc(8 * 64);
	// (the triggers' axes, -1 released to 1 pressed, and the pad's)
	static final raw:Array<Array<Float>> = [for (_ in 0...MAX) [for (_ in 0...8) 0.0]];

	static function pollLinux() {
		for (i in 0...MAX) {
			if (virtual[i]) continue;
			if (fds[i] < 0) {
				if (retry[i]-- > 0) continue;
				// (a pad plugged in later: tried again every 120 polls)
				retry[i] = 120;
				var path = "/dev/input/js" + i;
				fds[i] = Arena.scopedValue(a -> Posix.open(a.cstring(path), 0x800, 0)); // (O_RDONLY | O_NONBLOCK)
				if (fds[i] < 0) {
					live[i] = false;
					continue;
				}
				live[i] = true;
			}
			while (true) {
				var fd = fds[i];
				var n = Arena.scopedValue(a -> {
					var p = a.alloc(events.length, 8);
					var r = Posix.read(fd, p, events.length).toInt();
					if (r > 0) BytesPtr.copyIn(events, 0, p, r);
					r;
				});
				// (nothing new: EAGAIN; a pad unplugged keeps its last state for now)
				if (n <= 0) break;
				var k = 0;
				while (k + 8 <= n) {
					var value = events.getUInt16(k + 4), type = events.get(k + 6) & 0x7F, number = events.get(k + 7);
					if (value >= 0x8000) value -= 0x10000;
					if (type == 1) xpadButton(i, number, value != 0) else if (type == 2) xpadAxis(i, number, value / 32767);
					k += 8;
				}
				if (n < events.length) break;
			}
		}
	}

	// (Windows: XInput's state of each pad)
	static final xstate = Bytes.alloc(16);
	// XInput's button bits in the standard order (the guide has none)
	static final XBITS = [0x1000, 0x2000, 0x4000, 0x8000, 0x100, 0x200, -1, -1, 0x20, 0x10, 0x40, 0x80, 0x1, 0x2, 0x4, 0x8, -1];

	static function pollWindows() {
		for (i in 0...MAX) {
			if (virtual[i]) continue;
			var there = Arena.scopedValue(a -> {
				var p = a.alloc(16, 8);
				var r = hxmc.os.win32.XInput.XInputGetState(i, p);
				if (r == 0) BytesPtr.copyIn(xstate, 0, p, 16);
				r;
			}) == 0;
			live[i] = there;
			var bits = there ? xstate.getUInt16(4) : 0;
			for (b in 0...BUTTONS)
				buttons[i][b] = XBITS[b] >= 0 && bits & XBITS[b] != 0;
			// (the triggers, 0 to 255: pressed past 30, XInput's threshold)
			buttons[i][6] = there && xstate.get(6) > 30;
			buttons[i][7] = there && xstate.get(7) > 30;
			for (a in 0...AXES) {
				var v = there ? xstate.getUInt16(8 + 2 * a) : 0;
				if (v >= 0x8000) v -= 0x10000;
				// (XInput's y is up, the standard layout's down)
				axes[i][a] = Math.max(-1, v / 32767) * (a % 2 == 1 ? -1 : 1);
			}
		}
	}

	// xpad's buttons: A B X Y LB RB back start guide LS RS
	static function xpadButton(i:Int, number:Int, down:Bool) {
		var map = [0, 1, 2, 3, 4, 5, 8, 9, 16, 10, 11];
		if (number < map.length) buttons[i][map[number]] = down;
	}

	// xpad's axes: LX LY LT RX RY RT padX padY
	static function xpadAxis(i:Int, number:Int, v:Float) {
		if (number >= 8) return;
		raw[i][number] = v;
		switch number {
			case 0: axes[i][0] = v;
			case 1: axes[i][1] = v;
			case 3: axes[i][2] = v;
			case 4: axes[i][3] = v;
			case 2: buttons[i][6] = v > 0;
			case 5: buttons[i][7] = v > 0;
			case 6:
				buttons[i][14] = v < -0.5;
				buttons[i][15] = v > 0.5;
			case 7:
				buttons[i][12] = v < -0.5;
				buttons[i][13] = v > 0.5;
		}
	}
	#end
}
