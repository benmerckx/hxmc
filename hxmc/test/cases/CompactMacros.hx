// Compressed references (@:hxmc.compact, docs/hxmc.md "Compressed
// references") across the macro API: the compiler's typed and syntax trees
// are compact (core.TType, core.Ast). The macros type expressions full of
// string literals (with Mir macros the bundle's data, which the compiler's
// compact Constant and TExprDef values then refer to: below 32 GB,
// macro.Loader.alloc), walk the typed trees, store and read them back, read
// classes', enums' and fields' types, and lay out and match compact classes
// and enums of their own (with Mir macros the bundle's type records with
// compact maps, macro.Loader), with garbage to collect many times. The
// macros run on Mir here (and in the conformance case macro-compact, make
// mir-check, against the reference; under RT_VERIFY with small
// nurseries by hand: --interp). The program's own compact class and enum
// run interpreted under --mir-run (interp.MirRun: the compiler's
// compressed references), apart from the macro context's bundles
// (macro.Loader.apart).
// define: hxmc.macros=mir
import haxe.macro.Context;
import haxe.macro.Expr;

@:hxmc.compact
class Tree {
	public var left:Tree;
	public var right:Tree;
	public var name:String;
	public var n:Int;

	public function new(left, right, name, n) {
		this.left = left;
		this.right = right;
		this.name = name;
		this.n = n;
	}
}

@:hxmc.compact
enum Shape {
	Dot(name:String);
	Line(a:Shape, b:Shape, len:Int);
	Box(s:Shape, tag:String, flag:Bool);
}

class CompactMacros {
	static function build(d:Int, k:Int):Tree
		return d == 0 ? new Tree(null, null, "leaf" + k, k) : new Tree(build(d - 1, 2 * k), build(d - 1, 2 * k + 1), "node" + k, k);

	static function sum(t:Tree):Int
		return t == null ? 0 : t.n + sum(t.left) + sum(t.right) + t.name.length;

	static function shape(d:Int):Shape
		return d == 0 ? Dot("d") : d % 3 == 0 ? Box(shape(d - 1), "b" + d, d % 2 == 0) : Line(shape(d - 1), Dot("x" + d), d);

	static function measure(s:Shape):Int
		return switch s {
			case Dot(n): n.length;
			case Line(a, b, len): measure(a) + measure(b) + len;
			case Box(s, tag, flag): measure(s) + tag.length + (flag ? 1 : 0);
		}

	static function main() {
		Sys.println(MacroTrees.typed());
		Sys.println(MacroTrees.types());
		Sys.println(MacroTrees.own());
		Sys.println(MacroTrees.roundTrip());
		var total = 0;
		for (round in 0...20) {
			var t = build(10, 1);
			var s = shape(30);
			total += sum(t) + measure(s);
		}
		Sys.println("program: " + total);
	}
}

@:hxmc.compact
class MacroNode {
	public var label:String;
	public var next:MacroNode;
	public var expr:Expr;
	public var depth:Int;

	public function new(label, next, expr, depth) {
		this.label = label;
		this.next = next;
		this.expr = expr;
		this.depth = depth;
	}
}

@:hxmc.compact
enum MacroShape {
	MLeaf(s:String);
	MPair(a:MacroShape, b:MacroShape, n:Int);
	MExpr(e:Expr, flag:Bool);
}

class MacroTrees {
	#if macro
	// a typed expression's nodes (a string per kind, in the order met)
	static function walk(e:haxe.macro.Type.TypedExpr, counts:Array<Int>) {
		counts[e.expr.getIndex()]++;
		haxe.macro.TypedExprTools.iter(e, x -> walk(x, counts));
	}

	static function source(i:Int):Expr {
		var parts = [for (k in 0...12) macro $v{"part" + k + "_" + i}];
		return macro {
			var a = "lit" + $v{i};
			var b = [$a{parts}];
			var c = b.length + a.length + "constant".length;
			if (c > 3) Std.string(c) + "s" else b.join(",");
		};
	}

	static function shapeOf(d:Int):MacroShape
		return d == 0 ? MLeaf("leaf") : d % 2 == 0 ? MPair(shapeOf(d - 1), MLeaf("l" + d), d) : MExpr(macro $v{"e" + d}, d % 3 == 0);

	static function score(s:MacroShape):Int
		return switch s {
			case MLeaf(t): t.length;
			case MPair(a, b, n): score(a) + score(b) + n;
			case MExpr(e, flag): switch e.expr {
					case EConst(CString(v, _)): v.length + (flag ? 1 : 0);
					case _: -1000;
				}
		}
	#end

	// expressions typed (Context.typeExpr) and walked, many times
	public static macro function typed():Expr {
		var counts = [for (_ in 0...30) 0];
		var strings = 0;
		for (i in 0...300) {
			var te = Context.typeExpr(source(i));
			walk(te, counts);
			function lits(e:haxe.macro.Type.TypedExpr) {
				switch e.expr {
					case TConst(TString(s)) if (StringTools.startsWith(s, "part")):
						strings += s.length;
					case _:
				}
				haxe.macro.TypedExprTools.iter(e, lits);
			}
			lits(te);
		}
		return macro $v{"typed: " + counts.join(" ") + " strings " + strings};
	}

	// the types of classes, enums and their fields
	public static macro function types():Expr {
		var out = [];
		for (round in 0...50)
			for (name in ["CompactMacros.Tree", "CompactMacros.Shape", "CompactMacros.MacroNode", "CompactMacros.MacroShape"]) {
				var t = Context.getType(name);
				var line = switch t {
					case TInst(c, _):
						var ct = c.get();
						ct.name + "(" + [for (f in ct.fields.get()) f.name + ":" + haxe.macro.TypeTools.toString(f.type)].join(",") + ")";
					case TEnum(e, _):
						var et = e.get();
						et.name + "(" + [for (n in et.names) n + ":" + haxe.macro.TypeTools.toString(et.constructs.get(n).type)].join(",") + ")";
					case TAbstract(a, _): a.get().name;
					case TType(d, _): d.get().name;
					case _: "?";
				}
				if (round == 0) out.push(line);
			}
		return macro $v{"types: " + out.join(" ")};
	}

	// the macro's own compact class and enum, built and matched through collections
	public static macro function own():Expr {
		var total = 0;
		for (round in 0...200) {
			var list:MacroNode = null;
			for (i in 0...200)
				list = new MacroNode("n" + i, list, macro $v{i}, i);
			var k = list;
			while (k != null) {
				total += k.label.length + k.depth;
				switch k.expr.expr {
					case EConst(CInt(v, _)): total += Std.parseInt(v);
					case _: total -= 1000000;
				}
				k = k.next;
			}
			total += score(shapeOf(40));
		}
		return macro $v{"own: " + total};
	}

	// typed expressions stored and read back (the compiler's objects made from the macro's), printed
	public static macro function roundTrip():Expr {
		var printed = "";
		for (i in 0...100) {
			var te = Context.typeExpr(source(i));
			var e = Context.storeTypedExpr(te);
			var back = Context.typeExpr(e);
			var again = Context.getTypedExpr(back);
			if (i == 99) printed = new haxe.macro.Printer().printExpr(again).length > 0 ? "printed" : "empty";
		}
		return macro $v{"roundTrip: " + printed};
	}
}
