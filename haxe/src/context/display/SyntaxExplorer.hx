package context.display;

import core.Globals;
import core.Globals.Pos;
import compiler.CompilationCache;
import context.CommonCache;
import context.Typecore;
import context.Typecore.Typer;
import core.Ast;
import core.DisplayTypes;
import core.TType;

enum ReferenceKind {
	KVar;
	KIdent;
	KAnyField;
	KClassField;
	KEnumField;
	KModuleType;
	KConstructor;
}

class SyntaxExplorer {
	public static function findInSyntax(symbols:Array<{name:String, kind:Symbol}>, pack:Array<String>, decls:haxe.ds.Vector<TypeDecl>):Void {
		// Employ some heuristics: We know what kind of symbol we are looking for, so let's
		// filter where we can.
		function check(kind_:ReferenceKind, name_:String):Void {
			for (s in symbols) {
				if (s.name == name_) {
					var hit = switch [kind_, s.kind] {
						case [KIdent, _]: true;
						case [KAnyField, SKField(_) | SKConstructor(_) | SKEnumField(_)]: true;
						case [KClassField, SKField(_)]: true;
						case [KEnumField, SKEnumField(_)]: true;
						case [KModuleType, SKClass(_) | SKEnum(_) | SKTypedef(_) | SKAbstract(_)]: true;
						case [KConstructor, SKConstructor(_) | SKClass(_)]: true;
						case _: false;
					};
					if (hit) throw core.ds.Exit.raise();
				}
			}
		}
		var typeHint:TypeHint->Void = null;
		var expr:Expr->Void = null;
		var field:ClassField->Void = null;
		function typePath(kind:ReferenceKind, ptp:PlacedTypePath):Void {
			var path = ptp.path;
			check(KModuleType, path.tname);
			if (path.tsub != null) check(KModuleType, path.tsub);
			for (tp in path.tparams) switch tp {
				case TPType(th):
					typeHint(th);
				case TPExpr(e):
					expr(e);
			}
		}
		typeHint = function(th:TypeHint):Void {
			switch th.type {
				case CTPath(path):
					typePath(KModuleType, path);
				case CTParent(th) | CTOptional(th) | CTNamed(_, th):
					typeHint(th);
				case CTFunction(thl, th):
					for (th in thl) typeHint(th);
					typeHint(th);
				case CTAnonymous(cffl):
					for (f in cffl) field(f);
				case CTExtend(tl, cffl):
					for (ptp in tl) typePath(KModuleType, ptp);
					for (f in cffl) field(f);
				case CTIntersection(tl):
					for (th in tl) typeHint(th);
			}
		};
		function typeParam(tp:TypeParam):Void {
			for (tp in tp.tpParams) typeParam(tp);
			if (tp.tpConstraints != null) typeHint(tp.tpConstraints);
		}
		function exprOpt(eo:Null<Expr>):Void if (eo != null) expr(eo);
		function func(f:Func):Void {
			for (a in f.fArgs) {
				if (a.type != null) typeHint(a.type);
				exprOpt(a.expr);
			}
			for (tp in f.fParams) typeParam(tp);
			if (f.fType != null) typeHint(f.fType);
			exprOpt(f.fExpr);
		}
		expr = function(e:Expr):Void {
			switch e.expr {
				case EConst(Ident(s)):
					check(KIdent, s);
				case EField(e1, s, _):
					expr(e1);
					check(KAnyField, s);
				case EVars(vl):
					for (v in vl) {
						if (v.evType != null) typeHint(v.evType);
						exprOpt(v.evExpr);
					}
				case ECast(e1, tho):
					expr(e1);
					if (tho != null) typeHint(tho);
				case ENew(ptp, el):
					typePath(KConstructor, ptp);
					for (e in el) expr(e);
				case EFunction(_, f):
					func(f);
				case ETry(e1, catches):
					expr(e1);
					for (c in catches) {
						if (c.type != null) typeHint(c.type);
						expr(c.expr);
					}
				case ECheckType(e1, th):
					expr(e1);
					typeHint(th);
				case _:
					Ast.iterExpr(expr, e);
			}
		};
		function fieldKind(cffKind:ClassFieldKind):Void {
			switch cffKind {
				case FVar(tho, eo):
					if (tho != null) typeHint(tho);
					exprOpt(eo);
				case FFun(f):
					func(f);
				case FProp(_, _, tho, eo):
					if (tho != null) typeHint(tho);
					exprOpt(eo);
			}
		}
		field = function(cff:ClassField):Void {
			check(KClassField, cff.cffName.name);
			fieldKind(cff.cffKind);
		};
		for (decl in decls) switch decl.definition {
			case EImport({path: path}) | EUsing(path):
				switch ImportHandling.convertImportToSomethingUsable(Globals.nullPos, path).kind {
					case IDKModule(_, s): check(KModuleType, s);
					case IDKSubType(_, s1, s2):
						check(KModuleType, s1);
						check(KModuleType, s2);
					case IDKSubTypeField(_, s1, s2, s3):
						check(KModuleType, s1);
						check(KModuleType, s2);
						check(KAnyField, s3);
					case IDKModuleField(_, s1, s2):
						check(KModuleType, s1);
						check(KAnyField, s2);
					case IDKPackage(_) | IDK:
				}
			case EClass(d):
				check(KModuleType, d.name.name);
				for (f in d.flags) switch f {
					case HExtends(ptp) | HImplements(ptp): typePath(KModuleType, ptp);
					case _:
				}
				for (tp in d.params) typeParam(tp);
				for (f in d.data) field(f);
			case EEnum(d):
				check(KModuleType, d.name.name);
				for (ef in d.data) {
					if (ef.ecType != null) typeHint(ef.ecType);
					check(KEnumField, ef.ecName.name);
					for (tp in ef.ecParams) typeParam(tp);
				}
				for (tp in d.params) typeParam(tp);
			case ETypedef(d):
				check(KModuleType, d.name.name);
				for (tp in d.params) typeParam(tp);
				typeHint(d.data);
			case EAbstract(d):
				check(KModuleType, d.name.name);
				for (f in d.data) field(f);
				for (tp in d.params) typeParam(tp);
				for (f in d.flags) switch f {
					case AbFrom(th) | AbTo(th) | AbOver(th): typeHint(th);
					case _:
				}
			case EStatic(d):
				check(KModuleType, d.name.name);
				fieldKind(d.data);
		}
	}

	public static function exploreUncachedModules(tctx:Typer, cs:Cache, symbols:Array<{name:String, kind:Symbol}>):Array<ModuleDef> {
		DisplayToplevel.initOrUpdateServer(cs, tctx.com, ["display", "references"]);
		var cc = CommonCache.getCache(tctx.com);
		var files = cc.getFiles();
		var modules = cc.getModules();
		var acc = core.Timer.time(tctx.com.timerCtx, ["display", "references", "candidates"], function(_:Null<Bool>) {
			return files.fold(function(fileKey, cfile, acc:Array<ModuleDef>) {
				var moduleName = CompilationCache.getModuleNameOfCfile(cfile.cFilePath.file, cfile);
				if (modules.mem({pack: cfile.cPackage, name: moduleName})) return acc;
				try {
					findInSyntax(symbols, cfile.cPackage, cfile.cDecls);
					return acc;
				} catch (_:core.ds.Exit) {
					try {
						var m = tctx.g.doLoadModule(tctx, {pack: cfile.cPackage, name: moduleName}, Globals.nullPos);
						// We have to flush immediately so we catch exceptions from weird modules
						Typecore.flushPass(tctx.g, PFinal, {name: "final", path: cfile.cPackage.concat([moduleName])});
						acc.unshift(m);
						return acc;
					} catch (_:Dynamic) {
						return acc;
					}
				}
			}, []);
		}, null);
		return acc;
	}
}
