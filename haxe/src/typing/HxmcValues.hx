package typing;

import context.Typecore;
import core.Ast;
import core.Error;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.MetaList.StrictMeta as MetaTag;
import core.TFunctions.*;
import core.TType;
import core.ds.VectorTools.vector;

// hxmc: anonymous structures in scoped code are struct values
// (docs/plans/lowlevel.md, "Less to write"). A structure type written in a
// scoped class (its fields, signatures and bodies) or in a scoped typedef,
// and an object literal in a scoped class with no structure expected, is a
// scoped class made for its fields (hxmc.values.Anon_...): one per set of
// field names and types, so the same structure written anywhere is the same
// type. Its fields are variables (no methods, no optional fields, no type
// parameters); anything else stays a structure, which scoped code refuses.
class HxmcValues {
	// (> 0: loading a scoped typedef's type; suspended: a structure extended,
	// CTExtend, which needs the structure)
	public static var inTypedef = 0;
	public static var suspended = 0;

	// whether a structure type or literal typed by ctx is a value
	public static function applies(ctx:Typer):Bool {
		if (suspended > 0) return false;
		if (inTypedef > 0) return true;
		var c = ctx.c.curclass;
		return c != null && c != nullClass && core.HxmcScoped.isClass(c);
	}

	// the value class of structure a, or null (a stays a structure)
	public static function ofAnon(ctx:Typer, a:TAnon, p:Pos):Null<T> {
		var names = [for (n in a.aFields.keys()) n];
		if (names.length == 0) return null;
		names.sort(core.ds.Key.compareStrings);
		var key = new StringBuf();
		for (n in names) {
			var cf = a.aFields.get(n);
			if (cf.cfParams.length > 0 || !isPhysicalVarField(cf) || core.Meta.has(MetaTag.Optional, cf.cfMeta)) return null;
			switch cf.cfKind {
				case Var({vRead: AccNormal, vWrite: AccNormal | AccNever}):
				case _: return null;
			}
			if (!concrete(cf.cfType)) return null;
			key.add(n);
			key.add(hasClassFieldFlag(cf, CfFinal) ? "=" : ":");
			key.add(core.TPrinting.sType(core.TPrinting.printContext(), cf.cfType));
			key.add(";");
		}
		var k = key.toString();
		var path:GlobalTypePath = {pack: ["hxmc", "values"], name: "Anon_" + names.join("_") + "_" + hash(k)};
		var m = ctx.com.moduleLut.findOpt(path);
		if (m != null)
			for (mt in m.mTypes)
				switch mt {
					case TClassDecl(c) if (core.Meta.has(MetaTag.Custom(":hxmc.anon"), c.clMeta)):
						if (metaKey(c) != k) Error.raiseTypingError('two structures share the value class ${path.name} (${metaKey(c)} and $k): rename a field', p);
						return TInst(c, vector());
					case _:
				}
		var mg:ModuleDef = {
			mId: allocMid(),
			mPath: path,
			mTypes: [],
			mStatics: null,
			mExtra: moduleExtra(core.Globals.sTypePath(path), ctx.m.curmod.mExtra.mSign, 0., MFake, ctx.com.partScope.compilationStep,
				ctx.m.curmod.mExtra.mCheckPolicy)
		};
		var c = mkClass(mg, path, p, p);
		c.clMeta = [
			{meta: MetaTag.Custom(":hxmc.scoped"), exprs: vector(), pos: p},
			{meta: MetaTag.Custom(":hxmc.anon"), exprs: vector({expr: EConst(String(k, SDoubleQuotes)), pos: p}), pos: p},
			{meta: MetaTag.NoDoc, exprs: vector(), pos: p}
		];
		var types = [];
		for (n in names) {
			var old = a.aFields.get(n);
			var cf = mkField(n, old.cfType, p, p);
			if (hasClassFieldFlag(old, CfFinal)) addClassFieldFlag(cf, CfFinal);
			c.clFields.set(n, cf);
			c.clOrderedFields.push(cf);
			types.push(old.cfType);
		}
		mg.mTypes = [TClassDecl(c)];
		ctx.com.moduleLut.add(mg.mPath, mg);
		addDependency(ctx.m.curmod, mg, MDepFromTyping);
		typing.Generic.setTypeParameterDependencies(mg, haxe.ds.Vector.fromArrayCopy(types));
		TypeloadFields.ensureStructInitConstructor(ctx, c, [], p);
		// (inline, as a written struct class's would be: built in place)
		c.clConstructor.cfKind = Method(MethInline);
		return TInst(c, vector());
	}

	// an object literal of value class c (fields: typed, in source order):
	// the fields evaluated in that order, then the constructor called
	public static function literal(ctx:Typer, c:TClass, fields:haxe.ds.Vector<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>, p:Pos):TExpr {
		var t = TInst(c, vector()), decls = [], byName = new Map<String, TExpr>();
		var ordered = true;
		for (i in 1...fields.length)
			if (core.ds.Key.compareStrings(fields[i - 1].key.name, fields[i].key.name) > 0) ordered = false;
		for (f in fields) {
			var e = f.expr;
			if (!ordered && !e.eexpr.match(TConst(_) | TLocal(_) | TTypeExpr(_))) {
				var v = Typecore.genLocal(ctx, e.etype, e.epos);
				decls.push(mk(TVar(v, e), ctx.t.tvoid, e.epos));
				e = mk(TLocal(v), v.vType, e.epos);
			}
			byName.set(f.key.name, e);
		}
		var e = mk(TNew(c, vector(), haxe.ds.Vector.fromArrayCopy([for (cf in c.clOrderedFields) byName.get(cf.cfName)])), t, p);
		if (decls.length == 0) return e;
		decls.push(e);
		return mk(TBlock(haxe.ds.Vector.fromArrayCopy(decls)), t, p);
	}

	// a type with no type parameter and no unknown part
	static function concrete(t:T):Bool
		return switch t {
			case TMono(r): r.tmType != null && concrete(r.tmType);
			case TInst({clKind: KTypeParameter(_)}, _): false;
			case TInst(_, tl) | TEnum(_, tl) | TType(_, tl) | TAbstract(_, tl):
				for (t in tl)
					if (!concrete(t)) return false;
				true;
			case TFun(_) | TDynamic(_) | TAnon(_) | TLazy(_): false;
		}

	static function metaKey(c:TClass):String
		return switch core.Meta.getOpt(MetaTag.Custom(":hxmc.anon"), c.clMeta) {
			case {exprs: [{expr: EConst(String(s, _))}]}: s;
			case _: "";
		}

	// (FNV-1a, base 36)
	static function hash(s:String):String {
		var h = 0x811c9dc5;
		for (i in 0...s.length)
			h = (h ^ StringTools.fastCodeAt(s, i)) * 0x01000193;
		var u = haxe.Int64.make(0, h), r = "";
		do {
			var d = haxe.Int64.toInt(haxe.Int64.mod(u, 36));
			r = "0123456789abcdefghijklmnopqrstuvwxyz".charAt(d) + r;
			u = haxe.Int64.div(u, 36);
		} while (u != 0);
		return r;
	}
}
