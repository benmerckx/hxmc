package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__Passwd: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvPasswdUser implements ml2hx.rt.Block {
	public final username:String;
	public final uid:ml2hx.std.Unsigned_ULong.UnsignedULongT;
	public final gid:ml2hx.std.Unsigned_ULong.UnsignedULongT;
	public final shell:ml2hx.rt.MlOption<String>;
	public final homedir:String;
	public function new(username:String, uid:ml2hx.std.Unsigned_ULong.UnsignedULongT, gid:ml2hx.std.Unsigned_ULong.UnsignedULongT, shell:ml2hx.rt.MlOption<String>, homedir:String) {
		this.username = username;
		this.uid = uid;
		this.gid = gid;
		this.shell = shell;
		this.homedir = homedir;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 5;
	public function blockField(i:Int):Dynamic return ([username, uid, gid, shell, homedir] : Array<Dynamic>)[i];
}

class Luv__Passwd {
	public static function getPasswd(a1:ml2hx.rt.Unit, ?uid:ml2hx.std.Unsigned_ULong.UnsignedULongT):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Passwd.LuvPasswdUser, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Passwd.getPasswd is not available in the generated compiler"); }
}
