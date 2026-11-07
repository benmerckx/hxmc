// Repeated immutable snapshots of one large buffer, as a read-mostly
// consumer sees it. The checksum keeps every returned string observable.
class StringBufSnapshotBench {
	static function main() {
		var b = new StringBuf();
		var chunk = "0123456789abcdef";
		for (_ in 0...65536) b.add(chunk);
		var sum = 0;
		for (i in 0...8192) {
			var s = b.toString();
			sum += s.charCodeAt(i & 15) + s.length;
		}
		Sys.println(sum);
	}
}
