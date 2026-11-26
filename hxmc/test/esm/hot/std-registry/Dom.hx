// Cross-module std use (shek-dom setAttr / attrStr shape): Std.string on Dynamic, not in Main.
class Dom {
	public static function attrStr(value:Dynamic):Null<String> {
		if (value == null || value == false)
			return null;
		return value == true ? "" : Std.string(value);
	}
}