package hxmc.scene;

// A fixed-timestep clock for a game's simulation, driven by the app loop's
// variable frames (hxmc.os.App.run): each frame's time goes into an
// accumulator and the simulation steps dt at a time while it holds a step,
// at most maxSteps a frame (after a stall the rest is dropped, so a slow
// frame does not make the next slower: no spiral). alpha is how far the
// accumulator is into the next step, 0 to 1, to draw between the last two
// states.
//
//   var clock = new FixedStep(1 / 60);
//   App.run(() -> {
//     clock.advance(frameSeconds, dt -> world.step(dt));
//     draw(world, clock.alpha);
//   }, onEvent);
class FixedStep {
	public final dt:Float;
	public final maxSteps:Int;
	// the simulated time: steps * dt
	public var time(default, null) = 0.0;
	public var steps(default, null) = 0;
	public var alpha(default, null) = 0.0;
	// the time left over, under a step
	public var accumulator(default, null) = 0.0;

	public function new(dt = 1 / 60, maxSteps = 5) {
		if (dt <= 0) throw "hxmc.scene.FixedStep: dt must be positive";
		this.dt = dt;
		this.maxSteps = maxSteps;
	}

	// frame seconds passed: runs step(dt) as many times as they hold (at
	// most maxSteps); returns how many
	public function advance(frame:Float, step:Float->Void):Int {
		if (frame > 0) accumulator += frame;
		var n = 0;
		// (a step's worth less a hair: sums of frames of exactly dt land on it)
		while (accumulator >= dt - 1e-9 && n < maxSteps) {
			step(dt);
			accumulator -= dt;
			steps++;
			n++;
		}
		if (accumulator < 0) accumulator = 0;
		// (behind by more than a step after maxSteps: the rest is dropped)
		if (accumulator >= dt) accumulator = accumulator % dt;
		time = steps * dt;
		alpha = accumulator / dt;
		return n;
	}

	// the state to carry over a reload (hxmc.dev.Hot): steps and what is left
	public function save():{steps:Int, accumulator:Float}
		return {steps: steps, accumulator: accumulator};

	public function restore(s:{steps:Int, accumulator:Float}) {
		steps = s.steps;
		accumulator = s.accumulator;
		time = steps * dt;
		alpha = accumulator / dt;
	}
}
