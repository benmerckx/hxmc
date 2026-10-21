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

package core;

import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

// port: the module Printer is AstPrinter.hx, map_expr's local functions are AstExprMapper.hx,
// unescape (and Invalid_escape_sequence) is in syntax/Lexer.hx. The functions of the module Expr
// are in the class Ast.

enum Keyword {
	Function;
	Class;
	Var;
	If;
	Else;
	While;
	Do;
	For;
	Break;
	Continue;
	Return;
	Extends;
	Implements;
	Import;
	Switch;
	Case;
	Default;
	Static;
	Public;
	Private;
	Try;
	Catch;
	New;
	This;
	Throw;
	Extern;
	Enum;
	In;
	Interface;
	Untyped;
	Cast;
	Override;
	Typedef;
	Dynamic;
	Package;
	Inline;
	Using;
	Null;
	True;
	False;
	Abstract;
	Macro;
	Final;
	Operator;
	Overload;
}

enum Binop {
	OpAdd;
	OpMult;
	OpDiv;
	OpSub;
	OpAssign;
	OpEq;
	OpNotEq;
	OpGt;
	OpGte;
	OpLt;
	OpLte;
	OpAnd;
	OpOr;
	OpXor;
	OpBoolAnd;
	OpBoolOr;
	OpShl;
	OpShr;
	OpUShr;
	OpMod;
	OpAssignOp(op:Binop);
	OpInterval;
	OpArrow;
	OpIn;
	OpNullCoal;
}

enum Unop {
	Increment;
	Decrement;
	Not;
	Neg;
	NegBits;
	Spread;
}

enum StringLiteralKind {
	SDoubleQuotes;
	SSingleQuotes;
	/* | SMarkup */
}

enum Constant {
	Int(value:String, suffix:Null<String>);
	Float(value:String, suffix:Null<String>);
	String(value:String, kind:StringLiteralKind);
	Ident(value:String);
	Regexp(pattern:String, options:String);
}

enum Token {
	Eof;
	Const(value:Constant);
	Kwd(value:Keyword);
	Comment(value:String);
	CommentLine(value:String);
	Binop(value:Binop);
	Unop(value:Unop);
	Semicolon;
	Comma;
	BrOpen;
	BrClose;
	BkOpen;
	BkClose;
	POpen;
	PClose;
	Dot;
	DblDot;
	QuestionDot;
	Arrow;
	IntInterval(value:String);
	Sharp(value:String);
	Question;
	At;
	Dollar(value:String);
	Spread;
}

enum UnopFlag {
	Prefix;
	Postfix;
}

enum WhileFlag {
	NormalWhile;
	DoWhile;
}

enum QuoteStatus {
	NoQuotes;
	DoubleQuotes;
}

enum FunctionKind {
	FKAnonymous;
	FKNamed(name:PlacedName, isInline:Bool); // bool for `inline`
	FKArrow;
}

enum DisplayKind {
	DKCall;
	DKDot;
	DKStructure;
	DKMarked;
	DKPattern(isOuter:Bool);
}

enum EFieldKind {
	EFNormal;
	EFSafe;
}

enum Access {
	APublic;
	APrivate;
	AStatic;
	AOverride;
	ADynamic;
	AInline;
	AMacro;
	AFinal;
	AExtern;
	AAbstract;
	AOverload;
	AEnum;
}

enum ClassFieldKind {
	FVar(type:Null<TypeHint>, expr:Null<Expr>);
	FFun(func:Func);
	FProp(get:PlacedName, set:PlacedName, type:Null<TypeHint>, expr:Null<Expr>);
}

enum EnumFlag {
	EPrivate;
	EExtern;
}

enum ClassFlag {
	HInterface;
	HExtern;
	HPrivate;
	HExtends(path:PlacedTypePath);
	HImplements(path:PlacedTypePath);
	HFinal;
	HAbstract;
}

enum AbstractFlag {
	AbPrivate;
	AbFrom(type:TypeHint);
	AbTo(type:TypeHint);
	AbOver(type:TypeHint);
	AbExtern;
	AbEnum;
}

enum TypedefFlag {
	TDPrivate;
	TDExtern;
}

enum ImportMode {
	INormal;
	IAsName(name:PlacedName);
	IAll;
}

@:structInit class PlacedName {
	public var name:String;
	public var pos:Pos;

	public inline function new(name:String, pos:Pos) {
		this.name = name;
		this.pos = pos;
	}

	public inline function clone():PlacedName return new PlacedName(name, pos);
}

@:structInit class TypePath {
	public var tpackage:Array<String>;
	public var tname:String;
	public var tparams:Vector<TypeParamOrConst>;
	public var tsub:Null<String>;

	public inline function new(tpackage:Array<String>, tname:String, tparams:Vector<TypeParamOrConst>, tsub:Null<String>) {
		this.tpackage = tpackage;
		this.tname = tname;
		this.tparams = tparams;
		this.tsub = tsub;
	}

	public inline function clone():TypePath return new TypePath(tpackage, tname, tparams, tsub);
}

@:structInit class PlacedTypePath {
	public var path:TypePath;
	public var posFull:Pos;
	public var posPath:Pos;

	public inline function new(path:TypePath, posFull:Pos, posPath:Pos) {
		this.path = path;
		this.posFull = posFull;
		this.posPath = posPath;
	}

	public inline function clone():PlacedTypePath return new PlacedTypePath(path, posFull, posPath);
}

@:structInit class TypeHint {
	public var type:ComplexType;
	public var pos:Pos;

	public inline function new(type:ComplexType, pos:Pos) {
		this.type = type;
		this.pos = pos;
	}

	public inline function clone():TypeHint return new TypeHint(type, pos);
}

@:structInit class MetadataEntry {
	public var meta:Dynamic;
	public var exprs:Vector<Expr>;
	public var pos:Pos;

	public inline function new(meta:Dynamic, exprs:Vector<Expr>, pos:Pos) {
		this.meta = meta;
		this.exprs = exprs;
		this.pos = pos;
	}

	public inline function clone():MetadataEntry return new MetadataEntry(meta, exprs, pos);
}

typedef Metadata = Array<MetadataEntry>;
typedef Documentation = Null<DocBlock>;

/**
	This structure represents a documentation comment of a symbol.

	Use `Ast.get_doc_text` to generate a final user-readable text for a doc_block.
**/
@:structInit class DocBlock {
	/** Contains own docs written nearby the symbol in Haxe code **/
	public var docOwn:Null<String>;

	// port: upstream's doc comment as line comments: its sample's doc comments would end a block comment.
	// This field is for docs pointed by @:inheritDoc meta.
	//
	// It's populated with `InheritDoc.build_*` functions.
	// Each string in this list is compiled of a doc a single @:inheritDoc points to.
	//
	// E.g. calling `InheritDoc.build_class_field_doc` for `field4` (from sample below)
	// will produce `doc_inherited = ["Own field3 doc"; "Own field2 doc\nOwn field1 doc"]`.
	//
	// Sample:
	// ```
	// class MyClass {
	//
	// 	/** Own field1 doc */
	// 	function field1();
	//
	// 	/** Own field2 doc */
	// 	@:inheritDoc(MyClass.field1) function field2();
	//
	// 	/** Own field3 doc */
	// 	function field2();
	//
	// 	/** Own field4 doc */
	// 	@:inheritDoc(MyClass.field3)
	// 	@:inheritDoc(MyClass.field2)
	// 	function field4();
	// }
	// ```
	public var docInherited:Array<String>;

	public inline function new(docOwn:Null<String>, docInherited:Array<String>) {
		this.docOwn = docOwn;
		this.docInherited = docInherited;
	}

	public inline function clone():DocBlock return new DocBlock(docOwn, docInherited);
}

@:structInit class Func {
	public var fParams:Vector<TypeParam>;
	public var fArgs:Vector<FuncArg>;
	public var fType:Null<TypeHint>;
	public var fExpr:Null<Expr>;

	public inline function new(fParams:Vector<TypeParam>, fArgs:Vector<FuncArg>, fType:Null<TypeHint>, fExpr:Null<Expr>) {
		this.fParams = fParams;
		this.fArgs = fArgs;
		this.fType = fType;
		this.fExpr = fExpr;
	}

	public inline function clone():Func return new Func(fParams, fArgs, fType, fExpr);
}

@:structInit class FuncArg {
	public var name:PlacedName;
	public var optional:Bool;
	public var meta:Metadata;
	public var type:Null<TypeHint>;
	public var expr:Null<Expr>;

	public inline function new(name:PlacedName, optional:Bool, meta:Metadata, type:Null<TypeHint>, expr:Null<Expr>) {
		this.name = name;
		this.optional = optional;
		this.meta = meta;
		this.type = type;
		this.expr = expr;
	}

	public inline function clone():FuncArg return new FuncArg(name, optional, meta, type, expr);
}

@:structInit class TypeParam {
	public var tpName:PlacedName;
	public var tpParams:Vector<TypeParam>;
	public var tpConstraints:Null<TypeHint>;
	public var tpDefault:Null<TypeHint>;
	public var tpMeta:Metadata;

	public inline function new(tpName:PlacedName, tpParams:Vector<TypeParam>, tpConstraints:Null<TypeHint>, tpDefault:Null<TypeHint>,
			tpMeta:Metadata) {
		this.tpName = tpName;
		this.tpParams = tpParams;
		this.tpConstraints = tpConstraints;
		this.tpDefault = tpDefault;
		this.tpMeta = tpMeta;
	}

	public inline function clone():TypeParam return new TypeParam(tpName, tpParams, tpConstraints, tpDefault, tpMeta);
}

@:structInit class ClassField {
	public var cffName:PlacedName;
	public var cffDoc:Documentation;
	public var cffPos:Pos;
	public var cffMeta:Metadata;
	public var cffAccess:Array<PlacedAccess>;
	public var cffKind:ClassFieldKind;

	public inline function new(cffName:PlacedName, cffDoc:Documentation, cffPos:Pos, cffMeta:Metadata, cffAccess:Array<PlacedAccess>,
			cffKind:ClassFieldKind) {
		this.cffName = cffName;
		this.cffDoc = cffDoc;
		this.cffPos = cffPos;
		this.cffMeta = cffMeta;
		this.cffAccess = cffAccess;
		this.cffKind = cffKind;
	}

	public inline function clone():ClassField return new ClassField(cffName, cffDoc, cffPos, cffMeta, cffAccess, cffKind);
}

@:structInit class PlacedAccess {
	public var access:Access;
	public var pos:Pos;

	public inline function new(access:Access, pos:Pos) {
		this.access = access;
		this.pos = pos;
	}

	public inline function clone():PlacedAccess return new PlacedAccess(access, pos);
}

@:structInit class EVar {
	public var evName:PlacedName;
	public var evFinal:Bool;
	public var evStatic:Bool;
	public var evType:Null<TypeHint>;
	public var evExpr:Null<Expr>;
	public var evMeta:Metadata;

	public inline function new(evName:PlacedName, evFinal:Bool, evStatic:Bool, evType:Null<TypeHint>, evExpr:Null<Expr>, evMeta:Metadata) {
		this.evName = evName;
		this.evFinal = evFinal;
		this.evStatic = evStatic;
		this.evType = evType;
		this.evExpr = evExpr;
		this.evMeta = evMeta;
	}

	public inline function clone():EVar return new EVar(evName, evFinal, evStatic, evType, evExpr, evMeta);
}

@:structInit class EnumConstructor {
	public var ecName:PlacedName;
	public var ecDoc:Documentation;
	public var ecMeta:Metadata;
	public var ecArgs:Vector<EnumConstructorArg>;
	public var ecPos:Pos;
	public var ecParams:Vector<TypeParam>;
	public var ecType:Null<TypeHint>;

	public inline function new(ecName:PlacedName, ecDoc:Documentation, ecMeta:Metadata, ecArgs:Vector<EnumConstructorArg>, ecPos:Pos,
			ecParams:Vector<TypeParam>, ecType:Null<TypeHint>) {
		this.ecName = ecName;
		this.ecDoc = ecDoc;
		this.ecMeta = ecMeta;
		this.ecArgs = ecArgs;
		this.ecPos = ecPos;
		this.ecParams = ecParams;
		this.ecType = ecType;
	}

	public inline function clone():EnumConstructor return new EnumConstructor(ecName, ecDoc, ecMeta, ecArgs, ecPos, ecParams, ecType);
}

@:structInit class EnumConstructorArg {
	public var name:String;
	public var optional:Bool;
	public var type:TypeHint;

	public inline function new(name:String, optional:Bool, type:TypeHint) {
		this.name = name;
		this.optional = optional;
		this.type = type;
	}

	public inline function clone():EnumConstructorArg return new EnumConstructorArg(name, optional, type);
}

@:structInit class Import {
	public var path:Vector<PlacedName>;
	public var mode:ImportMode;

	public inline function new(path:Vector<PlacedName>, mode:ImportMode) {
		this.path = path;
		this.mode = mode;
	}

	public inline function clone():Import return new Import(path, mode);
}

@:structInit class TypeDecl {
	public var definition:TypeDef;
	public var pos:Pos;

	public inline function new(definition:TypeDef, pos:Pos) {
		this.definition = definition;
		this.pos = pos;
	}

	public inline function clone():TypeDecl return new TypeDecl(definition, pos);
}

@:structInit class Package {
	public var pack:Array<String>;
	public var declarations:Vector<TypeDecl>;

	public inline function new(pack:Array<String>, declarations:Vector<TypeDecl>) {
		this.pack = pack;
		this.declarations = declarations;
	}

	public inline function clone():Package return new Package(pack, declarations);
}

@:structInit class Expr {
	public var expr:ExprDef;
	public var pos:Pos;

	public inline function new(expr:ExprDef, pos:Pos) {
		this.expr = expr;
		this.pos = pos;
	}

	public inline function clone():Expr return new Expr(expr, pos);
}

enum TypeParamOrConst {
	TPType(type:TypeHint);
	TPExpr(expr:Expr);
}

enum ComplexType {
	CTPath(path:PlacedTypePath);
	CTFunction(args:Vector<TypeHint>, ret:TypeHint);
	CTAnonymous(fields:Vector<ClassField>);
	CTParent(type:TypeHint);
	CTExtend(paths:Vector<PlacedTypePath>, fields:Vector<ClassField>);
	CTOptional(type:TypeHint);
	CTNamed(name:PlacedName, type:TypeHint);
	CTIntersection(types:Vector<TypeHint>);
}

enum ExprDef {
	EConst(constant:Constant);
	EArray(array:Expr, index:Expr);
	EBinop(op:Binop, left:Expr, right:Expr);
	EField(expr:Expr, field:String, kind:EFieldKind);
	EParenthesis(expr:Expr);
	EObjectDecl(fields:Vector<ObjectField>);
	EArrayDecl(values:Vector<Expr>);
	ECall(expr:Expr, args:Vector<Expr>);
	ENew(path:PlacedTypePath, args:Vector<Expr>);
	EUnop(op:Unop, flag:UnopFlag, expr:Expr);
	EVars(vars:Vector<EVar>);
	EFunction(kind:FunctionKind, func:Func);
	EBlock(exprs:Vector<Expr>);
	EFor(iterator:Expr, body:Expr);
	EIf(condition:Expr, thenExpr:Expr, elseExpr:Null<Expr>);
	EWhile(condition:Expr, body:Expr, flag:WhileFlag);
	ESwitch(expr:Expr, cases:Vector<SwitchCase>, defaultCase:Null<SwitchDefault>);
	ETry(expr:Expr, catches:Vector<Catch>);
	EReturn(expr:Null<Expr>);
	EBreak;
	EContinue;
	EUntyped(expr:Expr);
	EThrow(expr:Expr);
	ECast(expr:Expr, type:Null<TypeHint>);
	EIs(expr:Expr, type:TypeHint);
	EDisplay(expr:Expr, kind:DisplayKind);
	ETernary(condition:Expr, thenExpr:Expr, elseExpr:Expr);
	ECheckType(expr:Expr, type:TypeHint);
	EMeta(meta:MetadataEntry, expr:Expr);
}

enum TypeDef {
	EClass(definition:ClassDefinition);
	EEnum(definition:EnumDefinition);
	ETypedef(definition:TypedefDefinition);
	EAbstract(definition:AbstractDefinition);
	EStatic(definition:StaticDefinition);
	EImport(value:Import);
	EUsing(path:Vector<PlacedName>);
}

@:structInit class ObjectField {
	public var key:{var name:String; var pos:Pos; var quote:QuoteStatus;};
	public var expr:Expr;

	public inline function new(key:{var name:String; var pos:Pos; var quote:QuoteStatus;}, expr:Expr) {
		this.key = key;
		this.expr = expr;
	}

	public inline function clone():ObjectField return new ObjectField(key, expr);
}

@:structInit class SwitchCase {
	public var values:Vector<Expr>;
	public var guard:Null<Expr>;
	public var expr:Null<Expr>;
	public var pos:Pos;

	public inline function new(values:Vector<Expr>, guard:Null<Expr>, expr:Null<Expr>, pos:Pos) {
		this.values = values;
		this.guard = guard;
		this.expr = expr;
		this.pos = pos;
	}

	public inline function clone():SwitchCase return new SwitchCase(values, guard, expr, pos);
}

@:structInit class SwitchDefault {
	public var expr:Null<Expr>;
	public var pos:Pos;

	public inline function new(expr:Null<Expr>, pos:Pos) {
		this.expr = expr;
		this.pos = pos;
	}

	public inline function clone():SwitchDefault return new SwitchDefault(expr, pos);
}

@:structInit class Catch {
	public var name:PlacedName;
	public var type:Null<TypeHint>;
	public var expr:Expr;
	public var pos:Pos;

	public inline function new(name:PlacedName, type:Null<TypeHint>, expr:Expr, pos:Pos) {
		this.name = name;
		this.type = type;
		this.expr = expr;
		this.pos = pos;
	}

	public inline function clone():Catch return new Catch(name, type, expr, pos);
}

@:structInit class ClassDefinition {
	public var name:PlacedName;
	public var doc:Documentation;
	public var params:Vector<TypeParam>;
	public var meta:Metadata;
	public var flags:Vector<ClassFlag>;
	public var data:Vector<ClassField>;

	public inline function new(name:PlacedName, doc:Documentation, params:Vector<TypeParam>, meta:Metadata, flags:Vector<ClassFlag>,
			data:Vector<ClassField>) {
		this.name = name;
		this.doc = doc;
		this.params = params;
		this.meta = meta;
		this.flags = flags;
		this.data = data;
	}

	public inline function clone():ClassDefinition return new ClassDefinition(name, doc, params, meta, flags, data);
}

@:structInit class EnumDefinition {
	public var name:PlacedName;
	public var doc:Documentation;
	public var params:Vector<TypeParam>;
	public var meta:Metadata;
	public var flags:Vector<EnumFlag>;
	public var data:Vector<EnumConstructor>;

	public inline function new(name:PlacedName, doc:Documentation, params:Vector<TypeParam>, meta:Metadata, flags:Vector<EnumFlag>,
			data:Vector<EnumConstructor>) {
		this.name = name;
		this.doc = doc;
		this.params = params;
		this.meta = meta;
		this.flags = flags;
		this.data = data;
	}

	public inline function clone():EnumDefinition return new EnumDefinition(name, doc, params, meta, flags, data);
}

@:structInit class TypedefDefinition {
	public var name:PlacedName;
	public var doc:Documentation;
	public var params:Vector<TypeParam>;
	public var meta:Metadata;
	public var flags:Vector<TypedefFlag>;
	public var data:TypeHint;

	public inline function new(name:PlacedName, doc:Documentation, params:Vector<TypeParam>, meta:Metadata, flags:Vector<TypedefFlag>,
			data:TypeHint) {
		this.name = name;
		this.doc = doc;
		this.params = params;
		this.meta = meta;
		this.flags = flags;
		this.data = data;
	}

	public inline function clone():TypedefDefinition return new TypedefDefinition(name, doc, params, meta, flags, data);
}

@:structInit class AbstractDefinition {
	public var name:PlacedName;
	public var doc:Documentation;
	public var params:Vector<TypeParam>;
	public var meta:Metadata;
	public var flags:Vector<AbstractFlag>;
	public var data:Vector<ClassField>;

	public inline function new(name:PlacedName, doc:Documentation, params:Vector<TypeParam>, meta:Metadata, flags:Vector<AbstractFlag>,
			data:Vector<ClassField>) {
		this.name = name;
		this.doc = doc;
		this.params = params;
		this.meta = meta;
		this.flags = flags;
		this.data = data;
	}

	public inline function clone():AbstractDefinition return new AbstractDefinition(name, doc, params, meta, flags, data);
}

@:structInit class StaticDefinition {
	public var name:PlacedName;
	public var doc:Documentation;
	public var params:Vector<TypeParam>;
	public var meta:Metadata;
	public var flags:Vector<PlacedAccess>;
	public var data:ClassFieldKind;

	public inline function new(name:PlacedName, doc:Documentation, params:Vector<TypeParam>, meta:Metadata, flags:Vector<PlacedAccess>,
			data:ClassFieldKind) {
		this.name = name;
		this.doc = doc;
		this.params = params;
		this.meta = meta;
		this.flags = flags;
		this.data = data;
	}

	public inline function clone():StaticDefinition return new StaticDefinition(name, doc, params, meta, flags, data);
}

class Ast {
	// port: Expr.dump_with_pos
	public static function dumpWithPos(e:Expr):String {
		var buf = new StringBuf();
		inline function line(tabs:String, p:Pos,
				s:String):Void buf.add(StringTools.lpad(Std.string(p.pmin), " ", 4)
				+ "-"
				+ StringTools.lpad(Std.string(p.pmax), " ", 4)
				+ " "
				+ tabs
				+ s
				+ "\n");
		function walk(tabs:String, e:Expr):Void {
			inline function add(s:String):Void line(tabs, e.pos, s);
			inline function loop(e:Expr):Void walk(tabs + "  ", e);
			switch e.expr {
				case EConst(c):
					add(sConstant(c));
				case EArray(a, b):
					add("EArray");
					loop(a);
					loop(b);
				case EBinop(op, a, b):
					add("EBinop " + sBinop(op));
					loop(a);
					loop(b);
				case EField(a, name, _):
					add("EField " + name);
					loop(a);
				case EParenthesis(a):
					add("EParenthesis");
					loop(a);
				case EObjectDecl(fl):
					add("EObjectDecl");
					for (f in fl) {
						line(tabs, f.key.pos, f.key.name);
						loop(f.expr);
					}
				case EArrayDecl(el):
					add("EArrayDecl");
					for (a in el) loop(a);
				case ECall(a, el):
					add("ECall");
					loop(a);
					for (a in el) loop(a);
				case ENew(tp, el):
					add("ENew " + Globals.sTypePath({pack: tp.path.tpackage, name: tp.path.tname}));
					for (a in el) loop(a);
				case EUnop(op, _, a):
					add("EUnop " + sUnop(op));
					loop(a);
				case EVars(vl):
					add("EVars");
					for (v in vl) {
						add(tabs + "  " + v.evName.name + (v.evType == null ? "" : ":" + AstPrinter.sComplexType("", v.evType.type)));
						if (v.evExpr != null) walk(tabs + "      ", v.evExpr);
					}
				case EFunction(_, f):
					add("EFunction");
					if (f.fExpr != null) loop(f.fExpr);
				case EBlock(el):
					add("EBlock");
					for (a in el) loop(a);
				case EFor(a, b):
					add("EFor");
					loop(a);
					loop(b);
				case EIf(a, b, c):
					add("EIf");
					loop(a);
					loop(b);
					if (c != null) loop(c);
				case EWhile(a, b, _):
					add("EWhile");
					loop(a);
					loop(b);
				case ESwitch(a, cases, def):
					add("ESwitch");
					loop(a);
					for (c in cases) {
						for (a in c.values) walk(tabs + "    ", a);
						if (c.expr != null) walk(tabs + "      ", c.expr);
					}
					if (def != null && def.expr != null) walk(tabs + "      ", def.expr);
				case ETry(a, catches):
					add("ETry");
					loop(a);
					for (c in catches) walk(tabs + "    ", c.expr);
				case EReturn(a):
					add("EReturn");
					if (a != null) loop(a);
				case EBreak:
					add("EBreak");
				case EContinue:
					add("EContinue");
				case EUntyped(a):
					add("EUntyped");
					loop(a);
				case EThrow(a):
					add("EThrow");
					loop(a);
				case ECast(a, _):
					add("ECast");
					loop(a);
				case EIs(a, _):
					add("EIs");
					loop(a);
				case EDisplay(a, k):
					add("EDisplay " + sDisplayKind(k));
					loop(a);
				case ETernary(a, b, c):
					add("ETernary");
					loop(a);
					loop(b);
					loop(c);
				case ECheckType(a, _):
					add("ECheckType");
					loop(a);
				case EMeta(m, a):
					add("EMeta " + core.Meta.toString(m.meta));
					loop(a);
			}
		}
		walk("", e);
		return buf.toString();
	}

	// port: mk_evar with the optional arguments last; mkEVar takes them in upstream order.
	public static function mkEvar(name:PlacedName, ?type:TypeHint, ?expr:Expr, ?meta:Metadata, isFinal:Bool = false,
			isStatic:Bool = false):EVar return {
			evName: name,
			evFinal: isFinal,
			evStatic: isStatic,
			evType: type,
			evExpr: expr,
			evMeta: meta == null ? [] : meta
		};

	/* Type path related functions */

	public static function stringPosListOfExprPathRaise(e:Expr):Array<PlacedName> return switch e.expr {
		case EConst(Ident(name)): ([{name: name, pos: e.pos}] : Array<core.Ast.PlacedName>);
		case EField(inner, name, _): ([{name: name, pos: e.pos}] : Array<core.Ast.PlacedName>).concat(stringPosListOfExprPathRaise(inner)); /* wrong p? */
		case _: throw core.ds.Exit.raise();
	};

	public static function fullDotPath2(mpath:GlobalTypePath,
			tpath:GlobalTypePath):Array<String> return core.ds.Key.compare(mpath,
			tpath) == 0 ? tpath.pack.concat([tpath.name]) : mpath.pack.concat([mpath.name, tpath.name]);

	public static function iterExpr(loop:Expr->Void, e:Expr):Void {
		inline function opt(e:Null<Expr>):Void if (e != null) loop(e);
		switch e.expr {
			case EConst(_) | EContinue | EBreak | EReturn(null):
			case EParenthesis(e) | EField(e, _, _) | EUnop(_, _, e) | EReturn(e) | EThrow(e) | EMeta(_, e) | ECheckType(e, _) |
				EDisplay(e, _) | ECast(e, _) | EIs(e, _) | EUntyped(e):
				loop(e);
			case EArray(a, b) | EBinop(_, a, b) | EFor(a, b) | EWhile(a, b, _) | EIf(a, b, null):
				loop(a);
				loop(b);
			case ETernary(a, b, c) | EIf(a, b, c):
				loop(a);
				loop(b);
				loop(c);
			case EArrayDecl(el) | ENew(_, el) | EBlock(el):
				for (e in el) loop(e);
			case ECall(e, el):
				loop(e);
				for (e in el) loop(e);
			case EObjectDecl(fields):
				for (f in fields) loop(f.expr);
			case ETry(e, catches):
				loop(e);
				for (c in catches) loop(c.expr);
			case ESwitch(e, cases, def):
				loop(e);
				for (c in cases) {
					for (e in c.values) loop(e);
					opt(c.guard);
					opt(c.expr);
				}
				if (def != null) opt(def.expr);
			case EFunction(_, f):
				for (a in f.fArgs) opt(a.expr);
				opt(f.fExpr);
			case EVars(vars):
				for (v in vars) opt(v.evExpr);
		}
	}

	public static function exists(check:ExprDef->Bool, e:Expr):Bool {
		function loop(e:Expr):Void {
			if (check(e.expr)) throw core.ds.Exit.raise();
			iterExpr(loop, e);
		}
		try {
			loop(e);
			return false;
		} catch (_:core.ds.Exit) {
			return true;
		}
	}

	public static function safeForAll2<A, B>(f:A->B->Bool, a:Array<A>, b:Array<B>):Bool {
		// port: List.for_all2 raises Invalid_argument for lists of different lengths
		if (a.length != b.length) return false;
		return try {
			for (i in 0...a.length) if (!f(a[i], b[i])) return false;
			true;
		} catch (_:Dynamic) false;
	}

	public static function removeDuplicates<T>(keep:T->T->Bool, items:Array<T>):Array<T> {
		if (items.length == 0) return [];
		var first = items[0];
		return [first].concat(removeDuplicates(keep, items.slice(1).filter(item -> keep(first, item))));
	}

	// port: a StringMap in place of the PMap (callers only look values up)
	public static function getValueMeta(meta:Metadata):haxe.ds.StringMap<Expr> {
		var result = new haxe.ds.StringMap<Expr>();
		try {
			var entry = core.Meta.get(core.Meta.Value, meta);
			if (entry.exprs.length == 1) switch entry.exprs[0].expr {
				case EObjectDecl(values):
					for (value in values) result.set(value.key.name, value.expr);
				case _:
			}
		} catch (_:core.ds.NotFound) {}
		return result;
	}

	public static function matchPath(recursive:Bool, path:Array<String>, pattern:Array<String>):Bool {
		function loop(top:Bool, pi:Int, mi:Int):Bool {
			if (mi < pattern.length && pattern[mi] == "**") {
				/* trailing ** matches any remainder, at any depth */
				if (mi + 1 == pattern.length) return true;
				/* ** matches zero segments here, or one or more by consuming sl1 */
				return loop(false, pi, mi + 1) || (pi < path.length && loop(false, pi + 1, mi));
			}
			if (pi == path.length && mi == pattern.length) return true;
			/* always recurse into types of package paths */
			if (pi + 1 < path.length && mi + 1 == pattern.length && isLowerIdent(pattern[mi]) && !isLowerIdent(path[pi + 1]))
				return path[pi] == pattern[mi];
			if (pi + 1 == path.length && mi == pattern.length && top) return true;
			if (mi == pattern.length) return recursive;
			if (pi == path.length) return false;
			/* * matches exactly one segment */
			return (pattern[mi] == "*" || path[pi] == pattern[mi]) && loop(false, pi + 1, mi + 1);
		}
		return loop(true, 0, 0);
	}

	public static function getMetaString(meta:Metadata, key:core.MetaList.StrictMeta):Null<String> {
		for (entry in meta) if (core.Meta.has(key, [entry]) && entry.exprs.length == 1) switch entry.exprs[0].expr {
			case EConst(String(name, _)):
				return name;
			case _:
		}
		return null;
	}

	public static function mapExpr(loop:Expr->Expr, e:Expr):Expr return new AstExprMapper(loop).map(e);

	public static function mkTypePath(pack:Array<String>, name:String, ?params:Vector<TypeParamOrConst>, ?sub:String):TypePath {
		if (name == "") throw new core.ds.InvalidArgument("Empty module name is not allowed");
		return {
			tpackage: pack,
			tname: name,
			tparams: params == null ? vector() : params,
			tsub: sub
		};
	}

	public static function mkEVar(name:PlacedName, ?finalValue = false, ?staticValue = false, ?type:TypeHint, ?expr:Expr,
			?meta:Metadata):EVar
		return {
			evName: name,
			evFinal: finalValue,
			evStatic: staticValue,
			evType: type,
			evExpr: expr,
			evMeta: meta == null ? [] : meta
		};

	public static function makePtp(path:TypePath, posFull:Pos,
			?posPath:Pos):PlacedTypePath return {path: path, posFull: posFull, posPath: posPath == null ? posFull : posPath};

	public static function makePtpCt(path:TypePath, posFull:Pos, ?posPath:Pos):ComplexType return CTPath(makePtp(path, posFull, posPath));

	public static function makePtpCtNull(path:TypePath):ComplexType return CTPath(makePtp(path, Globals.nullPos));

	public static function makePtpTh(path:TypePath, posFull:Pos,
			?posPath:Pos):TypeHint return {type: makePtpCt(path, posFull, posPath), pos: posFull};

	public static function makePtpThNull(path:TypePath):TypeHint return makePtpTh(path, Globals.nullPos);

	public static function ctMono():ComplexType return makePtpCt(mkTypePath(["$"], "_hx_mono"), Globals.nullPos);

	public static inline function pos(expr:Expr):Pos return expr.pos;

	public static function docFromString(value:String):Documentation return {docOwn: value, docInherited: []};

	public static function docFromStringOpt(value:Null<String>):Documentation return value == null ? null : docFromString(value);

	/**
		Generates full doc block text out of `doc_block` structure
		by concatenating `d.doc_own` and all entries of `d.doc_inherited` with new lines
		in between.
	**/
	public static function genDocText(doc:DocBlock):String return (doc.docOwn == null ? [] : [doc.docOwn]).concat(doc.docInherited)
		.join("\n");

	public static function genDocTextOpt(doc:Documentation):Null<String> return doc == null ? null : genDocText(doc);

	public static function getOwnDocOpt(doc:Documentation):Null<String> return doc == null ? null : doc.docOwn;

	public static function isLowerIdent(value:String):Bool {
		if (value.length == 0) throw new core.ds.InvalidArgument("Identifier name must not be empty");
		var i = 0;
		while (true) {
			var c = StringTools.fastCodeAt(value, i);
			if (c >= "a".code && c <= "z".code) return true;
			if (c != "_".code) return false;
			i++;
			if (i >= value.length) return true;
		}
	}

	public static function isPostfix(op:Unop):Bool return switch op {
		case Increment | Decrement | Not: true;
		case Neg | NegBits | Spread: false;
	};

	public static function baseClassName(path:GlobalTypePath):String return path.name;

	public static function punion(a:Pos,
			b:Pos):Pos return {pfile: a.pfile, pmin: a.pmin < b.pmin ? a.pmin : b.pmin, pmax: a.pmax > b.pmax ? a.pmax : b.pmax};

	public static function punionEl(exprs:Array<Expr>):Pos {
		if (exprs.length == 0) return Globals.nullPos;
		var result = exprs[0].pos;
		for (i in 1...exprs.length) result = punion(result, exprs[i].pos);
		return result;
	}

	public static function parsePath(value:String):TypePathParts {
		// port: like the current extlib, nsplit "" is [""]: both give ([], "")
		var parts = value.split(".");
		var name = parts.pop();
		return {pack: parts, name: name};
	}

	public static function sConstant(value:Constant):String return switch value {
		case Int(v, suffix) | Float(v, suffix): v + (suffix == null ? "" : suffix);
		case String(v, kind): '"' + StringHelper.sEscape(v) + '"';
		case Ident(v): v;
		case Regexp(pattern, _): "~/" + pattern + "/";
	};

	public static function sAccess(value:Access):String return switch value {
		case APublic: "public";
		case APrivate: "private";
		case AStatic: "static";
		case AOverride: "override";
		case ADynamic: "dynamic";
		case AInline: "inline";
		case AMacro: "macro";
		case AFinal: "final";
		case AExtern: "extern";
		case AAbstract: "abstract";
		case AOverload: "overload";
		case AEnum: "enum";
	};

	public static function sKeyword(value:Keyword):String return switch value {
		case Function: "function";
		case Class: "class";
		case Var: "var";
		case If: "if";
		case Else: "else";
		case While: "while";
		case Do: "do";
		case For: "for";
		case Break: "break";
		case Continue: "continue";
		case Return: "return";
		case Extends: "extends";
		case Implements: "implements";
		case Import: "import";
		case Switch: "switch";
		case Case: "case";
		case Default: "default";
		case Static: "static";
		case Public: "public";
		case Private: "private";
		case Try: "try";
		case Catch: "catch";
		case New: "new";
		case This: "this";
		case Throw: "throw";
		case Extern: "extern";
		case Enum: "enum";
		case In: "in";
		case Interface: "interface";
		case Untyped: "untyped";
		case Cast: "cast";
		case Override: "override";
		case Typedef: "typedef";
		case Dynamic: "dynamic";
		case Package: "package";
		case Inline: "inline";
		case Using: "using";
		case Null: "null";
		case True: "true";
		case False: "false";
		case Abstract: "abstract";
		case Macro: "macro";
		case Final: "final";
		case Operator: "operator";
		case Overload: "overload";
	};

	public static function sBinop(value:Binop):String return switch value {
		case OpAdd: "+";
		case OpMult: "*";
		case OpDiv: "/";
		case OpSub: "-";
		case OpAssign: "=";
		case OpEq: "==";
		case OpNotEq: "!=";
		case OpGt: ">";
		case OpGte: ">=";
		case OpLt: "<";
		case OpLte: "<=";
		case OpAnd: "&";
		case OpOr: "|";
		case OpXor: "^";
		case OpBoolAnd: "&&";
		case OpBoolOr: "||";
		case OpShl: "<<";
		case OpShr: ">>";
		case OpUShr: ">>>";
		case OpMod: "%";
		case OpAssignOp(op): sBinop(op) + "=";
		case OpInterval: "...";
		case OpArrow: "=>";
		case OpIn: " in ";
		case OpNullCoal: "??";
	};

	public static function sUnop(value:Unop):String return switch value {
		case Increment: "++";
		case Decrement: "--";
		case Not: "!";
		case Neg: "-";
		case NegBits: "~";
		case Spread: "...";
	};

	public static function sPlacedAccess(value:PlacedAccess):String return sAccess(value.access);

	public static function sToken(t:Token):String return switch t {
		case Eof: "<end of file>";
		case Const(c): sConstant(c);
		case Kwd(k): sKeyword(k);
		case Comment(s): "/*" + s + "*/";
		case CommentLine(s): "//" + s;
		case Binop(o): sBinop(o);
		case Unop(o): sUnop(o);
		case Semicolon: ";";
		case Comma: ",";
		case BkOpen: "[";
		case BkClose: "]";
		case BrOpen: "{";
		case BrClose: "}";
		case POpen: "(";
		case PClose: ")";
		case Dot: ".";
		case DblDot: ":";
		case QuestionDot: "?.";
		case Arrow: "->";
		case IntInterval(s): s + "...";
		case Sharp(s): "#" + s;
		case Question: "?";
		case At: "@";
		case Dollar(v): "$" + v;
		case Spread: "...";
	};

	public static function efield(e:Expr, s:String):ExprDef return EField(e, s, EFNormal);

	public static function sObjectKeyName(name:String, q:QuoteStatus):String return switch q {
		case DoubleQuotes: "\"" + StringHelper.sEscape(name) + "\"";
		case NoQuotes: name;
	};

	public static function sDisplayKind(dk:DisplayKind):String return switch dk {
		case DKCall: "DKCall";
		case DKDot: "DKDot";
		case DKStructure: "DKStructure";
		case DKMarked: "DKMarked";
		case DKPattern(_): "DKPattern";
	};

	public static function stringListOfExprPathRaise(e:Expr, ?rootCb:String->Array<String>):Array<String> return switch e.expr {
		case EConst(Ident(i)): rootCb == null ? [i] : rootCb(i);
		case EField(e, f, _): [f].concat(stringListOfExprPathRaise(e, rootCb));
		case _: throw core.ds.Exit.raise();
	};

	public static function exprOfTypePath(path:GlobalTypePath, p:Pos):Expr {
		if (path.pack.length == 0) return {expr: EConst(Ident(path.name)), pos: p};
		var e:Expr = {expr: EConst(Ident(path.pack[0])), pos: p};
		for (s in path.pack.slice(1)) e = {expr: EField(e, s, EFNormal), pos: p};
		return {expr: EField(e, path.name, EFNormal), pos: p};
	}

	/* module Expr */
	public static function ensureBlock(e:Expr):Expr return switch e.expr {
		case EBlock(_): e;
		case _: {expr: EBlock(vector(e)), pos: pos(e)};
	};

	public static function fieldAssoc(name:String, fl:Vector<ObjectField>):Expr {
		for (f in fl) if (f.key.name == name) return f.expr;
		throw core.ds.NotFound.raise();
	}

	public static function fieldMemAssoc(name:String, fl:Vector<ObjectField>):Bool {
		for (f in fl) if (f.key.name == name) return true;
		return false;
	}

	public static function findIdent(e:Expr):Null<String> return switch e.expr {
		case EConst(Ident(s)): s;
		case _: null;
	};

	public static function hasMetaOption(metas:Metadata, meta:core.MetaList.StrictMeta, s:String):Bool {
		for (entry in metas) if (core.Meta.metaEq(meta, entry.meta)) for (e in entry.exprs) switch e.expr {
			case EConst(Ident(s2)) if (s == s2):
				return true;
			case _:
		}
		return false;
	}

	public static function getMetaOptions(metas:Metadata, meta:core.MetaList.StrictMeta):Array<String> {
		for (entry in metas) if (core.Meta.metaEq(meta, entry.meta)) return [
			for (e in entry.exprs) switch e.expr {
				case EConst(Ident(s2)): s2;
				case _: continue;
			}
		];
		return [];
	}
}

typedef TypePathParts = core.Globals.GlobalTypePath;
