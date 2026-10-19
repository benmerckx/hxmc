package hxmc.scene;

// A frame's work in ordered stages, on top of hxmc.os.App's frames:
//
//   Input        once a frame, first (read devices, feed Actions)
//   FixedUpdate  at the fixed rate, as many times as the frame holds
//                (FixedStep: physics, gameplay), with the step's dt
//   Update       once a frame, with the frame's seconds
//   LateUpdate   once a frame, after Update (cameras following things)
//   PreRender    once a frame, last, with FixedStep's alpha (interpolation)
//
// Within a stage, functions run in the order they were added; on returns a
// function that removes one (a component's cleanup).
//
//   var stages = new Stages();
//   stages.on(FixedUpdate, dt -> physics.step(dt));
//   stages.on(LateUpdate, _ -> follow(camera, player));
//   App.run(() -> { stages.frame(seconds); renderer.draw(...); }, ...);
class Stages {
	public final clock:FixedStep;
	final lists:Array<Array<Float->Void>> = [for (_ in 0...5) []];

	public function new(?clock:FixedStep) {
		this.clock = clock != null ? clock : new FixedStep();
	}

	public function on(stage:Stage, f:Float->Void):Void->Void {
		var list = lists[stage];
		list.push(f);
		return () -> list.remove(f);
	}

	// one frame of seconds
	public function frame(seconds:Float) {
		// (loads in flight advanced first: Asset)
		Assets.poll();
		// (gamepads read once a frame, before the Input stage, when the program
		// enabled them: Actions see them)
		hxmc.os.Gamepads.poll();
		run(Input, seconds);
		var fixed = lists[FixedUpdate];
		clock.advance(seconds, dt -> for (f in fixed.copy()) f(dt));
		run(Update, seconds);
		run(LateUpdate, seconds);
		run(PreRender, clock.alpha);
	}

	inline function run(stage:Stage, v:Float)
		for (f in lists[stage].copy())
			f(v);
}

enum abstract Stage(Int) to Int {
	var Input;
	var FixedUpdate;
	var Update;
	var LateUpdate;
	var PreRender;
}
