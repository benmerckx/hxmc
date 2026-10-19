package hxmc.scene;

// The loads in flight: each a function polled until it returns true
class Assets {
	static final pending:Array<Void->Bool> = [];

	public static function track(poll:Void->Bool) {
		if (!poll()) pending.push(poll);
	}

	// advances every load (Stages.frame calls it); the number still loading
	public static function poll():Int {
		var i = 0;
		while (i < pending.length)
			if (pending[i]()) pending.splice(i, 1) else i++;
		return pending.length;
	}
}
