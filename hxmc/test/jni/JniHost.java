package jnihost;

// The Java program that loads JniLib (hxmc's shared library) with
// System.loadLibrary and calls the Haxe object its main registered.
public class JniHost {
	public interface Handler {
		String handle(String s, int n);
	}

	static Handler handler;

	public static void register(Handler h) { handler = h; }
	public static void log(String s) { System.out.println("haxe: " + s); }
	public static String thread() {
		String n = Thread.currentThread().getName();
		return n.startsWith("Thread-") ? "an attached thread" : n;
	}

	public static void main(String[] args) throws Exception {
		System.loadLibrary("hxjni");
		System.out.println("java: loaded, a handler " + (handler != null) + ", " + handler.getClass().getName());
		System.out.println("java: " + handler.handle("ab", 3));
		Thread t = new Thread(() -> System.out.println("java: " + handler.handle("t", 2)), "worker");
		t.start();
		t.join();
		int n = 0;
		Thread[] ts = new Thread[4];
		final int[] lens = new int[4];
		for (int i = 0; i < ts.length; i++) {
			final int k = i;
			ts[i] = new Thread(() -> { for (int j = 0; j < 250; j++) lens[k] += handler.handle("x", 2).length(); }, "many-" + i);
			ts[i].start();
		}
		for (Thread x : ts) x.join();
		System.out.println("java: many calls done " + (lens[0] > 0 && lens[3] > 0));
		System.gc();
		System.out.println("java: " + handler.handle("after", 1));
		try {
			handler.handle(null, 1);
		} catch (RuntimeException e) {
			System.out.println("java: caught " + e.getClass().getName() + ": " + e.getMessage());
		}
	}
}
