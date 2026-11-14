// The site's build (`node make.mjs site` passes -D site_version=<commit>): the files the
// pages fetch carry it in their address, so a deploy reaches browsers at once
// instead of after their caches expire
class Version {
	public static final ID:Null<String> = haxe.macro.Compiler.getDefine("site_version");

	public static function url(file:String):String
		return ID == null ? file : file + "?v=" + ID;
}
