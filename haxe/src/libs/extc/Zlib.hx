/* zlib.h -- interface of the 'zlib' general purpose compression library
  version 1.3.1, January 22nd, 2024

  Copyright (C) 1995-2024 Jean-loup Gailly and Mark Adler

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  Jean-loup Gailly        Mark Adler
  jloup@gzip.org          madler@alumni.caltech.edu
*/

package libs.extc;

import haxe.io.Bytes;

// port: the deflate side of zlib (deflate.c, trees.c, adler32.c of zlib 1.3.1),
// which upstream reaches through haxe/libs/extc (extc_stubs.c: deflateInit2 with
// memLevel 8 and Z_DEFAULT_STRATEGY, deflate, deflateEnd). The host runtimes of
// the port have no zlib, and the SWF output must be byte-identical to the zlib
// that the reference compiler links, so this is a line-by-line translation of
// the C code paths reachable from those calls: the zlib wrapper and raw
// deflate (no gzip, no preset dictionary), the default strategy, levels 0-9. The
// ct_data unions (Freq/Code, Dad/Len) are kept as shared arrays, and sym_buf
// overlays pending_buf as in C. detect_data_type is not translated: it only
// sets strm->data_type, which nothing reads.

private enum abstract BlockState(Int) {
	var NeedMore = 0; /* block not completed, need more input or more output */
	var BlockDone = 1; /* block flush performed */
	var FinishStarted = 2; /* finish started, need only more output at next deflate */
	var FinishDone = 3; /* finish done, accept no more input or output */
}

class Zlib {
	/* Allowed flush values; see deflate() below for details */
	public static inline var Z_NO_FLUSH = 0;
	public static inline var Z_PARTIAL_FLUSH = 1;
	public static inline var Z_SYNC_FLUSH = 2;
	public static inline var Z_FULL_FLUSH = 3;
	public static inline var Z_FINISH = 4;
	public static inline var Z_BLOCK = 5;

	/* Return codes for the compression/decompression functions. */
	public static inline var Z_OK = 0;
	public static inline var Z_STREAM_END = 1;
	public static inline var Z_STREAM_ERROR = -2;
	public static inline var Z_BUF_ERROR = -5;

	static inline var MAX_MEM_LEVEL = 9;
	static inline var MIN_MATCH = 3;
	static inline var MAX_MATCH = 258;
	static inline var LENGTH_CODES = 29;
	static inline var LITERALS = 256;
	static inline var L_CODES = LITERALS + 1 + LENGTH_CODES;
	static inline var D_CODES = 30;
	static inline var BL_CODES = 19;
	static inline var HEAP_SIZE = 2 * L_CODES + 1;
	static inline var MAX_BITS = 15;
	static inline var Buf_size = 16;
	static inline var INIT_STATE = 42;
	static inline var BUSY_STATE = 113;
	static inline var FINISH_STATE = 666;
	static inline var MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1;
	static inline var WIN_INIT = MAX_MATCH;
	static inline var NIL = 0;
	static inline var TOO_FAR = 4096;
	static inline var PRESET_DICT = 0x20;
	static inline var Z_DEFLATED = 8;
	static inline var STORED_BLOCK = 0;
	static inline var STATIC_TREES = 1;
	static inline var DYN_TREES = 2;
	static inline var MAX_BL_BITS = 7;
	static inline var END_BLOCK = 256;
	static inline var REP_3_6 = 16;
	static inline var REPZ_3_10 = 17;
	static inline var REPZ_11_138 = 18;
	static inline var SMALLEST = 1;
	static inline var MAX_STORED = 65535;
	static inline var LIT_BUFS = 4;

	static final extra_lbits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
	static final extra_dbits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
	static final extra_blbits = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7];
	static final bl_order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

	/* good lazy nice chain */
	static final configuration_table:Array<Array<Int>> = [
		/* 0 */ [0, 0, 0, 0], /* store only */
		/* 1 */ [4, 4, 8, 4], /* max speed, no lazy matches */
		/* 2 */ [4, 5, 16, 8],
		/* 3 */ [4, 6, 32, 32],
		/* 4 */ [4, 4, 16, 16], /* lazy matches */
		/* 5 */ [8, 16, 32, 32],
		/* 6 */ [8, 16, 128, 128],
		/* 7 */ [8, 32, 128, 256],
		/* 8 */ [32, 128, 258, 1024],
		/* 9 */ [32, 258, 258, 4096] /* max compression */
	];

	// port: the tables of tr_static_init (trees.h upstream), built once, under a lock: like
	// ... trees.h's constants, they serve streams on several threads at once (genjvm's jar
	// ... entries).
	static final static_init_done = new haxe.atomic.AtomicBool(false);
	static final static_init_lock = new sys.thread.Mutex();
	static var static_ltree_fc:Array<Int>;
	static var static_ltree_dl:Array<Int>;
	static var static_dtree_fc:Array<Int>;
	static var static_dtree_dl:Array<Int>;
	static var _dist_code:Array<Int>;
	static var _length_code:Array<Int>;
	static var base_length:Array<Int>;
	static var base_dist:Array<Int>;

	/* stream */
	var nextIn:Bytes;
	var nextInPos:Int;
	var availIn:Int;
	var totalIn:Int;
	var nextOut:Bytes;
	var nextOutPos:Int;
	var availOut:Int;
	var totalOut:Int;
	var adler:Int;

	/* state */
	var status:Int;
	var pending_buf:Bytes;
	var pending_buf_size:Int;
	var pending_out:Int;
	var pending:Int;
	var wrap:Int;
	var last_flush:Int;
	var w_size:Int;
	var w_bits:Int;
	var w_mask:Int;
	var window:Bytes;
	var window_size:Int;
	var prev:Array<Int>;
	var head:Array<Int>;
	var ins_h:Int;
	var hash_size:Int;
	var hash_bits:Int;
	var hash_mask:Int;
	var hash_shift:Int;
	var block_start:Int;
	var match_length:Int;
	var prev_match:Int;
	var match_available:Int;
	var strstart:Int;
	// port: C leaves match_start unset until longest_match, but fill_window slides
	// ... it before (a value then never read): 0, as an Int field starts on the
	// ... static targets, not null as on Eval
	var match_start:Int = 0;
	var lookahead:Int;
	var prev_length:Int;
	var max_chain_length:Int;
	var max_lazy_match:Int;
	var level:Int;
	var good_match:Int;
	var nice_match:Int;
	var dyn_ltree_fc:Array<Int>;
	var dyn_ltree_dl:Array<Int>;
	var dyn_dtree_fc:Array<Int>;
	var dyn_dtree_dl:Array<Int>;
	var bl_tree_fc:Array<Int>;
	var bl_tree_dl:Array<Int>;
	var l_desc:TreeDesc;
	var d_desc:TreeDesc;
	var bl_desc:TreeDesc;
	var bl_count:Array<Int>;
	var heap:Array<Int>;
	var heap_len:Int;
	var heap_max:Int;
	var depth:Array<Int>;
	var sym_buf:Int; // port: offset of sym_buf in pending_buf
	var lit_bufsize:Int;
	var sym_next:Int;
	var sym_end:Int;
	var opt_len:Int;
	var static_len:Int;
	var matches:Int;
	var insert:Int;
	var bi_buf:Int;
	var bi_valid:Int;
	var high_water:Int;

	function new() {}

	static inline function newArray(n:Int):Array<Int> {
		var a = [];
		a.resize(n);
		for (i in 0...n) a[i] = 0;
		return a;
	}

	// port: sets of stream buffers (window, prev, head, pending_buf) kept from
	// deflateEnd for the next deflateInit2 of the same sizes: a JAR deflates each
	// of its thousands of members with a fresh stream, and allocating and zeroing
	// some 300 KB per stream dominated the time spent in deflate. One set per
	// stream ended and not taken again yet (up to SPARE_MAX): streams run on
	// several threads at once (genjvm's jar entries).
	static final spares:Array<SpareBuffers> = [];
	static inline final SPARE_MAX = 16;
	static final spareLock = new sys.thread.Mutex();

	function takeBuffers():Bool {
		spareLock.acquire();
		var i = spares.length - 1;
		while (i >= 0 && !(spares[i].window.length == w_size * 2 && spares[i].head.length == hash_size)) i--;
		var s = null;
		if (i >= 0) {
			s = spares[i];
			spares[i] = spares[spares.length - 1];
			spares.pop();
		}
		spareLock.release();
		if (s == null) return false;
		window = s.window;
		prev = s.prev;
		head = s.head;
		pending_buf = s.pending;
		return true;
	}

	function giveBuffers():Void {
		if (window == null) return;
		var s = new SpareBuffers(window, prev, head, pending_buf);
		spareLock.acquire();
		if (spares.length == SPARE_MAX) spares.shift();
		spares.push(s);
		spareLock.release();
	}

	/* ========================================================================= */
	// port: deflateInit2_ for method Z_DEFLATED, memLevel 8 and Z_DEFAULT_STRATEGY
	// (the only arguments extc passes).
	public static function deflateInit2(level:Int, windowBits:Int):Zlib {
		var memLevel = 8;
		var wrap = 1;
		if (level == -1) level = 6;

		if (windowBits < 0) { /* suppress zlib wrapper */
			wrap = 0;
			if (windowBits < -15) throw new core.ds.Failure("Error in `zlib_deflate_init2` (extc_stubs.c): call to `deflateInit2` failed: Z_STREAM_ERROR");
			windowBits = -windowBits;
		} else if (windowBits > 15)
			throw new core.ds.Failure("haxe-in-haxe: the gzip wrapper of deflate is not ported");
		if (memLevel < 1 || memLevel > MAX_MEM_LEVEL || windowBits < 8 || windowBits > 15 || level < 0 || level > 9)
			throw new core.ds.Failure("Error in `zlib_deflate_init2` (extc_stubs.c): call to `deflateInit2` failed: Z_STREAM_ERROR");
		if (windowBits == 8) windowBits = 9; /* until 256-byte window bug fixed */
		var s = new Zlib();
		s.status = INIT_STATE; /* to pass state test in deflateReset() */

		s.wrap = wrap;
		s.w_bits = windowBits;
		s.w_size = 1 << s.w_bits;
		s.w_mask = s.w_size - 1;

		s.hash_bits = memLevel + 7;
		s.hash_size = 1 << s.hash_bits;
		s.hash_mask = s.hash_size - 1;
		s.hash_shift = Std.int((s.hash_bits + MIN_MATCH - 1) / MIN_MATCH);

		// port: the buffers of an ended stream of the same sizes are taken again
		// (see deflateEnd); fresh ones are zeroed. C allocates them with malloc
		// and leaves window, prev and pending_buf uninitialized: what deflate
		// reads of them it has written first, and lm_init clears head.
		var reused = s.takeBuffers();
		if (!reused) {
			s.window = Bytes.alloc(s.w_size * 2);
			s.window.fill(0, s.w_size * 2, 0);
			s.prev = newArray(s.w_size);
			s.head = newArray(s.hash_size);
		}

		s.high_water = 0; /* nothing written to s->window yet */

		s.lit_bufsize = 1 << (memLevel + 6); /* 16K elements by default */

		if (!reused) {
			s.pending_buf = Bytes.alloc(s.lit_bufsize * LIT_BUFS);
			s.pending_buf.fill(0, s.lit_bufsize * LIT_BUFS, 0);
		}
		s.pending_buf_size = s.lit_bufsize * 4;

		s.sym_buf = s.lit_bufsize;
		s.sym_end = (s.lit_bufsize - 1) * 3;

		s.level = level;

		s.dyn_ltree_fc = newArray(HEAP_SIZE);
		s.dyn_ltree_dl = newArray(HEAP_SIZE);
		s.dyn_dtree_fc = newArray(2 * D_CODES + 1);
		s.dyn_dtree_dl = newArray(2 * D_CODES + 1);
		s.bl_tree_fc = newArray(2 * BL_CODES + 1);
		s.bl_tree_dl = newArray(2 * BL_CODES + 1);
		s.bl_count = newArray(MAX_BITS + 1);
		s.heap = newArray(2 * L_CODES + 1);
		s.depth = newArray(2 * L_CODES + 1);

		s.deflateReset();
		return s;
	}

	/* ========================================================================= */
	function deflateResetKeep():Void {
		totalIn = totalOut = 0;

		pending = 0;
		pending_out = 0;

		if (wrap < 0) {
			wrap = -wrap; /* was made negative by deflate(..., Z_FINISH); */
		}
		status = INIT_STATE;
		adler = 1;
		last_flush = -2;

		_tr_init();
	}

	/* ===========================================================================
	 * Initialize the "longest match" routines for a new zlib stream
	 */
	function lm_init():Void {
		window_size = 2 * w_size;

		CLEAR_HASH();

		/* Set the default configuration parameters:
		 */
		max_lazy_match = configuration_table[level][1];
		good_match = configuration_table[level][0];
		nice_match = configuration_table[level][2];
		max_chain_length = configuration_table[level][3];

		strstart = 0;
		block_start = 0;
		lookahead = 0;
		insert = 0;
		match_length = prev_length = MIN_MATCH - 1;
		match_available = 0;
		ins_h = 0;
	}

	/* ========================================================================= */
	function deflateReset():Void {
		deflateResetKeep();
		lm_init();
	}

	inline function CLEAR_HASH():Void {
		#if static
		// port: zmemzero (NIL is 0): emptied and extended again, the array is
		// zero-filled in place (Int's default value on the static targets)
		// instead of 32K bounds-checked stores per stream
		head.resize(0);
		head.resize(hash_size);
		#else
		// port: Array.resize extends with null on the dynamic targets (Eval)
		for (i in 0...hash_size) head[i] = NIL;
		#end
	}

	inline function UPDATE_HASH(h:Int, c:Int):Int return ((h << hash_shift) ^ c) & hash_mask;

	inline function INSERT_STRING(str:Int):Int {
		ins_h = UPDATE_HASH(ins_h, window.get(str + (MIN_MATCH - 1)));
		var match_head = prev[str & w_mask] = head[ins_h];
		head[ins_h] = str;
		return match_head;
	}

	inline function MAX_DIST():Int return w_size - MIN_LOOKAHEAD;

	/* ===========================================================================
	 * Slide the hash table when sliding the window down (could be avoided with 32
	 * bit values at the expense of memory usage). We slide even when level == 0 to
	 * keep the hash table consistent if we switch back to level > 0 later.
	 */
	function slide_hash():Void {
		var wsize = w_size;
		var n = hash_size;
		do {
			n--;
			var m = head[n];
			head[n] = m >= wsize ? m - wsize : NIL;
		} while (n > 0);
		n = wsize;
		do {
			n--;
			var m = prev[n];
			prev[n] = m >= wsize ? m - wsize : NIL;
			/* If n is not on any hash chain, prev[n] is garbage but
			 * its value will never be used.
			 */
		} while (n > 0);
	}

	/* ===========================================================================
	 * Read a new buffer from the current input stream, update the adler32
	 * and total number of bytes read.  All deflate() input goes through
	 * this function so some applications may wish to modify it to avoid
	 * allocating a large strm->next_in buffer and copying from it.
	 * (See also flush_pending()).
	 */
	function read_buf(buf:Bytes, pos:Int, size:Int):Int {
		var len = availIn;

		if (len > size) len = size;
		if (len == 0) return 0;

		availIn -= len;

		buf.blit(pos, nextIn, nextInPos, len);
		if (wrap == 1) {
			adler = adler32(adler, buf, pos, len);
		}
		nextInPos += len;
		totalIn += len;

		return len;
	}

	static function adler32(adler:Int, buf:Bytes, pos:Int, len:Int):Int {
		var a = adler & 0xffff;
		var b = (adler >>> 16) & 0xffff;
		for (i in pos...pos + len) {
			a = (a + buf.get(i)) % 65521;
			b = (b + a) % 65521;
		}
		return (b << 16) | a;
	}

	/* ===========================================================================
	 * Fill the window when the lookahead becomes insufficient.
	 * Updates strstart and lookahead.
	 *
	 * IN assertion: lookahead < MIN_LOOKAHEAD
	 * OUT assertions: strstart <= window_size-MIN_LOOKAHEAD
	 *    At least one byte has been read, or avail_in == 0; reads are
	 *    performed for at least two bytes (required for the zip translate_eol
	 *    option -- not supported here).
	 */
	function fill_window():Void {
		var n:Int;
		var more:Int; /* Amount of free space at the end of the window. */
		var wsize = w_size;

		do {
			more = window_size - lookahead - strstart;

			/* If the window is almost full and there is insufficient lookahead,
			 * move the upper half to the lower one to make room in the upper half.
			 */
			if (strstart >= wsize + MAX_DIST()) {
				window.blit(0, window, wsize, wsize - more);
				match_start -= wsize;
				strstart -= wsize; /* we now have strstart >= MAX_DIST */
				block_start -= wsize;
				if (insert > strstart) insert = strstart;
				slide_hash();
				more += wsize;
			}
			if (availIn == 0) break;

			n = read_buf(window, strstart + lookahead, more);
			lookahead += n;

			/* Initialize the hash value now that we have some input: */
			if (lookahead + insert >= MIN_MATCH) {
				var str = strstart - insert;
				ins_h = window.get(str);
				ins_h = UPDATE_HASH(ins_h, window.get(str + 1));
				while (insert != 0) {
					ins_h = UPDATE_HASH(ins_h, window.get(str + MIN_MATCH - 1));
					prev[str & w_mask] = head[ins_h];
					head[ins_h] = str;
					str++;
					insert--;
					if (lookahead + insert < MIN_MATCH) break;
				}
			}
			/* If the whole input has less than MIN_MATCH bytes, ins_h is garbage,
			 * but this is not important since only literal bytes will be emitted.
			 */
		} while (lookahead < MIN_LOOKAHEAD && availIn != 0);

		/* If the WIN_INIT bytes after the end of the current data have never been
		 * written, then zero those bytes in order to avoid memory check reports of
		 * the use of uninitialized (or uninitialised as Julian writes) bytes by
		 * the longest match routines.  Update the high water mark for the next
		 * time through here.  WIN_INIT is set to MAX_MATCH since the longest match
		 * routines allow scanning to strstart + MAX_MATCH, ignoring lookahead.
		 */
		if (high_water < window_size) {
			var curr = strstart + lookahead;
			var init:Int;

			if (high_water < curr) {
				/* Previous high water mark below current data -- zero WIN_INIT
				 * bytes or up to end of window, whichever is less.
				 */
				init = window_size - curr;
				if (init > WIN_INIT) init = WIN_INIT;
				window.fill(curr, init, 0);
				high_water = curr + init;
			} else if (high_water < curr + WIN_INIT) {
				/* High water mark at or above current data, but below current data
				 * plus WIN_INIT -- zero out to current data plus WIN_INIT, or up
				 * to end of window, whichever is less.
				 */
				init = curr + WIN_INIT - high_water;
				if (init > window_size - high_water) init = window_size - high_water;
				window.fill(high_water, init, 0);
				high_water += init;
			}
		}
	}

	inline function put_byte(c:Int):Void {
		pending_buf.set(pending++, c);
	}

	/* =========================================================================
	 * Put a short in the pending buffer. The 16-bit value is put in MSB order.
	 * IN assertion: the stream state is correct and there is enough room in
	 * pending_buf.
	 */
	function putShortMSB(b:Int):Void {
		put_byte((b >> 8) & 0xff);
		put_byte(b & 0xff);
	}

	/* =========================================================================
	 * Flush as much pending output as possible. All deflate() output, except for
	 * some deflate_stored() output, goes through this function so some
	 * applications may wish to modify it to avoid allocating a large
	 * strm->next_out buffer and copying into it. (See also read_buf()).
	 */
	function flush_pending():Void {
		_tr_flush_bits();
		var len = pending;
		if (len > availOut) len = availOut;
		if (len == 0) return;

		nextOut.blit(nextOutPos, pending_buf, pending_out, len);
		nextOutPos += len;
		pending_out += len;
		totalOut += len;
		availOut -= len;
		pending -= len;
		if (pending == 0) {
			pending_out = 0;
		}
	}

	static inline function RANK(f:Int):Int return (f * 2) - (f > 4 ? 9 : 0);

	/* ========================================================================= */
	// port: z_stream's next_in/avail_in/next_out/avail_out are passed in; the
	// result is the return code, and the stream counters are read back with
	// availIn/availOut as extc does.
	public function deflate(src:Bytes, spos:Int, slen:Int, dst:Bytes, dpos:Int, dlen:Int, flush:Int):Int {
		nextIn = src;
		nextInPos = spos;
		availIn = slen;
		nextOut = dst;
		nextOutPos = dpos;
		availOut = dlen;
		var old_flush:Int; /* value of flush param for previous deflate call */

		if (flush > Z_BLOCK || flush < 0) {
			return Z_STREAM_ERROR;
		}

		if (status == FINISH_STATE && flush != Z_FINISH) {
			return Z_STREAM_ERROR;
		}
		if (availOut == 0) return Z_BUF_ERROR;

		old_flush = last_flush;
		last_flush = flush;

		/* Flush as much pending output as possible */
		if (pending != 0) {
			flush_pending();
			if (availOut == 0) {
				/* Since avail_out is 0, deflate will be called again with
				 * more output space, but possibly with both pending and
				 * avail_in equal to zero. There won't be anything to do,
				 * but this is not an error situation so make sure we
				 * return OK instead of BUF_ERROR at next call of deflate:
				 */
				last_flush = -1;
				return Z_OK;
			}

			/* Make sure there is something to do and avoid duplicate consecutive
			 * flushes. For repeated and useless calls with Z_FINISH, we keep
			 * returning Z_STREAM_END instead of Z_BUF_ERROR.
			 */
		} else if (availIn == 0 && RANK(flush) <= RANK(old_flush) && flush != Z_FINISH) {
			return Z_BUF_ERROR;
		}

		/* User must not provide more input after the first FINISH: */
		if (status == FINISH_STATE && availIn != 0) {
			return Z_BUF_ERROR;
		}

		/* Write the header */
		if (status == INIT_STATE && wrap == 0) status = BUSY_STATE;
		if (status == INIT_STATE) {
			/* zlib header */
			var header = (Z_DEFLATED + ((w_bits - 8) << 4)) << 8;
			var level_flags:Int;

			if (level < 2)
				level_flags = 0;
			else if (level < 6)
				level_flags = 1;
			else if (level == 6)
				level_flags = 2;
			else
				level_flags = 3;
			header |= (level_flags << 6);
			if (strstart != 0) header |= PRESET_DICT;
			header += 31 - (header % 31);

			putShortMSB(header);

			/* Save the adler32 of the preset dictionary: */
			if (strstart != 0) {
				putShortMSB(adler >>> 16);
				putShortMSB(adler & 0xffff);
			}
			adler = 1;
			status = BUSY_STATE;

			/* Compression must start with an empty pending buffer */
			flush_pending();
			if (pending != 0) {
				last_flush = -1;
				return Z_OK;
			}
		}

		/* Start a new block or continue the current one.
		 */
		if (availIn != 0 || lookahead != 0 || (flush != Z_NO_FLUSH && status != FINISH_STATE)) {
			var bstate:BlockState;

			bstate = level == 0 ? deflate_stored(flush) : level <= 3 ? deflate_fast(flush) : deflate_slow(flush);

			if (bstate == FinishStarted || bstate == FinishDone) {
				status = FINISH_STATE;
			}
			if (bstate == NeedMore || bstate == FinishStarted) {
				if (availOut == 0) {
					last_flush = -1; /* avoid BUF_ERROR next call, see above */
				}
				return Z_OK;
				/* If flush != Z_NO_FLUSH && avail_out == 0, the next call
				 * of deflate should use the same flush parameter to make sure
				 * that the flush is complete. So we don't have to output an
				 * empty block here, this will be done at next call. This also
				 * ensures that for a very small output buffer, we emit at most
				 * one empty block.
				 */
			}
			if (bstate == BlockDone) {
				if (flush == Z_PARTIAL_FLUSH) {
					_tr_align();
				} else if (flush != Z_BLOCK) { /* FULL_FLUSH or SYNC_FLUSH */
					_tr_stored_block(null, 0, 0, 0);
					/* For a full flush, this empty block will be recognized
					 * as a special marker by inflate_sync().
					 */
					if (flush == Z_FULL_FLUSH) {
						CLEAR_HASH(); /* forget history */
						if (lookahead == 0) {
							strstart = 0;
							block_start = 0;
							insert = 0;
						}
					}
				}
				flush_pending();
				if (availOut == 0) {
					last_flush = -1; /* avoid BUF_ERROR at next call, see above */
					return Z_OK;
				}
			}
		}

		if (flush != Z_FINISH) return Z_OK;
		if (wrap <= 0) return Z_STREAM_END;

		/* Write the trailer */
		putShortMSB(adler >>> 16);
		putShortMSB(adler & 0xffff);
		flush_pending();
		/* If avail_out is zero, the application will call deflate again
		 * to flush the rest.
		 */
		if (wrap > 0) wrap = -wrap; /* write the trailer only once! */
		return pending != 0 ? Z_OK : Z_STREAM_END;
	}

	// port: the stream counters extc reads after deflate().
	public inline function getAvailIn():Int return availIn;

	public inline function getAvailOut():Int return availOut;

	/* =========================================================================
	 * For the default windowBits of 15 and memLevel of 8, this function returns a
	 * close to exact, as well as small, upper bound on the compressed size. This
	 * is an expansion of ~0.03%, plus a small constant.
	 *
	 * For any setting other than those defaults for windowBits and memLevel, one
	 * of two worst case bounds is returned. This is at most an expansion of ~4% or
	 * ~13%, plus a small constant.
	 *
	 * Both the 0.03% and 4% derive from the overhead of stored blocks. The first
	 * one is for stored blocks of 16383 bytes (memLevel == 8), whereas the second
	 * is for stored blocks of 127 bytes (the worst case memLevel == 1). The
	 * expansion results from five bytes of header for each stored block.
	 *
	 * The larger expansion of 13% results from a window size less than or equal to
	 * the symbols buffer size (windowBits <= memLevel + 7). In that case some of
	 * the data being compressed may have slid out of the sliding window, impeding
	 * a stored block from being emitted. Then the only choice is a fixed or
	 * dynamic block, where a fixed block limits the maximum expansion to 9 bits
	 * per 8-bit byte, plus 10 bits for every block. The smallest block size for
	 * which this can occur is 255 (memLevel == 2).
	 *
	 * Shifts are used to approximate divisions, for speed.
	 */
	// port: deflateStateCheck cannot fail on a Zlib object; the gzip wrapper is not ported.
	public function deflateBound(sourceLen:Int):Int {
		var fixedlen, storelen, wraplen;

		/* upper bound for fixed blocks with 9-bit literals and length 255
		   (memLevel == 2, which is the lowest that may not use stored blocks) --
		   ~13% overhead plus a small constant */
		fixedlen = sourceLen + (sourceLen >> 3) + (sourceLen >> 8) + (sourceLen >> 9) + 4;

		/* upper bound for stored blocks with length 127 (memLevel == 1) --
		   ~4% overhead plus a small constant */
		storelen = sourceLen + (sourceLen >> 5) + (sourceLen >> 7) + (sourceLen >> 11) + 7;

		/* compute wrapper length */
		switch (wrap) {
			case 0: /* raw deflate */
				wraplen = 0;
			case 1: /* zlib wrapper */
				wraplen = 6 + (strstart != 0 ? 4 : 0);
			case _: /* for compiler happiness */
				wraplen = 6;
		}

		/* if not default parameters, return one of the conservative bounds */
		if (w_bits != 15 || hash_bits != 8 + 7)
			return (w_bits <= hash_bits && level != 0 ? fixedlen : storelen) + wraplen;

		/* default settings: return tight bound for that case -- ~0.03% overhead
		   plus a small constant */
		return sourceLen + (sourceLen >> 12) + (sourceLen >> 14) + (sourceLen >> 25) + 13 - 6 + wraplen;
	}

	/* ========================================================================= */
	public function deflateEnd():Int {
		giveBuffers();
		window = null;
		prev = null;
		head = null;
		pending_buf = null;
		return Z_OK;
	}

	/* ---------------------------------------------------------------------------
	 * Set match_start to the longest match starting at the given string and
	 * return its length. Matches shorter or equal to prev_length are discarded,
	 * in which case the result is equal to prev_length and match_start is
	 * garbage.
	 * IN assertions: cur_match is the head of the hash chain for the current
	 *   string (strstart) and its distance is <= MAX_DIST, and prev_length >= 1
	 * OUT assertion: the match length is not greater than s->lookahead.
	 */
	function longest_match(cur_match:Int):Int {
		var chain_length = max_chain_length; /* max hash chain length */
		var w = window;
		var scan = strstart; /* current string */
		var match:Int; /* matched string */
		var len:Int; /* length of current match */
		var best_len = prev_length; /* best match length so far */
		var nice_match = this.nice_match; /* stop if match long enough */
		var limit = strstart > MAX_DIST() ? strstart - MAX_DIST() : NIL;
		/* Stop when cur_match becomes <= limit. To simplify the code,
		 * we prevent matches with the string of window index 0.
		 */
		var prev = this.prev;
		var wmask = w_mask;

		var strend = strstart + MAX_MATCH;
		var scan_end1 = w.get(scan + best_len - 1);
		var scan_end = w.get(scan + best_len);

		/* Do not waste too much time if we already have a good match: */
		if (prev_length >= good_match) {
			chain_length >>= 2;
		}
		/* Do not look for matches beyond the end of the input. This is necessary
		 * to make deflate deterministic.
		 */
		if (nice_match > lookahead) nice_match = lookahead;

		do {
			match = cur_match;

			/* Skip to next match if the match length cannot increase
			 * or if the match length is less than 2.  Note that the checks below
			 * for insufficient lookahead only occur occasionally for performance
			 * reasons.  Therefore uninitialized memory will be accessed, and
			 * conditional jumps will be made that depend on those values.
			 * However the length of the match is limited to the lookahead, so
			 * the output of deflate is not affected by the uninitialized values.
			 */
			// port: `continue` of the C do/while, which evaluates the loop condition.
			if (w.get(match + best_len) != scan_end
				|| w.get(match + best_len - 1) != scan_end1
				|| w.get(match) != w.get(scan)
				|| w.get(++match) != w.get(scan + 1)) {} else {

			/* The check at best_len - 1 can be removed because it will be made
			 * again later. (This heuristic is not always a win.)
			 * It is not necessary to compare scan[2] and match[2] since they
			 * are always equal when the other bytes match, given that
			 * the hash keys are equal and that HASH_BITS >= 8.
			 */
			scan += 2;
			match++;

			/* We check for insufficient lookahead only every 8th comparison;
			 * the 256th check will be made at strstart + 258.
			 */
			do {} while (w.get(++scan) == w.get(++match) && w.get(++scan) == w.get(++match)
				&& w.get(++scan) == w.get(++match) && w.get(++scan) == w.get(++match)
				&& w.get(++scan) == w.get(++match) && w.get(++scan) == w.get(++match)
				&& w.get(++scan) == w.get(++match) && w.get(++scan) == w.get(++match)
				&& scan < strend);

			len = MAX_MATCH - (strend - scan);
			scan = strend - MAX_MATCH;

			if (len > best_len) {
				match_start = cur_match;
				best_len = len;
				if (len >= nice_match) break;
				scan_end1 = w.get(scan + best_len - 1);
				scan_end = w.get(scan + best_len);
			}
			}
		} while ((cur_match = prev[cur_match & wmask]) > limit && --chain_length != 0);

		if (best_len <= lookahead) return best_len;
		return lookahead;
	}

	/* ===========================================================================
	 * Flush the current block, with given end-of-file flag.
	 * IN assertion: strstart is set to the end of the current match.
	 */
	inline function FLUSH_BLOCK_ONLY(last:Int):Void {
		_tr_flush_block(block_start >= 0 ? window : null, block_start >= 0 ? block_start : 0, strstart - block_start, last);
		block_start = strstart;
		flush_pending();
	}

	static inline function MIN(a:Int, b:Int):Int return a > b ? b : a;

	/* ===========================================================================
	 * Copy without compression as much as possible from the input stream, return
	 * the current block state.
	 *
	 * In case deflateParams() is used to later switch to a non-zero compression
	 * level, s->matches (otherwise unused when storing) keeps track of the number
	 * of hash table slides to perform. If s->matches is 1, then one hash table
	 * slide will be done when switching. If s->matches is 2, the maximum value
	 * allowed here, then the hash table will be cleared, since two or more slides
	 * is the same as a clear.
	 *
	 * deflate_stored() is written to minimize the number of times an input byte is
	 * copied. It is most efficient with large input and output buffers, which
	 * maximizes the opportunities to have a single copy from next_in to next_out.
	 */
	function deflate_stored(flush:Int):BlockState {
		/* Smallest worthy block size when not flushing or finishing. By default
		 * this is 32K. This can be as small as 507 bytes for memLevel == 1. For
		 * large input and output buffers, the stored block size will be larger.
		 */
		var min_block = MIN(pending_buf_size - 5, w_size);

		/* Copy as many min_block or larger stored blocks directly to next_out as
		 * possible. If flushing, copy the remaining available input to next_out as
		 * stored blocks, if there is enough space.
		 */
		var len:Int, left:Int, have:Int, last = 0;
		var used = availIn;
		do {
			/* Set len to the maximum size block that we can copy directly with the
			 * available input data and output space. Set left to how much of that
			 * would be copied from what's left in the window.
			 */
			len = MAX_STORED; /* maximum deflate stored block length */
			have = (bi_valid + 42) >> 3; /* number of header bytes */
			if (availOut < have) /* need room for header */
				break;
			/* maximum stored block length that will fit in avail_out: */
			have = availOut - have;
			left = strstart - block_start; /* bytes left in window */
			if (len > left + availIn) len = left + availIn; /* limit len to the input */
			if (len > have) len = have; /* limit len to the output */

			/* If the stored block would be less than min_block in length, or if
			 * unable to copy all of the available input when flushing, then try
			 * copying to the window and the pending buffer instead. Also don't
			 * write an empty block when flushing -- deflate() does that.
			 */
			if (len < min_block && ((len == 0 && flush != Z_FINISH) || flush == Z_NO_FLUSH || len != left + availIn)) break;

			/* Make a dummy stored block in pending to get the header bytes,
			 * including any pending bits. This also updates the debugging counts.
			 */
			last = flush == Z_FINISH && len == left + availIn ? 1 : 0;
			_tr_stored_block(null, 0, 0, last);

			/* Replace the lengths in the dummy stored block with len. */
			pending_buf.set(pending - 4, len & 0xff);
			pending_buf.set(pending - 3, (len >> 8) & 0xff);
			pending_buf.set(pending - 2, (~len) & 0xff);
			pending_buf.set(pending - 1, (~len >> 8) & 0xff);

			/* Write the stored block header bytes. */
			flush_pending();

			/* Copy uncompressed bytes from the window to next_out. */
			if (left != 0) {
				if (left > len) left = len;
				nextOut.blit(nextOutPos, window, block_start, left);
				nextOutPos += left;
				availOut -= left;
				totalOut += left;
				block_start += left;
				len -= left;
			}

			/* Copy uncompressed bytes directly from next_in to next_out, updating
			 * the check value.
			 */
			if (len != 0) {
				read_buf(nextOut, nextOutPos, len);
				nextOutPos += len;
				availOut -= len;
				totalOut += len;
			}
		} while (last == 0);

		/* Update the sliding window with the last s->w_size bytes of the copied
		 * data, or append all of the copied data to the existing window if less
		 * than s->w_size bytes were copied. Also update the number of bytes to
		 * insert in the hash tables, in the event that deflateParams() switches to
		 * a non-zero compression level.
		 */
		used -= availIn; /* number of input bytes directly copied */
		if (used != 0) {
			/* If any input was used, then no unused input remains in the window,
			 * therefore s->block_start == s->strstart.
			 */
			if (used >= w_size) { /* supplant the previous history */
				matches = 2; /* clear hash */
				window.blit(0, nextIn, nextInPos - w_size, w_size);
				strstart = w_size;
				insert = strstart;
			} else {
				if (window_size - strstart <= used) {
					/* Slide the window down. */
					strstart -= w_size;
					window.blit(0, window, w_size, strstart);
					if (matches < 2) matches++; /* add a pending slide_hash() */
					if (insert > strstart) insert = strstart;
				}
				window.blit(strstart, nextIn, nextInPos - used, used);
				strstart += used;
				insert += MIN(used, w_size - insert);
			}
			block_start = strstart;
		}
		if (high_water < strstart) high_water = strstart;

		/* If the last block was written to next_out, then done. */
		if (last != 0) return FinishDone;

		/* If flushing and all input has been consumed, then done. */
		if (flush != Z_NO_FLUSH && flush != Z_FINISH && availIn == 0 && strstart == block_start) return BlockDone;

		/* Fill the window with any remaining input. */
		have = window_size - strstart;
		if (availIn > have && block_start >= w_size) {
			/* Slide the window down. */
			block_start -= w_size;
			strstart -= w_size;
			window.blit(0, window, w_size, strstart);
			if (matches < 2) matches++; /* add a pending slide_hash() */
			have += w_size; /* more space now */
			if (insert > strstart) insert = strstart;
		}
		if (have > availIn) have = availIn;
		if (have != 0) {
			read_buf(window, strstart, have);
			strstart += have;
			insert += MIN(have, w_size - insert);
		}
		if (high_water < strstart) high_water = strstart;

		/* There was not enough avail_out to write a complete worthy or flushed
		 * stored block to next_out. Write a stored block to pending instead, if we
		 * have enough input for a worthy block, or if flushing and there is enough
		 * room for the remaining input as a stored block in the pending buffer.
		 */
		have = (bi_valid + 42) >> 3; /* number of header bytes */
		/* maximum stored block length that will fit in pending: */
		have = MIN(pending_buf_size - have, MAX_STORED);
		min_block = MIN(have, w_size);
		left = strstart - block_start;
		if (left >= min_block || ((left != 0 || flush == Z_FINISH) && flush != Z_NO_FLUSH && availIn == 0 && left <= have)) {
			len = MIN(left, have);
			last = flush == Z_FINISH && availIn == 0 && len == left ? 1 : 0;
			_tr_stored_block(window, block_start, len, last);
			block_start += len;
			flush_pending();
		}

		/* We've done all we can with the available input and output. */
		return last != 0 ? FinishStarted : NeedMore;
	}

	/* ===========================================================================
	 * Compress as much as possible from the input stream, return the current
	 * block state.
	 * This function does not perform lazy evaluation of matches and inserts
	 * new strings in the dictionary only for unmatched strings or for short
	 * matches. It is used only for the fast compression options.
	 */
	function deflate_fast(flush:Int):BlockState {
		var hash_head:Int; /* head of the hash chain */
		var bflush:Bool; /* set if current block must be flushed */

		while (true) {
			/* Make sure that we always have enough lookahead, except
			 * at the end of the input file. We need MAX_MATCH bytes
			 * for the next match, plus MIN_MATCH bytes to insert the
			 * string following the next match.
			 */
			if (lookahead < MIN_LOOKAHEAD) {
				fill_window();
				if (lookahead < MIN_LOOKAHEAD && flush == Z_NO_FLUSH) {
					return NeedMore;
				}
				if (lookahead == 0) break; /* flush the current block */
			}

			/* Insert the string window[strstart .. strstart + 2] in the
			 * dictionary, and set hash_head to the head of the hash chain:
			 */
			hash_head = NIL;
			if (lookahead >= MIN_MATCH) {
				hash_head = INSERT_STRING(strstart);
			}

			/* Find the longest match, discarding those <= prev_length.
			 * At this point we have always match_length < MIN_MATCH
			 */
			if (hash_head != NIL && strstart - hash_head <= MAX_DIST()) {
				/* To simplify the code, we prevent matches with the string
				 * of window index 0 (in particular we have to avoid a match
				 * of the string with itself at the start of the input file).
				 */
				match_length = longest_match(hash_head);
				/* longest_match() sets match_start */
			}
			if (match_length >= MIN_MATCH) {
				bflush = _tr_tally_dist(strstart - match_start, match_length - MIN_MATCH);

				lookahead -= match_length;

				/* Insert new strings in the hash table only if the match length
				 * is not too large. This saves time but degrades compression.
				 */
				if (match_length <= max_lazy_match /* max_insert_length */ && lookahead >= MIN_MATCH) {
					match_length--; /* string at strstart already in table */
					do {
						strstart++;
						hash_head = INSERT_STRING(strstart);
						/* strstart never exceeds WSIZE-MAX_MATCH, so there are
						 * always MIN_MATCH bytes ahead.
						 */
					} while (--match_length != 0);
					strstart++;
				} else {
					strstart += match_length;
					match_length = 0;
					ins_h = window.get(strstart);
					ins_h = UPDATE_HASH(ins_h, window.get(strstart + 1));
					/* If lookahead < MIN_MATCH, ins_h is garbage, but it does not
					 * matter since it will be recomputed at next deflate call.
					 */
				}
			} else {
				/* No match, output a literal byte */
				bflush = _tr_tally_lit(window.get(strstart));
				lookahead--;
				strstart++;
			}
			if (bflush) {
				FLUSH_BLOCK_ONLY(0);
				if (availOut == 0) return NeedMore;
			}
		}
		insert = strstart < MIN_MATCH - 1 ? strstart : MIN_MATCH - 1;
		if (flush == Z_FINISH) {
			FLUSH_BLOCK_ONLY(1);
			if (availOut == 0) return FinishStarted;
			return FinishDone;
		}
		if (sym_next != 0) {
			FLUSH_BLOCK_ONLY(0);
			if (availOut == 0) return NeedMore;
		}
		return BlockDone;
	}

	/* ===========================================================================
	 * Same as above, but achieves better compression. We use a lazy
	 * evaluation for matches: a match is finally adopted only if there is
	 * no better match at the next window position.
	 */
	function deflate_slow(flush:Int):BlockState {
		var hash_head:Int; /* head of hash chain */
		var bflush:Bool; /* set if current block must be flushed */

		/* Process the input block. */
		while (true) {
			/* Make sure that we always have enough lookahead, except
			 * at the end of the input file. We need MAX_MATCH bytes
			 * for the next match, plus MIN_MATCH bytes to insert the
			 * string following the next match.
			 */
			if (lookahead < MIN_LOOKAHEAD) {
				fill_window();
				if (lookahead < MIN_LOOKAHEAD && flush == Z_NO_FLUSH) {
					return NeedMore;
				}
				if (lookahead == 0) break; /* flush the current block */
			}

			/* Insert the string window[strstart .. strstart + 2] in the
			 * dictionary, and set hash_head to the head of the hash chain:
			 */
			hash_head = NIL;
			if (lookahead >= MIN_MATCH) {
				hash_head = INSERT_STRING(strstart);
			}

			/* Find the longest match, discarding those <= prev_length.
			 */
			prev_length = match_length;
			prev_match = match_start;
			match_length = MIN_MATCH - 1;

			if (hash_head != NIL && prev_length < max_lazy_match && strstart - hash_head <= MAX_DIST()) {
				/* To simplify the code, we prevent matches with the string
				 * of window index 0 (in particular we have to avoid a match
				 * of the string with itself at the start of the input file).
				 */
				match_length = longest_match(hash_head);
				/* longest_match() sets match_start */

				if (match_length <= 5 && (match_length == MIN_MATCH && strstart - match_start > TOO_FAR)) {
					/* If prev_match is also MIN_MATCH, match_start is garbage
					 * but we will ignore the current match anyway.
					 */
					match_length = MIN_MATCH - 1;
				}
			}
			/* If there was a match at the previous step and the current
			 * match is not better, output the previous match:
			 */
			if (prev_length >= MIN_MATCH && match_length <= prev_length) {
				var max_insert = strstart + lookahead - MIN_MATCH;
				/* Do not insert strings in hash table beyond this. */

				bflush = _tr_tally_dist(strstart - 1 - prev_match, prev_length - MIN_MATCH);

				/* Insert in hash table all strings up to the end of the match.
				 * strstart - 1 and strstart are already inserted. If there is not
				 * enough lookahead, the last two strings are not inserted in
				 * the hash table.
				 */
				lookahead -= prev_length - 1;
				prev_length -= 2;
				do {
					if (++strstart <= max_insert) {
						hash_head = INSERT_STRING(strstart);
					}
				} while (--prev_length != 0);
				match_available = 0;
				match_length = MIN_MATCH - 1;
				strstart++;

				if (bflush) {
					FLUSH_BLOCK_ONLY(0);
					if (availOut == 0) return NeedMore;
				}
			} else if (match_available != 0) {
				/* If there was no match at the previous position, output a
				 * single literal. If there was a match but the current match
				 * is longer, truncate the previous match to a single literal.
				 */
				bflush = _tr_tally_lit(window.get(strstart - 1));
				if (bflush) {
					FLUSH_BLOCK_ONLY(0);
				}
				strstart++;
				lookahead--;
				if (availOut == 0) return NeedMore;
			} else {
				/* There is no previous match to compare with, wait for
				 * the next step to decide.
				 */
				match_available = 1;
				strstart++;
				lookahead--;
			}
		}
		if (match_available != 0) {
			bflush = _tr_tally_lit(window.get(strstart - 1));
			match_available = 0;
		}
		insert = strstart < MIN_MATCH - 1 ? strstart : MIN_MATCH - 1;
		if (flush == Z_FINISH) {
			FLUSH_BLOCK_ONLY(1);
			if (availOut == 0) return FinishStarted;
			return FinishDone;
		}
		if (sym_next != 0) {
			FLUSH_BLOCK_ONLY(0);
			if (availOut == 0) return NeedMore;
		}
		return BlockDone;
	}

	/* ===========================================================================
	 * trees.c
	 * ===========================================================================
	 */
	inline function d_code(dist:Int):Int return dist < 256 ? _dist_code[dist] : _dist_code[256 + (dist >> 7)];

	inline function _tr_tally_lit(c:Int):Bool {
		pending_buf.set(sym_buf + sym_next++, 0);
		pending_buf.set(sym_buf + sym_next++, 0);
		pending_buf.set(sym_buf + sym_next++, c);
		dyn_ltree_fc[c]++;
		return sym_next == sym_end;
	}

	inline function _tr_tally_dist(distance:Int, length:Int):Bool {
		var len = length & 0xff;
		var dist = distance & 0xffff;
		pending_buf.set(sym_buf + sym_next++, dist & 0xff);
		pending_buf.set(sym_buf + sym_next++, dist >> 8);
		pending_buf.set(sym_buf + sym_next++, len);
		dist--;
		dyn_ltree_fc[_length_code[len] + LITERALS + 1]++;
		dyn_dtree_fc[d_code(dist)]++;
		return sym_next == sym_end;
	}

	/* ===========================================================================
	 * Output a short LSB first on the stream.
	 * IN assertion: there is enough room in pendingBuf.
	 */
	inline function put_short(w:Int):Void {
		put_byte(w & 0xff);
		put_byte((w & 0xffff) >> 8);
	}

	/* ===========================================================================
	 * Reverse the first len bits of a code, using straightforward code (a faster
	 * method would use a table)
	 * IN assertion: 1 <= len <= 15
	 */
	static function bi_reverse(code:Int, len:Int):Int {
		var res = 0;
		do {
			res |= code & 1;
			code >>>= 1;
			res <<= 1;
		} while (--len > 0);
		return res >>> 1;
	}

	/* ===========================================================================
	 * Flush the bit buffer, keeping at most 7 bits in it.
	 */
	function bi_flush():Void {
		if (bi_valid == 16) {
			put_short(bi_buf);
			bi_buf = 0;
			bi_valid = 0;
		} else if (bi_valid >= 8) {
			put_byte(bi_buf & 0xff);
			bi_buf >>= 8;
			bi_valid -= 8;
		}
	}

	/* ===========================================================================
	 * Flush the bit buffer and align the output on a byte boundary
	 */
	function bi_windup():Void {
		if (bi_valid > 8) {
			put_short(bi_buf);
		} else if (bi_valid > 0) {
			put_byte(bi_buf & 0xff);
		}
		bi_buf = 0;
		bi_valid = 0;
	}

	/* ===========================================================================
	 * Generate the codes for a given tree and bit counts (which need not be
	 * optimal).
	 * IN assertion: the array bl_count contains the bit length statistics for
	 * the given tree and the field len is set for all tree elements.
	 * OUT assertion: the field code is set for all tree elements of non
	 *     zero code length.
	 */
	static function gen_codes(tree_fc:Array<Int>, tree_dl:Array<Int>, max_code:Int, bl_count:Array<Int>):Void {
		var next_code = newArray(MAX_BITS + 1); /* next code value for each bit length */
		var code = 0; /* running code value */

		/* The distribution counts are first used to generate the code values
		 * without bit reversal.
		 */
		for (bits in 1...MAX_BITS + 1) {
			code = (code + bl_count[bits - 1]) << 1;
			next_code[bits] = code & 0xffff;
		}
		for (n in 0...max_code + 1) {
			var len = tree_dl[n];
			if (len == 0) continue;
			/* Now reverse the bits */
			tree_fc[n] = bi_reverse(next_code[len]++, len) & 0xffff;
		}
	}

	/* ===========================================================================
	 * Send a value on a given number of bits.
	 * IN assertion: length <= 16 and value fits in length bits.
	 */
	inline function send_bits(value:Int, length:Int):Void {
		var len = length;
		if (bi_valid > Buf_size - len) {
			var val = value;
			bi_buf = (bi_buf | ((val & 0xffff) << bi_valid)) & 0xffff;
			put_short(bi_buf);
			bi_buf = (val & 0xffff) >> (Buf_size - bi_valid);
			bi_valid += len - Buf_size;
		} else {
			bi_buf = (bi_buf | ((value & 0xffff) << bi_valid)) & 0xffff;
			bi_valid += len;
		}
	}

	inline function send_code(c:Int, tree_fc:Array<Int>, tree_dl:Array<Int>):Void send_bits(tree_fc[c], tree_dl[c]);

	/* ===========================================================================
	 * Initialize the various 'constant' tables.
	 */
	static function tr_static_init():Void {
		if (static_init_done.load()) return;
		static_init_lock.acquire();
		if (!static_init_done.load()) tr_static_build();
		static_init_lock.release();
	}

	// port: tr_static_init's body, run once (see static_init_done).
	static function tr_static_build():Void {
		var n:Int; /* iterates over tree elements */
		var length:Int; /* length value */
		var code:Int; /* code value */
		var dist:Int; /* distance index */
		var bl_count = newArray(MAX_BITS + 1);
		/* number of codes at each bit length for an optimal tree */

		static_ltree_fc = newArray(L_CODES + 2);
		static_ltree_dl = newArray(L_CODES + 2);
		static_dtree_fc = newArray(D_CODES);
		static_dtree_dl = newArray(D_CODES);
		_dist_code = newArray(512);
		_length_code = newArray(MAX_MATCH - MIN_MATCH + 1);
		base_length = newArray(LENGTH_CODES);
		base_dist = newArray(D_CODES);

		/* Initialize the mapping length (0..255) -> length code (0..28) */
		length = 0;
		code = 0;
		while (code < LENGTH_CODES - 1) {
			base_length[code] = length;
			for (n in 0...(1 << extra_lbits[code])) {
				_length_code[length++] = code;
			}
			code++;
		}
		/* Note that the length 255 (match length 258) can be represented
		 * in two different ways: code 284 + 5 bits or code 285, so we
		 * overwrite length_code[255] to use the best encoding:
		 */
		_length_code[length - 1] = code;

		/* Initialize the mapping dist (0..32K) -> dist code (0..29) */
		dist = 0;
		code = 0;
		while (code < 16) {
			base_dist[code] = dist;
			for (n in 0...(1 << extra_dbits[code])) {
				_dist_code[dist++] = code;
			}
			code++;
		}
		dist >>= 7; /* from now on, all distances are divided by 128 */
		while (code < D_CODES) {
			base_dist[code] = dist << 7;
			for (n in 0...(1 << (extra_dbits[code] - 7))) {
				_dist_code[256 + dist++] = code;
			}
			code++;
		}

		/* Construct the codes of the static literal tree */
		n = 0;
		while (n <= 143) {
			static_ltree_dl[n++] = 8;
			bl_count[8]++;
		}
		while (n <= 255) {
			static_ltree_dl[n++] = 9;
			bl_count[9]++;
		}
		while (n <= 279) {
			static_ltree_dl[n++] = 7;
			bl_count[7]++;
		}
		while (n <= 287) {
			static_ltree_dl[n++] = 8;
			bl_count[8]++;
		}
		/* Codes 286 and 287 do not exist, but we must include them in the
		 * tree construction to get a canonical Huffman tree (longest code
		 * all ones)
		 */
		gen_codes(static_ltree_fc, static_ltree_dl, L_CODES + 1, bl_count);

		/* The static distance tree is trivial: */
		for (n in 0...D_CODES) {
			static_dtree_dl[n] = 5;
			static_dtree_fc[n] = bi_reverse(n, 5);
		}
		static_init_done.store(true);
	}

	/* ===========================================================================
	 * Initialize a new block.
	 */
	function init_block():Void {
		/* Initialize the trees. */
		for (n in 0...L_CODES) dyn_ltree_fc[n] = 0;
		for (n in 0...D_CODES) dyn_dtree_fc[n] = 0;
		for (n in 0...BL_CODES) bl_tree_fc[n] = 0;

		dyn_ltree_fc[END_BLOCK] = 1;
		opt_len = static_len = 0;
		sym_next = matches = 0;
	}

	/* ===========================================================================
	 * Initialize the tree data structures for a new zlib stream.
	 */
	function _tr_init():Void {
		tr_static_init();

		l_desc = new TreeDesc(dyn_ltree_fc, dyn_ltree_dl, static_ltree_fc, static_ltree_dl, extra_lbits, LITERALS + 1, L_CODES, MAX_BITS);
		d_desc = new TreeDesc(dyn_dtree_fc, dyn_dtree_dl, static_dtree_fc, static_dtree_dl, extra_dbits, 0, D_CODES, MAX_BITS);
		bl_desc = new TreeDesc(bl_tree_fc, bl_tree_dl, null, null, extra_blbits, 0, BL_CODES, MAX_BL_BITS);

		bi_buf = 0;
		bi_valid = 0;

		/* Initialize the first block of the first file: */
		init_block();
	}

	/* ===========================================================================
	 * Compares to subtrees, using the tree depth as tie breaker when
	 * the subtrees have equal frequency. This minimizes the worst case length.
	 */
	inline function smaller(tree_fc:Array<Int>, n:Int, m:Int):Bool
		return tree_fc[n] < tree_fc[m] || (tree_fc[n] == tree_fc[m] && depth[n] <= depth[m]);

	/* ===========================================================================
	 * Restore the heap property by moving down the tree starting at node k,
	 * exchanging a node with the smallest of its two sons if necessary, stopping
	 * when the heap property is re-established (each father smaller than its
	 * two sons).
	 */
	function pqdownheap(tree_fc:Array<Int>, k:Int):Void {
		var v = heap[k];
		var j = k << 1; /* left son of k */
		while (j <= heap_len) {
			/* Set j to the smallest of the two sons: */
			if (j < heap_len && smaller(tree_fc, heap[j + 1], heap[j])) {
				j++;
			}
			/* Exit if v is smaller than both sons */
			if (smaller(tree_fc, v, heap[j])) break;

			/* Exchange v with the smallest son */
			heap[k] = heap[j];
			k = j;

			/* And continue down the tree, setting j to the left son of k */
			j <<= 1;
		}
		heap[k] = v;
	}

	/* ===========================================================================
	 * Compute the optimal bit lengths for a tree and update the total bit length
	 * for the current block.
	 * IN assertion: the fields freq and dad are set, heap[heap_max] and
	 *    above are the tree nodes sorted by increasing frequency.
	 * OUT assertions: the field len is set to the optimal bit length, the
	 *     array bl_count contains the frequencies for each bit length.
	 *     The length opt_len is updated; static_len is also updated if stree is
	 *     not null.
	 */
	function gen_bitlen(desc:TreeDesc):Void {
		var tree_fc = desc.dyn_tree_fc;
		var tree_dl = desc.dyn_tree_dl;
		var max_code = desc.max_code;
		var stree_dl = desc.static_tree_dl;
		var extra = desc.extra_bits;
		var base = desc.extra_base;
		var max_length = desc.max_length;
		var h:Int; /* heap index */
		var n:Int, m:Int; /* iterate over the tree elements */
		var bits:Int; /* bit length */
		var xbits:Int; /* extra bits */
		var f:Int; /* frequency */
		var overflow = 0; /* number of elements with bit length too large */

		for (bits in 0...MAX_BITS + 1) bl_count[bits] = 0;

		/* In a first pass, compute the optimal bit lengths (which may
		 * overflow in the case of the bit length tree).
		 */
		tree_dl[heap[heap_max]] = 0; /* root of the heap */

		h = heap_max + 1;
		while (h < HEAP_SIZE) {
			n = heap[h];
			bits = tree_dl[tree_dl[n]] + 1;
			if (bits > max_length) {
				bits = max_length;
				overflow++;
			}
			tree_dl[n] = bits & 0xffff;
			/* We overwrite tree[n].Dad which is no longer needed */

			if (n > max_code) {
				h++;
				continue; /* not a leaf node */
			}

			bl_count[bits]++;
			xbits = 0;
			if (n >= base) xbits = extra[n - base];
			f = tree_fc[n];
			opt_len += f * (bits + xbits);
			if (stree_dl != null) static_len += f * (stree_dl[n] + xbits);
			h++;
		}
		if (overflow == 0) return;

		/* This happens for example on obj2 and pic of the Calgary corpus */

		/* Find the first bit length which could increase: */
		do {
			bits = max_length - 1;
			while (bl_count[bits] == 0) bits--;
			bl_count[bits]--; /* move one leaf down the tree */
			bl_count[bits + 1] += 2; /* move one overflow item as its brother */
			bl_count[max_length]--;
			/* The brother of the overflow item also moves one step up,
			 * but this does not affect bl_count[max_length]
			 */
			overflow -= 2;
		} while (overflow > 0);

		/* Now recompute all bit lengths, scanning in increasing frequency.
		 * h is still equal to HEAP_SIZE. (It is simpler to reconstruct all
		 * lengths instead of fixing only the wrong ones. This idea is taken
		 * from 'ar' written by Haruhiko Okumura.)
		 */
		bits = max_length;
		while (bits != 0) {
			n = bl_count[bits];
			while (n != 0) {
				m = heap[--h];
				if (m > max_code) continue;
				if (tree_dl[m] != bits) {
					opt_len += (bits - tree_dl[m]) * tree_fc[m];
					tree_dl[m] = bits;
				}
				n--;
			}
			bits--;
		}
	}

	/* ===========================================================================
	 * Construct one Huffman tree and assigns the code bit strings and lengths.
	 * Update the total bit length for the current block.
	 * IN assertion: the field freq is set for all tree elements.
	 * OUT assertions: the fields len and code are set to the optimal bit length
	 *     and corresponding code. The length opt_len is updated; static_len is
	 *     also updated if stree is not null. The field max_code is set.
	 */
	function build_tree(desc:TreeDesc):Void {
		var tree_fc = desc.dyn_tree_fc;
		var tree_dl = desc.dyn_tree_dl;
		var stree_dl = desc.static_tree_dl;
		var elems = desc.elems;
		var n:Int, m:Int; /* iterate over heap elements */
		var max_code = -1; /* largest code with non zero frequency */
		var node:Int; /* new node being created */

		/* Construct the initial heap, with least frequent element in
		 * heap[SMALLEST]. The sons of heap[n] are heap[2*n] and heap[2*n + 1].
		 * heap[0] is not used.
		 */
		heap_len = 0;
		heap_max = HEAP_SIZE;

		for (n in 0...elems) {
			if (tree_fc[n] != 0) {
				heap[++heap_len] = max_code = n;
				depth[n] = 0;
			} else {
				tree_dl[n] = 0;
			}
		}

		/* The pkzip format requires that at least one distance code exists,
		 * and that at least one bit should be sent even if there is only one
		 * possible code. So to avoid special checks later on we force at least
		 * two codes of non zero frequency.
		 */
		while (heap_len < 2) {
			node = heap[++heap_len] = (max_code < 2 ? ++max_code : 0);
			tree_fc[node] = 1;
			depth[node] = 0;
			opt_len--;
			if (stree_dl != null) static_len -= stree_dl[node];
			/* node is 0 or 1 so it does not have extra bits */
		}
		desc.max_code = max_code;

		/* The elements heap[heap_len/2 + 1 .. heap_len] are leaves of the tree,
		 * establish sub-heaps of increasing lengths:
		 */
		n = heap_len >> 1;
		while (n >= 1) {
			pqdownheap(tree_fc, n);
			n--;
		}

		/* Construct the Huffman tree by repeatedly combining the least two
		 * frequent nodes.
		 */
		node = elems; /* next internal node of the tree */
		do {
			/* pqremove */
			n = heap[SMALLEST];
			heap[SMALLEST] = heap[heap_len--];
			pqdownheap(tree_fc, SMALLEST);
			/* n = node of least frequency */
			m = heap[SMALLEST]; /* m = node of next least frequency */

			heap[--heap_max] = n; /* keep the nodes sorted by frequency */
			heap[--heap_max] = m;

			/* Create a new node father of n and m */
			tree_fc[node] = (tree_fc[n] + tree_fc[m]) & 0xffff;
			depth[node] = ((depth[n] >= depth[m] ? depth[n] : depth[m]) + 1) & 0xff;
			tree_dl[n] = tree_dl[m] = node;
			/* and insert the new node in the heap */
			heap[SMALLEST] = node++;
			pqdownheap(tree_fc, SMALLEST);
		} while (heap_len >= 2);

		heap[--heap_max] = heap[SMALLEST];

		/* At this point, the fields freq and dad are set. We can now
		 * generate the bit lengths.
		 */
		gen_bitlen(desc);

		/* The field len is now set, we can generate the bit codes */
		gen_codes(tree_fc, tree_dl, max_code, bl_count);
	}

	/* ===========================================================================
	 * Scan a literal or distance tree to determine the frequencies of the codes
	 * in the bit length tree.
	 */
	function scan_tree(tree_dl:Array<Int>, max_code:Int):Void {
		var prevlen = -1; /* last emitted length */
		var curlen:Int; /* length of current code */
		var nextlen = tree_dl[0]; /* length of next code */
		var count = 0; /* repeat count of the current code */
		var max_count = 7; /* max repeat count */
		var min_count = 4; /* min repeat count */

		if (nextlen == 0) {
			max_count = 138;
			min_count = 3;
		}
		tree_dl[max_code + 1] = 0xffff; /* guard */

		for (n in 0...max_code + 1) {
			curlen = nextlen;
			nextlen = tree_dl[n + 1];
			if (++count < max_count && curlen == nextlen) {
				continue;
			} else if (count < min_count) {
				bl_tree_fc[curlen] += count;
			} else if (curlen != 0) {
				if (curlen != prevlen) bl_tree_fc[curlen]++;
				bl_tree_fc[REP_3_6]++;
			} else if (count <= 10) {
				bl_tree_fc[REPZ_3_10]++;
			} else {
				bl_tree_fc[REPZ_11_138]++;
			}
			count = 0;
			prevlen = curlen;
			if (nextlen == 0) {
				max_count = 138;
				min_count = 3;
			} else if (curlen == nextlen) {
				max_count = 6;
				min_count = 3;
			} else {
				max_count = 7;
				min_count = 4;
			}
		}
	}

	/* ===========================================================================
	 * Send a literal or distance tree in compressed form, using the codes in
	 * bl_tree.
	 */
	function send_tree(tree_dl:Array<Int>, max_code:Int):Void {
		var prevlen = -1; /* last emitted length */
		var curlen:Int; /* length of current code */
		var nextlen = tree_dl[0]; /* length of next code */
		var count = 0; /* repeat count of the current code */
		var max_count = 7; /* max repeat count */
		var min_count = 4; /* min repeat count */

		/* tree[max_code + 1].Len = -1; */ /* guard already set */
		if (nextlen == 0) {
			max_count = 138;
			min_count = 3;
		}

		for (n in 0...max_code + 1) {
			curlen = nextlen;
			nextlen = tree_dl[n + 1];
			if (++count < max_count && curlen == nextlen) {
				continue;
			} else if (count < min_count) {
				do {
					send_code(curlen, bl_tree_fc, bl_tree_dl);
				} while (--count != 0);
			} else if (curlen != 0) {
				if (curlen != prevlen) {
					send_code(curlen, bl_tree_fc, bl_tree_dl);
					count--;
				}
				send_code(REP_3_6, bl_tree_fc, bl_tree_dl);
				send_bits(count - 3, 2);
			} else if (count <= 10) {
				send_code(REPZ_3_10, bl_tree_fc, bl_tree_dl);
				send_bits(count - 3, 3);
			} else {
				send_code(REPZ_11_138, bl_tree_fc, bl_tree_dl);
				send_bits(count - 11, 7);
			}
			count = 0;
			prevlen = curlen;
			if (nextlen == 0) {
				max_count = 138;
				min_count = 3;
			} else if (curlen == nextlen) {
				max_count = 6;
				min_count = 3;
			} else {
				max_count = 7;
				min_count = 4;
			}
		}
	}

	/* ===========================================================================
	 * Construct the Huffman tree for the bit lengths and return the index in
	 * bl_order of the last bit length code to send.
	 */
	function build_bl_tree():Int {
		var max_blindex:Int; /* index of last bit length code of non zero freq */

		/* Determine the bit length frequencies for literal and distance trees */
		scan_tree(dyn_ltree_dl, l_desc.max_code);
		scan_tree(dyn_dtree_dl, d_desc.max_code);

		/* Build the bit length tree: */
		build_tree(bl_desc);
		/* opt_len now includes the length of the tree representations, except the
		 * lengths of the bit lengths codes and the 5 + 5 + 4 bits for the counts.
		 */

		/* Determine the number of bit length codes to send. The pkzip format
		 * requires that at least 4 bit length codes be sent. (appnote.txt says
		 * 3 but the actual value used is 4.)
		 */
		max_blindex = BL_CODES - 1;
		while (max_blindex >= 3) {
			if (bl_tree_dl[bl_order[max_blindex]] != 0) break;
			max_blindex--;
		}
		/* Update opt_len to include the bit length tree and counts */
		opt_len += 3 * (max_blindex + 1) + 5 + 5 + 4;

		return max_blindex;
	}

	/* ===========================================================================
	 * Send the header for a block using dynamic Huffman trees: the counts, the
	 * lengths of the bit length codes, the literal tree and the distance tree.
	 * IN assertion: lcodes >= 257, dcodes >= 1, blcodes >= 4.
	 */
	function send_all_trees(lcodes:Int, dcodes:Int, blcodes:Int):Void {
		send_bits(lcodes - 257, 5); /* not +255 as stated in appnote.txt */
		send_bits(dcodes - 1, 5);
		send_bits(blcodes - 4, 4); /* not -3 as stated in appnote.txt */
		for (rank in 0...blcodes) {
			send_bits(bl_tree_dl[bl_order[rank]], 3);
		}

		send_tree(dyn_ltree_dl, lcodes - 1); /* literal tree */

		send_tree(dyn_dtree_dl, dcodes - 1); /* distance tree */
	}

	/* ===========================================================================
	 * Send a stored block
	 */
	function _tr_stored_block(buf:Null<Bytes>, bufPos:Int, stored_len:Int, last:Int):Void {
		send_bits((STORED_BLOCK << 1) + last, 3); /* send block type */
		bi_windup(); /* align on byte boundary */
		put_short(stored_len & 0xffff);
		put_short((~stored_len) & 0xffff);
		if (stored_len != 0) pending_buf.blit(pending, buf, bufPos, stored_len);
		pending += stored_len;
	}

	/* ===========================================================================
	 * Flush the bits in the bit buffer to pending output (leaves at most 7 bits)
	 */
	function _tr_flush_bits():Void {
		bi_flush();
	}

	/* ===========================================================================
	 * Send one empty static block to give enough lookahead for inflate.
	 * This takes 10 bits, of which 7 may remain in the bit buffer.
	 */
	function _tr_align():Void {
		send_bits(STATIC_TREES << 1, 3);
		send_code(END_BLOCK, static_ltree_fc, static_ltree_dl);
		bi_flush();
	}

	/* ===========================================================================
	 * Send the block data compressed using the given Huffman trees
	 */
	function compress_block(ltree_fc:Array<Int>, ltree_dl:Array<Int>, dtree_fc:Array<Int>, dtree_dl:Array<Int>):Void {
		var dist:Int; /* distance of matched string */
		var lc:Int; /* match length or unmatched char (if dist == 0) */
		var sx = 0; /* running index in symbol buffers */
		var code:Int; /* the code to send */
		var extra:Int; /* number of extra bits to send */

		if (sym_next != 0) do {
			dist = pending_buf.get(sym_buf + sx++) & 0xff;
			dist += (pending_buf.get(sym_buf + sx++) & 0xff) << 8;
			lc = pending_buf.get(sym_buf + sx++);
			if (dist == 0) {
				send_code(lc, ltree_fc, ltree_dl); /* send a literal byte */
			} else {
				/* Here, lc is the match length - MIN_MATCH */
				code = _length_code[lc];
				send_code(code + LITERALS + 1, ltree_fc, ltree_dl); /* send length code */
				extra = extra_lbits[code];
				if (extra != 0) {
					lc -= base_length[code];
					send_bits(lc, extra); /* send the extra length bits */
				}
				dist--; /* dist is now the match distance - 1 */
				code = d_code(dist);

				send_code(code, dtree_fc, dtree_dl); /* send the distance code */
				extra = extra_dbits[code];
				if (extra != 0) {
					dist -= base_dist[code];
					send_bits(dist, extra); /* send the extra distance bits */
				}
			} /* literal or match pair ? */
		} while (sx < sym_next);

		send_code(END_BLOCK, ltree_fc, ltree_dl);
	}

	/* ===========================================================================
	 * Determine the best encoding for the current block: dynamic trees, static
	 * trees or store, and write out the encoded block.
	 */
	function _tr_flush_block(buf:Null<Bytes>, bufPos:Int, stored_len:Int, last:Int):Void {
		var opt_lenb:Int, static_lenb:Int; /* opt_len and static_len in bytes */
		var max_blindex = 0; /* index of last bit length code of non zero freq */

		/* Build the Huffman trees unless a stored block is forced */
		if (level > 0) {
			/* Construct the literal and distance trees */
			build_tree(l_desc);

			build_tree(d_desc);
			/* At this point, opt_len and static_len are the total bit lengths of
			 * the compressed block data, excluding the tree representations.
			 */

			/* Build the bit length tree for the above two trees, and get the index
			 * in bl_order of the last bit length code to send.
			 */
			max_blindex = build_bl_tree();

			/* Determine the best encoding. Compute the block lengths in bytes. */
			opt_lenb = (opt_len + 3 + 7) >>> 3;
			static_lenb = (static_len + 3 + 7) >>> 3;

			if (static_lenb <= opt_lenb) opt_lenb = static_lenb;
		} else {
			opt_lenb = static_lenb = stored_len + 5; /* force a stored block */
		}

		if (stored_len + 4 <= opt_lenb && buf != null) {
			/* 4: two words for the lengths */
			/* The test buf != NULL is only necessary if LIT_BUFSIZE > WSIZE.
			 * Otherwise we can't have processed more than WSIZE input bytes since
			 * the last block flush, because compression would have been
			 * successful. If LIT_BUFSIZE <= WSIZE, it is never too late to
			 * transform a block into a stored block.
			 */
			_tr_stored_block(buf, bufPos, stored_len, last);
		} else if (static_lenb == opt_lenb) {
			send_bits((STATIC_TREES << 1) + last, 3);
			compress_block(static_ltree_fc, static_ltree_dl, static_dtree_fc, static_dtree_dl);
		} else {
			send_bits((DYN_TREES << 1) + last, 3);
			send_all_trees(l_desc.max_code + 1, d_desc.max_code + 1, max_blindex + 1);
			compress_block(dyn_ltree_fc, dyn_ltree_dl, dyn_dtree_fc, dyn_dtree_dl);
		}
		init_block();

		if (last != 0) {
			bi_windup();
		}
	}
}

// port: tree_desc and its static_tree_desc, with the ct_data arrays split in
// their Freq/Code and Dad/Len halves.
private class TreeDesc {
	public final dyn_tree_fc:Array<Int>;
	public final dyn_tree_dl:Array<Int>;
	public var max_code:Int;
	public final static_tree_fc:Null<Array<Int>>;
	public final static_tree_dl:Null<Array<Int>>;
	public final extra_bits:Array<Int>;
	public final extra_base:Int;
	public final elems:Int;
	public final max_length:Int;

	public function new(dyn_tree_fc, dyn_tree_dl, static_tree_fc, static_tree_dl, extra_bits, extra_base, elems, max_length) {
		this.dyn_tree_fc = dyn_tree_fc;
		this.dyn_tree_dl = dyn_tree_dl;
		this.max_code = 0;
		this.static_tree_fc = static_tree_fc;
		this.static_tree_dl = static_tree_dl;
		this.extra_bits = extra_bits;
		this.extra_base = extra_base;
		this.elems = elems;
		this.max_length = max_length;
	}
}

// port: a set of stream buffers kept for the next stream (see Zlib.spares).
private class SpareBuffers {
	public final window:Bytes;
	public final prev:Array<Int>;
	public final head:Array<Int>;
	public final pending:Bytes;

	public function new(window:Bytes, prev:Array<Int>, head:Array<Int>, pending:Bytes) {
		this.window = window;
		this.prev = prev;
		this.head = head;
		this.pending = pending;
	}
}
