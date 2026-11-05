package jnitest;

import java.util.concurrent.atomic.AtomicInteger;

// The Java side of JniThreads: methods Haxe threads call at once, and Java
// threads calling a Haxe object at once.
public class JniThreads {
	static final AtomicInteger calls = new AtomicInteger();
	public final String text;

	public JniThreads(String text) { this.text = text; }

	public static JniThreads work(int id, String s) {
		calls.incrementAndGet();
		return new JniThreads(s + "#" + id);
	}
	public static int calls() { return calls.get(); }
	public static int threads() { return Thread.getAllStackTraces().size(); }
	public static String self() {
		Thread t = Thread.currentThread();
		return (t.getName().startsWith("Thread-") ? "an attached thread" : t.getName()) + ", daemon " + t.isDaemon();
	}
	public static int hammer(Runnable r, int threads, int times) throws InterruptedException {
		Thread[] ts = new Thread[threads];
		for (int i = 0; i < threads; i++) {
			ts[i] = new Thread(() -> { for (int k = 0; k < times; k++) r.run(); }, "hammer-" + i);
			ts[i].start();
		}
		for (Thread t : ts) t.join();
		return threads * times;
	}
}
