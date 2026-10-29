// the markup literals FrontendCheck's frontend types (hxmc/test/frontend/Frontend.hx,
// typing.Typer.markupHook): in a module-level function and in methods, one
// expected to be an Int, one with a hole; hxmc's own compiler (no hook) gives
// upstream's error at each
function page():String
	return <p>hello</p>;

class Main {
	static function main() {
		Sys.println(page());
		Sys.println(new View("world").render());
		var n:Int = <b>four</b>;
		Sys.println(n);
	}
}

class View {
	var name:String;

	public function new(name:String)
		this.name = name;

	public function render():String {
		var who = name;
		return <p>{who}</p>;
	}
}
