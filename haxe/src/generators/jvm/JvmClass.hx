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

package generators.jvm;

import generators.jvm.JvmGlobals;
import generators.jvm.JvmData;
import generators.jvm.JvmSignature;
import generators.jvm.JvmSignature.NativeSignatures.*;
import generators.jvm.JvmAttribute;
import generators.jvm.JvmBuilder;
import generators.jvm.JvmMethod;
import generators.jvm.JvmConstantPool;
import haxe.ds.Vector;

using core.ds.VectorTools;

/* High-level class builder. */
class JvmClassBuilder extends BaseBuilder {
	final pathThis:JPath;
	final pathSuper:JPath;
	final pool = new JvmConstantPool();
	final jsig:JSignature;
	var offsetThis = 0;
	var offsetSuper = 0;
	var typeParameters:Array<{name:String, jsigs:Array<JSignature>}> = [];
	var superTypeParameters:Array<JTypeArgument> = [];
	// port: OCaml lists built by prepending; index 0 is the head.
	var interfaces:Array<{path:JPath, params:Array<JTypeArgument>}> = [];
	var interfaceOffsets:Array<Int> = [];
	final fields:Array<JvmField> = [];
	final methods:Array<JvmField> = [];
	// port: the following tables are only used for lookups.
	final methodSigs:haxe.ds.StringMap<JvmMethodBuilder> = new haxe.ds.StringMap();
	final innerClasses:haxe.ds.IntMap<JvmClassBuilder> = new haxe.ds.IntMap();
	var innerClassesLength = 0;
	final typedFunctionPaths:haxe.ds.StringMap<Bool> = new haxe.ds.StringMap();
	final closureIdsPerName:haxe.ds.StringMap<Int> = new haxe.ds.StringMap();
	// port: OCaml list built by prepending; index 0 is the head.
	var spawnedMethods:Array<{jm:JvmMethodBuilder, popScope:Null<Void->Void>}> = [];
	var staticInitMethod:Null<JvmMethodBuilder> = null;
	var sourceFile:Null<String> = null;

	public function new(pathThis:JPath, pathSuper:JPath) {
		super();
		this.pathThis = pathThis;
		this.pathSuper = pathSuper;
		jsig = JObject(pathThis, []);
		offsetThis = pool.addPath(pathThis);
		offsetSuper = pool.addPath(pathSuper);
	}

	static function pathKey(p:JPath):String return p.pack.join("/") + "/" + p.name;

	public function addInterface(path:JPath, params:Array<JTypeArgument>):Void {
		interfaceOffsets.unshift(pool.addPath(path));
		interfaces.unshift({path: path, params: params});
	}

	public function setTypeParameters(sl:Array<{name:String, jsigs:Array<JSignature>}>):Void {
		typeParameters = sl;
	}

	public function setSuperParameters(params:Array<JTypeArgument>):Void {
		superTypeParameters = params;
	}

	public function addField(f:JvmField):Void {
		fields.push(f);
	}

	public function getPool():JvmConstantPool return pool;

	public function getThisPath():JPath return pathThis;

	public function getSuperPath():JPath return pathSuper;

	public function getJsig():JSignature return jsig;

	public function getOffsetThis():Int return offsetThis;

	public function getAccessFlags():Int return accessFlags;

	public function setSourceFile(file:String):Void {
		sourceFile = file;
	}

	public function getStaticInitMethod():JvmMethodBuilder {
		return switch staticInitMethod {
			case null:
				var jm = spawnMethod("<clinit>", methodSig([], null), [MStatic]);
				staticInitMethod = jm;
				jm;
			case jm:
				jm;
		}
	}

	public function hasMethod(name:String, jsig:JSignature):Bool {
		return methodSigs.exists(name + "\x00" + JvmSignature.generateMethodSignature(false, jsig));
	}

	public function getNextClosureId(name:String):Int {
		var r = closureIdsPerName.get(name);
		if (r != null) {
			r++;
			closureIdsPerName.set(name, r);
			return r;
		} else {
			var r = 0;
			closureIdsPerName.set(name, r);
			return r;
		}
	}

	public function spawnInnerClass(jm:Null<JvmMethodBuilder>, pathSuper:JPath, name:Null<String>):JvmClassBuilder {
		var path:JPath = switch name {
			case null: {pack: pathThis.pack, name: pathThis.name + "$" + innerClassesLength};
			case name: {pack: pathThis.pack, name: pathThis.name + "$" + name};
		}
		var jc = new JvmClassBuilder(path, pathSuper);
		jc.addAccessFlag(0x01);
		switch jm {
			case null:
			case jm:
				var pool = jc.getPool();
				var offsetClass = pool.addPath(pathThis);
				var offsetName = pool.addString(jm.getName());
				var offsetDesc = pool.addString(JvmSignature.generateSignature(false, jm.getJsig()));
				var offsetInfo = pool.add(ConstNameAndType(offsetName, offsetDesc));
				jc.addAttribute(AttributeEnclosingMethod(offsetClass, offsetInfo));
		}
		var offset = pool.addPath(path);
		// port: Hashtbl.add: a later binding for the same offset shadows the earlier one
		innerClasses.set(offset, jc);
		innerClassesLength++;
		switch sourceFile {
			case null:
			case file:
				jc.setSourceFile(file);
		}
		return jc;
	}

	public function addTypedFunction(path:JPath):Void {
		typedFunctionPaths.set(pathKey(path), true);
	}

	public function hasTypedFunction(path:JPath):Bool {
		return typedFunctionPaths.exists(pathKey(path));
	}

	public function spawnMethod(name:String, jsigMethod:JSignature, flags:Array<MethodAccessFlags>):JvmMethodBuilder {
		var jm = new JvmMethodBuilder(this, name, jsigMethod);
		var ssigMethod = JvmSignature.generateMethodSignature(false, jsigMethod);
		if (methodSigs.exists(name + "\x00" + ssigMethod))
			JvmGlobals.jerror('Duplicate field on class ${core.Globals.sTypePath({pack: pathThis.pack, name: pathThis.name})}: $name $ssigMethod');
		methodSigs.set(name + "\x00" + ssigMethod, jm);
		for (flag in flags) jm.addAccessFlag(MethodAccessFlagsTools.toInt(flag));
		var popScope = jm.pushScope();
		if (!jm.hasMethodFlag(MStatic))
			jm.addLocal("this", if (jm.getName() == "<init>") JUninitialized(null) else jsig, VarArgument);
		spawnedMethods.unshift({jm: jm, popScope: popScope});
		return jm;
	}

	public function spawnField(name:String, jsigMethod:JSignature, flags:Array<FieldAccessFlags>):JvmMethodBuilder {
		var jm = new JvmMethodBuilder(this, name, jsigMethod);
		for (flag in flags) jm.addAccessFlag(FieldAccessFlagsTools.toInt(flag));
		spawnedMethods.unshift({jm: jm, popScope: null});
		return jm;
	}

	function commitInnerClasses():Void {
		if (pool.getInnerClasses().length() > 0) {
			var l = pool.getInnerClasses().fold(function(k:InnerClassKey, offsetClass:Int, acc:Array<{path:JPath, name:String, offsetClass:Int}>) {
				acc.unshift({path: k.path, name: k.name, offsetClass: offsetClass});
				return acc;
			}, []);
			var l = l.mapToVector(function(e) {
				var offsetName = pool.addString(e.name);
				var inner = innerClasses.get(e.offsetClass);
				var flags = inner != null ? inner.getAccessFlags() : 9;
				var offsetOuter = pool.addPath(e.path);
				var ic:JvmInnerClass = {
					icInnerClassInfoIndex: e.offsetClass,
					icOuterClassInfoIndex: offsetOuter,
					icInnerNameIndex: offsetName,
					icInnerClassAccessFlags: flags,
				};
				return ic;
			});
			addAttribute(AttributeInnerClasses(l));
		}
	}

	function generateClassSignature():Void {
		var stl = switch typeParameters {
			case []: "";
			case params:
				var stl = params.map(function(p) {
					var jsigs = switch p.jsigs {
						case []: [objectSig];
						case _: p.jsigs;
					}
					var s = jsigs.map(function(jsig) return ":" + JvmSignature.generateSignature(true, jsig)).join("");
					return p.name + s;
				}).join("");
				"<" + stl + ">";
		}
		var ssuper = JvmSignature.generateMethodSignature(true, JObject(pathSuper, superTypeParameters));
		var sinterfaces = interfaces.map(function(i) return JvmSignature.generateMethodSignature(true, JObject(i.path, i.params))).join("");
		var s = stl + ssuper + sinterfaces;
		var offset = getPool().addString(s);
		addAttribute(AttributeSignature(offset));
	}

	public function exportClass(config:ExportConfig):JvmClassData {
		if (wasExported) throw new core.ds.Failure("assert");
		switch sourceFile {
			case null:
			case file:
				addAttribute(AttributeSourceFile(getPool().addString(file)));
		}
		switch staticInitMethod {
			case null:
			case jm:
				if (!jm.isTerminated()) jm.return_();
		}
		generateClassSignature();
		wasExported = true;
		var l = spawnedMethods.copy();
		l.reverse();
		for (e in l) {
			switch e.popScope {
				case null:
					addField(e.jm.exportField());
				case popScope:
					popScope();
					methods.push(e.jm.exportMethod(config));
			}
		}
		commitInnerClasses();
		commitAnnotations(pool);
		var attributes = exportAttributes(pool);
		var pool = pool.close();
		return {
			classMinorVersion: 0,
			classMajorVersion: 0x34,
			classConstantPool: pool,
			classAccessFlags: accessFlags,
			classThisClass: offsetThis,
			classSuperClass: offsetSuper,
			classInterfaces: Vector.fromArrayCopy(interfaceOffsets),
			classFields: Vector.fromArrayCopy(fields),
			classMethods: Vector.fromArrayCopy(methods),
			classAttributes: attributes,
		};
	}
}
