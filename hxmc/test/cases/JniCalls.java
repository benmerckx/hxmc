package jnitest;

// The Java side of JniCalls: static and instance methods of every primitive
// type, overloads, constructors, fields, strings, boxing, exceptions.
public class JniCalls {
	public static int instances;
	public static String label = "static";
	public static final double PI = 3.25;
	public int count;
	public String name = "calls";
	public boolean flag;
	public char letter = 'x';
	public long big = 1L << 40;
	public float ratio = 0.5f;
	public byte small = -3;
	public short mid = 1234;

	public JniCalls() { instances++; }
	public JniCalls(int c) { this(); count = c; }
	public JniCalls(String n) { this(); name = n; }
	public JniCalls(String n, int c) { this(); name = n; count = c; }

	public static int add(int a, int b) { return a + b; }
	public static long mul(long a, long b) { return a * b; }
	public static double half(double d) { return d / 2; }
	public static float third(float f) { return f / 3; }
	public static boolean not(boolean b) { return !b; }
	public static byte negByte(byte b) { return (byte) -b; }
	public static char upper(char c) { return Character.toUpperCase(c); }
	public static short twice(short s) { return (short) (s * 2); }
	public static int mixed(int i, double d, boolean b, String s, long l, float f) {
		return i + (int) d + (b ? 100 : 0) + s.length() + (int) l + (int) f;
	}
	public static String greet(String s) { return "hello, " + s + " (" + s.length() + ")"; }
	public static int length(CharSequence s) { return s.length(); }
	public static String codes(String s) {
		StringBuilder b = new StringBuilder();
		for (int i = 0; i < s.length(); i++) b.append(i == 0 ? "" : " ").append(Integer.toHexString(s.charAt(i)));
		return b.toString();
	}
	public static String make(int n) {
		StringBuilder b = new StringBuilder();
		for (int i = 0; i < n; i++) b.append((char) ('a' + i % 26));
		return b.toString();
	}
	public static String nothing() { return null; }
	public static String show(int i) { return "int " + i; }
	public static String show(String s) { return "string " + s; }
	public static String show(double d) { return "double " + d; }
	public static String show(int a, int b) { return "ints " + a + " " + b; }
	public int next() { return ++count; }
	public String describe() { return name + ":" + count + " " + flag + " " + letter + " " + big + " " + ratio + " " + small + " " + mid; }
	public JniCalls self() { return this; }
	public JniCalls other() { return new JniCalls("other"); }
	public static JniCalls create(int c) { return new JniCalls(c); }
	public static String kind(Object o) { return o == null ? "null" : o.getClass().getName(); }
	public static String text(Object o) { return String.valueOf(o); }
	public static Object any(int which) {
		switch (which) {
			case 0: return 42;
			case 1: return 2.5;
			case 2: return true;
			case 3: return "str";
			case 4: return (short) 7;
			case 5: return 'c';
			default: return null;
		}
	}
	public static Integer boxed(Integer i) { return i == null ? null : i + 1; }
	public static Double boxedD(Double d) { return d == null ? null : d * 2; }
	public static Boolean boxedB(Boolean b) { return b == null ? null : !b; }
	public static void fail(String why) { throw new IllegalStateException(why); }
	public static int deep(int n) {
		if (n == 0) throw new ArithmeticException("at the bottom");
		return deep(n - 1);
	}
	public static void failCause() {
		try {
			fail("inner");
		} catch (IllegalStateException e) {
			throw new RuntimeException("outer", e);
		}
	}
}
