package hxmc.scene.input;

import hxmc.gfx.shader.Vec2;
import hxmc.os.Event;
import hxmc.os.Gamepads;

// Named actions bound to input (Binding: keys, mouse buttons, screen
// regions, pairs of keys as axes), read once per simulation step so that
// input and the simulation agree (a press and its release within one step
// still count as a press):
//
//   var actions = new Actions();
//   actions.bind("jump", Key(0x20)).bind("jump", Region(0.75, 0.6, 1, 1));
//   actions.bind("moveX", KeyAxis(0xFF51, 0xFF53)).bind("moveX", KeyAxis(0x61, 0x64));
//   App.run(..., e -> actions.event(e));
//   clock.advance(dt, step -> {
//     actions.step();
//     if (actions.pressed("jump")) ...;
//     player.x += actions.axis("moveX") * speed * step;
//   });
//
// Bindings are data (rebind at run time with unbind and bind). Gamepads:
// PadButton and PadAxis, read at each step from hxmc.os.Gamepads (which
// Stages.frame polls; Gamepads.set feeds an on-screen stick).
class Actions {
	final names:Array<String> = [];
	final bindings:Array<Array<Binding>> = [];
	// per action: how many of its bindings are down now; presses and
	// releases since the last step; the last step's view
	final down:Array<Int> = [];
	final pressEvents:Array<Int> = [];
	final releaseEvents:Array<Int> = [];
	final pressedNow:Array<Bool> = [];
	final releasedNow:Array<Bool> = [];
	final heldNow:Array<Bool> = [];
	// axes: per action, the keys of its KeyAxis bindings held (negative, positive)
	final axisValue:Array<Float> = [];
	// what is held: keys and buttons, the regions the pointer holds
	final keys = new Map<Int, Bool>();
	final buttons = new Map<Int, Bool>();
	var pointerDown = false;
	var px = 0.0;
	var py = 0.0;
	var width = 1.0;
	var height = 1.0;
	final regionHeld = new Map<Int, Bool>();
	final padHeld = new Map<Int, Bool>();
	// a stick's travel taken as rest (its axes' first 0.15)
	public var deadZone = 0.15;

	public function new() {}

	function index(action:String):Int {
		var k = names.indexOf(action);
		if (k >= 0) return k;
		names.push(action);
		bindings.push([]);
		down.push(0);
		pressEvents.push(0);
		releaseEvents.push(0);
		pressedNow.push(false);
		releasedNow.push(false);
		heldNow.push(false);
		axisValue.push(0);
		return names.length - 1;
	}

	public function bind(action:String, b:Binding):Actions {
		bindings[index(action)].push(b);
		return this;
	}

	// all of an action's bindings removed
	public function unbind(action:String):Actions {
		var k = names.indexOf(action);
		if (k >= 0) {
			bindings[k] = [];
			down[k] = 0;
		}
		return this;
	}

	// the window's size, for Region bindings (by default the event's window)
	public function setSize(width:Float, height:Float) {
		this.width = width;
		this.height = height;
	}

	// an event from hxmc.os's loop
	public function event(e:Event) {
		switch e.kind {
			case KeyDown:
				if (!keys.exists(e.key)) {
					keys.set(e.key, true);
					changed(b -> switch b {
						case Key(k): k == e.key;
						case _: false;
					}, true);
				}
			case KeyUp:
				if (keys.remove(e.key)) changed(b -> switch b {
					case Key(k): k == e.key;
					case _: false;
				}, false);
			case MouseDown:
				if (e.window != null) setSize(e.window.width, e.window.height);
				if (!buttons.exists(e.button)) {
					buttons.set(e.button, true);
					changed(b -> switch b {
						case Mouse(n): n == e.button;
						case _: false;
					}, true);
				}
				if (e.button == 1) {
					pointerDown = true;
					pointer(e.x, e.y);
				}
			case MouseUp:
				if (buttons.remove(e.button)) changed(b -> switch b {
					case Mouse(n): n == e.button;
					case _: false;
				}, false);
				if (e.button == 1) {
					pointerDown = false;
					pointer(e.x, e.y);
				}
			case MouseMove:
				if (pointerDown) pointer(e.x, e.y);
			case _:
		}
		axes();
	}

	// the bindings that match went down (or up): their actions' counts
	function changed(match:Binding->Bool, isDown:Bool) {
		for (k in 0...names.length)
			for (b in bindings[k])
				if (match(b)) {
					if (isDown) {
						if (down[k]++ == 0) pressEvents[k]++;
					} else if (down[k] > 0 && --down[k] == 0)
						releaseEvents[k]++;
				}
	}

	// the regions under the pointer (held while it is down inside them)
	function pointer(x:Float, y:Float) {
		px = x / width;
		py = y / height;
		for (k in 0...names.length)
			for (i in 0...bindings[k].length)
				switch bindings[k][i] {
					case Region(x0, y0, x1, y1):
						var id = k * 1024 + i;
						var inside = pointerDown && px >= x0 && px <= x1 && py >= y0 && py <= y1;
						var was = regionHeld.exists(id);
						if (inside && !was) {
							regionHeld.set(id, true);
							if (down[k]++ == 0) pressEvents[k]++;
						} else if (!inside && was) {
							regionHeld.remove(id);
							if (down[k] > 0 && --down[k] == 0) releaseEvents[k]++;
						}
					case _:
				}
	}

	// the gamepads' buttons (Gamepads, as last polled: Stages.frame polls)
	function pads() {
		for (k in 0...names.length)
			for (i in 0...bindings[k].length)
				switch bindings[k][i] {
					case PadButton(b):
						var now = false;
						for (p in 0...Gamepads.MAX)
							if (Gamepads.button(p, b)) now = true;
						var id = k * 1024 + i, was = padHeld.exists(id);
						if (now && !was) {
							padHeld.set(id, true);
							if (down[k]++ == 0) pressEvents[k]++;
						} else if (!now && was) {
							padHeld.remove(id);
							if (down[k] > 0 && --down[k] == 0) releaseEvents[k]++;
						}
					case _:
				}
	}

	function axes() {
		for (k in 0...names.length) {
			var v = 0.0;
			for (b in bindings[k])
				switch b {
					case KeyAxis(neg, pos):
						if (keys.exists(neg)) v -= 1;
						if (keys.exists(pos)) v += 1;
					case PadAxis(a, scale):
						// (the pad pushed furthest, past the dead zone, rescaled to 0..1)
						var best = 0.0;
						for (p in 0...Gamepads.MAX) {
							var x = Gamepads.axis(p, a);
							if (Math.abs(x) > Math.abs(best)) best = x;
						}
						var m = Math.abs(best);
						if (m > deadZone) v += (best < 0 ? -1 : 1) * (m - deadZone) / (1 - deadZone) * scale;
					case _:
				}
			axisValue[k] = Math.max(-1, Math.min(1, v));
		}
	}

	// a simulation step begins: what happened since the last one becomes
	// what pressed, released and held answer
	public function step() {
		pads();
		axes();
		for (k in 0...names.length) {
			pressedNow[k] = pressEvents[k] > 0;
			releasedNow[k] = releaseEvents[k] > 0;
			heldNow[k] = down[k] > 0;
			pressEvents[k] = releaseEvents[k] = 0;
		}
	}

	// went down since the last step (also when it went up again)
	public function pressed(action:String):Bool {
		var k = names.indexOf(action);
		return k >= 0 && pressedNow[k];
	}

	public function released(action:String):Bool {
		var k = names.indexOf(action);
		return k >= 0 && releasedNow[k];
	}

	// down at the step
	public function held(action:String):Bool {
		var k = names.indexOf(action);
		return k >= 0 && heldNow[k];
	}

	// an axis action's value (KeyAxis, PadAxis), -1 to 1, now
	public function axis(action:String):Float {
		var k = names.indexOf(action);
		return k >= 0 ? axisValue[k] : 0;
	}

	// two axes as a vector (x right, y up), of length 1 at most
	public function stick(x:String, y:String):Vec2 {
		var v = new Vec2(axis(x), axis(y));
		var l = Math.sqrt(v.x * v.x + v.y * v.y);
		return l > 1 ? v / l : v;
	}
}
