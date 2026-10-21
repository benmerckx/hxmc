package core.data;

import core.Ast;
import core.Error;
import core.AstPrinter as Printer;

// port: from haxe/src/core/data/metaDataApi.ml.
class MetaDataApi {
	public static function error(s:String, pos:core.Globals.Pos):Dynamic return Error.raiseTypingError(s, pos);

	/**
		Converts metadata arguments (expr list) into an EObjectDecl expression.
		Each argument must be either:
		  - `EConst (Ident key)` which is treated as `key = true`
		  - `EBinop (OpAssign, EConst (Ident key), value)` which is treated as `key = value`
	**/
	public static function ofMetadataEntry(entry:MetadataEntry):Expr {
		var fields = entry.exprs.map(function(expr):ObjectField return switch expr.expr {
				case EConst(Ident(key)):
					{key: {name: key, pos: expr.pos, quote: NoQuotes}, expr: {expr: EConst(Ident("true")), pos: expr.pos}};
				case EBinop(OpAssign, {expr: EConst(Ident(key)), pos: kpos}, value):
					{key: {name: key, pos: kpos, quote: NoQuotes}, expr: value};
				case _:
					error('Expected identifier or identifier = value, got ${Printer.sExprInner("", expr)}', expr.pos);
			});
		return {expr: EObjectDecl(fields), pos: entry.pos};
	}
}

class MetaReaderApi {
	public static function readOptional(data:Expr, f:Expr->Void):Void {
		switch data.expr {
			case EObjectDecl([]):
			case _:
				f(data);
		}
	}

	public static function readObject(data:Expr):Array<{name:String, value:Expr}> return switch data.expr {
		case EObjectDecl(fl): [for (f in fl) {name: f.key.name, value: f.expr}];
		case _: MetaDataApi.error('Expected object, got ${Printer.sExprInner("", data)}', data.pos);
	};

	public static function readArray(data:Expr):Array<Expr> return switch data.expr {
		case EArrayDecl(l): l.toArray();
		case _: MetaDataApi.error('Expected array, got ${Printer.sExprInner("", data)}', data.pos);
	};

	public static function readString(data:Expr):String return switch data.expr {
		case EConst(String(s, _)): s;
		case _: MetaDataApi.error('Expected string, got ${Printer.sExprInner("", data)}', data.pos);
	};

	public static function readIdent(data:Expr):String return switch data.expr {
		case EConst(Ident(s)): s;
		case _: MetaDataApi.error('Expected identifier, got ${Printer.sExprInner("", data)}', data.pos);
	};

	public static function readBool(data:Expr):Bool return switch data.expr {
		case EConst(Ident("true")): true;
		case EConst(Ident("false")): false;
		case _: MetaDataApi.error('Expected bool, got ${Printer.sExprInner("", data)}', data.pos);
	};

	public static function readInt(data:Expr):Int return switch data.expr {
		case EConst(Int(s, null)):
			var value = Std.parseInt(s);
			if (value == null) MetaDataApi.error('Invalid int: $s', data.pos) else value;
		case _: MetaDataApi.error('Expected int, got ${Printer.sExprInner("", data)}', data.pos);
	};

	public static function dataToString(data:Expr):String return Printer.sExprInner("", data);
}
