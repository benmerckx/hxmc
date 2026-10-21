package codegen;

import haxe.io.Bytes;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.ds.AtomicLazy;
import core.ds.Failure;
import core.ds.NotFound;
import core.ZipInput;
import context.Common;
import context.NativeLibraries;
import generators.jvm.JvmSignature.JWildcard;
import generators.jvm.JvmSignature.JTypeArgument;
import generators.jvm.JvmSignature.JSignature;
import core.ds.VectorTools;

using core.ds.VectorTools;

private typedef MetaTag = core.MetaList.StrictMeta;

// port: from haxe/src/codegen/javaModern.ml. JDataHoldovers' jsignature is the JVM
// generator's (generators.jvm.JvmSignature, constructors prefixed with J); the class
// reader works on the class-file bytes like extlib's IO.BigEndian.
enum AccessFlag {
	MPublic;
	MPrivate;
	MProtected;
	MStatic;
	MFinal;
	MSynchronized;
	MBridge;
	MVarargs;
	MNative;
	MInterface;
	MAbstract;
	MStrict;
	MSynthetic;
	MAnnotation;
	MEnum;
}

class AccessFlags {
	public static function toInt(f:AccessFlag):Int return switch f {
		case MPublic: 0x1;
		case MPrivate: 0x2;
		case MProtected: 0x4;
		case MStatic: 0x8;
		case MFinal: 0x10;
		case MSynchronized: 0x20;
		case MBridge: 0x40;
		case MVarargs: 0x80;
		case MNative: 0x100;
		case MInterface: 0x200;
		case MAbstract: 0x400;
		case MStrict: 0x800;
		case MSynthetic: 0x1000;
		case MAnnotation: 0x2000;
		case MEnum: 0x4000;
	}

	public static function hasFlag(b:Int, flag:AccessFlag):Bool return b & toInt(flag) != 0;
}

typedef JTypes = Array<{name:String, ext:Null<JSignature>, impls:Array<JSignature>}>;

@:structInit class JAnnotation {
	public var annType:JSignature;
	public var annElements:Array<{name:String, value:JAnnotationValue}>;
}

enum JAnnotationValue {
	ValConst(jsig:JSignature, i:Int);
	ValEnum(jsig:JSignature, name:String); /* e */
	ValClass(jsig:JSignature); /* c */ /* V -> Void */
	ValAnnotation(a:JAnnotation); /* @ */
	ValArray(l:Array<JAnnotationValue>); /* [ */
}

// port: the Exit/Invalid_string exceptions of the signature parser.
private class SigExit extends haxe.Exception {
	public function new() super("Exit");
}

class JReaderHoldovers {
	static function sub(s:String, pos:Int, len:Int):String {
		if (pos < 0 || len < 0 || pos + len > s.length) throw new core.ds.InvalidArgument("String.sub / Bytes.sub");
		return s.substr(pos, len);
	}

	// port: s.[i], a char code (comparing codes allocates no one-character strings)
	static function at(s:String, i:Int):Int {
		if (i < 0 || i >= s.length) throw new core.ds.InvalidArgument("index out of bounds");
		return StringTools.fastCodeAt(s, i);
	}

	public static function parseTypeParameterPart(s:String):{a:JTypeArgument, l:Int} {
		return switch at(s, 0) {
			case "*".code: {a: JTAny, l: 1};
			case c:
				var wildcard, i;
				switch c {
					case "+".code:
						wildcard = WExtends;
						i = 1;
					case "-".code:
						wildcard = WSuper;
						i = 1;
					case _:
						wildcard = WNone;
						i = 0;
				}
				var r = parseSignaturePart(sub(s, i, s.length - 1));
				{a: JTType(wildcard, r.s), l: r.l + i};
		}
	}

	public static function parseSignaturePart(s:String):{s:JSignature, l:Int} {
		var len = s.length;
		if (len == 0) throw new SigExit();
		return switch at(s, 0) {
			case "B".code: {s: JByte, l: 1};
			case "C".code: {s: JChar, l: 1};
			case "D".code: {s: JDouble, l: 1};
			case "F".code: {s: JFloat, l: 1};
			case "I".code: {s: JInt, l: 1};
			case "J".code: {s: JLong, l: 1};
			case "S".code: {s: JShort, l: 1};
			case "Z".code: {s: JBool, l: 1};
			case "L".code:
				var origS = s;
				function loop(start:Int, i:Int, acc:Array<String>):{pack:Array<String>, name:String, params:Array<JTypeArgument>, end:Int} {
					while (true) {
						switch at(s, i) {
							case "/".code:
								acc.unshift(sub(s, start, i - start));
								i = i + 1;
								start = i;
							case ";".code | ".".code:
								var pack = acc.copy();
								pack.reverse();
								return {pack: pack, name: sub(s, start, i - start), params: [], end: i};
							case "<".code:
								var name = sub(s, start, i - start);
								function loopParams(i:Int, acc:Array<JTypeArgument>):{params:Array<JTypeArgument>, end:Int} {
									while (true) {
										var s = sub(s, i, len - i);
										switch at(s, 0) {
											case ">".code:
												var l = acc.copy();
												l.reverse();
												return {params: l, end: i + 1};
											case _:
												var r = parseTypeParameterPart(s);
												i = r.l + i;
												acc.unshift(r.a);
										}
									}
								}
								var r = loopParams(i + 1, []);
								var pack = acc.copy();
								pack.reverse();
								return {pack: pack, name: name, params: r.params, end: r.end};
							case _:
								i = i + 1;
						}
					}
				}
				var r = loop(1, 1, []);
				var pack = r.pack, name = r.name, params = r.params, end = r.end;
				var inners:Array<{name:String, params:Array<JTypeArgument>}> = [];
				var end2 = 0;
				while (true) {
					switch at(s, end) {
						case ".".code:
							var r = loop(end + 1, end + 1, []);
							if (r.pack.length > 0) throw new Failure("Inner types must not define packages. For '" + origS + "'.");
							inners.push({name: r.name, params: r.params});
							end = r.end;
						case ";".code:
							end2 = end + 1;
							break;
						case c:
							throw new Failure("End of complex type signature expected after type parameter. Got '" + std.String.fromCharCode(c) + "' for '" + origS + "'.");
					}
				}
				switch inners {
					case []: {s: JObject({pack: pack, name: name}, params), l: end2};
					case _: {s: JObjectInner(pack, [{name: name, params: params}].concat(inners)), l: end2};
				}
			case "[".code:
				var p = 1;
				while (p < s.length && at(s, p) >= "0".code && at(s, p) <= "9".code) p++;
				var size = if (p > 1) core.ds.OcamlInt.ofString(sub(s, 1, p - 1)) else null;
				var r = parseSignaturePart(sub(s, p, s.length - p));
				{s: JArray(r.s, size), l: r.l + p};
			case "(".code:
				var p = 1;
				var args = [];
				while (p < s.length && at(s, p) != ")".code) {
					var r = parseSignaturePart(sub(s, p, s.length - p));
					args.push(r.s);
					p = p + r.l;
				}
				p++;
				if (p >= s.length) throw new SigExit();
				var ret, l;
				switch at(s, p) {
					case "V".code:
						ret = null;
						l = 1;
					case _:
						var r = parseSignaturePart(sub(s, p, s.length - p));
						ret = r.s;
						l = r.l;
				}
				{s: JMethod(args, ret), l: p + l};
			case "T".code:
				var idx = s.indexOf(";");
				if (idx < 0) throw new SigExit();
				var s1 = s.substr(0, idx);
				var len = s1.length;
				{s: JTypeParameter(sub(s1, 1, len - 1)), l: len + 1};
			case _:
				throw new SigExit();
		}
	}

	public static function parseSignature(s:String):JSignature {
		try {
			var r = parseSignaturePart(s);
			if (s.length != r.l) throw new SigExit();
			return r.s;
		} catch (_:SigExit) {
			throw new Failure("Invalid signature '" + s + "'");
		}
	}

	public static function parseMethodSignature(s:String):JSignature {
		return switch parseSignature(s) {
			case m = JMethod(_): m;
			case _: throw new Failure("Unexpected signature '" + s + "'. Expecting method");
		}
	}

	public static function parseFormalTypeParams(s:String):{types:JTypes, idx:Int} {
		return switch at(s, 0) {
			case "<".code:
				function readId(i:Int):Int {
					while (true) switch at(s, i) {
						case ":".code | ">".code: return i;
						case _: i = i + 1;
					}
				}
				var len = s.length;
				var acc:JTypes = [];
				var idx = 0;
				while (true) {
					var idi = readId(idx + 1);
					var id = sub(s, idx + 1, idi - idx - 1);
					/* next must be a : */
					switch at(s, idi) {
						case ":".code:
						case c: throw new Failure("Invalid formal type signature character: " + std.String.fromCharCode(c) + " ; from " + s);
					}
					var ext, l;
					switch at(s, idi + 1) {
						case ":".code | ">".code:
							ext = null;
							l = idi + 1;
						case _:
							var r = parseSignaturePart(sub(s, idi + 1, len - idi - 1));
							ext = r.s;
							l = r.l + idi + 1;
					}
					var ifaces = [];
					var idx2 = l;
					while (true) {
						switch at(s, idx2) {
							case ":".code:
								var r = parseSignaturePart(sub(s, idx2 + 1, len - idx2 - 1));
								idx2 = idx2 + r.l + 1;
								ifaces.unshift(r.s);
							case _:
								break;
						}
					}
					acc.unshift({name: id, ext: ext, impls: ifaces});
					if (at(s, idx2) == ">".code) {
						var l = acc.copy();
						l.reverse();
						return {types: l, idx: idx2 + 1};
					} else
						idx = idx2 - 1;
				}
				null;
			case _: {types: [], idx: 0};
		}
	}

	public static function parseThrows(s:String):{throws:Array<JSignature>, idx:Int} {
		var len = s.length;
		var idx = 0;
		var acc = [];
		while (true) {
			if (idx > len) throw new SigExit() else if (idx == len) return {throws: acc, idx: idx} else switch at(s, idx) {
				case "^".code:
					var r = parseSignaturePart(sub(s, idx + 1, len - idx - 1));
					idx = idx + r.l + 1;
					acc.unshift(r.s);
				case _:
					return {throws: acc, idx: idx};
			}
		}
	}

	public static function parseCompleteMethodSignature(s:String):{tparams:JTypes, msig:JSignature, throws:Array<JSignature>} {
		try {
			var len = s.length;
			var ft = parseFormalTypeParams(s);
			var tparams = ft.types, i = ft.idx;
			var r = parseSignaturePart(sub(s, i, len - i));
			var sign = r.s, l = r.l;
			var t = parseThrows(sub(s, i + l, len - i - l));
			if ((i + l + t.idx) != len) throw new SigExit();
			return switch sign {
				case JMethod(_): {tparams: tparams, msig: sign, throws: t.throws};
				case _: throw new SigExit();
			}
		} catch (_:SigExit) {
			throw new Failure("Invalid method extended signature '" + s + "'");
		}
	}
}

// port: extlib's IO input on a string, big-endian.
private class ClassInput {
	final b:Bytes;
	var pos = 0;

	public function new(b:Bytes) this.b = b;

	function check(n:Int):Void if (pos + n > b.length) throw new haxe.io.Eof();

	public function readByte():Int {
		check(1);
		return b.get(pos++);
	}

	public function readUi16():Int {
		check(2);
		var v = (b.get(pos) << 8) | b.get(pos + 1);
		pos += 2;
		return v;
	}

	public function readRealI32():Int {
		check(4);
		var v = (b.get(pos) << 24) | (b.get(pos + 1) << 16) | (b.get(pos + 2) << 8) | b.get(pos + 3);
		pos += 4;
		return v;
	}

	public function readI32():Int return readRealI32();

	public function skip(n:Int):Void {
		check(n);
		pos += n;
	}

	public function nreadString(n:Int):String {
		check(n);
		var s = b.getString(pos, n);
		pos += n;
		return s;
	}
}

enum JAttribute {
	AttrCode(attribs:Array<JAttribute>);
	AttrDeprecated;
	AttrLocalVariableTable(locals:Array<JLocal>);
	AttrMethodParameters(params:Array<{name:String, flags:Int}>);
	AttrSignature(s:String);
	AttrVisibleAnnotations(anns:Array<JAnnotation>);
	AttrOther;
}

@:structInit class JLocal {
	public var ldStartPc:Int;
	public var ldLength:Int;
	public var ldName:String;
	public var ldDescriptor:String;
	public var ldIndex:Int;
}

@:structInit class JField {
	public var jfName:String;
	public var jfFlags:Int;
	public var jfTypes:JTypes;
	public var jfDescriptor:JSignature;
	public var jfAttributes:Array<JAttribute>;
	public var jfCode:Null<Array<JAttribute>>;
}

@:structInit class JClass {
	public var jcPath:GlobalTypePath;
	public var jcFlags:Int;
	public var jcSuper:JSignature;
	public var jcInterfaces:Array<JSignature>;
	public var jcTypes:JTypes;
	public var jcFields:Array<JField>;
	public var jcMethods:Array<JField>;
	public var jcAttributes:Array<JAttribute>;
}

typedef ConstantPool = {strings:Vector<String>, paths:Vector<GlobalTypePath>, nameAndTypes:Vector<{name:String, t:String}>};

class JReaderModern {
	static function readConstantPool(ch:ClassInput):ConstantPool {
		var count = ch.readUi16();
		var strings = new Vector<String>(count, "");
		var paths = new Vector<Int>(count, 0);
		var nameAndTypes = new Vector<{name:Int, t:Int}>(count, {name: 0, t: 0});
		var i = 1;
		while (i < count) {
			switch ch.readByte() {
				case 1:
					strings[i] = ch.nreadString(ch.readUi16());
				case 3:
					ch.readRealI32();
				case 4:
					ch.skip(4);
				case 5:
					i++;
					ch.skip(8);
				case 6:
					i++;
					ch.skip(8);
				case 7:
					paths[i] = ch.readUi16();
				case 8:
					ch.readUi16();
				case 9 | 10 | 11:
					ch.readUi16();
					ch.readUi16();
				case 12:
					var name = ch.readUi16();
					var t = ch.readUi16();
					nameAndTypes[i] = {name: name, t: t};
				case 15:
					ch.readByte();
					ch.readUi16();
				case 16:
					ch.readUi16();
				case 17 | 18:
					ch.readUi16();
					ch.readUi16();
				case 19 | 20:
					ch.readUi16();
				case i:
					throw new Failure('Invalid constant pool byte: $i');
			}
			i++;
		}
		function asPath(s:String):GlobalTypePath {
			var l = s.split("/");
			return switch l.length {
				case 1: {pack: [], name: l[0]};
				case 0: throw new Failure("assert");
				case _: {pack: l.slice(0, l.length - 1), name: l[l.length - 1]};
			}
		}
		var paths = paths.map(function(index) return if (index > 0) asPath(strings[index]) else ({pack: [], name: ""} : GlobalTypePath));
		var nameAndTypes = nameAndTypes.map(function(nt) {
			var name = if (nt.name > 0) strings[nt.name] else "";
			var t = if (nt.t > 0) strings[nt.t] else "";
			return {name: name, t: t};
		});
		return {strings: strings, paths: paths, nameAndTypes: nameAndTypes};
	}

	static function parseElementValue(consts:ConstantPool, ch:ClassInput):JAnnotationValue {
		var tag = ch.readByte();
		var c = std.String.fromCharCode(tag);
		return switch c {
			case "B" | "C" | "D" | "F" | "I" | "J" | "S" | "Z" | "s":
				var jsig = switch c {
					case "s":
						JObject({pack: ["java", "lang"], name: "String"}, []);
					case tag:
						JReaderHoldovers.parseSignaturePart(tag).s;
				}
				ValConst(jsig, ch.readUi16());
			case "e":
				var path = JReaderHoldovers.parseSignature(consts.strings[ch.readUi16()]);
				var name = consts.strings[ch.readUi16()];
				ValEnum(path, name);
			case "c":
				var name = consts.strings[ch.readUi16()];
				var jsig = if (name == "V") JObject({pack: [], name: "Void"}, []) else JReaderHoldovers.parseSignature(name);
				ValClass(jsig);
			case "@":
				ValAnnotation(parseAnnotation(consts, ch));
			case "[":
				var numVals = ch.readUi16();
				ValArray([for (_ in 0...numVals) parseElementValue(consts, ch)]);
			case tag:
				throw new Failure("Invalid element value: '" + tag + "'");
		}
	}

	static function parseAnnElement(consts:ConstantPool, ch:ClassInput):{name:String, value:JAnnotationValue} {
		var name = consts.strings[ch.readUi16()];
		var elementValue = parseElementValue(consts, ch);
		return {name: name, value: elementValue};
	}

	static function parseAnnotation(consts:ConstantPool, ch:ClassInput):JAnnotation {
		var anntype = JReaderHoldovers.parseSignature(consts.strings[ch.readUi16()]);
		var count = ch.readUi16();
		return {
			annType: anntype,
			annElements: [for (_ in 0...count) parseAnnElement(consts, ch)]
		};
	}

	static function parseAttribute(consts:ConstantPool, ch:ClassInput):JAttribute {
		var name = consts.strings[ch.readUi16()];
		var length = ch.readI32();
		return switch name {
			case "Code":
				ch.readUi16(); /* max stack */
				ch.readUi16(); /* max locals */
				var len = ch.readI32();
				ch.skip(len); /* code */
				var len = ch.readUi16();
				for (_ in 0...len) ch.skip(8); /* exceptions */
				var attribs = parseAttributes(consts, ch);
				AttrCode(attribs);
			case "Deprecated":
				AttrDeprecated;
			case "LocalVariableTable":
				var len = ch.readUi16();
				var locals = [
					for (_ in 0...len) {
						var startPc = ch.readUi16();
						var length = ch.readUi16();
						var name = consts.strings[ch.readUi16()];
						var descriptor = consts.strings[ch.readUi16()];
						var index = ch.readUi16();
						({
							ldStartPc: startPc,
							ldLength: length,
							ldName: name,
							ldDescriptor: descriptor,
							ldIndex: index
						} : JLocal);
					}
				];
				AttrLocalVariableTable(locals);
			case "MethodParameters":
				var len = ch.readByte();
				var parameters = [
					for (_ in 0...len) {
						var name = consts.strings[ch.readUi16()];
						var flags = ch.readUi16();
						{name: name, flags: flags};
					}
				];
				AttrMethodParameters(parameters);
			case "RuntimeVisibleAnnotations":
				var count = ch.readUi16();
				AttrVisibleAnnotations([for (_ in 0...count) parseAnnotation(consts, ch)]);
			case "Signature":
				var s = consts.strings[ch.readUi16()];
				AttrSignature(s);
			case _:
				ch.skip(length);
				AttrOther;
		}
	}

	static function parseAttributes(consts:ConstantPool, ch:ClassInput):Array<JAttribute> {
		var n = ch.readUi16();
		return [for (_ in 0...n) parseAttribute(consts, ch)];
	}

	static function parseField(consts:ConstantPool, isMethod:Bool, ch:ClassInput):JField {
		var flags = ch.readUi16();
		var name = consts.strings[ch.readUi16()];
		var descriptor = consts.strings[ch.readUi16()];
		var attributes = parseAttributes(consts, ch);
		var types:JTypes = [];
		var jsig:Null<JSignature> = null;
		var code:Null<Array<JAttribute>> = null;
		for (a in attributes) switch a {
			case AttrCode(code2):
				code = code2;
			case AttrSignature(s):
				if (isMethod) {
					var r = JReaderHoldovers.parseCompleteMethodSignature(s);
					types = r.tparams;
					jsig = r.msig;
				} else
					jsig = JReaderHoldovers.parseSignature(s);
			case _:
		}
		return {
			jfName: name,
			jfFlags: flags,
			jfTypes: types,
			jfDescriptor: switch jsig {
				case null: JReaderHoldovers.parseSignature(descriptor);
				case jsig: jsig;
			},
			jfAttributes: attributes,
			jfCode: code,
		};
	}

	public static function parseClass(ch0:Bytes):JClass {
		var ch = new ClassInput(ch0);
		if (ch.readRealI32() != 0xCAFEBABE) throw new Failure("Invalid header");
		ch.readUi16();
		ch.readUi16();
		var consts = readConstantPool(ch);
		var flags = ch.readUi16();
		var thisPath = consts.paths[ch.readUi16()];
		var superSig = JObject(consts.paths[ch.readUi16()], []);
		var n = ch.readUi16();
		var interfaces = [for (_ in 0...n) JObject(consts.paths[ch.readUi16()], [])];
		var n = ch.readUi16();
		var fields = [for (_ in 0...n) parseField(consts, false, ch)];
		var n = ch.readUi16();
		var methods = [for (_ in 0...n) parseField(consts, true, ch)];
		var attributes = parseAttributes(consts, ch);
		var types:JTypes = [];
		for (a in attributes) switch a {
			case AttrSignature(s):
				var r = JReaderHoldovers.parseFormalTypeParams(s);
				types = r.types;
				var s = s.substr(r.idx, s.length - r.idx);
				var len = s.length;
				var r = JReaderHoldovers.parseSignaturePart(s);
				var sup = r.s, idx = r.l;
				var acc = [];
				while (idx != len) {
					var s = s.substr(idx, len - idx);
					var r = JReaderHoldovers.parseSignaturePart(s);
					idx = idx + r.l;
					acc.unshift(r.s);
				}
				interfaces = acc;
				superSig = sup;
			case _:
		}
		return {
			jcPath: thisPath,
			jcFlags: flags,
			jcSuper: superSig,
			jcInterfaces: interfaces,
			jcTypes: types,
			jcFields: fields,
			jcMethods: methods,
			jcAttributes: attributes,
		};
	}
}

class PathConverter {
	// port: ExtString.String.nsplit
	static function nsplit(s:String, sep:String):Array<String> return s.split(sep);

	public static function jnameToHx(name:String):{mname:Null<String>, name:String} {
		var name = if (name != "" && (name.charAt(0) < "A" || name.charAt(0) > "Z")) name.charAt(0).toUpperCase() + name.substr(1) else name;
		var name = nsplit(name, "_").join("__");
		var parts = nsplit(name, "$");
		return switch parts {
			case []:
				die("", "codegen/javaModern.ml");
			case [_]:
				{mname: null, name: name};
			case [x, ""]:
				{mname: null, name: x + "_"}; /* trailing $ */
			case _:
				var x = parts[0];
				var name = parts.join("_");
				if (x == "") {mname: null, name: name} /* leading $ */ else {mname: x, name: name};
		}
	}

	public static function normalizePack(pack:Array<String>):Array<String> {
		return pack.map(function(str) return switch str {
			case "": "";
			case str if (str.charAt(0) >= "A" && str.charAt(0) <= "Z"): str.toLowerCase();
			case str: str;
		});
	}

	public static function jpathToHx(path:GlobalTypePath):{pack:Array<String>, mname:Null<String>, name:String} {
		var pack = path.pack, name = path.name;
		if (pack.length == 2 && pack[0] == "haxe" && pack[1] == "root") pack = [] else if (pack.length > 0 && (switch pack[0] {
			case "javax" | "sun" | "sunw": true;
			case "com": pack.length > 1 && (pack[1] == "oracle" || pack[1] == "sun");
			case "org": pack.length > 1 && (pack[1] == "ietf" || pack[1] == "jcp" || pack[1] == "omg" || pack[1] == "w3c" || pack[1] == "xml");
			case _: false;
		})) pack = ["java"].concat(pack);
		var pack = normalizePack(pack);
		var r = jnameToHx(name);
		return {pack: pack, mname: r.mname, name: r.name};
	}

	public static function jpathToPath(pack:Array<String>, mname:Null<String>, name:String):GlobalTypePath {
		return switch mname {
			case null: {pack: pack, name: name};
			case mname: {pack: pack.concat([mname]), name: name};
		}
	}

	public static function isHaxeKeyword(s:String):Bool return switch s {
		case "cast" | "extern" | "function" | "in" | "typedef" | "using" | "var" | "untyped" | "inline": true;
		case _: false;
	}
}

typedef JavaLibCtx = {typeParams:haxe.ds.StringMap<ComplexType>};

class SignatureConverter {
	public static function mkTypePath(path:GlobalTypePath, params:Array<TypeParamOrConst>, p:Pos):ComplexType {
		var r = PathConverter.jpathToHx(path);
		var path:TypePath = switch r.mname {
			case null:
				{
					tpackage: r.pack,
					tname: r.name,
					tparams: Vector.fromArrayCopy(params),
					tsub: null,
				};
			case mname:
				{
					tpackage: r.pack,
					tname: mname,
					tparams: Vector.fromArrayCopy(params),
					tsub: r.name,
				};
		}
		return core.Ast.Ast.makePtpCt(path, p);
	}

	public static function ctTypeParam(name:String):ComplexType return core.Ast.Ast.makePtpCt({
		tpackage: [],
		tname: name,
		tparams: vector(),
		tsub: null
	}, nullPos);

	public static function ctVoid():ComplexType return core.Ast.Ast.makePtpCt({
		tpackage: [],
		tname: "Void",
		tparams: vector(),
		tsub: null
	}, nullPos);

	public static function ctDynamic():ComplexType return core.Ast.Ast.makePtpCt({
		tpackage: [],
		tname: "Dynamic",
		tparams: vector(),
		tsub: null
	}, nullPos);

	public static function convertArg(ctx:JavaLibCtx, p:Pos, arg:JTypeArgument):TypeParamOrConst {
		return switch arg {
			case JTAny | JTType(WSuper, _): TPType({type: mkTypePath({pack: [], name: "Dynamic"}, [], p), pos: p});
			case JTType(_, jsig): TPType({type: convertSignature(ctx, p, jsig), pos: p});
		}
	}

	static inline function isJavaLang(path:GlobalTypePath, name:String):Bool return path.pack.length == 2 && path.pack[0] == "java"
		&& path.pack[1] == "lang" && path.name == name;

	public static function convertSignature(ctx:JavaLibCtx, p:Pos, jsig:JSignature):ComplexType {
		return switch jsig {
			case JByte: mkTypePath({pack: ["jvm"], name: "Int8"}, [], p);
			case JChar: mkTypePath({pack: ["jvm"], name: "Char16"}, [], p);
			case JDouble: mkTypePath({pack: [], name: "Float"}, [], p);
			case JFloat: mkTypePath({pack: [], name: "Single"}, [], p);
			case JInt: mkTypePath({pack: [], name: "Int"}, [], p);
			case JLong: mkTypePath({pack: ["haxe"], name: "Int64"}, [], p);
			case JShort: mkTypePath({pack: ["jvm"], name: "Int16"}, [], p);
			case JBool: mkTypePath({pack: [], name: "Bool"}, [], p);
			case JObject({pack: ["haxe", "root"], name: name}, args): mkTypePath({pack: [], name: name}, args.map(convertArg.bind(ctx, p)), p);
			case JObject(path, []) if (isJavaLang(path, "Object")): mkTypePath({pack: [], name: "Dynamic"}, [], p);
			case JObject(path, []) if (isJavaLang(path, "String")): mkTypePath({pack: [], name: "String"}, [], p);
			case JObject(path, [_]) if (isJavaLang(path, "Enum")): mkTypePath({pack: [], name: "EnumValue"}, [], p);
			case JObject(path, []):
				mkTypePath(path, [], p);
			case JObject(path, args): mkTypePath(path, args.map(convertArg.bind(ctx, p)), p);
			case JObjectInner(pack, inners) if (inners.length > 0):
				var name = inners[0].name;
				var rest = inners.slice(1);
				var actualParam = if (rest.length > 0) rest[rest.length - 1].params else die("", "codegen/javaModern.ml");
				mkTypePath({pack: pack, name: name + "$" + rest.map(function(i) return i.name).join("$")},
					actualParam.map(function(param) return convertArg(ctx, p, param)), p);
			case JObjectInner(_):
				die("", "codegen/javaModern.ml");
			case JArray(jsig, _): mkTypePath({pack: ["jvm"], name: "NativeArray"}, [TPType({type: convertSignature(ctx, p, jsig), pos: p})], p);
			case JMethod(_): throw new Failure("TMethod cannot be converted directly into Complex Type");
			case JTypeParameter(s):
				var ct = ctx.typeParams.get(s);
				ct != null ? ct : ctDynamic();
			case JUninitialized(_): die("", "codegen/javaModern.ml");
		}
	}
}

class Converter {
	public static function getTypePath(ct:ComplexType):PlacedTypePath return switch ct {
		case CTPath(ptp): ptp;
		case _: die("", "codegen/javaModern.ml");
	}

	static function meta(m:MetaTag, exprs:Vector<Expr>, p:Pos):MetadataEntry return {meta: m, exprs: exprs, pos: p};

	static function sJPath(p:GlobalTypePath):String return sTypePath(p);

	public static function extractRetentionPolicy(l:Array<JAttribute>):Null<String> {
		function loop2(l:Array<JAnnotation>):Null<String> {
			for (ann in l) switch [ann.annType, ann.annElements] {
				case [JObject({pack: ["java", "lang", "annotation"], name: "Retention"}, _), [{name: "value", value: ValEnum(_, name)}]]:
					return name;
				case _:
			}
			return null;
		}
		for (a in l) switch a {
			case AttrVisibleAnnotations(l):
				return loop2(l);
			case _:
		}
		return null;
	}

	public static function convertTypeParameter(ctx:JavaLibCtx, tp:{name:String, ext:Null<JSignature>, impls:Array<JSignature>}, p:Pos):TypeParam {
		var name = tp.name;
		var jsigs = switch tp.ext {
			case null: tp.impls;
			case jsig: [jsig].concat(tp.impls);
		}
		var constraints:Array<TypeHint> = [];
		for (jsig in jsigs) switch jsig {
			case JTypeParameter(name2) if (name == name2):
			case _:
				constraints.push({type: SignatureConverter.convertSignature(ctx, p, jsig), pos: p});
		}
		var tp:TypeParam = {
			tpName: {name: name, pos: p},
			tpParams: vector(),
			tpMeta: [],
			tpDefault: null,
			tpConstraints: switch constraints {
				case []: null;
				case _: {type: CTIntersection(Vector.fromArrayCopy(constraints)), pos: p};
			}
		};
		return tp;
	}

	public static function convertEnum(jc:JClass, file:String):TypeDecl {
		var p = filePos(file);
		var meta:Metadata = [];
		function addMeta(m:MetadataEntry) meta.unshift(m);
		var data:Array<EnumConstructor> = [];
		for (jf in jc.jcFields) switch jf.jfDescriptor {
			case JObject(path, []) if (context.Common.samePath(path, jc.jcPath) && AccessFlags.hasFlag(jf.jfFlags, MStatic)
				&& AccessFlags.hasFlag(jf.jfFlags, MFinal)):
				data.unshift({
					ecName: {name: jf.jfName, pos: p},
					ecDoc: null,
					ecMeta: [],
					ecArgs: vector(),
					ecPos: p,
					ecParams: vector(),
					ecType: null
				});
			case _:
		}
		var className = PathConverter.jnameToHx(jc.jcPath.name).name;
		addMeta(Converter.meta(MetaTag.Native, vector({expr: EConst(String(sJPath(jc.jcPath), SDoubleQuotes)), pos: p}), p));
		var data = data.copy();
		data.reverse();
		var d:EnumDefinition = {
			name: {name: className, pos: p},
			doc: null,
			params: vector(), /* enums never have type parameters */
			meta: meta,
			flags: vector(EExtern),
			data: Vector.fromArrayCopy(data),
		};
		return {definition: EEnum(d), pos: p};
	}

	public static function typeParamLut(acc:haxe.ds.StringMap<ComplexType>, params:JTypes):haxe.ds.StringMap<ComplexType> {
		var acc = acc.copy();
		for (tp in params) acc.set(tp.name, SignatureConverter.ctTypeParam(tp.name));
		return acc;
	}

	/**
		`haxe.Rest<T>` auto-boxes primitive types.
		That means we can't use it as varargs for extern methods.
		E.g externs with `int` varargs are represented as `int[]` at run time
		while `haxe.Rest<Int>` is actually `java.lang.Integer[]`.
	**/
	public static function isEligibleForHaxeRestArgs(argType:JSignature):Bool {
		return switch argType {
			case JByte | JChar | JDouble | JFloat | JInt | JLong | JShort | JBool: false;
			case _: true;
		}
	}

	public static function convertField(ctx:JavaLibCtx, isMethod:Bool, jc:JClass, isInterface:Bool, jf:JField, p:Pos):ClassField {
		var ctx:JavaLibCtx = {
			typeParams: typeParamLut(ctx.typeParams, jf.jfTypes),
		};
		var p:Pos = {pfile: p.pfile + "@" + jf.jfName, pmin: p.pmin, pmax: p.pmax};
		var isStatic = AccessFlags.hasFlag(jf.jfFlags, MStatic);
		var access:Array<PlacedAccess> = [];
		var meta:Metadata = [];
		function addAccess(a:PlacedAccess) access.unshift(a);
		function addMeta(m:MetadataEntry) meta.unshift(m);
		if (isStatic) addAccess({access: AStatic, pos: p});
		for (a in jf.jfAttributes) switch a {
			case AttrDeprecated if (!isPathEq(jc.jcPath, ["java", "util"], "Date")):
				addMeta(Converter.meta(MetaTag.Deprecated, vector(), p));
			case AttrVisibleAnnotations(ann):
				for (a in ann) switch a.annType {
					case JObject({pack: ["java", "lang"], name: "Override"}, []):
						addAccess({access: AOverride, pos: nullPos});
					case _:
				}
			case AttrCode(_) if (isInterface):
				addMeta(Converter.meta(MetaTag.JavaDefault, vector(), p));
			case _:
		}
		function addNativeMeta() {
			addMeta(Converter.meta(MetaTag.Native, vector({expr: EConst(String(jf.jfName, SDoubleQuotes)), pos: p}), p));
		}
		var name = switch jf.jfName.split("$") {
			case ["<init>"]:
				"new";
			case [name]:
				if (PathConverter.isHaxeKeyword(name)) {
					addNativeMeta();
					"_" + name;
				} else
					name;
			case parts:
				addNativeMeta();
				parts.join("_");
		}
		if (isMethod) addAccess({access: AOverload, pos: p});
		if (AccessFlags.hasFlag(jf.jfFlags, MFinal)) addAccess({access: AFinal, pos: p});
		if (!isInterface && AccessFlags.hasFlag(jf.jfFlags, MAbstract)) addAccess({access: AAbstract, pos: p});
		function extractLocalNames():Int->String {
			function default_(i:Int):String return "param" + i;
			function loop(attribs:Array<JAttribute>):Array<{index:Int, name:String}> {
				for (a in attribs) switch a {
					case AttrLocalVariableTable(locals):
						var shift = if (isStatic) 0 else -1;
						return locals.map(function(loc) return {index: loc.ldIndex + shift, name: loc.ldName});
					case AttrMethodParameters(l):
						return [for (i in 0...l.length) {index: i, name: l[i].name}];
					case _:
				}
				throw NotFound.raise();
			}
			function use(locals:Array<{index:Int, name:String}>):Int->String {
				var h = new haxe.ds.IntMap<String>();
				for (l in locals) h.set(l.index, l.name);
				return function(i:Int) {
					var r = h.get(i - 1); /* they are 1-based */
					return r != null ? r : "param" + i;
				};
			}
			return try {
				use(loop(jf.jfAttributes));
			} catch (_:NotFound) {
				try {
					switch jf.jfCode {
						case null:
							default_;
						case attribs:
							use(loop(attribs));
					}
				} catch (_:NotFound) {
					default_;
				}
			}
		}
		var kind = if (!isMethod) FVar({type: SignatureConverter.convertSignature(ctx, p, jf.jfDescriptor), pos: p}, null) else {
			switch jf.jfDescriptor {
				case JMethod(args, ret):
					var localNames = extractLocalNames();
					var argsCount = args.length;
					var isVarargs = AccessFlags.hasFlag(jf.jfFlags, MVarargs);
					function convertArg(i:Int, jsig:JSignature):FuncArg {
						var name = localNames(i + 1);
						var hxSig = switch jsig {
							case JArray(jsig1, _) if (isVarargs && i + 1 == argsCount && isEligibleForHaxeRestArgs(jsig1)):
								SignatureConverter.mkTypePath({pack: ["haxe"], name: "Rest"}, [TPType({type: SignatureConverter.convertSignature(ctx, p, jsig1), pos: p})], p);
							case _:
								SignatureConverter.convertSignature(ctx, p, jsig);
						}
						return {
							name: {name: name, pos: p},
							optional: false,
							meta: [],
							type: {type: hxSig, pos: p},
							expr: null
						};
					}
					var f:Func = {
						fParams: Vector.fromArrayCopy(jf.jfTypes.map(function(tp) return convertTypeParameter(ctx, tp, p))),
						fArgs: VectorTools.init(args.length, i -> convertArg(i, args[i])),
						fType: switch ret {
							case null: {type: SignatureConverter.ctVoid(), pos: p};
							case jsig: {type: SignatureConverter.convertSignature(ctx, p, jsig), pos: p};
						},
						fExpr: null,
					};
					FFun(f);
				case _:
					throw new Failure("assert");
			}
		}
		var cff:ClassField = {
			cffName: {name: name, pos: p},
			cffDoc: null,
			cffPos: p,
			cffMeta: meta,
			cffAccess: access,
			cffKind: kind,
		};
		return cff;
	}

	static function isPathEq(p:GlobalTypePath, pack:Array<String>, name:String):Bool return context.Common.samePath(p, {pack: pack, name: name});

	public static function convertClass(ctx:JavaLibCtx, jc:JClass, file:String):TypeDecl {
		var p = filePos(file);
		var flags:Array<ClassFlag> = [HExtern];
		var meta:Metadata = [];
		function addFlag(f:ClassFlag) flags.unshift(f);
		function addMeta(m:MetadataEntry) meta.unshift(m);
		addMeta(Converter.meta(MetaTag.LibType, vector(), p));
		var isInterface = AccessFlags.hasFlag(jc.jcFlags, MInterface);
		if (isInterface) addFlag(HInterface) else if (AccessFlags.hasFlag(jc.jcFlags, MAbstract)) addFlag(HAbstract);
		var isAnnotation = AccessFlags.hasFlag(jc.jcFlags, MAnnotation);
		switch jc.jcSuper {
			case JObject({pack: [], name: ""}, _) | JObject({pack: ["java", "lang"], name: "Object"}, _):
				if (isAnnotation)
					addFlag(HExtends(core.Ast.Ast.makePtp({
						tpackage: ["java", "lang", "annotation"],
						tname: "Annotation",
						tsub: null,
						tparams: vector()
					}, p)));
			case jsig:
				addFlag(HExtends(getTypePath(SignatureConverter.convertSignature(ctx, p, jsig))));
		}
		for (jsig in jc.jcInterfaces) {
			var path = getTypePath(SignatureConverter.convertSignature(ctx, p, jsig));
			if (isInterface) addFlag(HExtends(path)) else addFlag(HImplements(path));
		}
		var fields:Array<ClassField> = [];
		// port: only used for lookups.
		var knownNames = new haxe.ds.StringMap<JField>();
		var knownSigs = new haxe.ds.StringMap<JField>();
		function shouldGenerate(jf:JField):Bool {
			return !AccessFlags.hasFlag(jf.jfFlags, MPrivate) /* We might need member synthetics for proper call resolution, but we should never need static ones (issue #10279). */
				&& (!AccessFlags.hasFlag(jf.jfFlags, MSynthetic) || !AccessFlags.hasFlag(jf.jfFlags, MStatic))
				&& jf.jfName != "<clinit>";
		}
		if (!isPathEq(jc.jcPath, ["java", "lang"], "CharSequence")) {
			for (jf in jc.jcMethods) {
				if (shouldGenerate(jf)) {
					knownNames.set(jf.jfName, jf);
					var sigKey = switch jf.jfDescriptor {
						case JMethod(jsigs, _): JMethod(jsigs, null); /* lack of return type variance */
						case jsig: jsig;
					}
					var key = jf.jfName + "\x00" + generators.jvm.JvmSignature.jsigKey(sigKey);
					if (!knownSigs.exists(key)) {
						knownSigs.set(key, jf);
						fields.push(convertField(ctx, true, jc, isInterface, jf, p));
					}
				}
			}
			for (jf in jc.jcFields) {
				if (shouldGenerate(jf)) {
					if (!knownNames.exists(jf.jfName)) {
						knownNames.set(jf.jfName, jf);
						fields.push(convertField(ctx, false, jc, isInterface, jf, p));
					}
				}
			}
		}
		var className = PathConverter.jnameToHx(jc.jcPath.name).name;
		addMeta(Converter.meta(MetaTag.Native, vector({expr: EConst(String(sJPath(jc.jcPath), SDoubleQuotes)), pos: p}), p));
		if (isAnnotation) {
			var args:Vector<Expr> = switch extractRetentionPolicy(jc.jcAttributes) {
				case null:
					vector();
				case v:
					vector({expr: EConst(String(v, SDoubleQuotes)), pos: p});
			}
			addMeta(Converter.meta(MetaTag.Annotation, args, p));
		}
		var hasFiAnnotation = false;
		for (attr in jc.jcAttributes) switch attr {
			case AttrVisibleAnnotations(ann):
				for (a in ann) switch a.annType {
					case JObject({pack: ["java", "lang"], name: "FunctionalInterface"}, []):
						hasFiAnnotation = true;
					case _:
				}
			case _:
		}
		/* Match javac's SAM rule: an interface is functional if it declares exactly
			 one abstract instance method (ignoring static/default/private/synthetic
			 methods, constructors, and Object members re-declared as abstract). The
			 @FunctionalInterface annotation is advisory in javac — Android SDK
			 listeners are rarely annotated, so structural detection unlocks lambdas
			 for them without per-extern opt-in. */
		/* JLS §9.8 excludes methods that would be members of Object from the SAM
			 count. Match by name+arity rather than full descriptor — equals's exact
			 param encoding can vary across class-file shapes (raw Object, generic
			 erasure variants), and equals/hashCode/toString have unique arities on
			 java.lang.Object so name+arity is unambiguous. */
		function isObjectRedeclaration(jf:JField):Bool {
			return switch [jf.jfName, jf.jfDescriptor] {
				case ["equals", JMethod([_], _)]: true;
				case ["hashCode", JMethod([], _)]: true;
				case ["toString", JMethod([], _)]: true;
				case _: false;
			}
		}
		/* Skip JDK-internal packages: sun.*, com.sun.*, jdk.internal.*. They host
			 many single-method classes (sun.reflect.ConstructorAccessor,
			 sun.nio.ch.Interruptible, sun.reflect.generics.tree.TypeTree, ...) that
			 compile-time externs see but the runtime JDK may not expose — sun.* was
			 moved to jdk.internal.* in JDK 9+ and is inaccessible to app code.
			 Auto-tagging them as functional interfaces makes the JFI matcher emit
			 `implements sun.reflect.ConstructorAccessor` on every matching closure,
			 which then fails to defineClass at runtime. User code can't target these
			 anyway, so structural detection must skip them. The @FunctionalInterface
			 annotation path is still honored (none of the affected JDK-internal
			 classes carry it, so this is a safe restriction). */
		function isJdkInternalPackage(pack:Array<String>):Bool {
			return (pack.length >= 1 && pack[0] == "sun") || (pack.length >= 2 && pack[0] == "com" && pack[1] == "sun")
				|| (pack.length >= 2 && pack[0] == "jdk" && pack[1] == "internal");
		}
		var isStructuralSam = isInterface && !isJdkInternalPackage(jc.jcPath.pack) && {
			var count = 0;
			for (jf in jc.jcMethods) {
				if (AccessFlags.hasFlag(jf.jfFlags, MAbstract)
					&& !AccessFlags.hasFlag(jf.jfFlags, MStatic)
					&& !AccessFlags.hasFlag(jf.jfFlags, MPrivate)
					&& !AccessFlags.hasFlag(jf.jfFlags, MSynthetic)
					&& jf.jfName != "<init>"
					&& !isObjectRedeclaration(jf)) count = count + 1;
			}
			count == 1;
		};
		if (hasFiAnnotation || isStructuralSam) addMeta(Converter.meta(MetaTag.FunctionalInterface, vector(), p));
		var d:ClassDefinition = {
			name: {name: className, pos: p},
			doc: null,
			params: Vector.fromArrayCopy(jc.jcTypes.map(function(tp) return convertTypeParameter(ctx, tp, p))),
			meta: meta,
			flags: Vector.fromArrayCopy(flags),
			data: Vector.fromArrayCopy(fields.copy()),
		};
		return {definition: EClass(d), pos: p};
	}

	public static function convertType(ctx:JavaLibCtx, jc:JClass, file:String):TypeDecl {
		return if (AccessFlags.hasFlag(jc.jcFlags, MEnum)) convertEnum(jc, file) else convertClass(ctx, jc, file);
	}

	public static function convertModule(pack:Array<String>, jcs:Array<{jc:JClass, file:String}>):Package {
		var types = jcs.map(function(e) {
			var ctx:JavaLibCtx = {
				typeParams: typeParamLut(new haxe.ds.StringMap(), e.jc.jcTypes),
			};
			return convertType(ctx, e.jc, e.file);
		});
		return {pack: pack, declarations: Vector.fromArrayCopy(types)};
	}
}

class JavaLibraryModern extends NativeLibraryBase implements NativeLibrary<JavaLibType, Void> {
	final com:CommonContext;
	final zip:AtomicLazy<ZipInput>;
	var cachedFiles:Array<GlobalTypePath> = [];
	// port: Hashtbl.add/find_all keyed by (pack,mname); the newest binding first.
	final modules:haxe.ds.StringMap<Array<{filename:String, entry:ZipEntry}>> = new haxe.ds.StringMap();
	var loaded = false;
	var closed = false;

	public function new(com:CommonContext, name:String, filePath:String) {
		super(name, filePath);
		this.com = com;
		zip = AtomicLazy.fromFun(function() return ZipInput.openIn(filePath));
	}

	// port: redeclared for the Eval host: as the only implementer of NativeLibrary, Eval's
	// JIT calls interface methods through this class's own prototype, which lacks
	// inherited methods ("Field index for getFilePath not found on prototype").
	override public function addFlag(flag:context.NativeLibraries.NativeLibFlags):Void super.addFlag(flag);

	override public function hasFlag(flag:context.NativeLibraries.NativeLibFlags):Bool return super.hasFlag(flag);

	override public function getName():String return super.getName();

	override public function getFilePath():String return super.getFilePath();

	static function key(path:GlobalTypePath):String return path.pack.join("/") + "#" + path.name;

	function doLoad():Void {
		for (entry in zip.force().entries) {
			var filename = entry.filename;
			if (!entry.isDirectory && StringTools.endsWith(filename, ".class")) {
				var pack = filename.split("/");
				if (pack.length == 0) continue;
				var name = pack[pack.length - 1];
				var name = name.substr(0, name.length - 6);
				var pack = pack.slice(0, pack.length - 1);
				var r = PathConverter.jpathToHx({pack: pack, name: name});
				var path = PathConverter.jpathToPath(r.pack, r.mname, r.name);
				var mname = switch r.mname {
					case null:
						cachedFiles.unshift(path);
						r.name;
					case mname: mname;
				}
				var k = key({pack: r.pack, name: mname});
				var l = modules.get(k);
				if (l == null) {
					l = [];
					modules.set(k, l);
				}
				l.unshift({filename: filename, entry: entry});
			}
		}
	}

	public function load():Void {
		if (!loaded) {
			loaded = true;
			core.Timer.time(com.timerCtx, ["jar", "load"], function(_:Null<Bool>) {
				doLoad();
				return null;
			}, null);
		}
	}

	function read(zip:ZipInput, e:{filename:String, entry:ZipEntry}):{jc:JClass, file:String} {
		return core.Timer.time(com.timerCtx, ["jar", "read"], function(_:Null<Bool>) {
			var data = zip.readEntry(e.entry);
			var jc = JReaderModern.parseClass(data);
			return {jc: jc, file: filePath + "@" + e.filename};
		}, null);
	}

	public function lookup(path:GlobalTypePath):JavaLibType return null;

	public function close():Void {
		if (!closed) {
			closed = true;
			zip.force().closeIn();
		}
	}

	public function listModules():Array<GlobalTypePath> return cachedFiles;

	public function build(path:GlobalTypePath, p:Pos):Null<Package> {
		function build(path:GlobalTypePath):Null<Package> {
			return if (context.Common.samePath(path, {pack: ["java", "lang"], name: "String"})) null else {
				try {
					var entries = modules.get(key(path));
					if (entries == null || entries.length == 0) throw NotFound.raise();
					var zip = zip.force();
					var jcs = entries.map(function(e) return read(zip, e));
					core.Timer.time(com.timerCtx, ["jar", "convert"], function(_:Null<Bool>) return Converter.convertModule(path.pack, jcs), null);
				} catch (_:NotFound) {
					null;
				}
			}
		}
		return build(path);
	}

	public function getData():Void {}
}

class JavaModern {
	public static function addJavaLib(com:CommonContext, name:String, std:Bool, isExtern:Bool):Void->Void {
		var file = if (sys.FileSystem.exists(name)) name else try {
			Common.findFile(com, name);
		} catch (_:NotFound) {
			try {
				Common.findFile(com, name + ".jar");
			} catch (_:NotFound) {
				throw new Failure("Java lib " + name + " not found");
			}
		}
		var javaLib = new JavaLibraryModern(com, name, file);
		if (std) javaLib.addFlag(FlagIsStd);
		if (isExtern) javaLib.addFlag(FlagIsExtern);
		com.nativeLibs.javaLibs.unshift(javaLib);
		return context.CommonCache.handleNativeLib(com, cast javaLib);
	}
}
