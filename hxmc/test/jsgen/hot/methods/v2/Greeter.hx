class Greeter {
	public static var count = 0;
	var name:String;
	public function new(name:String) this.name = name;
	public function greet() {
		count++;
		return "hi " + name + " " + count;
	}
	public static function shout(s:String) return s + "!";
}
