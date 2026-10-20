// Null access on threads (docs/hxmc.md, "Null access"): each thread's null
// accesses throw on that thread and are caught there, while the others
// allocate and collect (a 64 KB nursery: stops of the world between the
// faults); the counts are the same as on the reference's --interp.
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

class Cell {
	public var v:Int;
	public var s:String;

	public function new(v:Int) {
		this.v = v;
		s = "c" + v;
	}
}

class NullAccessThreads {
	static function nul<T>(v:T):T
		return Sys.args().length > 99 ? v : null;

	static function work(id:Int):String {
		var caught = 0, sum = 0;
		var keep:Array<Cell> = [];
		for (i in 0...3000) {
			var c:Cell = (i + id) % 4 == 0 ? nul(new Cell(i)) : new Cell(i);
			var mine = new Cell(-i);
			try {
				sum += c.v + c.s.length;
				keep.push(c);
			} catch (e:String) {
				caught++;
				keep.push(mine);
			}
			if (keep.length > 64) keep = keep.slice(32);
		}
		var check = 0;
		for (k in keep)
			check += k.s.length;
		return 'thread $id: caught $caught, sum $sum, kept ${keep.length}, check $check';
	}

	static function main() {
		var done = new Lock();
		var m = new Mutex();
		var lines = [];
		for (id in 0...4)
			Thread.create(() -> {
				var r = try work(id) catch (e:Dynamic) 'thread $id: escaped $e';
				m.acquire();
				lines.push(r);
				m.release();
				done.release();
			});
		for (_ in 0...4)
			done.wait();
		lines.sort(Reflect.compare);
		for (l in lines)
			Sys.println(l);
		Sys.println(work(4));
	}
}
