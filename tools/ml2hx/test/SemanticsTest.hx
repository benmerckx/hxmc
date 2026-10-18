import semantics.Semantics;
import semantics.Semantics.Payload;
import ml2hx.rt.Unit;
class SemanticsTest {
	static function main() {
		var u = Unit.value;
		var eval = Semantics.evaluationOrder()(u);
		var sharing = Semantics.sharedRef()(u);
		var partial = Semantics.partial()(u);
		var lines = [
			eval.v0.toString() + "," + eval.v1.toString(),
			sharing.v0.toString() + "," + sharing.v1.toString() + "," + sharing.v2.toString(),
			Semantics.sum()(ml2hx.rt.Int63.ofInt(100000))(ml2hx.rt.Int63.ofInt(0)).toString(),
			partial.v0.toString() + "," + partial.v1.toString(),
			Semantics.payload()(Number(ml2hx.rt.Int63.ofInt(5))).toString(),
			Semantics.payload()(Empty).toString(),
			Semantics.guarded()(Number(ml2hx.rt.Int63.ofInt(5))).toString(),
			Semantics.guarded()(Number(ml2hx.rt.Int63.ofInt(15))).toString(),
			Semantics.binary.length + ":" + [for (i in 0...Semantics.binary.length) Semantics.binary.charCodeAt(i)].join(","),
			Semantics.wide.toString(), Semantics.wrap.toString(), Semantics.unsigned.toString(),
			Semantics.bounds()(u).toString(), Semantics.shortCircuit()(u).toString(),
			(function() {var t=Semantics.grouped()(u);return t.v0.toString()+","+t.v1.toString()+","+t.v2.toString();})(),
			(function() {var t=Semantics.copyOrder()(u);return t.v0.toString()+","+t.v1.toString();})()
		];
		#if js js.Syntax.code("console.log({0})", lines.join("\n"));
		#else Sys.println(lines.join("\n")); #end
	}
}
