package esm.hot;

extern class Cell {
	@:native("cell")
	public static function cell<T>(id:String, initHash:String, init:Void->T):T;
}