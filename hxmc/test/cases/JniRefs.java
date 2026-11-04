package jnitest;

import java.lang.ref.WeakReference;
import java.util.ArrayList;

// The Java side of JniRefs: objects Java keeps only weak references to, so
// that what keeps them is what Haxe holds (global references).
public class JniRefs {
	static final ArrayList<WeakReference<JniRefs>> watched = new ArrayList<>();
	static final JniRefs one = new JniRefs(-1);
	public static Object kept;
	public final int id;

	JniRefs(int id) { this.id = id; }

	public int id() { return id; }

	// a new object only a weak reference of Java's watches
	public static synchronized JniRefs make(int id) {
		JniRefs r = new JniRefs(id);
		watched.add(new WeakReference<>(r));
		return r;
	}

	// how many of the watched objects live after Java's collections
	public static synchronized int alive() {
		for (int i = 0; i < 3; i++) System.gc();
		int n = 0;
		for (WeakReference<JniRefs> w : watched) if (w.get() != null) n++;
		return n;
	}

	public static synchronized void forget() { watched.clear(); }

	public static JniRefs one() { return one; }

	public static void keep(Object o) { kept = o; }

	public static int idOf(JniRefs r) { return r == null ? -2 : r.id; }
}
