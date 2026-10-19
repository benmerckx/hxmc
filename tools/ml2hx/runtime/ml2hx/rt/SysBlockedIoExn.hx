package ml2hx.rt;

// OCaml predefined exception (README).
class SysBlockedIoExn extends Exn {
	public function new() {
		super("Sys_blocked_io");
	}
	override public function structuralFields():Array<Any> return [];
}
