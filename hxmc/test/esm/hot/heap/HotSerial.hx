import HotEnum;

class HotSerial {
	public static function pick():HotEnum {
		return HotEnum.Beta;
	}

	public static function cycleFn():Void->String {
		var box:{self:Dynamic} = {self: null};
		box.self = box;
		return function() return "cycle";
	}
}