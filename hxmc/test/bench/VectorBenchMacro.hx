import haxe.macro.Context;
import haxe.macro.Expr;

// Generate concrete element/container types: a generic Array<T> benchmark
// would measure Dynamic boxing instead of native Int and Float storage.
class VectorBenchMacro {
	public static macro function build():Array<Field> {
		var fields = Context.getBuildFields();
		var setups = [];
		var workloads = ["read", "read4", "write", "update", "alloc"];
		var types = [
			{name: "Int", type: "Int", x: "17", y: "23", sum: "v"},
			{name: "Float", type: "Float", x: "1.25", y: "2.5", sum: "v"},
			{name: "Int64", type: "haxe.Int64", x: "haxe.Int64.make(1, 17)", y: "haxe.Int64.make(2, 23)", sum: "v.low"},
			{name: "Bool", type: "Bool", x: "true", y: "false", sum: "(v ? 1 : 0)"},
			{name: "String", type: "String", x: '"alpha"', y: '"beta"', sum: "v.length"},
			{name: "Object", type: "BenchValue", x: "new BenchValue(17)", y: "new BenchValue(23)", sum: "v.value"},
			{name: "Anon", type: "{value:Int}", x: "{value:17}", y: "{value:23}", sum: "v.value"},
			{name: "Nullable", type: "Null<Int>", x: "17", y: "null", sum: "(v == null ? -1 : v)"},
			{name: "Dynamic", type: "Dynamic", x: "17", y: "23", sum: "(v : Int)"},
		];
		function addFunction(name:String, source:String, noInline = false) {
			var expr = Context.parse(source, Context.currentPos());
			switch expr.expr {
				case EFunction(_, fn):
					fields.push({name: name, access: [AStatic], kind: FFun(fn), pos: expr.pos,
						meta: noInline ? [{name: ":noInline", pos: expr.pos}] : []});
				case _: Context.error("Expected a benchmark function", expr.pos);
			}
		}
		for (t in types) {
			var setup = 'setup${t.name}';
			setups.push('$setup(n, pairs);');
			var body = 'function(n:Int, pairs:Array<BenchPair>):Void { var x:${t.type} = ${t.x}; var y:${t.type} = ${t.y};';
			for (container in ["Array", "NativeArray", "Vector"]) {
				var ct = switch container {
					case "Array": 'Array<${t.type}>';
					case "Vector": 'haxe.ds.Vector<${t.type}>';
					case _: 'hxmc.NativeArray<${t.type}>';
				};
				var init = 'var a:$ct = ' + (container == "Array" ? '[]; a.resize(n);' : 'new $ct(n);');
				body += '{ $init for (i in 0...n) a[i] = (i & 1) == 0 ? x : y;';
				for (work in workloads) {
					var method = '${work}${t.name}$container';
					var checksum = 'var sum = 0.0; for (i in 0...n) { var v = a[i]; sum += ${t.sum}; }';
					var read4 = 'var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0; for (pass in 0...rounds) { var i = 0; while (i + 3 < n) {';
					for (lane in 0...4) read4 += '{ var v = a[i + $lane]; s$lane += ${t.sum}; }';
					read4 += 'i += 4; } while (i < n) { var v = a[i++]; s0 += ${t.sum}; } } return s0 + s1 + s2 + s3;';
					var loop = switch work {
						case "read": 'var sum = 0.0; for (pass in 0...rounds) for (i in 0...n) { var v = a[i]; sum += ${t.sum}; } return sum;';
						case "read4": read4;
						case "write": 'for (pass in 0...rounds) { var v = (pass & 1) == 0 ? x : y; for (i in 0...n) a[i] = v; } $checksum return sum;';
						case "update": 'for (pass in 0...rounds) for (i in 0...n) a[i] = a[i] == x ? y : x; $checksum return sum;';
						case _: 'var sum = 0.0; for (pass in 0...rounds) { $init var v = (pass & 1) == 0 ? x : y; for (i in 0...n) a[i] = v; var v = a[pass % n]; sum += ${t.sum} + a.length; } return sum;';
					};
					addFunction(method, 'function(a:$ct, n:Int, rounds:Int, x:${t.type}, y:${t.type}):Float { $loop }', true);
					if (container == "Array") body += 'pairs.push({type:"${t.name}", work:"$work", array: r -> $method(a, n, r, x, y), nativeArray:null, vector:null});';
					else {
						var field = container == "Vector" ? "vector" : "nativeArray";
						body += 'pairs[pairs.length - ${workloads.length} + ${workloads.indexOf(work)}].$field = r -> $method(a, n, r, x, y);';
					}
				}
				body += '}';
			}
			body += '}';
			addFunction(setup, body);
		}
		addFunction("setup", 'function(n:Int):Array<BenchPair> { var pairs:Array<BenchPair> = []; ${setups.join("\n")} return pairs; }');
		return fields;
	}
}
