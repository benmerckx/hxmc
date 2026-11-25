package esm.hot;

extern class Scope {
	@:native("scopeEnter")
	public static function enter(id:String, ?key:String):Void;

	@:native("scopeExit")
	public static function exit():Void;
}