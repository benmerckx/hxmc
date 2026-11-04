package jnitest;

import java.util.Arrays;

// The Java side of JniArrays: arrays of primitives, Strings and objects.
public class JniArrays {
	public int id;
	public static int[] held = {1, 2, 3, 4};

	public JniArrays(int id) { this.id = id; }

	public static int sum(int[] a) { int s = 0; for (int x : a) s += x; return s; }
	public static int[] squares(int n) { int[] r = new int[n]; for (int i = 0; i < n; i++) r[i] = i * i; return r; }
	public static double[] scale(double[] a, double k) { double[] r = a.clone(); for (int i = 0; i < r.length; i++) r[i] *= k; return r; }
	public static float[] halves(float[] a) { float[] r = a.clone(); for (int i = 0; i < r.length; i++) r[i] /= 2; return r; }
	public static boolean[] invert(boolean[] a) { boolean[] r = new boolean[a.length]; for (int i = 0; i < a.length; i++) r[i] = !a[i]; return r; }
	public static long total(long[] a) { long s = 0; for (long x : a) s += x; return s; }
	public static short[] shorts(int n) { short[] r = new short[n]; for (int i = 0; i < n; i++) r[i] = (short) (-1000 * i); return r; }
	public static char[] chars(String s) { return s.toCharArray(); }
	public static String ofChars(char[] c) { return new String(c); }
	public static byte[] reverse(byte[] b) { byte[] r = new byte[b.length]; for (int i = 0; i < b.length; i++) r[i] = b[b.length - 1 - i]; return r; }
	public static String join(String[] a) { return String.join("+", a); }
	public static String[] split(String s) { return s.split(","); }
	public static JniArrays[] many(int n) { JniArrays[] r = new JniArrays[n]; for (int i = 0; i < n; i++) r[i] = new JniArrays(i * 10); return r; }
	public static int ids(JniArrays[] a) { int s = 0; for (JniArrays x : a) s += x == null ? -1 : x.id; return s; }
	public static String kinds(Object[] a) {
		StringBuilder b = new StringBuilder();
		for (Object o : a) b.append(o == null ? "null" : o.getClass().getSimpleName()).append(' ');
		return b.toString().trim();
	}
	public static Object[] mixed() { return new Object[] {1, "two", 3.5, false, null, new JniArrays(7)}; }
	public static int[] empty() { return new int[0]; }
	public static int[] none() { return null; }
	public static int[] shared() { return held; }
	public static String heldText() { return Arrays.toString(held); }
	public static int[] big(int n) { int[] r = new int[n]; for (int i = 0; i < n; i++) r[i] = i; return r; }
	public static String strings(String[] a) { return Arrays.toString(a); }
	public static String[][] grid() { return new String[][] {{"a", "b"}, {"c"}}; }
	public static String gridText(Object[] g) { return Arrays.deepToString(g); }
}
