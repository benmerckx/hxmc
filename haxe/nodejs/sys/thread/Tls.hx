package sys.thread;

// Single-threaded stand-in for the Node.js compiler frontend.
class Tls<T> {
	public var value(get, set):T;
	var v:T;
	public function new() {}
	function get_value():T return v;
	function set_value(x:T):T return v = x;
}
