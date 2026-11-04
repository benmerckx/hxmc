package jnitest;

// The Java side of JniPeers: Java code calling interfaces that Haxe classes
// implement, keeping their objects, throwing and catching through them.
public class JniPeers {
	public interface Callback {
		int onEvent(String name, int value);
		String describe();
	}

	public interface Source {
		JniPeers make(int id);
		double[] values(double scale);
		Object any(Object in);
	}

	static Runnable stored;
	public final int id;

	public JniPeers(int id) { this.id = id; }

	public static void run(Runnable r) { r.run(); }
	public static int fire(Callback c, String n, int v) { return c.onEvent(n, v) + c.onEvent(n + n, v + 1); }
	public static String describe(Callback c) { return "<" + c.describe() + ">"; }
	public static String use(Source s) {
		double[] v = s.values(0.5);
		return s.make(42).id + " " + v.length + " " + v[0] + " " + s.any(7) + " " + s.any("x") + " " + s.any(null);
	}
	public static void store(Runnable r) { stored = r; }
	public static void runStored() { stored.run(); }
	public static Runnable stored() { return stored; }
	public static void drop() { stored = null; }
	public static void gc() {
		for (int i = 0; i < 3; i++) {
			System.gc();
			try { Thread.sleep(20); } catch (InterruptedException e) {}
		}
	}
	public static boolean same(Object a, Object b) { return a == b; }
	public static String className(Object o) { return o.getClass().getName(); }
	public static boolean isRunnable(Object o) { return o instanceof Runnable; }
	public static String catching(Runnable r) {
		try {
			r.run();
			return "nothing thrown";
		} catch (RuntimeException e) {
			return e.getClass().getName() + ": " + e.getMessage();
		}
	}
	public static void fail(String why) { throw new UnsupportedOperationException(why); }
	public static String onThread(Runnable r) throws InterruptedException {
		Thread t = new Thread(r, "java-caller");
		t.start();
		t.join();
		return "joined";
	}
	public static int many(Runnable[] rs, int times) {
		for (int i = 0; i < times; i++) for (Runnable r : rs) r.run();
		return rs.length;
	}
}
