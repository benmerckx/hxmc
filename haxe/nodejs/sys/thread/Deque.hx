package sys.thread;

class Deque<T> {
	var items:Array<T> = [];
	public function new() {}
	public function add(i:T):Void items.push(i);
	public function push(i:T):Void items.unshift(i);
	public function pop(block:Bool):Null<T> {
		if (items.length == 0 && block) throw "Deque.pop would block forever in the single-threaded JS shim";
		return items.shift();
	}
}
