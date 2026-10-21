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

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.ds.Failure;
import core.ds.NotFound;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import context.Common;
import context.NativeLibraries;
import libs.extlib.IO;
import libs.swflib.Swf;
import libs.swflib.As3;
import libs.swflib.As3hl;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

private typedef MetaTag = core.MetaList.StrictMeta;

// port: the `(name, stat)` keys of build_class's getter/setter/override tables.
private typedef NameStat = {name:String, stat:Bool};

// port: a `(Meta.strict_meta * constant list)` element of build_class's `meta` ref.
private typedef PendingMeta = {m:MetaTag, cl:Array<Constant>};

class SwfLoader {
	static function lowercase_pack(pack:Array<String>):Array<String> {
		var acc = [];
		for (name in pack) {
			var name = {
				// port: String.get raises Invalid_argument on an empty name.
				if (name.length == 0) throw new core.ds.InvalidArgument("index out of bounds");
				var fchar = name.charCodeAt(0);
				if (fchar >= 'A'.code && fchar <= 'Z'.code)
					std.String.fromCharCode(fchar + 32) + name.substr(1, name.length - 1)
				else
					name;
			};
			acc.push(name);
		}
		return acc;
	}

	static final tp_dyn:PlacedTypePath = core.Ast.Ast.makePtp({
		tpackage: [],
		tname: "Dynamic",
		tparams: vector(),
		tsub: null
	}, nullPos);

	static final ct_dyn:ComplexType = CTPath(tp_dyn);

	static final ct_rest:ComplexType = core.Ast.Ast.makePtpCt({
		tpackage: ["haxe"],
		tname: "Rest",
		tparams: vector(TPType({type: ct_dyn, pos: nullPos})),
		tsub: null,
	}, nullPos);

	// port: ExtString.String.nsplit; an empty string has no parts.
	static function nsplit(s:String, sep:String):Array<String> return s == "" ? [] : s.split(sep);

	static function make_tpath(x:HlName):PlacedTypePath {
		var path:TypePath = switch x {
			case HMPath(pack, name):
				var pdyn = false;
				var pn = switch [pack, name] {
					case [[], "void"]: {pack: [], name: "Void"};
					case [[], "int"]: {pack: [], name: "Int"};
					case [[], "uint"]: {pack: ["haxe"], name: "UInt32"};
					case [[], "Number"]: {pack: [], name: "Float"};
					case [[], "Boolean"]: {pack: [], name: "Bool"};
					case [[], "Object"]: {pack: ["flash", "utils"], name: "Object"};
					case [[], "Function"]: {pack: ["flash", "utils"], name: "Function"};
					case [[], "Class"] | [[], "Array"]:
						pdyn = true;
						{pack: pack, name: name};
					case [[], "Error"]: {pack: ["flash", "errors"], name: "Error"};
					case [[], "XML"]: {pack: ["flash", "xml"], name: "XML"};
					case [[], "XMLList"]: {pack: ["flash", "xml"], name: "XMLList"};
					case [[], "QName"]: {pack: ["flash", "utils"], name: "QName"};
					case [[], "Namespace"]: {pack: ["flash", "utils"], name: "Namespace"};
					case [[], "RegExp"]: {pack: ["flash", "utils"], name: "RegExp"};
					case [["__AS3__", "vec"], "Vector"]:
						pdyn = true;
						{pack: ["flash"], name: "Vector"};
					case _: {pack: lowercase_pack(pack), name: name};
				}
				{
					tpackage: pn.pack,
					tname: pn.name,
					tparams: if (pdyn) vector(TPType({type: ct_dyn, pos: nullPos})) else vector(),
					tsub: null,
				};
			case HMName(id, ns):
				{
					tpackage: (switch ns {
						case HNInternal(ns) if (ns != null):
							nsplit(ns, ".");
						case HNPrivate(ns) if (ns != null):
							// port: ExtString.String.split raises Invalid_string when ".as$" is absent.
							switch ns.indexOf(".as$") {
								case -1: [];
								case i: [ns.substr(0, i) + "_" + ns.substr(i + 4)];
							}
						case _:
							[];
					}),
					tname: id,
					tparams: vector(),
					tsub: null,
				};
			case HMNSAny(id):
				{
					tpackage: [],
					tname: id,
					tparams: vector(),
					tsub: null,
				};
			case HMMultiName(_):
				die("", "codegen/swfLoader.ml");
			case HMRuntimeName(_):
				die("", "codegen/swfLoader.ml");
			case HMRuntimeNameLate:
				die("", "codegen/swfLoader.ml");
			case HMMultiNameLate(_):
				die("", "codegen/swfLoader.ml");
			case HMAttrib(_):
				die("", "codegen/swfLoader.ml");
			case HMAny:
				die("", "codegen/swfLoader.ml");
			case HMParams(t, params):
				var params = [for (t in params) TPType({type: CTPath(make_tpath(t)), pos: nullPos})];
				var ptp = make_tpath(t);
				{
					tpackage: ptp.path.tpackage,
					tname: ptp.path.tname,
					tparams: Vector.fromArrayCopy(params),
					tsub: ptp.path.tsub
				};
		}
		return core.Ast.Ast.makePtp(path, nullPos);
	}

	static function make_topt(t:Null<HlName>):PlacedTypePath return t == null ? tp_dyn : make_tpath(t);

	static function make_type(t:Null<HlName>):ComplexType return CTPath(make_topt(t));

	static function make_dyn_type(t:Null<HlName>):ComplexType {
		var o = make_topt(t);
		return switch o.path {
			case {tpackage: ["flash", "utils"], tname: "Object" | "Function"}: make_type(null);
			case _: CTPath(o);
		}
	}

	static function is_valid_path(com:CommonContext, pack:Array<String>, name:String):Bool {
		function loop(l:Array<ExternTypeLoader>, i:Int):Bool {
			if (i >= l.length) return false;
			return switch l[i].load({pack: pack, name: name}, nullPos) {
				case null: loop(l, i + 1);
				case _: true;
			}
		}
		var file = pack.join("/") + "/" + name + ".hx";
		return loop(com.loadExternType, 0) || (try {
			Common.findFile(com, file);
			true;
		} catch (_:NotFound) false);
	}

	static function access(a:Access):PlacedAccess return {access: a, pos: nullPos};

	static function hasAccess(l:Array<PlacedAccess>, a:Access):Bool {
		for (x in l) if (x.access == a) return true;
		return false;
	}

	static function hashNameStat(k:NameStat):Int return OcamlHash.hash(OBlock(0, [OString(k.name), OInt(k.stat ? 1 : 0)]));

	static function eqNameStat(a:NameStat, b:NameStat):Bool return a.name == b.name && a.stat == b.stat;

	// port: structural equality (`=`) of an `hl_name option`.
	static function hlNameOptEq(a:Null<HlName>, b:Null<HlName>):Bool {
		if (a == null || b == null) return a == null && b == null;
		return libs.swflib.As3hlparse.nameKey(a) == libs.swflib.As3hlparse.nameKey(b);
	}

	static function posEq(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	// port: structural equality of the metadata entries mk_meta builds (constants only).
	static function metaEntryEq(a:MetadataEntry, b:MetadataEntry):Bool {
		if (a.meta != b.meta || !posEq(a.pos, b.pos) || a.exprs.length != b.exprs.length) return false;
		for (i in 0...a.exprs.length) {
			var e1 = a.exprs[i], e2 = b.exprs[i];
			if (!posEq(e1.pos, e2.pos)) return false;
			switch [e1.expr, e2.expr] {
				case [EConst(c1), EConst(c2)]:
					if (!Type.enumEq(c1, c2)) return false;
				case _:
					return false;
			}
		}
		return true;
	}

	// port: structural equality of the `CTPath` types compared by the enum-abstract
	// detection (paths without type parameters, null positions).
	static function realTypeEq(a:ComplexType, b:ComplexType):Bool {
		return switch [a, b] {
			case [CTPath(p1), CTPath(p2)]:
				p1.path.tpackage.join(".") == p2.path.tpackage.join(".")
				&& p1.path.tpackage.length == p2.path.tpackage.length
				&& p1.path.tname == p2.path.tname
				&& p1.path.tsub == p2.path.tsub
				&& p1.path.tparams.length == 0
				&& p2.path.tparams.length == 0
				&& posEq(p1.posFull, p2.posFull)
				&& posEq(p1.posPath, p2.posPath);
			case _:
				false;
		}
	}

	static function build_class(com:CommonContext, c:HlClass, file:String):Package {
		var path = (make_tpath(c.hlc_name)).path;
		var pos = filePos(file + "@" + sTypePath({pack: path.tpackage, name: path.tname}));
		switch path {
			case {tpackage: ["flash", "utils"], tname: "Object" | "Function"}:
				var inf:TypedefDefinition = {
					name: {name: path.tname, pos: nullPos},
					doc: null,
					params: vector(),
					meta: [],
					flags: vector(),
					data: {type: ct_dyn, pos: nullPos},
				};
				return {pack: path.tpackage, declarations: vector({definition: ETypedef(inf), pos: pos})};
			case _:
		}
		/* make flags */
		var flags:Array<ClassFlag> = [HExtern];
		if (c.hlc_interface) flags.unshift(HInterface);
		switch c.hlc_super {
			case null | HMPath([], "Object"):
			case HMPath([], "Function"): /* found in AIR SDK */
			case s:
				flags.unshift(HExtends(make_tpath(s)));
		}
		var impls = [
			for (i in c.hlc_implements) {
				var i = (switch i {
					case HMMultiName(id, ns) if (id != null):
						function loop(l:Array<HlNamespace>, k:Int):HlName {
							if (k >= l.length) return HMPath([], id);
							return switch l[k] {
								case HNPublic(ns) if (ns != null && is_valid_path(com, nsplit(ns, "."), id)): HMPath(nsplit(ns, "."), id);
								case _: loop(l, k + 1);
							}
						}
						loop(ns, 0);
					case HMPath(_):
						i;
					case _:
						die("", "codegen/swfLoader.ml");
				});
				if (c.hlc_interface) HExtends(make_tpath(i)) else HImplements(make_tpath(i));
			}
		];
		var flags = impls.concat(flags);
		var flags = if (c.hlc_sealed || Common.defined(com, core.Define.FlashStrict)) flags else [HImplements(tp_dyn)].concat(flags);
		/* make fields */
		var getters = new OcamlHashtbl<NameStat, {t:Null<HlName>, meta:Metadata}>(hashNameStat, eqNameStat);
		var setters = new OcamlHashtbl<NameStat, {t:Null<HlName>, meta:Metadata}>(hashNameStat, eqNameStat);
		var override_ = new OcamlHashtbl<NameStat, Bool>(hashNameStat, eqNameStat);
		var is_xml = (switch [path.tpackage, path.tname] {
			case [["flash", "xml"], "XML" | "XMLList"]: true;
			case _: false;
		});
		function make_field(stat:Bool, acc:Array<ClassField>, f:HlField):Array<ClassField> {
			var meta:Array<PendingMeta> = [];
			var flags:Array<PlacedAccess> = (switch f.hlf_name {
				case HMPath(_):
					[access(APublic)];
				case HMName(_, ns):
					switch ns {
						case HNPrivate(_) | HNNamespace("http://www.adobe.com/2006/flex/mx/internal"):
							[];
						case HNNamespace(ns):
							if (!(c.hlc_interface || is_xml)) meta.unshift({m: MetaTag.Ns, cl: [String(ns, SDoubleQuotes)]});
							[access(APublic)];
						case HNInternal(ns) if (ns != null):
							if (!(c.hlc_interface || is_xml)) meta.unshift({m: MetaTag.Ns, cl: [String(ns, SDoubleQuotes), Ident("internal")]});
							[access(APublic)];
						case HNExplicit(_) | HNInternal(_) | HNPublic(_):
							[access(APublic)];
						case HNStaticProtected(_) | HNProtected(_):
							meta.unshift({m: MetaTag.Protected, cl: []});
							[access(APrivate)];
					}
				case _:
					[];
			});
			if (flags.length == 0) return acc;
			var flags = if (stat) [access(AStatic)].concat(flags) else flags;
			var name = (make_tpath(f.hlf_name)).path.tname;
			function mk_meta():Metadata {
				return [
					for (m in meta)
						({meta: m.m, exprs: m.cl.mapToVector(c -> ({expr: EConst(c), pos: pos} : Expr)), pos: pos} : MetadataEntry)
				];
			}
			var cf:ClassField = {
				cffName: {name: name, pos: nullPos},
				cffDoc: null,
				cffPos: pos,
				cffMeta: [],
				cffAccess: flags,
				cffKind: FVar(null, null),
			};
			switch f.hlf_kind {
				case HFVar(v):
					cf.cffMeta = mk_meta();
					cf.cffKind = FVar({type: make_dyn_type(v.hlv_type), pos: nullPos}, null);
					if (v.hlv_const) {
						cf.cffAccess = [access(AFinal)].concat(cf.cffAccess);
					}
					return [cf].concat(acc);
				case HFMethod(m) if (m.hlm_override):
					override_.add({name: name, stat: stat}, true);
					return acc;
				case HFMethod(m):
					switch m.hlm_kind {
						case MK3Normal:
							var t = m.hlm_type;
							var p = 0, pn = 0;
							var make_type = if (stat || name == "new") make_dyn_type else make_type;
							var args:Array<FuncArg> = [
								for (at in t.hlmt_args) {
									var aname = (switch t.hlmt_pnames {
										case null:
											pn++;
											"p" + pn;
										case l:
											// port: List.nth raises past the end (not caught here).
											if (p >= l.length) throw new Failure("nth");
											switch l[p] {
												case null:
													pn++;
													"p" + pn;
												case i:
													i;
											}
									});
									var opt_val = (switch t.hlmt_dparams {
										case null:
											null;
										case l:
											// port: List.nth raises Invalid_argument/Failure outside the list (caught: None).
											var k = p - t.hlmt_args.length + l.length;
											if (k < 0 || k >= l.length) null else {v: l[k]};
									});
									p++;
									var t = make_type(at);
									var is_opt = false;
									var def_val = (switch opt_val {
										case null:
											null;
										case {v: v}:
											var v = (switch v {
												case HVNone | HVNull | HVNamespace(_):
													is_opt = true;
													null;
												case HVString(s):
													is_opt = true;
													String(s, SDoubleQuotes);
												case HVBool(b):
													Ident(if (b) "true" else "false");
												case HVInt(i) | HVUInt(i):
													Int(Std.string(i), null);
												case HVFloat(f):
													Float(core.Numeric.floatRepres(f), null);
											});
											switch v {
												case null:
													null;
												case v:
													/* add for -D gen-hx-classes generation */
													meta.unshift({m: MetaTag.DefParam, cl: [String(aname, SDoubleQuotes), v]});
													({expr: EConst(v), pos: pos} : Expr);
											}
									});
									({
										name: {name: aname, pos: nullPos},
										optional: is_opt,
										meta: [],
										type: {type: t, pos: nullPos},
										expr: def_val
									} : FuncArg);
								}
							];
							var args = if (t.hlmt_var_args) args.concat([
								{
									name: {name: "restArgs", pos: nullPos},
									optional: false,
									meta: [],
									type: {type: ct_rest, pos: nullPos},
									expr: null
								}
							]) else args;
							var f:Func = {
								fParams: vector(),
								fArgs: Vector.fromArrayCopy(args),
								fType: {type: make_type(t.hlmt_ret), pos: nullPos},
								fExpr: null,
							};
							cf.cffMeta = mk_meta();
							cf.cffKind = FFun(f);
							return [cf].concat(acc);
						case MK3Getter:
							getters.add({name: name, stat: stat}, {t: m.hlm_type.hlmt_ret, meta: mk_meta()});
							return acc;
						case MK3Setter:
							setters.add({name: name, stat: stat}, {
								t: (switch m.hlm_type.hlmt_args {
									case [t]: t;
									case _: die("", "codegen/swfLoader.ml");
								}),
								meta: mk_meta()
							});
							return acc;
					}
				case _:
					return acc;
			}
		}
		var fields = if (c.hlc_interface) [] else {
			var mt = c.hlc_construct.copy();
			mt.hlmt_ret = HMPath([], "void");
			make_field(false, [], {
				hlf_name: HMPath([], "new"),
				hlf_slot: 0,
				hlf_metas: null,
				hlf_kind: HFMethod({
					hlm_type: mt,
					hlm_final: false,
					hlm_override: false,
					hlm_kind: MK3Normal
				})
			});
		};
		for (f in c.hlc_fields) fields = make_field(false, fields, f);
		for (f in c.hlc_static_fields) fields = make_field(true, fields, f);
		function make_get_set(name:String, stat:Bool, tget:Null<{t:Null<HlName>, meta:Metadata}>, tset:Null<{t:Null<HlName>, meta:Metadata}>):Array<ClassField> {
			var r = (switch [tget, tset] {
				case [null, null]: die("", "codegen/swfLoader.ml");
				case [g, null]: {get: true, set: false, t: g.t, meta: g.meta};
				case [null, s]: {get: false, set: true, t: s.t, meta: s.meta};
				case [g, s]:
					{
						get: true,
						set: true,
						t: (if (!hlNameOptEq(g.t, s.t)) null else g.t),
						meta: g.meta.concat(s.meta.filter(m -> !Lambda.exists(g.meta, m1 -> metaEntryEq(m, m1))))
					};
			});
			var get = r.get, set = r.set, t = r.t, meta = r.meta;
			var t = if (name == "endian") HMPath(["flash", "utils"], "Endian") else t;
			var flags = [access(APublic)], accessor_flags = [access(APrivate)];
			if (stat) {
				flags = [access(AStatic)].concat(flags);
				accessor_flags = [access(AStatic)].concat(accessor_flags);
			}
			var property_typehint:TypeHint = {type: make_dyn_type(t), pos: nullPos};
			var fields:Array<ClassField> = [];
			var read_access:PlacedName = if (get) {
				var getter:ClassField = {
					cffName: {name: "get_" + name, pos: nullPos},
					cffPos: pos,
					cffDoc: null,
					cffAccess: accessor_flags,
					cffMeta: [],
					cffKind: FFun({
						fParams: vector(),
						fArgs: vector(),
						fType: property_typehint,
						fExpr: null,
					}),
				};
				fields.unshift(getter);
				{name: "get", pos: nullPos};
			} else {name: "never", pos: nullPos};
			var write_access:PlacedName = if (set) {
				var setter:ClassField = {
					cffName: {name: "set_" + name, pos: nullPos},
					cffPos: pos,
					cffDoc: null,
					cffAccess: accessor_flags,
					cffMeta: [],
					cffKind: FFun({
						fParams: vector(),
						fArgs: vector(
							{
								name: {name: "value", pos: nullPos},
								optional: false,
								meta: [],
								type: property_typehint,
								expr: null
							}
						),
						fType: property_typehint,
						fExpr: null,
					}),
				};
				fields.unshift(setter);
				{name: "set", pos: nullPos};
			} else {name: "never", pos: nullPos};
			var prop:ClassField = {
				cffName: {name: name, pos: nullPos},
				cffPos: pos,
				cffDoc: null,
				cffAccess: flags,
				cffMeta: [({meta: MetaTag.FlashProperty, exprs: vector(), pos: pos} : MetadataEntry)].concat(meta),
				cffKind: FProp(read_access, write_access, property_typehint, null),
			};
			return [prop].concat(fields);
		}
		var fields = getters.fold(function(k, t, acc:Array<ClassField>) {
			if (override_.mem(k)) return acc;
			return make_get_set(k.name, k.stat, t, try setters.find(k) catch (_:NotFound) null).concat(acc);
		}, fields);
		var fields = setters.fold(function(k, t, acc:Array<ClassField>) {
			if (getters.mem(k) || override_.mem(k))
				return acc
			else
				return make_get_set(k.name, k.stat, null, t).concat(acc);
		}, fields);
		try {
			/*
				If the class only contains static String constants, make it an enum
			 */
			var real_type:Null<ComplexType> = null;
			function loop(l:Array<ClassField>, i:Int):Array<ClassField> {
				if (i >= l.length) return [];
				var f = l[i];
				// port: the String/Int/haxe.UInt32 `CTPath` of an `FVar (Some (t,_),None)` or a
				// `FProp (("default",_),("never",_),Some (t,_),None)`.
				function constType(th:Null<TypeHint>):Null<ComplexType> {
					if (th == null) return null;
					return switch th.type {
						case CTPath({path: {tpackage: [], tname: "String" | "Int"}}) | CTPath({path: {tpackage: ["haxe"], tname: "UInt32"}}): th.type;
						case _: null;
					}
				}
				var real_t:Null<ComplexType> = switch f.cffKind {
					case FVar(th, null):
						constType(th);
					case FProp(get, set, th, null) if (get.name == "default" && set.name == "never"):
						constType(th);
					case _:
						null;
				}
				if (real_t != null && !hasAccess(f.cffAccess, AStatic)) real_t = null;
				if (real_t != null) {
					switch real_type {
						case null:
							real_type = real_t;
						case t:
							if (!realTypeEq(t, real_t)) throw core.ds.Exit.raise();
					}
					var r:ClassField = {
						cffName: f.cffName,
						cffDoc: null,
						cffPos: pos,
						cffMeta: [],
						cffAccess: [],
						cffKind: FVar({type: real_t, pos: nullPos}, null),
					};
					return [r].concat(loop(l, i + 1));
				}
				return switch f.cffKind {
					case FFun({fArgs: []}) if (f.cffName.name == "new"): loop(l, i + 1);
					case _: throw core.ds.Exit.raise();
				}
			}
			for (f in flags) switch f {
				case HExtends(_) | HImplements(_): throw core.ds.Exit.raise();
				case _:
			}
			var constr = loop(fields, 0);
			var name = "enumAbstract:" + path.tpackage.concat([path.tname]).join(".");
			if (!Common.rawDefined(com, name)) throw core.ds.Exit.raise();
			var native_path = sTypePath({pack: path.tpackage, name: path.tname});
			var real_type:ComplexType = real_type;
			if (real_type == null) throw new Failure("Option.get");
			var abstract_data:AbstractDefinition = {
				name: {name: path.tname, pos: nullPos},
				doc: null,
				params: vector(),
				meta: [
					{
						meta: MetaTag.Native,
						exprs: vector({expr: EConst(String(native_path, SDoubleQuotes)), pos: nullPos}),
						pos: nullPos
					}
				],
				flags: vector(AbEnum, AbExtern, AbOver({type: real_type, pos: pos}), AbFrom({type: real_type, pos: pos})),
				data: Vector.fromArrayCopy(constr),
			};
			return {pack: path.tpackage, declarations: vector({definition: EAbstract(abstract_data), pos: pos})};
		} catch (_:core.ds.Exit) {
			var flags = if (c.hlc_final
				&& Lambda.exists(fields, f -> f.cffName.name != "new" && !hasAccess(f.cffAccess, AStatic))) [HFinal].concat(flags) else flags;
			var meta:Metadata = /* if the package was lowercased, add @:native("Original.Path") meta */
				switch c.hlc_name {
					case HMPath(pack, name) if (pack.length != 0 && pack.join("\x00") != path.tpackage.join("\x00")):
						var native_path = pack.join(".") + "." + name;
						[
							{
								meta: MetaTag.Native,
								exprs: vector({expr: EConst(String(native_path, SDoubleQuotes)), pos: pos}),
								pos: pos
							}
						];
					case _:
						[];
				};
			var class_data:ClassDefinition = {
				name: {name: path.tname, pos: nullPos},
				doc: null,
				params: vector(),
				meta: meta,
				flags: Vector.fromArrayCopy(flags),
				data: Vector.fromArrayCopy(fields),
			};
			return {pack: path.tpackage, declarations: vector({definition: EClass(class_data), pos: pos})};
		}
	}

	static function hashPath(p:GlobalTypePath):Int return OcamlHash.hashPath(p);

	static function eqPath(a:GlobalTypePath, b:GlobalTypePath):Bool return Common.samePath(a, b);

	static function extract_data_(swf:SwfData):OcamlHashtbl<GlobalTypePath, HlClass> {
		var h = new OcamlHashtbl<GlobalTypePath, HlClass>(hashPath, eqPath);
		function loop_field(f:HlField) {
			switch f.hlf_kind {
				case HFClass(c):
					var path = (make_tpath(f.hlf_name)).path;
					switch path {
						case {tpackage: [], tname: "Float" | "Bool" | "Int" | "UInt" | "Dynamic"}:
						case {tpackage: ["haxe"], tname: "UInt32"}:
						case {tpackage: _, tname: "MethodClosure"}:
						case _:
							h.add({pack: path.tpackage, name: path.tname}, c);
					}
				case _:
			}
		}
		for (t in swf.tags) {
			switch t.tdata {
				case TActionScript3(_, as3):
					for (i in libs.swflib.As3hlparse.parse(as3)) for (f in i.hls_fields) loop_field(f);
				case _:
			}
		}
		return h;
	}

	static function extract_data(com:CommonContext, arg:SwfData):OcamlHashtbl<GlobalTypePath, HlClass> {
		return core.Timer.time(com.timerCtx, ["read", "swf"], extract_data_, arg);
	}

	static function remove_debug_infos(as3:As3Tag):As3Tag {
		var hl = libs.swflib.As3hlparse.parse(as3);
		var methods = new Map<Int, HlMethod>();
		// port: the `let rec ... and ...` group, forward-declared.
		var loop_method:HlMethod->HlMethod = null;
		var loop_class:HlClass->HlClass = null;
		var loop_function:HlFunction->HlFunction = null;
		function loop_field(f:HlField):HlField {
			return {
				hlf_name: f.hlf_name,
				hlf_slot: f.hlf_slot,
				hlf_metas: f.hlf_metas,
				hlf_kind: (switch f.hlf_kind {
					case HFMethod(m): HFMethod({
							hlm_type: loop_method(m.hlm_type),
							hlm_final: m.hlm_final,
							hlm_override: m.hlm_override,
							hlm_kind: m.hlm_kind
						});
					case HFFunction(f): HFFunction(loop_method(f));
					case HFVar(v): HFVar(v);
					case HFClass(c): HFClass(loop_class(c));
				})
			};
		}
		loop_class = function(c:HlClass):HlClass {
			/* mutate in order to preserve sharing */
			c.hlc_construct = loop_method(c.hlc_construct);
			c.hlc_fields = c.hlc_fields.map(loop_field);
			c.hlc_static_construct = loop_method(c.hlc_static_construct);
			c.hlc_static_fields = c.hlc_static_fields.map(loop_field);
			return c;
		};
		function loop_static(s:HlStatic):HlStatic {
			return {
				hls_method: loop_method(s.hls_method),
				hls_fields: s.hls_fields.map(loop_field),
			};
		}
		loop_method = function(m:HlMethod):HlMethod {
			switch methods.get(m.hlmt_index) {
				case null:
					var m2 = m.copy();
					m2.hlmt_debug_name = null;
					m2.hlmt_pnames = null;
					methods.set(m.hlmt_index, m2);
					m2.hlmt_function = (switch m.hlmt_function {
						case null: null;
						case f: loop_function(f);
					});
					return m2;
				case m2:
					return m2;
			}
		};
		loop_function = function(f:HlFunction):HlFunction {
			var cur = 0;
			var positions = [
				for (op in f.hlf_code) {
					var p = cur;
					switch op {
						case HDebugReg(_) | HDebugLine(_) | HDebugFile(_) | HBreakPointLine(_) | HTimestamp:
						case _:
							cur++;
					}
					p;
				}
			];
			positions.push(cur);
			var code:Array<HlOpcode> = [];
			for (pos in 0...f.hlf_code.length) {
				var op = f.hlf_code[pos];
				switch op {
					case HDebugReg(_) | HDebugLine(_) | HDebugFile(_) | HBreakPointLine(_) | HTimestamp:
					case _:
						function p(delta:Int):Int {
							// port: MultiArray.get raises outside the array.
							var k = pos + delta;
							if (k < 0 || k >= positions.length) throw new core.ds.InvalidArgument("index out of bounds");
							return positions[k] - code.length;
						}
						var op = (switch op {
							case HJump(j, delta): HJump(j, p(delta));
							case HSwitch(d, deltas):
								// port: OCaml evaluates the constructor arguments right to left.
								var l = deltas.map(p);
								HSwitch(p(d), l);
							case HFunction(m): HFunction(loop_method(m));
							case HCallStatic(m, args): HCallStatic(loop_method(m), args);
							case HClassDef(c): HClassDef(c); /* mutated */
							case _: op;
						});
						code.push(op);
				}
			}
			f.hlf_code = code;
			f.hlf_trys = f.hlf_trys.map(t -> ({
				hltc_start: positions[t.hltc_start],
				hltc_end: positions[t.hltc_end],
				hltc_handle: positions[t.hltc_handle],
				hltc_type: t.hltc_type,
				hltc_name: t.hltc_name,
			} : HlTryCatch));
			return f;
		};
		return libs.swflib.As3hlparse.flatten(hl.map(loop_static));
	}

	static function parse_swf_(file:String):SwfData {
		var ext = core.Path.fileExtension(file);
		var is_swc = ext == "swc" || ext == "ane";
		var ch = if (is_swc) {
			var zip = core.ZipInput.openIn(file);
			try {
				// port: Zip.find_entry (Hashtbl.find: the last member of that name) raises
				// Not_found for a missing member.
				var entry = null;
				for (e in zip.entries) if (e.filename == "library.swf") entry = e;
				if (entry == null) throw NotFound.raise();
				var ch = IO.inputString(zip.readEntry(entry));
				zip.closeIn();
				ch;
			} catch (_:Dynamic) {
				zip.closeIn();
				throw new Failure("The input swc " + file + " is corrupted");
			}
		} else
			IO.inputChannel(sys.io.File.read(file, true));
		var swf = try Swf.parse(ch) catch (_:Dynamic) throw new Failure("The input swf " + file + " is corrupted");
		IO.closeIn(ch);
		for (t in swf.tags) {
			switch t.tdata {
				case TActionScript3(id, as3):
					t.tdata = TActionScript3(id, remove_debug_infos(as3));
				case _:
			}
		}
		return swf;
	}

	static function parse_swf(com:CommonContext, file:String):SwfData return core.Timer.time(com.timerCtx, ["read", "swf"], parse_swf_, file);

	public static function add_swf_lib(com:CommonContext, file:String, extern_:Bool):Void->Void {
		var real_file = (try Common.findFile(com, file) catch (_:NotFound) throw new Failure(" Library not found : " + file));
		var swf_lib = new SwfLibrary(com, file, real_file);
		if (!extern_) com.nativeLibs.swfLibs.unshift(swf_lib);
		return context.CommonCache.handleNativeLib(com, cast swf_lib);
	}

	public static function remove_classes(toremove:Array<GlobalTypePath>, lib:SwfData, l:Array<GlobalTypePath>):SwfData {
		switch toremove {
			case []:
				return lib;
			case _:
				var hcl = new OcamlHashtbl<GlobalTypePath, Bool>(hashPath, eqPath);
				for (path in l) hcl.add(path, true);
				switch toremove.filter(c -> hcl.mem(c)) {
					case []:
						return lib;
					case classes:
						function mem(p:GlobalTypePath):Bool return Lambda.exists(classes, c -> Common.samePath(c, p));
						function tags(l:Array<Tag>, i:Int):Array<Tag> {
							if (i >= l.length) return [];
							var t = l[i];
							switch t.tdata {
								case TActionScript3(h, data):
									var data = libs.swflib.As3hlparse.parse(data);
									function loop(f:HlField):Bool {
										return switch f.hlf_kind {
											case HFClass(_):
												var path = (make_tpath(f.hlf_name)).path;
												!mem({pack: path.tpackage, name: path.tname});
											case _:
												true;
										}
									}
									var data = [for (s in data) ({hls_method: s.hls_method, hls_fields: s.hls_fields.filter(loop)} : HlStatic)];
									var data = data.filter(s -> s.hls_fields.length > 0);
									return (if (data.length == 0) tags(l,
										i + 1) else [({tid: t.tid, textended: t.textended, tdata: TActionScript3(h, libs.swflib.As3hlparse.flatten(data))} : Tag)].concat(tags(l,
											i + 1)));
								case _:
									return [t].concat(tags(l, i + 1));
							}
						}
						// port: `toremove` is a ref updated in place.
						var rest = toremove.filter(p -> !mem(p));
						toremove.resize(0);
						for (p in rest) toremove.push(p);
						return {header: lib.header, tags: tags(lib.tags, 0)};
				}
		}
	}
}

class SwfLibrary extends NativeLibraryBase implements NativeLibrary<SwfLibType, SwfData> {
	final com:CommonContext;
	var swf_data:Null<SwfData> = null;
	var swf_classes:Null<OcamlHashtbl<GlobalTypePath, HlClass>> = null;
	final haxe_classes:Map<String, Package> = new Map();

	public function new(com:CommonContext, name:String, filePath:String) {
		super(name, filePath);
		this.com = com;
	}

	public function load():Void {
		get_swf();
	}

	function get_swf():SwfData {
		return switch swf_data {
			case null:
				var d = @:privateAccess SwfLoader.parse_swf(com, filePath);
				swf_data = d;
				d;
			case d:
				d;
		}
	}

	function extract():OcamlHashtbl<GlobalTypePath, HlClass> {
		return switch swf_classes {
			case null:
				var d = @:privateAccess SwfLoader.extract_data(com, get_swf());
				swf_classes = d;
				d;
			case d:
				d;
		}
	}

	public function lookup(path:GlobalTypePath):SwfLibType {
		return try extract().find(path) catch (_:NotFound) null;
	}

	public function listModules():Array<GlobalTypePath> {
		return extract().fold((path, _, acc:Array<GlobalTypePath>) -> [path].concat(acc), []);
	}

	public function close():Void {}

	static function key(path:GlobalTypePath):String return path.pack.join(".") + "#" + path.name;

	public function build(path:GlobalTypePath, p:Pos):Null<Package> {
		switch haxe_classes.get(key(path)) {
			case null:
			case c:
				return c;
		}
		return try {
			var c = extract().find(path);
			var c = @:privateAccess SwfLoader.build_class(com, c, filePath);
			haxe_classes.set(key(path), c);
			c;
		} catch (_:NotFound) {
			null;
		}
	}

	public function getData():SwfData return get_swf();
}
