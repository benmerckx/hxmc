import p.Api.*;

// Overloaded call operators (@:op(a())) of p.Sig's abstracts, one taking a
// function called with a lambda, from a module-level function.
function run() {
	var s = sig(1);
	s(2);
	s(c -> c + 1);
	s(5);
	trace(s());
	var s = sigFirst(1);
	s(2);
	s(c -> c * 10);
	trace(s());
	var s = sigPlain("a");
	s(c -> c + "b");
	trace(s());
	var s = sigPlainFirst(7);
	s(c -> c - 1);
	s(s() + 1);
	trace(s());
}
