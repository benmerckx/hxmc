package core;

import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TType.TVarOrigin;
import context.Common;
import syntax.Lexer;

// port: from haxe/src/core/naming.ml.
class Naming {
	public static function displayIdentifierError(com:CommonContext, msg:String, p:Pos, ?prependMsg:String):Void {
		Common.displayError(com, (prependMsg == null ? "" : prependMsg + " ") + msg, p);
	}

	public static function checkIdentifierName(com:CommonContext, name:String, kind:String, p:Pos, ?prependMsg:String):Void {
		if (StringTools.startsWith(name, "$"))
			displayIdentifierError(com, StringHelper.capitalize(kind) + ' names starting with a dollar are not allowed: "' + name + '"',
				p, prependMsg);
		else if (!Lexer.isValidIdentifier(name))
			displayIdentifierError(com, '"' + StringHelper.sEscape(name) + '" is not a valid ' + kind + ' name.', p, prependMsg);
	}

	public static function checkFieldName(com:CommonContext, name:String, p:Pos):Void {
		// "new" is the only keyword allowed in field names
		if (name != "new") checkIdentifierName(com, name, "field", p);
	}

	// Turns the name of a variable into a valid field name, for when the compiler stores a variable in a field.
	// Generators expect field names to be valid identifiers, so they don't deal with names like the `this`
	// of abstracts. Generated variables get the same "_g" prefix that renameVars gives them, and any other
	// invalid name is prefixed with "_hx_", with invalid characters replaced. Target keywords are left
	// to the generators, like they are for user fields.
	public static function fieldNameOfVarName(name:String):String {
		var name = if (core.Globals.startsWith(name, core.Globals.genLocalPrefix.charAt(0))) "_g" + name.substr(1) else name;
		if (Lexer.isValidIdentifier(name)) return name;
		// port: String.map over the bytes: a character beyond ASCII becomes one '_' per byte of its UTF-8.
		var bytes = haxe.io.Bytes.ofString(name);
		var buf = new StringBuf();
		buf.add("_hx_");
		for (i in 0...bytes.length) {
			var c = bytes.get(i);
			buf.addChar((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code ? c : "_".code);
		}
		return buf.toString();
	}

	public static function checkUppercaseIdentifierName(com:CommonContext, name:String, kind:String, p:Pos, ?prependMsg:String):Void {
		if (name.length == 0) displayIdentifierError(com, StringHelper.capitalize(kind) + " name must not be empty.", p, prependMsg);
		else if (Ast.isLowerIdent(name)) displayIdentifierError(com,
			StringHelper.capitalize(kind) + ' name should start with an uppercase letter: "' + name + '"', p, prependMsg);
		else checkIdentifierName(com, name, kind, p, prependMsg);
	}

	public static function checkModulePath(com:CommonContext, path:GlobalTypePath, p:Pos):Void {
		var fullPath = StringHelper.sEscape(path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name);
		checkUppercaseIdentifierName(com, path.name, "module", p, 'Module "' + fullPath + '" does not have a valid name.');
		try {
			for (part in path.pack) Path.checkPackageName(part);
		} catch (e:core.ds.Failure) {
			var msg = e.message;
			Common.displayErrorExt(com,
				Error.makeError(Custom('"' + StringHelper.sEscape(path.pack.join(".")) + '" is not a valid package name:'), p,
					[Error.makeError(Custom(msg), p)]));
		}
	}

	public static function checkLocalVariableName(com:CommonContext, name:String, origin:TVarOrigin, p:Pos):Void {
		if (name == "this") return; // TODO: vars named `this` should technically be VGenerated, not VUser
		var kind = switch origin {
			case TVOLocalVariable: "variable";
			case TVOArgument: "function argument";
			case TVOForVariable: "for variable";
			case TVOPatternVariable: "pattern variable";
			case TVOCatchVariable: "catch variable";
			case TVOLocalFunction: "function";
		};
		checkIdentifierName(com, name, kind, p);
	}
}
