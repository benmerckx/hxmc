package unit.moduleload;

class LargeLoopBound {
	static function main():Void {
		var k = 0;
		for (x in 0...1_000_000_000) {
			k++;
		}
		trace(k);
	}
}
