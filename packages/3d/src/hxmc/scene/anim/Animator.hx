package hxmc.scene.anim;

import hxmc.scene.Node;

// Plays clips on a set of nodes (an instance's: the glTF nodes by index,
// GltfNodes.build's made), advanced by update(dt) from the simulation's
// step: play starts a clip (looping or not, at a speed), fading from what
// played before over fade seconds (a cross-fade).
class Animator {
	public final nodes:Array<Node>;
	var current:Null<AnimationClip>;
	var previous:Null<AnimationClip>;
	public var time(default, null) = 0.0;
	var previousTime = 0.0;
	var fade = 0.0;
	var fading = 0.0;
	public var loop = true;
	public var speed = 1.0;

	public function new(nodes:Array<Node>) {
		this.nodes = nodes;
	}

	public function play(clip:AnimationClip, ?options:{?loop:Bool, ?speed:Float, ?fade:Float}) {
		if (current != null && options != null && options.fade != null && options.fade > 0) {
			previous = current;
			previousTime = time;
			fade = options.fade;
			fading = 0;
		} else
			previous = null;
		current = clip;
		time = 0;
		loop = options == null || options.loop == null ? true : options.loop;
		speed = options == null || options.speed == null ? 1.0 : options.speed;
		apply();
	}

	public function update(dt:Float) {
		if (current == null) return;
		time = advance(current, time, dt * speed);
		if (previous != null) {
			previousTime = advance(previous, previousTime, dt * speed);
			fading += dt;
			if (fading >= fade) previous = null;
		}
		apply();
	}

	function advance(clip:AnimationClip, t:Float, dt:Float):Float {
		t += dt;
		if (clip.duration <= 0) return 0;
		return loop ? t % clip.duration : Math.min(t, clip.duration);
	}

	function apply() {
		if (previous != null) {
			previous.apply(nodes, previousTime);
			current.apply(nodes, time, fading / fade);
		} else
			current.apply(nodes, time);
	}
}
