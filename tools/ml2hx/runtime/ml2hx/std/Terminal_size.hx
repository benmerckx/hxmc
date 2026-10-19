package ml2hx.std;

import ml2hx.rt.*;

// terminal_size (C stubs over ioctl TIOCGWINSZ): Haxe's sys API cannot ask
// the terminal its size, so it is unknown, as when output is not a terminal.
class Terminal_size {
	public static function getColumns(_:Unit):MlOption<Int63> return None;
	public static function getRows(_:Unit):MlOption<Int63> return None;
}
