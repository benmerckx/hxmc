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
import generators.jvm.JvmSignature;
import generators.jvm.JvmAttribute;
import generators.jvm.JvmData;
import haxe.ds.Vector;

using core.ds.VectorTools;

enum AnnotationKind {
	AInt(i:Int);
	ADouble(f:Float);
	AString(s:String);
	ABool(b:Bool);
	AEnum(jsig:JSignature, name:String);
	AArray(l:Array<AnnotationKind>);
	AAnnotation(jsig:JSignature, a:Annotation);
	AClass(jsig:Null<JSignature>);
}

typedef Annotation = Array<{name:String, kind:AnnotationKind}>;

@:structInit class ExportConfig {
	public var exportDebug:Bool;
}

class JvmBuilder {
	public static function convertAnnotations(pool:JvmConstantPool, annotations:Array<{jsig:JSignature, a:Annotation}>):Vector<JAnnotation> {
		function processAnnotation(jsig:JSignature, l:Annotation):JAnnotation {
			var offset = pool.addString(JvmSignature.generateSignature(false, jsig));
			var l = l.mapToVector(function(e) {
				var offset = pool.addString(e.name);
				function loop(ak:AnnotationKind):JAnnotationElementValue return switch ak {
					case AInt(i32):
						{c: "I", v: ValConst(pool.add(ConstInt(i32)))};
					case ADouble(f):
						{c: "D", v: ValConst(pool.add(ConstDouble(f)))};
					case AString(s):
						{c: "s", v: ValConst(pool.addString(s))};
					case ABool(b):
						{c: "Z", v: ValConst(pool.add(ConstInt(if (b) 1 else 0)))};
					case AEnum(jsig, name):
						// port: OCaml evaluates the constructor arguments right to left
						var i2 = pool.addString(name);
						var i1 = pool.addString(JvmSignature.generateSignature(false, jsig));
						{c: "e", v: ValEnum(i1, i2)};
					case AArray(l):
						var l = l.mapToVector(function(ak) return loop(ak));
						{c: "[", v: ValArray(l)};
					case AAnnotation(jsig, a):
						var ann = processAnnotation(jsig, a);
						{c: "@", v: ValAnnotation(ann)};
					case AClass(jsig):
						{c: "c", v: ValClass(pool.addString(jsig == null ? "V" : JvmSignature.generateSignature(false, jsig)))};
				}
				return {index: offset, value: loop(e.kind)};
			});
			return {
				annType: offset,
				annElements: l
			};
		}
		return annotations.mapToVector(function(a) return processAnnotation(a.jsig, a.a));
	}
}

class BaseBuilder {
	var accessFlags = 0;
	final attributes:Array<JAttribute> = [];
	final runtimeVisibleAnnotations:Array<{jsig:JSignature, a:Annotation}> = [];
	final runtimeInvisibleAnnotations:Array<{jsig:JSignature, a:Annotation}> = [];
	var wasExported = false;

	public function new() {}

	public function addAccessFlag(i:Int):Void {
		accessFlags = i | accessFlags;
	}

	public function addAttribute(a:JAttribute):Void {
		attributes.push(a);
	}

	public function addAnnotation(path:JPath, a:Annotation, isRuntimeVisible:Bool):Void {
		(if (isRuntimeVisible) runtimeVisibleAnnotations else runtimeInvisibleAnnotations).push({jsig: JObject(path, []), a: a});
	}

	function commitAnnotations(pool:JvmConstantPool):Void {
		if (runtimeVisibleAnnotations.length > 0) {
			var a = JvmBuilder.convertAnnotations(pool, runtimeVisibleAnnotations);
			addAttribute(AttributeRuntimeVisibleAnnotations(a));
		}
		if (runtimeInvisibleAnnotations.length > 0) {
			var a = JvmBuilder.convertAnnotations(pool, runtimeInvisibleAnnotations);
			addAttribute(AttributeRuntimeInvisibleAnnotations(a));
		}
	}

	public function exportAttributes(pool:JvmConstantPool):Vector<JvmAttributeData> {
		return attributes.mapToVector(function(a) return JvmAttribute.writeAttribute(pool, a));
	}
}
