package staticinitsetup;

private class Bridge extends Setup {}

class Table extends Bridge {
	public static final value = Setup.read();
}
