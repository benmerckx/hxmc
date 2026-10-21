/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package generators;

import core.Ast;
import core.Ast as AstOps;
import core.AstPrinter;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Meta.MetaNotFound;
import context.Common.CommonContext;

using core.ds.VectorTools;

private typedef SParam = {name:String, value:Null<Constant>, type:T};

class Genhxold {
	static function createDir(acc:String, l:Array<String>):Void {
		if (l.length == 0) return;
		var path = acc + "/" + l[0];
		// port: Unix.mkdir with every error ignored
		try sys.FileSystem.createDirectory(path) catch (_:Dynamic) {}
		createDir(path, l.slice(1));
	}

	static function convPath(p:GlobalTypePath):GlobalTypePath {
		var pack = p.pack;
		if (pack.length > 0 && Globals.startsWith(pack[pack.length - 1], "_"))
			return {pack: pack.slice(0, pack.length - 1).concat(["priv" + pack[pack.length - 1]]), name: p.name};
		return p;
	}

	static function getRealPath(meta:Metadata, path:GlobalTypePath):GlobalTypePath {
		try {
			var realPath = switch Meta.get(Meta.RealPath, meta).exprs {
				case [{expr: EConst(String(s, _))}]:
					s;
				case _:
					throw MetaNotFound.raise();
			}
			// port: ExtString.String.nsplit never yields an empty list for a non-empty separator
			var parts = realPath.split(".");
			var name = parts.pop();
			return {pack: parts, name: name};
		} catch (_:MetaNotFound) {
			return path;
		}
	}

	static function samePack(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	static function generateType(com:CommonContext, t:ModuleType):Void {
		var basePath = "hxclasses";
		switch t {
			case TClassDecl({clKind: KAbstractImpl(_)}): return;
			case _:
		}
		var info = tInfos(t);
		var rp = getRealPath(info.mtMeta, info.mtPath);
		var pack = rp.pack, name = rp.name;
		createDir(".", [basePath].concat(pack));
		switch [pack, name] {
			case [["flash", "net"], "NetStreamPlayTransitions"]
				| [["flash", "filters"], "BitmapFilterQuality"]
				| [["flash", "display"], "BitmapDataChannel" | "GraphicsPathCommand"]:
				return;
			case _:
		}
		var file = basePath + "/" + (pack.length == 0 ? "" : pack.join("/") + "/") + name + ".hx";
		var ch = new StringBuf();
		inline function p(s:String) ch.add(s);
		if (pack.length > 0) p("package " + pack.join(".") + ";\n\n");
		function notnull(t:T):T return switch t {
			case TMono(r):
				r.tmType == null ? t : notnull(r.tmType);
			case TLazy(f):
				notnull(lazyType(f));
			case TAbstract({aPath: {pack: [], name: "Null"}}, [t]):
				t;
			case _:
				t;
		}
		var stype:T->String = null, ftype:T->String = null;
		function path(meta:Metadata, p:GlobalTypePath, tl:TParams):String {
			var p = convPath(getRealPath(meta, p));
			return (samePack(p.pack, pack) ? p.name : Globals.sTypePath(p))
				+ (tl.length == 0 ? "" : "<" + tl.map(stype).join(",") + ">");
		}
		stype = function(t:T):String return switch t {
			case TMono(r):
				r.tmType == null ? "Unknown" : stype(r.tmType);
			case TInst(c = {clKind: KTypeParameter(_)}, tl):
				path([], {pack: [], name: c.clPath.name}, tl);
			case TInst(c, tl):
				path(c.clMeta, c.clPath, tl);
			case TEnum(e, tl):
				path(e.eMeta, e.ePath, tl);
			case TType(t, tl):
				path(t.tMeta, t.tPath, tl);
			case TAbstract(a, tl):
				path(a.aMeta, a.aPath, tl);
			case TAnon(a):
				var fields = core.ds.PMap.fold(function(f:TClassField, acc:Array<String>) {
					acc.unshift(f.cfName + " : " + stype(f.cfType));
					return acc;
				}, a.aFields, []);
				"{" + fields.join(", ") + "}";
			case TLazy(f):
				stype(lazyType(f));
			case TDynamic(null):
				"Dynamic";
			case TDynamic(t2):
				"Dynamic<" + stype(t2) + ">";
			case TFun({args: [], ret: ret}):
				"() -> " + ftype(ret);
			case TFun({args: args, ret: ret}):
				args.map(a -> ftype(a.type)).join(" -> ") + " -> " + ftype(ret);
		}
		ftype = function(t:T):String return switch t {
			case TMono(r):
				r.tmType == null ? stype(t) : ftype(r.tmType);
			case TLazy(f):
				ftype(lazyType(f));
			case TFun(_):
				"(" + stype(t) + ")";
			case _:
				stype(t);
		}
		function sparam(sp:SParam):String {
			var n = sp.name, t = sp.type;
			return switch sp.value {
				case null:
					n + " : " + stype(t);
				case Ident("null"):
					if (isNullable(notnull(t)))
						"?" + n + " : " + stype(notnull(t));
					else
						/* we have not found a default value stored in metadata, let's generate it */
						n + " : " + stype(t) + " = " + (switch follow(t) {
							case TAbstract({aPath: {pack: [], name: "Int" | "Float" | "UInt"}}, _)
								| TAbstract({aPath: {pack: ["haxe"], name: "UInt32"}}, _): "0";
							case TAbstract({aPath: {pack: [], name: "Bool"}}, _): "false";
							case _: "null";
						});
				case v:
					n + " : " + stype(t) + " = " + (switch AstOps.sConstant(v) {
						case "nan": "0./*NaN*/";
						case v: v;
					});
			}
		}
		function printMeta(ml:Metadata):Void {
			for (m in ml) {
				if (Meta.metaEq(Meta.DefParam, m.meta) || Meta.metaEq(Meta.CoreApi, m.meta) || Meta.metaEq(Meta.Used, m.meta)
					|| Meta.metaEq(Meta.FlatEnum, m.meta) || Meta.metaEq(Meta.Value, m.meta) || Meta.metaEq(Meta.DirectlyUsed, m.meta)
					|| Meta.metaEq(Meta.Enum, m.meta)) continue;
				if (m.exprs.length == 0)
					p("@" + Meta.toString(m.meta) + " ");
				else
					p("@" + Meta.toString(m.meta) + "(" + m.exprs.map(AstPrinter.sExpr).join(",") + ") ");
			}
		}
		function access(isRead:Bool, a:VarAccess):String return core.TPrinting.sAccess(isRead, a);
		function printField(stat:Bool, f:TClassField):Void {
			p("\t");
			printMeta(f.cfMeta);
			if (!hasClassFieldFlag(f, CfPublic)) p("private ");
			if (stat) p("static ");
			var name = try (switch Meta.get(Meta.RealPath, f.cfMeta).exprs {
				case [{expr: EConst(String(s, _))}]:
					s;
				case _:
					throw MetaNotFound.raise();
			}) catch (_:MetaNotFound) f.cfName;
			switch f.cfKind {
				case Var(v):
					if (hasClassFieldFlag(f, CfFinal))
						p("final " + name);
					else {
						p("var " + name);
						if (v.vRead != AccNormal || v.vWrite != AccNormal) p("(" + access(true, v.vRead) + "," + access(false, v.vWrite) + ")");
					}
					p(" : " + stype(f.cfType));
				case Method(_):
					var params:Array<SParam>, ret:T;
					switch follow(f.cfType) {
						case TFun(sig):
							params = sig.args.mapToArray(function(arg):SParam {
								var a = arg.name;
								function loop(l:Metadata, i:Int):Constant {
									if (i >= l.length) return Ident("null");
									var m = l[i];
									if (Meta.metaEq(Meta.DefParam, m.meta)) switch m.exprs {
										case [{expr: EConst(String(pn, _))}, {expr: EConst(v)}] if (pn == a):
											return switch v {
												case Float("1.#QNAN", _): Float("0./*NaN*/", null);
												case Float("4294967295.", _): Int("0xFFFFFFFF", null);
												case Int("16777215", _): Int("0xFFFFFF", null);
												case Float(x, _):
													try {
														var f = core.ds.OcamlFloat.ofString(x);
														// port: OCaml int_of_float/string_of_int; out-of-range values cannot
														// ...produce `s ^ "."` equal to a decimal literal of that value
														var s = haxe.Int64.toStr(haxe.Int64.fromFloat(f));
														if (s + "." == x) Int(s, null) else v;
													} catch (_:Dynamic) {
														v;
													}
												case _: v;
											};
										case _:
									}
									return loop(l, i + 1);
								}
								return {name: a, value: arg.optional ? loop(f.cfMeta, 0) : null, type: arg.type};
							});
							ret = sig.ret;
						case _:
							throw Globals.die("", "genhxold.ml");
					}
					var tparams = f.cfParams.length == 0 ? "" : "<" + f.cfParams.map(extractParamName).join(",") + ">";
					p("function " + name + tparams + "(" + params.map(sparam).join(", ") + ") : " + stype(ret));
			}
			p(";\n");
			if (hasClassFieldFlag(f, CfOverload)) for (f in f.cfOverloads) printField(stat, f);
		}
		switch t {
			case TClassDecl(c):
				printMeta(c.clMeta);
				var finalmod = hasClassFlag(c, CFinal) ? "final " : "";
				p("extern " + finalmod + (hasClassFlag(c, CInterface) ? "interface" : "class") + " "
					+ stype(TInst(c, extractParamTypes(c.clParams))));
				var ext = switch c.clSuper {
					case null: [];
					case sup: [" extends " + stype(TInst(sup.cls, sup.params))];
				};
				for (i in c.clImplements)
					ext.unshift((hasClassFlag(c, CInterface) ? " extends " : " implements ") + stype(TInst(i.cls, i.params)));
				switch c.clDynamic {
					case null:
					case t:
						switch c.clPath {
							case {pack: ["flash", "errors"]}:
							case _ if (t == tDynamic): ext.unshift(" implements Dynamic");
							case _: ext.unshift(" implements Dynamic<" + stype(t) + ">");
						}
				}
				ext = switch c.clPath {
					case {pack: ["flash", "utils"], name: "ByteArray"}: [" implements ArrayAccess<Int>"].concat(ext);
					case {pack: ["flash", "utils"], name: "Dictionary"}: [" implements ArrayAccess<Dynamic>"];
					case {pack: ["flash", "xml"], name: "XML"}: [" implements Dynamic<XMLList>"];
					case {pack: ["flash", "xml"], name: "XMLList"}: [" implements ArrayAccess<XML>"];
					case {pack: ["flash", "display"], name: "MovieClip"}: [" extends Sprite #if !flash_strict implements Dynamic #end"];
					case {pack: ["flash", "errors"], name: "Error"}: [" #if !flash_strict implements Dynamic #end"];
					case _: ext;
				};
				ext.reverse();
				p(ext.join(""));
				p(" {\n");
				function sort(l:Array<TClassField>):Array<TClassField> {
					var a = l.filter(f -> !hasClassFieldFlag(f, CfOverride));
					function name(n:String):String return n == "new" ? "" : n;
					// port: OCaml's Array.sort (heap sort); native renames can make names equal
					Hlcode.ocamlArraySort(function(f1:TClassField, f2:TClassField):Int return switch [f1.cfKind, f2.cfKind] {
						case [Var(_), Var(_)] | [Method(_), Method(_)]: core.ds.Key.compareStrings(name(f1.cfName), name(f2.cfName));
						case [Var(_), _]: -1;
						case _: 1;
					}, a);
					return a;
				}
				for (f in sort(c.clConstructor == null ? c.clOrderedFields : [c.clConstructor].concat(c.clOrderedFields))) printField(false, f);
				for (f in sort(c.clOrderedStatics)) printField(true, f);
				p("}\n");
			case TEnumDecl(e):
				printMeta(e.eMeta);
				p("extern enum " + stype(TEnum(e, extractParamTypes(e.eParams))) + " {\n");
				for (n in e.eNames) {
					var c = core.ds.PMap.find(n, e.eConstrs);
					p("\t" + c.efName);
					switch follow(c.efType) {
						case TFun(sig):
							p("(" + sig.args.map(a -> sparam({name: a.name, value: a.optional ? Ident("null") : null, type: a.type})).join(", ") + ")");
						case _:
					}
					p(";\n");
				}
				p("}\n");
			case TTypeDecl(t):
				printMeta(t.tMeta);
				p("typedef " + stype(TType(t, extractParamTypes(t.tParams))) + " = ");
				p(stype(t.tType));
				p("\n");
			case TAbstractDecl(a):
				printMeta(a.aMeta);
				if (a.aImpl != null) try printMeta([Meta.get(Meta.Require, a.aImpl.clMeta)]) catch (_:MetaNotFound) {};
				p("extern ");
				var isEnum = a.aEnum;
				if (isEnum) p("enum ");
				p("abstract " + stype(TAbstract(a, extractParamTypes(a.aParams))));
				if (!Meta.has(Meta.CoreType, a.aMeta)) p("(" + stype(a.aThis) + ")");
				p(" {\n");
				if (a.aImpl != null) {
					var c = a.aImpl;
					var fields = c.clOrderedStatics;
					if (isEnum) {
						fields = fields.copy();
						Hlcode.ocamlArraySort((a:TClassField, b:TClassField) -> core.ds.Key.compareStrings(a.cfName, b.cfName), fields);
					}
					for (f in fields) {
						var isStatic = !hasClassFieldFlag(f, CfImpl);
						if (!isStatic && isEnum && hasClassFieldFlag(f, CfEnum)) {
							p("\tvar " + f.cfName + ";\n");
						} else
							printField(isStatic, f);
					}
				}
				p("}\n");
		}
		var out = sys.io.File.write(file, true);
		out.writeString(ch.toString());
		out.close();
	}

	public static function generate(com:CommonContext):Void {
		for (t in com.types) generateType(com, t);
	}
}
