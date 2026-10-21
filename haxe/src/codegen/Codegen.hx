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

import core.TType;
import core.ds.OcamlInt;
import core.ds.OcamlInt.IntParseFailure;
import core.TFunctions.*;
import core.TOther.*;
import core.Texpr.Builder;
import core.Meta;
import core.Globals.Pos;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

// port: the Str.full_split results of interpolate_code.
private enum CodePart {
	Text(value:String);
	Delim(value:String);
}

class Codegen {
	// -------------------------------------------------------------------------- //
	// TOOLS

	public static function hasProperties(c:TClass):Bool {
		for (f in c.clOrderedFields) switch f.cfKind {
			case Var({vRead: AccCall | AccPrivateCall}) | Var({vWrite: AccCall | AccPrivateCall}):
				return true;
			case _:
				if (Meta.has(core.MetaList.StrictMeta.Accessor, f.cfMeta)) return true;
		}
		return c.clSuper != null && hasProperties(c.clSuper.cls);
	}

	public static function getProperties(fields:Array<TClassField>):Array<{name:String, field:String}> {
		var acc = [];
		for (f in fields) {
			if (Meta.has(core.MetaList.StrictMeta.Accessor, f.cfMeta)) acc.unshift({name: f.cfName, field: f.cfName});
			else {
				switch f.cfKind {
					case Var({vRead: AccCall | AccPrivateCall}):
						acc.unshift({name: "get_" + f.cfName, field: "get_" + f.cfName});
					case _:
				}
				switch f.cfKind {
					case Var({vWrite: AccCall | AccPrivateCall}):
						acc.unshift({name: "set_" + f.cfName, field: "set_" + f.cfName});
					case _:
				}
			}
		}
		return acc;
	}

	// -------------------------------------------------------------------------- //
	// MISC FEATURES

	public static function isVolatile(t:T):Bool return switch t {
		case TMono(r): r.tmType != null && isVolatile(r.tmType);
		case TLazy(f): isVolatile(lazyType(f));
		case TType(t, tl): isVolatile(applyTypedef(t, tl));
		case _: false;
	};

	// port: ExtLib's Base64.str_encode writes no '=' padding.
	public static function bytesSerialize(data:haxe.io.Bytes):String return haxe.crypto.Base64.encode(data, false);

	/*
		Build a default safe-cast expression :
		{ var $t = <e>; if( Std.is($t,<t>) ) $t else throw "Class cast error"; }
	*/
	public static function defaultCast(api:BasicTypes, std:TClass, e:TExpr, texpr:ModuleType, t:T, p:Pos, vtmp:String = "$t"):TExpr {
		var v = allocVar(VGenerated, vtmp, e.etype, e.epos);
		var decl = mk(TVar(v, e), api.tvoid, p);
		var ve = mk(TLocal(v), e.etype, p);
		var te = Builder.makeTypeexpr(texpr, p);
		var is = Builder.resolveAndMakeStaticCall(std, "isOfType", vector(ve, te), p);
		var enull = Builder.makeNull(ve.etype, p);
		var eop = Builder.binop(OpEq, ve, enull, api.tbool, p);
		var condition = Builder.binop(OpBoolOr, is, eop, api.tbool, p);
		var exc = mk(TThrow(mk(TConst(TString("Class cast error")), api.tstring, p)), t, p);
		var check = mk(TIf(Builder.mkParent(condition), mk(TCast(ve, null), t, p), exc), t, p);
		return mk(TBlock(vector(decl, check, ve)), t, p);
	}

	public static function interpolateCode<A>(error:String->Pos->Void, code:String, tl:Array<A>, fString:String->Void, fExpr:A->Void,
			p:Pos):Void {
		// port: Str.full_split does not insert empty Text tokens between delimiters.
		var parts:Array<CodePart> = [], start = 0;
		for (j in 0...code.length) if (code.charAt(j) == "{" || code.charAt(j) == "}") {
			if (j > start) parts.push(Text(code.substring(start, j)));
			parts.push(Delim(code.charAt(j)));
			start = j + 1;
		}
		if (start < code.length) parts.push(Text(code.substr(start)));
		var i = 0, index = 0;
		while (index < parts.length) switch parts[index] {
			case Text(txt):
				i += txt.length;
				fString(txt);
				index++;
			case Delim("{") if (index + 2 < parts.length):
				switch [parts[index + 1], parts[index + 2]] {
					case [Text(n), Delim("}")]:
						try {
							var k = OcamlInt.parse(n);
							if (k < 0 || k >= tl.length) error("Out-of-bounds special parameter: " + n,
								{pfile: p.pfile, pmin: p.pmin + i, pmax: p.pmax});
							else fExpr(tl[k.low]);
						} catch (_:IntParseFailure) {
							fString("{" + n + "}");
						}
						i += 2 + n.length;
						index += 3;
					case _:
						fString("{");
						i++;
						index++;
				}
			case Delim(x):
				fString(x);
				i++;
				index++;
		}
	}
}

class UnificationCallback {
	public static function checkCallParams(f:TExpr->T->TExpr, el:Vector<TExpr>,
			tl:Vector<{name:String, optional:Bool, type:T}>):Vector<TExpr> {
		var result = new Vector<TExpr>(el.length);
		for (i in 0...el.length) result[i] = i < tl.length ? f(el[i], tl[i].type) : el[i];
		return result;
	}

	public static function checkCall(f:TExpr->T->TExpr, el:Vector<TExpr>, t:T):Vector<TExpr> return switch follow(t) {
		case TFun(s): checkCallParams(f, el, s.args);
		case _: el.map(function(e) return f(e, tDynamic));
	};
}

// Static extensions for classes
class ExtClass {
	public static function addStaticInit(c:TClass, cf:TClassField, e:TExpr, p:Pos):Void {
		var ethis = Builder.makeStaticThis(c, p);
		var ef = mk(TField(ethis, FStatic(c, cf)), cf.cfType, p);
		core.TOther.TClassTools.addClInit(c, mk(TBinop(OpAssign, ef, e), e.etype, p));
	}
}
