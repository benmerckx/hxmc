class RootNodeMini {
	public function new() {}

	public static function create(fn:RootNodeMini -> Void):Void -> Void {
		final root = new RootNodeMini();
		try {
			fn(root);
		} catch (e:Dynamic) {
			throw e;
		}
		return () -> {};
	}
}