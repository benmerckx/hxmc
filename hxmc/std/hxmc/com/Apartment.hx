package hxmc.com;

// The apartment a thread enters (Com.init): COINIT_APARTMENTTHREADED (a
// single-threaded apartment, which UI objects need: its objects are called
// on this thread, which runs a message loop) or COINIT_MULTITHREADED.
enum abstract Apartment(Int) to Int {
	var SingleThreaded = 2;
	var MultiThreaded = 0;
}
