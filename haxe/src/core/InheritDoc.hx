package core;

import Type as StdType;
import core.Ast;
import core.Globals;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import typing.Typeload;
import core.ds.VectorTools.vector;

// port: from haxe/src/core/inheritDoc.ml.
class InheritDoc {
	public static function exprToTarget(e:Expr):{path:GlobalTypePath, sub:Null<String>} {
		function loop(e:Expr):Array<String> return switch e.expr {
			case EConst(Ident(s)) if (s != ""): [s];
			case EField(e, s, _): [s].concat(loop(e));
			case _: Error.raiseTypingError("Invalid target expression for @:inheritDoc", e.pos);
		};
		var parts = loop(e);
		if (parts.length >= 2 && !Ast.isLowerIdent(parts[1])) {
			var pack = parts.slice(2);
			pack.reverse();
			return {path: {pack: pack, name: parts[1]}, sub: parts[0]};
		}
		if (parts.length >= 1) {
			var pack = parts.slice(1);
			pack.reverse();
			return {path: {pack: pack, name: parts[0]}, sub: null};
		}
		return Error.raiseTypingError("Invalid target path for @:inheritDoc", e.pos);
	}

	public static function getConstructor(c:TClass):{cls:Null<TClass>, field:TClassField} {
		if (c.clConstructor != null) return {cls: c, field: c.clConstructor};
		if (c.clSuper == null) throw NotFound.raise();
		return getConstructor(c.clSuper.cls);
	}

	public static function getClassField(c:TClass, fieldName:String):{cls:Null<TClass>, field:TClassField} {
		try {
			var cf = try findMap(c.clFields, fieldName) catch (_:NotFound) findMap(c.clStatics, fieldName);
			return {cls: c, field: cf};
		} catch (_:NotFound) {
			if (c.clSuper == null) throw NotFound.raise();
			return getClassField(c.clSuper.cls, fieldName);
		}
	}

	public static function findType(ctx:context.Typecore.Typer, mode:LoadInstanceMode, tp:TypePath, p:Pos):T {
		try return Typeload.loadInstancePrime(ctx, Ast.makePtp(tp, p), ParamSpawnMonos, mode)
		catch (_:Dynamic) throw NotFound.raise();
	}

	/**
		Finds `@:inheritDoc` meta in `meta` and populates `doc_inherited` field of `doc`
		with found docs.
	**/
	public static function buildDoc(ctx:context.Typecore.Typer, doc:{value:Documentation}, meta:Metadata,
			?noArgsCb:(Documentation->Void)->Void):Void {
		function add(d:Documentation):Void {
			if (d == null) return;
			var s = Ast.genDocText(d);
			if (s == "") return;
			if (doc.value == null) doc.value = {docOwn: null, docInherited: [s]};
			else doc.value.docInherited.unshift(s);
		}
		for (m in meta) if (StdType.enumEq(m.meta, Meta.InheritDoc)) {
			if (m.exprs.length == 0) {
				if (noArgsCb != null) noArgsCb(add);
			} else for (t in m.exprs) add(getTargetDoc(ctx, t));
		}
	}

	/**
		Populates `doc_inherited` field of `c.cl_doc`
	**/
	public static function buildClassDoc(ctx:context.Typecore.Typer, c:TClass):Void {
		if (c.clDoc != null && c.clDoc.docInherited.length != 0) c.clDoc.docInherited = [];
		var doc = {value: c.clDoc};
		buildDoc(ctx, doc, c.clMeta, function(add) {
			if (c.clSuper != null) {
				buildClassDoc(ctx, c.clSuper.cls);
				add(c.clSuper.cls.clDoc);
			}
		});
		c.clDoc = doc.value;
	}

	/**
		Populates `doc_inherited` field of `enm.e_doc`
	**/
	public static function buildEnumDoc(ctx:context.Typecore.Typer, en:TEnum):Void {
		if (en.eDoc != null && en.eDoc.docInherited.length != 0) en.eDoc.docInherited = [];
		var doc = {value: en.eDoc};
		buildDoc(ctx, doc, en.eMeta);
		en.eDoc = doc.value;
	}

	/**
		Populates `doc_inherited` field of `a.a_doc`
	**/
	public static function buildAbstractDoc(ctx:context.Typecore.Typer, a:TAbstract):Void {
		if (a.aDoc != null && a.aDoc.docInherited.length != 0) a.aDoc.docInherited = [];
		var doc = {value: a.aDoc};
		buildDoc(ctx, doc, a.aMeta);
		a.aDoc = doc.value;
	}

	/**
		Populates `doc_inherited` field of `cf.cf_doc`
	**/
	public static function buildClassFieldDoc(ctx:context.Typecore.Typer, cOpt:Null<TClass>, cf:TClassField):Void {
		if (cf.cfDoc != null && cf.cfDoc.docInherited.length != 0) cf.cfDoc.docInherited = [];
		var doc = {value: cf.cfDoc};
		buildDoc(ctx, doc, cf.cfMeta, function(add) {
			if (cOpt != null && cOpt.clSuper != null) try {
				var result = cf.cfName == "new" ? getConstructor(cOpt.clSuper.cls) : getClassField(cOpt.clSuper.cls, cf.cfName);
				buildClassFieldDoc(ctx, result.cls, result.field);
				add(result.field.cfDoc);
			} catch (_:NotFound) {}
		});
		cf.cfDoc = doc.value;
	}

	/**
		Populates `doc_inherited` field of `ef.ef_doc`
	**/
	public static function buildEnumFieldDoc(ctx:context.Typecore.Typer, ef:TEnumField):Void {
		if (ef.efDoc != null && ef.efDoc.docInherited.length != 0) ef.efDoc.docInherited = [];
		var doc = {value: ef.efDoc};
		buildDoc(ctx, doc, ef.efMeta);
		ef.efDoc = doc.value;
	}

	/**
		Collects `Ast.documentation` for a provided `target`
		The `target` is an AST expr representing a dot path for a type or a field.
		E.g. `my.pack.MyType` or `my.pack.MyType.field`
	**/
	public static function getTargetDoc(ctx:context.Typecore.Typer, eTarget:Expr):Documentation {
		var target = exprToTarget(eTarget);
		var path = target.path;
		// port: not inline: HashLink 2.0 JIT: an early exit through two nested try blocks restores only the innermost trap, leaving a dangling handler (resolveField's try sits inside the try below).
		function resolveField(fieldName:String):Documentation {
			var reversed = path.pack.copy();
			reversed.reverse();
			var tp = if (reversed.length > 0 && !Ast.isLowerIdent(reversed[0])) {
				var pack = reversed.slice(1);
				pack.reverse();
				Ast.mkTypePath(pack, reversed[0], vector(), path.name);
			} else Ast.mkTypePath(path.pack, path.name);
			var t = findType(ctx, LoadNormal, tp, eTarget.pos);
			try return switch follow(t) {
				case TInst(c, _):
					var r = fieldName == "new" ? getConstructor(c) : getClassField(c, fieldName);
					buildClassFieldDoc(ctx, r.cls, r.field);
					r.field.cfDoc;
				case TAnon(a):
					var cf = findMap(a.aFields, fieldName);
					buildClassFieldDoc(ctx, null, cf);
					cf.cfDoc;
				case TEnum(en, _):
					var ef = findMap(en.eConstrs, fieldName);
					buildEnumFieldDoc(ctx, ef);
					ef.efDoc;
				case TAbstract(a, _) if (a.aImpl != null):
					var r = getClassField(a.aImpl, fieldName == "new" ? "_hx_new" : fieldName);
					buildClassFieldDoc(ctx, r.cls, r.field);
					r.field.cfDoc;
				case _: throw NotFound.raise();
			} catch (_:NotFound) return null;
		}
		inline function resolveTypeT(t:T):Documentation return switch follow(t) {
			case TInst(c, _):
				buildClassDoc(ctx, c);
				c.clDoc;
			case TAbstract(a, _):
				buildAbstractDoc(ctx, a);
				a.aDoc;
			case TEnum(en, _):
				buildEnumDoc(ctx, en);
				en.eDoc;
			case _: throw NotFound.raise();
		};
		try {
			// type
			if (target.sub == null) return resolveTypeT(findType(ctx, LoadNormal, Ast.mkTypePath(path.pack, path.name), eTarget.pos));
			// field or sub type
			if (Ast.isLowerIdent(target.sub)) return resolveField(target.sub);
			var doc = try resolveTypeT(findType(ctx, LoadNormal, Ast.mkTypePath(path.pack, path.name, vector(), target.sub),
				eTarget.pos)) catch (_:NotFound) resolveField(target.sub);
			return doc;
		} catch (_:NotFound) return null;
	}
}
