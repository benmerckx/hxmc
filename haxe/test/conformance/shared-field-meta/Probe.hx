import haxe.macro.Context;

class Probe {
	static function use() {
		Context.onAfterGenerate(() -> {
			for (n in ["Named", "Base", "Impl"]) switch Context.getType("SharedFieldMeta." + n) {
				case TInst(c, _):
					for (f in c.get().fields.get()) Sys.println(n + "." + f.name + " " + [for (m in f.meta.get()) m.name].join(","));
				case _:
			}
		});
	}
}
