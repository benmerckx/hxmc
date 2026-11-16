package codegen;

import core.TType;
import core.Ast.Metadata;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther.TClassTools;
import core.TPrinting;
import core.TPrinting.Printer;
import core.Globals;
import core.Globals.*;
import core.Path;
import core.Meta;
import context.Common;
import context.DumpConfig;
import context.Parallel;

class Dump {
	/*
		Make a dump of the full typed AST of all types
	*/
	public static function createDumpfile(acc:Array<String>, parts:Array<String>):{buffer:StringBuf, close:Void->Void} {
		var ch = Path.createFile(false, ".dump", acc, parts),
			buf = new StringBuf();
		return {
			buffer: buf,
			close: function() {
				ch.writeString(buf.toString());
				ch.close();
			}
		};
	}

	public static function createDumpfileFromPath(com:CommonContext, path:GlobalTypePath):{buffer:StringBuf, close:Void->Void}
		return createDumpfile([], [
			com.partScope.dumpConfig.dumpPath,
			DumpConfig.stringOfDumpStage(com.partScope.dumpConfig.dumpStage),
			Common.platformNameMacro(com)
		].concat(path.pack).concat([path.name]));

	public static function dumpTypesFormatted(com:CommonContext, pretty:Bool):Void {
		var restore:Void->Void = function() {};
		if (!pretty) {
			var old = TPrinting.MonomorphPrinting.showMonoIds;
			TPrinting.MonomorphPrinting.showMonoIds = com.partScope.dumpConfig.dumpPrintIds;
			restore = function() TPrinting.MonomorphPrinting.showMonoIds = old;
		}
		var pc = TPrinting.printContext();
		function st(t:T):String return TPrinting.sType(pc, t);
		inline function se(e:TExpr):String return pretty ? TPrinting.sExprPretty(false, "\t", true, st,
			e) : TPrinting.sExprAst(com.partScope.dumpConfig.dumpPrintIds, "\t", st, e);
		function tp(param:TypedTypeParam):String return pretty ? TPrinting.sTypeParam(st, param) : Printer.sTypeParam("", param);
		function params(tl:TypeParams):String return tl.length == 0 ? "" : "<" + tl.map(tp).join(", ") + ">";
		function emit(mt:ModuleType):Void {
			var path = tPath(mt),
				out = createDumpfileFromPath(com, path),
				buf = out.buffer;
			inline function metas(ml:Metadata, tabs:String):String {
				if (ml.length == 0) return "";
				return ml.map(function(m) return "@"
					+ Meta.toString(m.meta)
					+ (m.exprs.length == 0 ? "" : "(" + m.exprs.map(core.AstPrinter.sExpr).join(", ") + ")"))
					.join(" ") + "\n"
					+ tabs;
			}
			switch mt {
				case TClassDecl(c):
					function cfExpr(f:TClassField):String return f.cfExpr == null ? "" : se(f.cfExpr);
					inline function inlineVar(kind:FieldKind):Bool return switch kind {
						case Var({vRead: AccInline, vWrite: AccNever}): true;
						case _: false;
					};
					function printField(stat:Bool, f:TClassField):Void {
						var modifier = switch f.cfKind {
							case Var(_) if (inlineVar(f.cfKind)): "inline ";
							case Var(_): "";
							case Method(MethNormal): "";
							case Method(MethDynamic): "dynamic ";
							case Method(MethInline): "inline ";
							case Method(MethMacro): "macro ";
						};
						var kind = switch f.cfKind {
							case Var(_): "var";
							case Method(_): "function";
						};
						var accessor = switch f.cfKind {
							case Var({vRead: AccNormal, vWrite: AccNormal}): "";
							case Var(_) if (inlineVar(f.cfKind)): "";
							case Var(v): "(" + TPrinting.sAccess(true, v.vRead) + "," + TPrinting.sAccess(false, v.vWrite) + ")";
							case _: "";
						};
						buf.add("\n\t"
							+ metas(f.cfMeta, "\t")
							+ (hasClassFieldFlag(f, CfPublic)
								&& !hasClassFlag(c, CExtern)
								&& !hasClassFlag(c, CInterface) ? "public " : "")
							+ (stat ? "static " : "")
							+ modifier
							+ kind
							+ " "
							+ f.cfName
							+ accessor
							+ params(f.cfParams));
						switch f.cfKind {
							case Var(_):
								buf.add(":" + st(f.cfType) + (f.cfExpr == null ? "" : " = " + cfExpr(f)) + ";");
							case Method(_):
								if (hasClassFlag(c, CExtern) || hasClassFlag(c, CInterface)) switch f.cfType {
									case TFun(s): buf.add("("
											+ s.args.map(function(a) return a.name + ":" + st(a.type)).join(", ")
											+ "):"
											+ st(s.ret)
											+ ";");
									case _:
								}
								else buf.add(cfExpr(f));
						}
						buf.add("\n");
						for (overloadedField in f.cfOverloads) printField(stat, overloadedField);
					}
					buf.add(metas(c.clMeta, "") + (c.clPrivate ? "private " : "") + (hasClassFlag(c, CExtern) ? "extern " : "")
						+ (hasClassFlag(c, CInterface) ? "interface" : "class") + " " + sTypePath(path) + params(c.clParams));
					if (c.clSuper != null) buf.add(" extends " + st(TInst(c.clSuper.cls, c.clSuper.params)));
					for (parent in c.clImplements) buf.add(" implements " + st(TInst(parent.cls, parent.params)));
					if (c.clArrayAccess != null) buf.add(" implements ArrayAccess<" + st(c.clArrayAccess) + ">");
					buf.add(" {\n");
					if (c.clConstructor != null) printField(false, c.clConstructor);
					for (f in c.clFields) printField(false, f);
					for (f in c.clStatics) printField(true, f);
					var init = TClassTools.getClInit(c);
					if (init != null) buf.add("\n\tstatic function __init__() " + se(init) + "\n");
					buf.add("}");
				case TEnumDecl(e):
					buf.add(metas(e.eMeta, "") + (e.ePrivate ? "private " : "") + (hasEnumFlag(e, EnExtern) ? "extern " : "") + "enum "
						+ sTypePath(path) + params(e.eParams) + " {\n");
					for (name in e.eConstrs.names()) {
						var f = e.eConstrs.get(name);
						var suffix = switch f.efType {
							case TFun(s): "("
								+ s.args.map(function(a) return (a.optional ? "?" : "") + a.name + ":" + st(a.type)).join(", ")
								+ ")";
							case _: "";
						};
						buf.add("\t" + f.efName + suffix + ";\n");
					}
					buf.add("}");
				case TTypeDecl(t):
					buf.add(metas(t.tMeta, "")
						+ (t.tPrivate ? "private " : "")
						+ "typedef "
						+ sTypePath(path)
						+ params(t.tParams)
						+ " = "
						+ st(t.tType));
				case TAbstractDecl(a):
					buf.add(metas(a.aMeta, "")
						+ (a.aPrivate ? "private " : "")
						+ "abstract "
						+ sTypePath(path)
						+ params(a.aParams)
						+ a.aFrom.map(function(t) return " from " + st(t)).join(" ")
						+ a.aTo.map(function(t) return " to " + st(t)).join(" ")
						+ " {}");
			}
			out.close();
		}
		Parallel.runWithPool(com.sctx.pool, function(pool) {
			ParallelArray.iter(pool, emit, com.types.copy());
			return null;
		});
		restore();
	}

	public static function dumpRecord(com:CommonContext):Void {
		function emit(mt:ModuleType):Void {
			var out = createDumpfileFromPath(com, tPath(mt));
			var text = switch mt {
				case TClassDecl(c): Printer.sTclass("", c);
				case TEnumDecl(e): Printer.sTenum("", e);
				case TTypeDecl(t): Printer.sTdef("", t);
				case TAbstractDecl(a): Printer.sTabstract("", a);
			};
			out.buffer.add(text);
			out.close();
		}
		Parallel.runWithPool(com.sctx.pool, function(pool) {
			ParallelArray.iter(pool, emit, com.types.copy());
			return null;
		});
	}

	public static function dumpPosition(com:CommonContext):Void {
		function emit(mt:ModuleType):Void switch mt {
			case TClassDecl(c):
				var out = createDumpfileFromPath(com, tPath(mt));
				out.buffer.add(sTypePath(c.clPath) + "\n");
				inline function field(cf:TClassField):Void {
					out.buffer.add("\t" + cf.cfName + "\n");
					if (cf.cfExpr != null) out.buffer.add(core.Texpr.dumpWithPos("\t", cf.cfExpr) + "\n");
				}
				if (c.clConstructor != null) field(c.clConstructor);
				for (cf in c.clStatics) field(cf);
				for (cf in c.clFields) field(cf);
				out.close();
			case _:
		};
		Parallel.runWithPool(com.sctx.pool, function(pool) {
			ParallelArray.iter(pool, emit, com.types.copy());
			return null;
		});
	}

	public static function dumpTypes(com:CommonContext):Void switch com.partScope.dumpConfig.dumpMode {
		case NoDump:
		case Pretty:
			dumpTypesFormatted(com, true);
		case Record:
			dumpRecord(com);
		case Position:
			dumpPosition(com);
		case Ast:
			dumpTypesFormatted(com, false);
	};

	public static function dumpDependencies(com:CommonContext, ?targetOverride:String):Void {
		var target = targetOverride == null ? Common.platformNameMacro(com) : targetOverride;
		var out = createDumpfile([], [com.partScope.dumpConfig.dumpPath, target, "dependencies"]);
		var deps = new core.ds.OcamlHashtbl<String, Array<ModuleDef>>(core.ds.OcamlHash.hashString, (a, b) -> a == b, 0);
		for (m in com.modules) {
			out.buffer.add(Path.UniqueKey.lazyPath(m.mExtra.mFile) + ":\n");
			var keys = [for (key in m.mExtra.mDeps.keys()) key];
			keys.sort(function(a, b) return a - b);
			for (key in keys) {
				var dep = m.mExtra.mDeps.get(key), ctx = com, prefix = "";
				if (dep.mdKind == MMacro && !com.isMacroContext) {
					ctx = com.getMacros();
					if (ctx == null) throw "Invalid_argument: option is None";
					prefix = "[macro] ";
				}
				var extra = try ctx.moduleLut.find(dep.mdPath).mExtra catch (e:Dynamic) {
					if (e != "Not_found") throw e;
					ctx.cs.getContext(dep.mdSign).findModuleExtra(dep.mdPath);
				};
				var file = Path.UniqueKey.lazyPath(extra.mFile);
				out.buffer.add("\t" + prefix + file + "\n");
				var l = deps.findOpt(file);
				deps.replace(file, [m].concat(l == null ? [] : l));
			}
		}
		out.close();
		var out = createDumpfile([], [com.partScope.dumpConfig.dumpPath, target, "dependants"]);
		deps.iter(function(n, ml) {
			out.buffer.add(n + ":\n");
			for (m in ml) out.buffer.add("\t" + Path.UniqueKey.lazyPath(m.mExtra.mFile) + "\n");
		});
		out.close();
	}

	public static function maybeGenerateDump(com:CommonContext, stage:DumpStage):Void {
		if (com.partScope.dumpConfig.dumpMode != NoDump
			&& com.partScope.dumpConfig.dumpStage == stage) core.Timer.time(com.timerCtx, ["generate", "dump"], function(_:Null<Bool>) {
				dumpTypes(com);
				var macros = com.getMacros();
				if (macros != null) dumpTypes(macros);
			}, null);
	}
}
