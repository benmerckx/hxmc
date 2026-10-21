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

package codegen;

import core.Ast;
import core.Ast as AstOps;
import core.AstPrinter;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Meta.MetaNotFound;
import haxe.ds.StringMap;

using core.ds.VectorTools;

private typedef Attribute = {name:String, value:String};

private enum RttiXml {
	Node(name:String, attributes:Array<Attribute>, children:Array<RttiXml>);
	PCData(value:String);
	CData(value:String);
}

class Genxml {
	static function attr(name:String, value:String):Attribute return {name: name, value: value};

	static function node(name:String, attributes:Array<Attribute>, children:Array<RttiXml>):RttiXml return Node(name, attributes, children);

	static function tag(name:String):RttiXml return Node(name, [], []);

	static function genPath(p:GlobalTypePath, priv:Bool):Attribute return attr("path", p.pack.concat([p.name]).join("."));

	static function genString(s:String):RttiXml return s.indexOf("<") >= 0
		|| s.indexOf(">") >= 0
		|| s.indexOf("&") >= 0 ? CData(s) : PCData(s);

	// port: ExtString.String.strip with its default characters " \t\r\n"
	static function strip(s:String):String {
		inline function isStrip(c:Int):Bool return c == " ".code || c == "\t".code || c == "\r".code || c == "\n".code;
		var start = 0, end = s.length;
		while (start < end && isStrip(StringTools.fastCodeAt(s, start))) start++;
		while (end > start && isStrip(StringTools.fastCodeAt(s, end - 1))) end--;
		return s.substring(start, end);
	}

	static function genDoc(s:String):RttiXml {
		// remove trailing space and convert newlines
		s = strip(s);
		s = s.split("\r\n").join("\n").split("\r").join("\n");
		return node("haxe_doc", [], [genString(s)]);
	}

	static function genDocOpt(d:Documentation):Array<RttiXml> return d == null ? [] : [genDoc(AstOps.genDocText(d))];

	static function realPath(path:GlobalTypePath, meta:Metadata):GlobalTypePath {
		for (m in meta) if (m.meta == Meta.RealPath) switch m.exprs {
			case [{expr: EConst(String(s, _))}]:
				return AstOps.parsePath(s);
			case _:
		}
		return path;
	}

	static function tpath(t:ModuleType):GlobalTypePath {
		var i = tInfos(t);
		return realPath(i.mtPath, i.mtMeta);
	}

	static function followParam(t:T):T return switch followLazy(t) {
		case TMono(m): m.tmType == null ? t : followParam(m.tmType);
		case TAbstract({aPath: {pack: [], name: "Null"}}, [inner]): followParam(inner);
		case _: t;
	}

	static function genMeta(meta:Metadata):Array<RttiXml> {
		var filtered = meta.filter(m -> switch m.meta {
			case core.MetaList.StrictMeta.Used | core.MetaList.StrictMeta.RealPath | core.MetaList.StrictMeta.Pure | core.MetaList.StrictMeta.HxbId: false;
			case _: true;
		});
		return filtered.length == 0 ? [] : [
			node("meta", [],
				filtered.map(m -> node("m", [attr("n", Meta.toString(m.meta))],
					m.exprs.mapToArray(e -> node("e", [], [genString(AstPrinter.sExpr(e))])))))
		];
	}

	static function genType(t:T, ?values:StringMap<Expr>):RttiXml return switch t {
		case TMono(m): m.tmType == null ? tag("unknown") : genType(m.tmType);
		case TEnum(e, pl): genTypeRef("e", TEnumDecl(e), pl);
		case TInst(c, pl): genTypeRef("c", TClassDecl(c), pl);
		case TAbstract(a, pl): genTypeRef("x", TAbstractDecl(a), pl);
		case TType(d, pl): genTypeRef("t", TTypeDecl(d), pl);
		case TFun(sig):
			var attributes = [attr("a", sig.args.map(a -> (a.optional ? "?" : "") + a.name).join(":"))];
			if (values != null) {
				var any = false;
				var texts = sig.args.map(function(a) {
					var e = values.get(a.name);
					if (e == null) return "";
					any = true;
					return AstPrinter.sExpr(e);
				});
				if (any) attributes.push(attr("v", texts.join(":")));
			}
			node("f", attributes, sig.args.mapToArray(a -> genType(a.optional ? followParam(a.type) : a.type)).concat([genType(sig.ret)]));
		case TAnon(a):
			var names = [for (name in a.aFields.keys()) name];
			names.sort(core.ds.Key.compareStrings);
			var children = [];
			for (name in names) {
				var cf = core.ds.Record.copy(a.aFields.get(name));
				removeClassFieldFlag(cf, CfPublic);
				children.unshift(genField([], cf));
			}
			node("a", [], children);
		case TDynamic(null): node("d", [], []);
		case TDynamic(inner): node("d", [], [genType(inner)]);
		case TLazy(l): genType(lazyType(l));
	}

	static function genTypeRef(name:String, t:ModuleType,
			params:TParams):RttiXml return node(name, [genPath(tpath(t), tPrivate(t))], params.mapToArray(t -> genType(t)));

	static function genField(attributes:Array<Attribute>, f:TClassField):RttiXml {
		inline function addGetSet(access:VarAccess, name:String, attrs:Array<Attribute>):Array<Attribute> return switch access {
			case AccNormal | AccRequire(_, _) | AccCtor: attrs;
			case AccNo | AccNever: [attr(name, "null")].concat(attrs);
			case AccCall | AccPrivateCall: [attr(name, "accessor")].concat(attrs);
			case AccInline: [attr(name, "inline")].concat(attrs);
		}
		if (f.cfExpr != null) attributes = [attr("line", Std.string(syntax.Lexer.getErrorLine(f.cfExpr.epos)))].concat(attributes);
		var values:StringMap<Expr> = new StringMap();
		switch f.cfKind {
			case Var(v):
				try {
					var m = Meta.get(Meta.Value, f.cfMeta);
					if (m.exprs.length == 1) attributes = [attr("expr", AstPrinter.sExpr(m.exprs[0]))].concat(attributes);
				} catch (_:MetaNotFound) {}
				attributes = addGetSet(v.vRead, "get", addGetSet(v.vWrite, "set", attributes));
			case Method(method):
				attributes = switch method {
					case MethNormal | MethMacro: [attr("set", "method")].concat(attributes);
					case MethDynamic: [attr("set", "dynamic")].concat(attributes);
					case MethInline: [attr("get", "inline"), attr("set", "null")].concat(attributes);
				};
				values = AstOps.getValueMeta(f.cfMeta);
		}
		if (f.cfParams.length > 0) attributes = [attr("params", f.cfParams.map(extractParamName).join(":"))].concat(attributes);
		var overloaded = f.cfOverloads.map(f -> genField([], f));
		var children = overloaded.length == 0 ? [] : [node("overloads", [], overloaded)];
		var name = f.cfName;
		try {
			var m = Meta.get(Meta.RealPath, f.cfMeta);
			switch m.exprs {
				case [{expr: EConst(String(s, _))}]:
					name = s;
				case _:
			}
		} catch (_:MetaNotFound) {}
		if (hasClassFieldFlag(f, CfPublic)) attributes = [attr("public", "1")].concat(attributes);
		if (hasClassFieldFlag(f, CfFinal)) attributes = [attr("final", "1")].concat(attributes);
		if (hasClassFieldFlag(f, CfAbstract)) attributes = [attr("abstract", "1")].concat(attributes);
		return node(name, attributes, [genType(f.cfType, values)].concat(genMeta(f.cfMeta)).concat(genDocOpt(f.cfDoc)).concat(children));
	}

	static function genConstr(e:TEnumField):RttiXml {
		var doc = genDocOpt(e.efDoc), attributes:Array<Attribute> = [], children = doc;
		switch follow(e.efType) {
			case TFun(sig):
				attributes = [attr("a", sig.args.map(a -> (a.optional ? "?" : "") + a.name).join(":"))];
				children = sig.args.mapToArray(a -> genType(a.optional ? followParam(a.type) : a.type)).concat(doc);
			case _:
		}
		return node(e.efName, attributes, children.concat(genMeta(e.efMeta)));
	}

	static function genTypeParams(includePos:Bool, priv:Bool, path:GlobalTypePath, params:TypeParams, pos:Pos,
			m:ModuleDef):Array<Attribute> {
		var result = [genPath(path, priv), attr("params", params.map(extractParamName).join(":"))];
		if (includePos && (pos.pfile != Globals.nullPos.pfile || pos.pmin != Globals.nullPos.pmin || pos.pmax != Globals.nullPos.pmax))
			result.push(attr("file", pos.pfile));
		if (priv) result.push(attr("private", "1"));
		if (Globals.sTypePath(m.mPath) != Globals.sTypePath(path)) result.push(attr("module", genPath(m.mPath, false).value));
		return result;
	}

	static function genClassPath(name:String,
			ct:{cls:TClass, params:TParams}):RttiXml return node(name, [attr("path", Globals.sTypePath(tpath(TClassDecl(ct.cls))))],
			ct.params.mapToArray(t -> genType(t)));

	static function fieldExists(f:TClassField,
			c:TClass):Bool return c.clFields.exists(f.cfName) || c.clSuper != null && fieldExists(f, c.clSuper.cls);

	static function genTypeDecl(includePos:Bool, t:ModuleType):RttiXml {
		var m = tModule(t);
		return switch t {
			case TClassDecl(c):
				function visible(cf:TClassField):Bool return !Meta.has(Meta.GenericInstance, cf.cfMeta)
					&& !Meta.has(Meta.NoDoc, cf.cfMeta);
				var statics = c.clOrderedStatics.filter(cf -> cf.cfName != "__meta__" && visible(cf))
					.map(cf -> genField([attr("static", "1")], cf));
				var fields = c.clOrderedFields.filter(visible)
					.map(cf -> genField(c.clSuper != null && fieldExists(cf, c.clSuper.cls) ? [attr("override", "1")] : [], cf));
				var ctor = c.clConstructor == null ? [] : [genField([], c.clConstructor)];
				var tree = c.clImplements.map(ct -> genClassPath(hasClassFlag(c, CInterface) ? "extends" : "implements", ct));
				if (c.clSuper != null) tree.unshift(genClassPath("extends", c.clSuper));
				var attrs = genTypeParams(includePos, c.clPrivate, tpath(t), c.clParams, c.clPos, m);
				if (hasClassFlag(c, CExtern)) attrs.push(attr("extern", "1"));
				if (hasClassFlag(c, CInterface)) attrs.push(attr("interface", "1"));
				if (hasClassFlag(c, CFinal)) attrs.push(attr("final", "1"));
				if (hasClassFlag(c, CAbstract)) attrs.push(attr("abstract", "1"));
				node("class", attrs, tree.concat(statics).concat(fields).concat(ctor).concat(genDocOpt(c.clDoc)).concat(genMeta(c.clMeta)));
			case TEnumDecl(e): node("enum", genTypeParams(includePos, e.ePrivate, tpath(t), e.eParams, e.ePos, m),
					e.eNames.map(name -> genConstr(core.ds.PMap.find(name, e.eConstrs)))
						.concat(genDocOpt(e.eDoc))
						.concat(genMeta(e.eMeta)));
			case TTypeDecl(d): node("typedef", genTypeParams(includePos, d.tPrivate, d.tPath, d.tParams, d.tPos, m),
					[genType(d.tType)].concat(genDocOpt(d.tDoc)).concat(genMeta(d.tMeta)));
			case TAbstractDecl(a):
				inline function casts(name:String, types:Array<T>, fields:Array<{type:T, field:TClassField}>):Array<RttiXml> {
					if (types.length == 0 && fields.length == 0) return [];
					var children = types.map(t -> node("icast", [], [genType(t)]));
					for (f in fields) if (!Meta.has(Meta.NoDoc,
						f.field.cfMeta)) children.push(node("icast", [attr("field", f.field.cfName)], [genType(f.type)]));
					return [node(name, [], children)];
				}
				var impl = a.aImpl == null ? [] : [node("impl", [], [genTypeDecl(includePos, TClassDecl(a.aImpl))])];
				node("abstract", genTypeParams(includePos, a.aPrivate, tpath(t), a.aParams, a.aPos, m),
					casts("from", a.aFrom,
						a.aFromField).concat([node("this", [], [genType(a.aThis)])])
						.concat(casts("to", a.aTo, a.aToField))
						.concat(genDocOpt(a.aDoc))
						.concat(genMeta(a.aMeta))
						.concat(impl));
		}
	}

	// port: XML-Light's `Xml.to_string (Xml.PCData s)`, including its preservation of numeric entities.
	static function escapeEntities(value:String):String {
		var out = new StringBuf();
		for (i in 0...value.length) out.add(switch value.charAt(i) {
			case ">": "&gt;";
			case "<": "&lt;";
			case "&": value.charAt(i + 1) == "#" ? "&" : "&amp;";
			case "'": "&apos;";
			case "\"": "&quot;";
			case c: c;
		});
		return out.toString();
	}

	static function attString(attributes:Array<Attribute>):String return attributes.map(a -> " "
		+ a.name
		+ "=\""
		+ escapeEntities(a.value)
		+ "\"")
		.join("");

	static function writeXml(out:StringBuf, tabs:String, x:RttiXml):Void switch x {
		case Node(name, attrs, []):
			out.add(tabs + "<" + name + attString(attrs) + "/>");
		case Node(name, attrs, [child]):
			out.add(tabs + "<" + name + attString(attrs) + ">");
			writeXml(out, "", child);
			out.add("</" + name + ">");
		case Node(name, attrs, children):
			out.add(tabs + "<" + name + attString(attrs) + ">\n");
			for (child in children) {
				writeXml(out, tabs + "\t", child);
				out.add("\n");
			}
			out.add(tabs + "</" + name + ">");
		case PCData(s):
			out.add(s);
		case CData(s):
			out.add("<![CDATA[" + s + "]]>");
	}

	public static function generate(com:context.Common.CommonContext, file:String):Void {
		function f(_:Null<Bool>):RttiXml {
			return node("haxe", [], com.types.filter(t -> !Meta.has(Meta.NoDoc, tInfos(t).mtMeta)).map(t -> genTypeDecl(true, t)));
		}
		var x = core.Timer.time(com.timerCtx, ["generate", "xml"], f, null);

		function f2(_:Null<Bool>):Null<Bool> {
			var out = new StringBuf();
			out.add("<!-- This file can be parsed by haxe.rtti.XmlParser -->\n");
			writeXml(out, "", x);
			var ch = sys.io.File.write(file, true);
			ch.writeString(out.toString());
			ch.close();
			return null;
		}
		core.Timer.time(com.timerCtx, ["write", "xml"], f2, null);
	}

	public static function genTypeString(t:ModuleType):String {
		var out = new StringBuf();
		writeXml(out, "", genTypeDecl(false, t));
		return out.toString();
	}
}
