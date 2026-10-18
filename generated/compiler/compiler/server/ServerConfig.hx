package compiler.server;
// Generated from src/compiler/server/serverConfig.ml. Do not edit.
/* Maximum age in seconds for unused context caches before they are removed.
   10 minutes is long enough to survive bursts of display requests with
   varying defines, while still cleaning up contexts that are truly abandoned.
   If set to -1, the feature is disabled. */
class ServerConfigModule {
	public static final doNotCheckModules:ml2hx.rt.Ref<Bool> = (function() {
		var _ml0 = false;
		return new ml2hx.rt.Ref(_ml0);
	})();
	public static final maxCompletionItems:ml2hx.rt.Ref<ml2hx.rt.Int63> = (function() {
		var _ml1 = ml2hx.rt.Int63.parse("0");
		return new ml2hx.rt.Ref(_ml1);
	})();
	public static final defaultStaleContextMaxAge:ml2hx.rt.Int63 = ml2hx.rt.Int63.parse("600");
	public static final staleContextMaxAgeSeconds:ml2hx.rt.Ref<ml2hx.rt.Int63> = (function() {
		var _ml2 = defaultStaleContextMaxAge;
		return new ml2hx.rt.Ref(_ml2);
	})();
	public static function reset():(ml2hx.rt.Unit -> ml2hx.rt.Unit) {
		return function(_ml4:ml2hx.rt.Unit):ml2hx.rt.Unit {
			var _ml3 = _ml4;
			(function() {
				var _ml6 = false;
				var _ml5 = doNotCheckModules;
				return (function() {
					_ml5.value = _ml6;
					return ml2hx.rt.Unit.value;
				})();
			})();
			(function() {
				var _ml8 = ml2hx.rt.Int63.parse("0");
				var _ml7 = maxCompletionItems;
				return (function() {
					_ml7.value = _ml8;
					return ml2hx.rt.Unit.value;
				})();
			})();
			return (function() {
				var _ml10 = defaultStaleContextMaxAge;
				var _ml9 = staleContextMaxAgeSeconds;
				return (function() {
					_ml9.value = _ml10;
					return ml2hx.rt.Unit.value;
				})();
			})();
		};
	}
}
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
