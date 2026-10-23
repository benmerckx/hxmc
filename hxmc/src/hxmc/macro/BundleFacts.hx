package hxmc.macro;

import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import core.TType;
import hxmc.Obj;
import hxmc.ir.Ir;


// What the Loader needs of a bundle compiled for the Mir interpreter
// (interp.MirMacros, interp.MirRun) besides its object: the program-wide
// facts to number, register and initialize its parts (`facts`), and which
// of its classes and functions are the runtime's (hxmc.rt, hxmc.unsafe),
// whose functions and state are the compiler's.
@:access(hxmc.ir.Facts)
@:access(hxmc.ir.Lower)
@:access(hxmc.macro.Loader)
class BundleFacts {
	static function runtime(f:FuncInfo):Bool
		return f.module != null && (StringTools.startsWith(f.module, "hxmc.rt.") || StringTools.startsWith(f.module, "hxmc.unsafe."));

	static function kindChar(t:Null<Ty>):String
		return t == null ? "-" : switch t {
			case TI32: "i";
			case TBool: "b";
			case TF64: "f";
			case TI64: "l";
			case _: "p";
		};

	// what the loader needs to number, register and initialize the program's parts
	// (types: the program's, com.types by default; the macro context's handed over so far for interp.MirMacros)
	static function facts(com:context.Common.CommonContext, p:Program, e:hxmc.ir.Facts, l:hxmc.ir.Lower, main:Null<TClass>, ?types:Array<ModuleType>):Dynamic {
		var tn = e.typeNames;
		// what may be the compiler's own: the std's types and statics (hxmc's std, with the
		// runtime, included); the program's are its own even when named as one of the compiler's
		var roots = [];
		for (cp in com.classPaths.asList())
			if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx")))
				roots.push(cp.path);
		function isStd(file:String):Bool {
			for (r in roots)
				if (StringTools.startsWith(file, r)) return true;
			return false;
		}
		var stdTypes = new Map<String, Bool>();
		var globalShare = new Map<Int, Bool>();
		for (t in (types != null ? types : com.types)) {
			var info = core.TFunctions.tInfos(t);
			var std = isStd(info.mtPos.pfile);
			if (std) stdTypes.set(core.Globals.sTypePath(info.mtPath), true);
			switch t {
				case TClassDecl(c):
					for (cf in c.clOrderedStatics) {
						var g = l.staticVars.get(cf);
						if (g != null) globalShare.set(g, std);
					}
				case _:
			}
		}
		for (en in p.enums)
			for (c in en.ctors)
				if (c.global >= 0) globalShare.set(c.global, stdTypes.exists(en.name));
		inline function tyName(i:Int):Dynamic
			return i < 0 ? null : i < Abi.T_FIRST ? Std.string(i) : tn[i];
		var share = new Map<Int, Bool>();
		var types = [];
		for (i in Abi.T_FIRST...e.types.length) {
			var t = e.types[i];
			share.set(i, switch t.tk {
				case "TK_ANON" | "TK_BOUND": true;
				case "TK_CLOSURE": false;
				case "TK_CTOR": share.get(t.sup) == true;
				case _: stdTypes.exists(t.name);
			});
			var supIsSig = t.tk == "TK_CLOSURE" || t.tk == "TK_BOUND";
			types.push({
				sym: tn[i],
				name: t.name,
				share: share.get(i),
				tk: t.tk,
				sup: supIsSig ? e.sigNames[t.sup] : tyName(t.sup),
				slots: [for (s in t.slots) kindChar(s)].join(""),
				fields: [for (f in t.fields) {name: f.name, slot: f.slot, kind: f.kind != null ? String.fromCharCode(f.kind) : kindChar(f.ty)}],
				// (a method with default values for numbers or Bools: its entry taking them nullable, as DataGen)
				methods: [for (m in t.methods) {name: m.name, fn: m.dfn != null ? m.dfn : m.fn, sig: e.sigNames[m.dfn != null ? m.dsig : m.sig]}],
				ifaces: [for (x in t.ifaces) tyName(x)],
				tag: t.tag,
				ctors: [for (x in t.ctors) tyName(x)],
				// (Type.createInstance's entry, as DataGen writes it: fn null, no constructor)
				maker: t.maker == null ? null : {fn: t.maker.fn, sig: t.maker.fn == null ? null : e.sigNames[t.maker.sig]}
			});
		}
		// (statics: what Reflect finds on the class value, as DataGen writes them)
		function statics(ss:Null<Array<StaticEntry>>):Array<Dynamic> {
			if (ss == null) return [];
			// (the live ones, as DataGen: hxmc.ir.Reach)
			return [
				for (x in ss)
					if (x.clos != null && !p.isLive(x.clos.fn)) continue else if (x.clos != null) {name: x.name, kind: "c", ty: tn[x.clos.tindex], fn: e.symbol(x.clos.fn)}
					else if (Ir.isRef(p.globals[x.global].ty)) {name: x.name, kind: "p", global: e.globalNames[x.global]}
					else {name: x.name, kind: kindChar(p.globals[x.global].ty), sym: e.scalarGlobal(x.global)}
			];
		}
		var classes = [for (c in p.classes) if (c.tindex >= Abi.T_FIRST) {ty: tn[c.tindex], sup: c.sup == null || c.sup.tindex < 0 ? null : tn[c.sup.tindex], span: c.lastDescendant - c.id, statics: statics(c.statics)}];
		// (an interface's statics: its __meta__, as DataGen writes them)
		var interfaces = [for (c in p.interfaces) if (c.tindex >= Abi.T_FIRST && c.statics != null && c.statics.length > 0) {ty: tn[c.tindex], statics: statics(c.statics)}];
		// (and an enum's: its __meta__, Lower.reflectEnum)
		var enumStatics = [for (en in p.enums) if (en.tindex >= Abi.T_FIRST && en.statics != null && en.statics.length > 0) {ty: tn[en.tindex], statics: statics(en.statics)}];
		var globals = [], bss = [];
		for (g in 0...p.globals.length) {
			var gl = p.globals[g];
			// (a @:hxmc.bss static: a zeroed block, the compiler's when it has it)
			if (gl.bss != null) bss.push({sym: gl.sym, size: gl.bss});
			if (gl.tls != null || gl.bss != null) continue;
			var ref = Ir.isRef(gl.ty);
			globals.push({
				name: e.globalNames[g],
				ref: ref,
				share: globalShare.get(g) == true,
				sym: ref ? "GIOFF_" + e.globalNames[g].substr(3) : e.scalarGlobal(g),
				size: gl.ty == TI32 || gl.ty == TBool ? 4 : 8,
				init: gl.init == null ? null : tn[gl.init.tindex]
			});
		}
		var inits = [];
		for (f in p.inits) {
			var c = l.initOf.get(f);
			if (c != null && runtimeClass(c)) continue;
			var ci = c == null ? null : l.classes.get(c);
			inits.push({fn: e.symbol(f), ty: ci == null || ci.tindex < 0 ? null : tn[ci.tindex], share: c != null && stdTypes.exists(core.Globals.sTypePath(c.clPath))});
		}
		// (each class's effective methods once, as findMethod finds them: the
		// rows of each selector in the classes' order)
		var rowsOf:Array<Array<Dynamic>> = [for (_ in 0...p.selectors.length) []];
		for (c in p.classes) {
			if (c.tindex < Abi.T_FIRST) continue;
			var seen = new Map<String, Bool>();
			var k = c;
			while (k != null) {
				for (name => m in k.methods)
					if (!seen.exists(name)) {
						seen.set(name, true);
						var s = m.dispatchSel;
						if (s >= 0 && p.selectors[s].name == name && p.isLive(m)) rowsOf[s].push({ty: tn[c.tindex], fn: e.symbol(m)});
					}
				k = k.sup;
			}
		}
		var selectors = [for (s in 0...p.selectors.length) {sym: e.selNames[s], rows: rowsOf[s]}];
		var entries = [];
		if (main != null)
			for (cf in main.clOrderedStatics) {
				var f = l.funcs.get(cf);
				if (f != null && cf.cfName != "main" && p.isLive(f)) entries.push({name: cf.cfName, sym: e.symbol(f)});
			}
		// the singletons of constructors without arguments (the bridge's enum values)
		var singletons = [];
		for (en in p.enums)
			for (c in en.ctors)
				if (c.global >= 0) singletons.push({ty: tn[c.tindex], global: e.globalNames[c.global]});
		return {
			types: types,
			classes: classes,
			interfaces: interfaces,
			enumStatics: enumStatics,
			fields: [for (n in e.fieldNames) {name: n, sym: e.fidNames.get(n)}],
			sigs: [for (s in p.sigs) {sym: e.sigNames[s.id], key: s.key, dyn: "DYN" + s.id, bt: "BT" + s.id, bound: tn[e.boundTypes.get(s.id)]}],
			globals: globals,
			bss: bss,
			inits: inits,
			selectors: selectors,
			entries: entries,
			singletons: singletons
		};
	}

	static function runtimeClass(c:TClass):Bool {
		var pk = c.clPath.pack;
		return pk.length >= 2 && pk[0] == "hxmc" && (pk[1] == "rt" || pk[1] == "unsafe");
	}
}
