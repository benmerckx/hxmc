class Counter {
	public static var made = 100;
	public var n:Int;
	public var label = "L";
	public function new(n:Int) {
		this.n = n * 10;
		made++;
	}
	public function describe() return 'n=$n label=$label made=$made';
}
