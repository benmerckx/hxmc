package ml2hx.rt;
enum MlList<T> {
	Nil;
	Cons(head:T, tail:MlList<T>);
}
