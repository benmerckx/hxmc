package core.ds;

// port: the lazy, counted token stream operations used by OCaml's Stream parsers.
// @:generic so the buffer is a typed array on static targets (HashLink
// otherwise boxes every Array<T> of a type parameter in an ArrayDyn).
@:generic
class Stream<T> {
	final produce:Int->Null<T>;
	final buffered:Array<T> = [];
	var head = 0; // port: buffered[head] is the next token: junk advances it instead of shifting
	var consumed = 0;
	var produced = 0;
	var ended = false;

	// port: Stream.from and Stream.of_list: a generic class has no statics, construct with new.
	public function new(produce:Int->Null<T>) this.produce = produce;

	public function count():Int return consumed;

	// port: (hxmc) the tokens produced and not consumed (Grammar.skipBody: none, the lexer is where the stream is)
	public function pending():Int return buffered.length - head;

	inline function fill(n:Int):Void {
		while (!ended && buffered.length - head < n) {
			var value = produce(produced);
			if (value == null) ended = true;
			else {
				buffered.push(value);
				produced++;
			}
		}
	}

	public function npeek(n:Int):Array<T> {
		fill(n);
		return buffered.slice(head, head + n);
	}

	// port: without the npeek copy: the parser peeks at every token.
	public function peek():Null<T> {
		fill(1);
		return buffered.length > head ? buffered[head] : null;
	}

	public function junk():Void {
		if (peek() != null) {
			head++;
			consumed++;
			if (head == buffered.length) {
				buffered.resize(0);
				head = 0;
			} else if (head >= 64) {
				buffered.splice(0, head);
				head = 0;
			}
		}
	}

	public function next():T {
		var value = peek();
		if (value == null) throw StreamFailure.raise();
		junk();
		return value;
	}

	public function empty():Void if (peek() != null) throw StreamFailure.raise();

	public function iter(f:T->Void):Void while (peek() != null) f(next());
}

class StreamFailure extends haxe.Exception {
	// port: shared instance; see NotFound. The parser backtracks through this constantly.
	public static final instance = new StreamFailure();

	// port: throw site helper: `throw X.raise()`. On HashLink the shared instance is
	// thrown with rethrow, which skips libhl's native stack capture per throw.
	public static inline function raise():StreamFailure {
		#if hl hl.Api.rethrow(instance); #end
		return instance;
	}

	public function new() super("Stream.Failure");
}

class StreamError extends haxe.Exception {}
