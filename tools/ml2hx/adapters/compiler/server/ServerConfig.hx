// Expose the port's existing fields while retaining the generated reference cells.
class ServerConfig {
	public static var doNotCheckModules(get, set):Bool;
	static function get_doNotCheckModules():Bool return ServerConfigModule.doNotCheckModules.value;
	static function set_doNotCheckModules(v:Bool):Bool return ServerConfigModule.doNotCheckModules.value = v;
	public static var maxCompletionItems(get, set):Int;
	static function get_maxCompletionItems():Int return ServerConfigModule.maxCompletionItems.value.toInt();
	static function set_maxCompletionItems(v:Int):Int {
		ServerConfigModule.maxCompletionItems.value = ml2hx.rt.Int63.ofInt(v);
		return v;
	}
	public static final defaultStaleContextMaxAge:Int = ServerConfigModule.defaultStaleContextMaxAge.toInt();
	public static var staleContextMaxAgeSeconds(get, set):Int;
	static function get_staleContextMaxAgeSeconds():Int return ServerConfigModule.staleContextMaxAgeSeconds.value.toInt();
	static function set_staleContextMaxAgeSeconds(v:Int):Int {
		ServerConfigModule.staleContextMaxAgeSeconds.value = ml2hx.rt.Int63.ofInt(v);
		return v;
	}
	public static function reset():Void ServerConfigModule.reset()(ml2hx.rt.Unit.value);
}
