class BenchmarkInput {
	static function main() {
		var values = [for (i in 0...100) i * i];
		var sum = 0;
		for (v in values) sum += v;
		if (sum != 328350) throw "wrong result";
	}
}
