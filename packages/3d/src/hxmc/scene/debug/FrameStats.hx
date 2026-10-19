package hxmc.scene.debug;

// Frame timing: the last frames' times (seconds), their average, minimum
// and maximum, and the renderer's counts of the last frame; what the
// overlay (Overlay) shows and a game may log.
class FrameStats {
	public final capacity:Int;
	final times:Array<Float>;
	var next = 0;
	public var count(default, null) = 0;
	public var draws = 0;
	public var culled = 0;
	public var instanced = 0;

	public function new(capacity = 120) {
		this.capacity = capacity;
		times = [for (_ in 0...capacity) 0.0];
	}

	// a frame took seconds
	public function add(seconds:Float) {
		times[next] = seconds;
		next = (next + 1) % capacity;
		if (count < capacity) count++;
	}

	// the k-th newest frame's time (0: the last)
	public function at(k:Int):Float
		return k < count ? times[(next - 1 - k + capacity * 2) % capacity] : 0;

	public function average():Float {
		var s = 0.0;
		for (k in 0...count)
			s += at(k);
		return count > 0 ? s / count : 0;
	}

	public function max():Float {
		var m = 0.0;
		for (k in 0...count)
			if (at(k) > m) m = at(k);
		return m;
	}

	public function min():Float {
		if (count == 0) return 0;
		var m = at(0);
		for (k in 0...count)
			if (at(k) < m) m = at(k);
		return m;
	}

	// the renderer's counts of its last draw
	public function from(r:hxmc.scene.render.Renderer) {
		draws = r.draws;
		culled = r.culled;
		instanced = r.instanced;
	}
}
