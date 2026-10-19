package ml2hx.rt;

class SysBlockedIo extends MlException {
	public static final instance = new SysBlockedIo();

	public function new() super();

	public static inline function raise():SysBlockedIo
		return instance;

	override public function exnName():String
		return "Sys_blocked_io";
}
