import HotEnum;

class HotSerial {
	@:esm.hot.function
	public static function pick():HotEnum {
		return HotEnum.Beta;
	}

	@:esm.hot.function
	public static function cycleFn():Void->String {
		var box:{self:Dynamic} = {self: null};
		box.self = box;
		return function() return "cycle";
	}
}