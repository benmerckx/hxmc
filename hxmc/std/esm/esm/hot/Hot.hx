package esm.hot;

// Dev hot-reload API (phase 2). Implementation lives in __hx_esm_runtime.mjs ($h).
extern class Hot {
	@:native("applyHotPatch")
	public static function applyPatch(manifest:Dynamic):Dynamic;

	@:native("esmSerialize")
	public static function serialize(value:Dynamic):Dynamic;

	@:native("esmUnserialize")
	public static function unserialize(data:Dynamic):Dynamic;

	@:native("trackInstance")
	public static function trackInstance(typeId:String, inst:Dynamic):Void;
}