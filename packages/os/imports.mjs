// The JavaScript side of hxmc.os in the browser: the imports of the module
// "hxmc_os" (src/hxmc/os/web/Dom.hx) for Window, App and Event on a canvas
// (hxmc.os.web.CanvasWindow). Loaded by browser.mjs (its `canvas` option: the
// canvas of the first window, an element or its id).
//
// A canvas's drawing buffer follows its displayed size in device pixels,
// checked before each frame (a Resize event when it changes); a canvas the
// page does not size is given the window's size in CSS pixels. Events are
// queued as they come and polled at the start of the next frame, as the
// native loops poll theirs: keys (as X11 KeySyms, Event.key) once the canvas
// has the focus (a click gives it), the mouse over the canvas in buffer
// pixels from the top left, a change of devicePixelRatio (ScaleChange,
// checked before each frame). Frames pause while no window's canvas is in
// view (as requestAnimationFrame pauses in a hidden tab). host.os.redraw()
// asks every window for a frame (a Redraw event): the page wants its pixels
// (host.gfx.readPixels) while the program has nothing new to draw. The
// clipboard: writes go to navigator.clipboard; a read takes the text of the
// paste event the key press that asked for it brought (no permission
// needed), else navigator.clipboard.readText, and comes back as an event.
// Text input (Window.startTextInput): keys go to a transparent textarea of
// the page placed at the caret, focused instead of the canvas, so that
// input methods work: their compositions come as TextEditing events, their
// commits (and text inserted without keys: an emoji picker, dictation) as
// TextInput.
// Swapped out (hxmc dev, host.dispose(): browser.mjs), the instance ends its
// frames, its listeners and observers and its audio, and keeps its windows'
// canvases (host.os.canvases: the next instance's option canvas, and
// host.keep), their pixels as they are: a canvas run's option canvas gives a
// new instance keeps its size and contents when they are the window's.
// host.os.stop() ends the frames and lets go of the canvases; a frame that
// throws ends them too, and goes to run's option onError when given (as an
// exit with an error code in a frame does).
//
// Audio (hxmc.os.audio.WebAudioOutput): an AudioContext at the rate asked
// for, and an AudioWorklet node (PROCESSOR, loaded from a blob) that plays
// chunks of interleaved samples posted to it, telling the page each time it
// has played one. The module's memory is not shared with the worklet, so
// the page calls the module's fill for a new chunk then (and at start: as
// many as `ahead`), copies it and posts it: the module stays at most
// `ahead` frames ahead of the output. Browsers start an AudioContext only
// after a user gesture: one made before is resumed on the page's next click
// or key. The option audioContext, a function (sampleRate, channels) =>
// context, gives another context: an OfflineAudioContext (tests), whose
// whole length start fills at once; its promise hxmcReady resolves once the
// node is connected and has those chunks (then startRendering).

// EventKind (src/hxmc/os/Event.hx)
const RESIZE = 2, KEY_DOWN = 3, KEY_UP = 4, MOUSE_MOVE = 5, MOUSE_DOWN = 6, MOUSE_UP = 7, TEXT_INPUT = 8, REDRAW = 9, TEXT_EDITING = 10, SCROLL = 11,
	SCALE_CHANGE = 12;
// (not an EventKind: CanvasWindow hands the text to Clipboard.read's callback)
const CLIPBOARD = 100;

// KeyboardEvent.key to an X11 KeySym: Latin-1 characters are their
// (unshifted) code, the others from this table
const KEYS = {
	Escape: 0xff1b, Enter: 0xff0d, Tab: 0xff09, Backspace: 0xff08, Delete: 0xffff, Insert: 0xff63, Home: 0xff50, End: 0xff57,
	PageUp: 0xff55, PageDown: 0xff56, ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54,
	Shift: 0xffe1, Control: 0xffe3, Alt: 0xffe9, Meta: 0xffe7, CapsLock: 0xffe5, ContextMenu: 0xff67,
};
for (let i = 1; i <= 12; i++) KEYS['F' + i] = 0xffbd + i;

function keysym(e) {
	if (KEYS[e.key]) return KEYS[e.key];
	if (e.key.length === 1) {
		const c = e.key.toLowerCase().charCodeAt(0);
		if (c < 256) return c;
	}
	return 0;
}

// the worklet's side: a queue of chunks (Float32Arrays, interleaved), played
// in order into its output; 'clear' empties it, 'ping' is answered (once
// the chunks posted before it are queued)
const PROCESSOR = `
class HxmcOutput extends AudioWorkletProcessor {
	constructor(o) {
		super();
		this.channels = o.processorOptions.channels;
		this.queue = [];
		this.at = 0;
		this.port.onmessage = (e) => {
			if (e.data === 'clear') {
				this.queue = [];
				this.at = 0;
			} else if (e.data === 'ping') this.port.postMessage('ping');
			else this.queue.push(e.data);
		};
	}
	process(inputs, outputs) {
		const out = outputs[0], n = out[0].length, ch = this.channels;
		let i = 0;
		while (i < n && this.queue.length > 0) {
			const c = this.queue[0], frames = c.length / ch, k = Math.min(n - i, frames - this.at);
			for (let x = 0; x < out.length; x++) {
				const o = out[x];
				for (let j = 0; j < k; j++) o[i + j] = c[(this.at + j) * ch + x];
			}
			i += k;
			this.at += k;
			if (this.at === frames) {
				this.queue.shift();
				this.at = 0;
				this.port.postMessage(frames);
			}
		}
		return true;
	}
}
registerProcessor('hxmc-output', HxmcOutput);
`;
let processorUrl = null;

export default function (host) {
	const queue = [];
	const windows = new Set();
	let first = true, ratio = devicePixelRatio;
	// the last paste event's text, and when
	let pasted = null;
	let stopped = false;
	// (hxmc dev: swapped out, the canvases kept for the next instance)
	host.onDispose?.(() => {
		host.os.canvases = [...windows].map((h) => host.handles.get(h));
		for (const c of host.os.canvases) host.keep(c);
		host.os.stop();
		for (const a of [...outputs]) hxmc_os.audio_close(a.handle);
		if (resumes) for (const t of ['pointerdown', 'keydown']) document.removeEventListener(t, resume, { capture: true });
		cancelAnimationFrame(frameId);
	});
	host.os = {
		canvases: [],
		redraw: () => { for (const h of windows) push([h, REDRAW, 0, 0, 0, 0, 0]); },
		// no more frames or events: the windows let go of their canvases (a
		// page frees a program it no longer shows: loader.js, data-stop)
		stop() {
			stopped = true;
			for (const h of windows) {
				const c = host.handles.get(h);
				c.hxmcOff.abort();
				c.hxmcSeen.disconnect();
				c.hxmcInput.remove();
			}
			windows.clear();
			queue.length = 0;
		},
	};

	function push(ev) {
		// (moves between two frames, compositions: the last one)
		const last = queue[queue.length - 1];
		// (scrolls between two frames: added up, at the last position)
		if (ev[1] === SCROLL && last && last[1] === SCROLL && last[0] === ev[0] && last[6] === ev[6]) {
			queue[queue.length - 1] = [ev[0], SCROLL, last[2] + ev[2], ev[3], ev[4], last[5] + ev[5], ev[6]];
			return;
		}
		if ((ev[1] === MOUSE_MOVE || ev[1] === TEXT_EDITING) && last && last[1] === ev[1] && last[0] === ev[0]) {
			if (last[1] === TEXT_EDITING && last[2]) host.handles.remove(last[2]);
			queue[queue.length - 1] = ev;
		} else queue.push(ev);
	}

	function sync(h) {
		const c = host.handles.get(h);
		const w = Math.round(c.clientWidth * devicePixelRatio), hh = Math.round(c.clientHeight * devicePixelRatio);
		if (w > 0 && hh > 0 && (w !== c.width || hh !== c.height)) {
			c.width = w;
			c.height = hh;
			return true;
		}
		return false;
	}

	function listen(c, h) {
		const pos = (e) => [Math.round(e.offsetX * c.width / Math.max(1, c.clientWidth)), Math.round(e.offsetY * c.height / Math.max(1, c.clientHeight))];
		const off = new AbortController();
		const on = (type, f, o = {}) => c.addEventListener(type, f, { ...o, signal: off.signal });
		// (Event.mods: Shift 1, Control 2, Alt 4, Meta 8)
		const mods = (e) => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
		// the text input's element (text_input)
		const ta = document.createElement('textarea');
		for (const [k, v] of [['autocomplete', 'off'], ['autocapitalize', 'off'], ['spellcheck', 'false'], ['tabindex', '-1']]) ta.setAttribute(k, v);
		ta.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none;resize:none;border:0;padding:0;margin:0;outline:none;overflow:hidden;white-space:pre;';
		document.body.appendChild(ta);
		c.hxmcInput = ta;
		const onInput = (type, f) => ta.addEventListener(type, f, { signal: off.signal });
		const keydown = (e) => {
			// (an input method's keys: its composition's)
			if (e.isComposing || e.keyCode === 229) return;
			push([h, KEY_DOWN, keysym(e), 0, 0, 0, mods(e)]);
			// then its character (one code point: not a named key), as the native windows type them
			const cp = e.key.codePointAt(0);
			if (!e.ctrlKey && !e.metaKey && e.key.length === String.fromCodePoint(cp).length && cp >= 0x20) {
				push([h, TEXT_INPUT, cp, 0, 0, 0, mods(e)]);
				// (not typed into the textarea too)
				if (e.currentTarget === ta) e.preventDefault();
			}
			// (Tab stays in the canvas: the program moves its own focus)
			if (e.key === 'Tab' || e.key === 'Backspace') e.preventDefault();
		};
		const keyup = (e) => {
			if (!e.isComposing && e.keyCode !== 229) push([h, KEY_UP, keysym(e), 0, 0, 0, mods(e)]);
		};
		on('keydown', keydown);
		on('keyup', keyup);
		onInput('keydown', keydown);
		onInput('keyup', keyup);
		// the composition: the textarea's text from where it started to what
		// followed it then, the caret in it
		let composing = false, start = 0, tail = 0;
		const editing = (t, caret) => push([h, TEXT_EDITING, t ? host.handles.add(t) : 0, Math.max(0, Math.min(t.length, caret)), 0, 0, 0]);
		onInput('compositionstart', () => {
			composing = true;
			start = ta.selectionStart;
			tail = ta.value.length - ta.selectionEnd;
		});
		// (before the textarea changes: its caret at the end, until the input event)
		onInput('compositionupdate', (e) => editing(e.data ?? '', (e.data ?? '').length));
		onInput('compositionend', (e) => {
			composing = false;
			editing('', 0);
			for (const ch of e.data ?? '') push([h, TEXT_INPUT, ch.codePointAt(0), 0, 0, 0, 0]);
			setTimeout(() => composing || (ta.value = ''));
		});
		onInput('input', (e) => {
			if (composing) {
				const t = ta.value.slice(start, ta.value.length - tail);
				return editing(t, ta.selectionEnd - start);
			}
			// (text inserted without its keys; not a composition's, which compositionend gave)
			if ((e.inputType === 'insertText' || e.inputType === 'insertReplacementText') && e.data)
				for (const ch of e.data) push([h, TEXT_INPUT, ch.codePointAt(0), 0, 0, 0, 0]);
			ta.value = '';
		});
		on('mousemove', (e) => push([h, MOUSE_MOVE, 0, ...pos(e), 0, mods(e)]));
		on('mousedown', (e) => {
			// (typing: the focus stays the textarea's)
			if (c.hxmcTyping) {
				e.preventDefault();
				ta.focus({ preventScroll: true });
			} else c.focus();
			push([h, MOUSE_DOWN, 0, ...pos(e), e.button + 1, mods(e)]);
		});
		on('mouseup', (e) => push([h, MOUSE_UP, 0, ...pos(e), e.button + 1, mods(e)]));
		// (a mouse's press captured: a drag that leaves the canvas still
		// moves, and its release still comes, at positions outside it)
		on('pointerdown', (e) => e.pointerType === 'mouse' && c.setPointerCapture?.(e.pointerId));
		// (the deltas in canvas pixels, in 1/256ths: in key and button; lines 40 pixels, pages the canvas)
		on('wheel', (e) => {
			const k = (e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? c.clientHeight : 1) * devicePixelRatio * 256;
			push([h, SCROLL, Math.round(e.deltaX * k), ...pos(e), Math.round(e.deltaY * k), mods(e)]);
		}, { passive: true });
		// touch: a drag scrolls what is under where it started (the content
		// follows the finger, then glides when let go moving), a tap clicks
		// (no mouse events of the browser's own for either). The option
		// touchAction (the canvas's CSS touch-action, by default 'none')
		// lets the browser pan the page along its axes: with 'pan-y', a drag
		// that starts vertical asks the program first (scrolls_at: the query
		// of Window.scrollsAt, once a gesture, at its first move) whether
		// something under where it started scrolls that way. Yes: the drag is
		// the program's, the browser held off it (its touchmoves cancelled,
		// the listener not passive); no, or no answer: the browser pans the
		// page (it cancels the pointer when it takes it over), as at a
		// scroller's end (the page scrolls on, as a browser chains scrolls).
		// A drag's scrolls have Mods.TOUCH (16: a finger on the canvas), and
		// it ends with a scroll of nothing without it (its glide's are
		// without it too): a program that follows the finger knows when it
		// is let go, even after it rested
		const action = host.options.touchAction ?? 'none';
		c.style.touchAction = action;
		const words = action.split(/\s+/), pans = (...w) => words.some((a) => a === 'auto' || a === 'manipulation' || w.includes(a));
		const panX = pans('pan-x', 'pan-left', 'pan-right'), panY = pans('pan-y', 'pan-up', 'pan-down');
		let touch = null, glide = 0;
		const TOUCH = 16;
		// (whether the gesture is the program's: decided at its first move
		// away from where it started; then its touchmoves cancelled)
		const decide = (t, x, y) => {
			if (t.taken === undefined) {
				const dx = t.x - x, dy = t.y - y, vertical = Math.abs(dy) > Math.abs(dx);
				const a = vertical ? panY : panX;
				// (asked along the gesture's axis: a vertical one does not move a carousel)
				t.taken = !a || (query !== 0 && host.call(query, h, t.x, t.y, vertical ? 0 : Math.round(dx), vertical ? Math.round(dy) : 0) === 1);
			}
			return t.taken;
		};
		on('touchmove', (e) => {
			const t = touch;
			if (!t || !e.cancelable) return;
			if (t.taken === undefined) {
				const p = e.changedTouches[0], r = c.getBoundingClientRect();
				const x = Math.round((p.clientX - r.left - c.clientLeft) * c.width / Math.max(1, c.clientWidth));
				const y = Math.round((p.clientY - r.top - c.clientTop) * c.height / Math.max(1, c.clientHeight));
				// (within a few pixels: no direction yet, nor a pan of the browser's)
				if (Math.hypot(x - t.x, y - t.y) < 4 * devicePixelRatio) return;
				decide(t, x, y);
			}
			if (t.taken) e.preventDefault();
		}, { passive: false });
		const scrollBy = (x, y, dx, dy, m = 0) => push([h, SCROLL, Math.round(dx * 256), x, y, Math.round(dy * 256), m]);
		on('pointerdown', (e) => {
			if (e.pointerType !== 'touch' || touch) return;
			e.preventDefault();
			cancelAnimationFrame(glide);
			const [x, y] = pos(e);
			touch = { id: e.pointerId, x, y, lx: x, ly: y, t: performance.now(), vx: 0, vy: 0, drag: false, taken: undefined };
			c.setPointerCapture?.(e.pointerId);
		});
		on('pointermove', (e) => {
			if (!touch || e.pointerId !== touch.id) return;
			const [x, y] = pos(e), now = performance.now();
			if (!touch.drag && Math.hypot(x - touch.x, y - touch.y) > 8 * devicePixelRatio) {
				// (the browser's gesture: neither a drag nor a tap)
				if (!decide(touch, x, y)) {
					touch = null;
					return;
				}
				touch.drag = true;
			}
			if (!touch.drag) return;
			const dx = touch.lx - x, dy = touch.ly - y, dt = Math.max(1, now - touch.t);
			scrollBy(touch.x, touch.y, dx, dy, TOUCH);
			// (pixels per millisecond, smoothed)
			touch.vx = 0.8 * (dx / dt) + 0.2 * touch.vx;
			touch.vy = 0.8 * (dy / dt) + 0.2 * touch.vy;
			Object.assign(touch, { lx: x, ly: y, t: now });
		});
		const lift = (e) => {
			if (!touch || e.pointerId !== touch.id) return;
			const t = touch;
			touch = null;
			// (the drag's end: the finger let go, or the browser took it over)
			if (t.drag) scrollBy(t.x, t.y, 0, 0);
			// (cancelled: the browser took the pointer over, to pan the page)
			if (e.type === 'pointercancel') return;
			if (!t.drag) {
				if (c.hxmcTyping) ta.focus({ preventScroll: true });
				else c.focus();
				push([h, MOUSE_MOVE, 0, t.x, t.y, 0, 0]);
				push([h, MOUSE_DOWN, 0, t.x, t.y, 1, 0]);
				push([h, MOUSE_UP, 0, t.x, t.y, 1, 0]);
				return;
			}
			// (let go moving: on at that speed, slowing 5% a frame)
			if (performance.now() - t.t > 100) return;
			let vx = t.vx * 16, vy = t.vy * 16;
			const step = () => {
				vx *= 0.95;
				vy *= 0.95;
				if (Math.hypot(vx, vy) < 0.5) return;
				scrollBy(t.x, t.y, vx, vy);
				glide = requestAnimationFrame(step);
			};
			glide = requestAnimationFrame(step);
		};
		on('pointerup', lift);
		on('pointercancel', lift);
		on('contextmenu', (e) => e.preventDefault());
		const paste = (e) => {
			pasted = { text: e.clipboardData ? e.clipboardData.getData('text/plain') : '', at: performance.now() };
			e.preventDefault();
		};
		on('paste', paste);
		onInput('paste', paste);
		return off;
	}

	// (an output's chunks, up to `ahead` frames queued in the worklet)
	function pump(a, h) {
		while (a.running && a.queued < a.ahead) {
			host.call(a.fill, h, a.frames);
			// (the callback closed it, or the program ended)
			if (!a.running || host.exitCode !== null) break;
			const chunk = new Float32Array(host.memory().buffer, a.buffer, a.frames * a.channels).slice();
			if (a.node) a.node.port.postMessage(chunk, [chunk.buffer]);
			else a.pending.push(chunk);
			a.queued += a.frames;
		}
	}
	const resume = () => {
		for (const a of outputs) if (a.running && a.ctx.state === 'suspended') a.ctx.resume();
	};
	const outputs = new Set();
	let resumes = false;
	// Window.scrollsAt's query (a callback; 0: none)
	let query = 0;
	// the next frame's requestAnimationFrame
	let frameId = 0;

	const hxmc_os = {
		audio_open(rate, channels, frames, buffer, fill) {
			if (typeof AudioWorkletNode === 'undefined') return 0;
			const ctx = host.options.audioContext ? host.options.audioContext(rate, channels) : new AudioContext({ sampleRate: rate, latencyHint: 'interactive' });
			const offline = typeof OfflineAudioContext !== 'undefined' && ctx instanceof OfflineAudioContext;
			// (about 50 ms ahead, in chunks)
			const ahead = offline ? ctx.length : frames * Math.max(2, Math.ceil(ctx.sampleRate * 0.05 / frames));
			const a = { ctx, channels, frames, buffer, fill, ahead, offline, node: null, queued: 0, running: false, pending: [] };
			const h = host.handles.add(a);
			a.handle = h;
			processorUrl ??= URL.createObjectURL(new Blob([PROCESSOR], { type: 'text/javascript' }));
			// (ready once the worklet has the chunks posted so far)
			ctx.hxmcReady = ctx.audioWorklet.addModule(processorUrl).then(() => new Promise((ready) => {
				if (a.closed) return ready();
				a.node = new AudioWorkletNode(ctx, 'hxmc-output', { numberOfInputs: 0, outputChannelCount: [channels], processorOptions: { channels } });
				a.node.port.onmessage = (e) => {
					if (e.data === 'ping') return ready();
					a.queued = Math.max(0, a.queued - e.data);
					pump(a, h);
				};
				a.node.connect(ctx.destination);
				for (const c of a.pending) a.node.port.postMessage(c, [c.buffer]);
				a.pending = [];
				a.node.port.postMessage('ping');
			}));
			if (!offline && !resumes) {
				resumes = true;
				for (const t of ['pointerdown', 'keydown']) document.addEventListener(t, resume, { capture: true });
			}
			outputs.add(a);
			return h;
		},
		audio_rate: (h) => host.handles.get(h).ctx.sampleRate,
		audio_latency(h) {
			const a = host.handles.get(h);
			return a.ahead / a.ctx.sampleRate + (a.ctx.baseLatency ?? 0) + (a.ctx.outputLatency ?? 0);
		},
		audio_start(h) {
			const a = host.handles.get(h);
			a.running = true;
			if (!a.offline) a.ctx.resume();
			pump(a, h);
		},
		audio_stop(h) {
			const a = host.handles.get(h);
			a.running = false;
			a.queued = 0;
			a.pending = [];
			if (a.node) a.node.port.postMessage('clear');
			if (!a.offline) a.ctx.suspend();
		},
		audio_close(h) {
			const a = host.handles.get(h);
			a.running = false;
			a.closed = true;
			if (a.node) a.node.disconnect();
			if (!a.offline) a.ctx.close();
			outputs.delete(a);
			host.handles.remove(h);
		},

		window_open(title, width, height) {
			const given = first && host.options.canvas;
			first = false;
			let c = typeof given === 'string' ? document.getElementById(given) : given;
			const made = !c;
			if (made) {
				c = document.createElement('canvas');
				c.setAttribute('aria-label', host.string(title));
				document.body.appendChild(c);
			}
			// (a canvas the page does not size, whose displayed size is its
			// buffer's: it would grow with the buffer; one an earlier instance
			// sized, kept by hxmc dev: as it is, its pixels too, when its size
			// is the window's)
			const kept = !made && c.hxmcKeepStyled === true;
			if (!kept) {
				const w0 = c.clientWidth;
				c.width += 1;
				if (made || c.clientWidth !== w0) {
					c.style.width = width + 'px';
					c.style.height = height + 'px';
					c.hxmcKeepStyled = true;
				}
			} else if (c.style.width !== width + 'px' || c.style.height !== height + 'px') {
				c.style.width = width + 'px';
				c.style.height = height + 'px';
			}
			const bw = Math.round(width * devicePixelRatio), bh = Math.round(height * devicePixelRatio);
			if (c.width !== bw) c.width = bw;
			if (c.height !== bh) c.height = bh;
			if (c.tabIndex < 0) c.tabIndex = 0;
			const h = host.handles.add(c);
			sync(h);
			c.hxmcOff = listen(c, h);
			c.hxmcSeen = new IntersectionObserver(([e]) => (c.hxmcShown = e.isIntersecting));
			c.hxmcSeen.observe(c);
			c.hxmcMade = made;
			windows.add(h);
			return h;
		},
		window_close(h) {
			const c = host.handles.get(h);
			c.hxmcOff.abort();
			c.hxmcSeen.disconnect();
			c.hxmcInput.remove();
			if (c.hxmcMade) c.remove();
			windows.delete(h);
			host.handles.remove(h);
		},
		canvas(id) {
			const c = document.getElementById(host.string(id));
			return c instanceof HTMLCanvasElement ? host.handles.add(c) : 0;
		},
		width: (h) => host.handles.get(h).width,
		height: (h) => host.handles.get(h).height,
		scale: () => devicePixelRatio,
		prefers_dark: () => (matchMedia('(prefers-color-scheme: dark)').matches ? 1 : 0),
		clipboard_write(p) {
			const s = host.string(p);
			navigator.clipboard?.writeText(s).catch(() => {});
		},
		clipboard_read() {
			const deliver = (s) => queue.push([0, CLIPBOARD, s == null ? 0 : host.handles.add(String(s)), 0, 0, 0, 0]);
			if (pasted && performance.now() - pasted.at < 1000) {
				const t = pasted.text;
				pasted = null;
				deliver(t);
			} else if (navigator.clipboard?.readText) navigator.clipboard.readText().then(deliver, () => deliver(null));
			else deliver(null);
		},
		// gamepad i (Gamepads.hx): its buttons' values then its axes into p
		gamepad_state(i, p) {
			const pad = navigator.getGamepads ? navigator.getGamepads()[i] : null;
			if (!pad || !pad.connected) return 0;
			const f = new Float32Array(host.memory().buffer, p, 21);
			for (let b = 0; b < 17; b++) f[b] = pad.buttons[b] ? pad.buttons[b].value || (pad.buttons[b].pressed ? 1 : 0) : 0;
			for (let a = 0; a < 4; a++) f[17 + a] = pad.axes[a] ?? 0;
			return 1;
		},
		// a fetch (Fetch.hx): started, polled, its body taken
		fetch_start(p) {
			const f = { state: 0, body: null };
			fetch(new URL(host.string(p), document.baseURI)).then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(r.status))).then(
				(b) => { f.body = new Uint8Array(b); f.state = 1; }, () => { f.state = -1; });
			return host.handles.add(f);
		},
		fetch_state: (h) => host.handles.get(h).state,
		fetch_length: (h) => host.handles.get(h).body?.length ?? 0,
		fetch_take(h, p) {
			const f = host.handles.get(h);
			if (f.body) new Uint8Array(host.memory().buffer, p, f.body.length).set(f.body);
			host.handles.remove(h);
		},
		fetch_free: (h) => host.handles.remove(h),
		// a string handle's UTF-8 length, then its bytes into p (the handle freed)
		text_length: (h) => new TextEncoder().encode(host.handles.get(h)).length,
		text_take(h, p) {
			const b = new TextEncoder().encode(host.handles.get(h));
			new Uint8Array(host.memory().buffer, p, b.length).set(b);
			host.handles.remove(h);
		},
		// text input on: the textarea at that area of the canvas (buffer
		// pixels), focused while the focus is the canvas's (or its fallback
		// content's: hxmc.ui's accessibility mirror); off: the canvas focused again
		text_input(h, on, x, y, w, ht) {
			const c = host.handles.get(h), ta = c.hxmcInput;
			c.hxmcTyping = !!on;
			const a = document.activeElement;
			if (on) {
				const r = c.getBoundingClientRect();
				const kx = c.clientWidth / Math.max(1, c.width), ky = c.clientHeight / Math.max(1, c.height);
				const s = ta.style;
				s.left = r.left + c.clientLeft + x * kx + 'px';
				s.top = r.top + c.clientTop + y * ky + 'px';
				s.width = Math.max(1, w * kx) + 'px';
				s.height = s.lineHeight = Math.max(1, ht * ky) + 'px';
				if (a === c || c.contains(a)) ta.focus({ preventScroll: true });
			} else if (a === ta) c.focus({ preventScroll: true });
		},
		set_title(p) {
			document.title = host.string(p);
		},
		set_size(h, w, ht, min) {
			const st = host.handles.get(h).style;
			if (min) {
				st.minWidth = w + 'px';
				st.minHeight = ht + 'px';
			} else {
				st.width = w + 'px';
				st.height = ht + 'px';
			}
		},
		set_cursor(h, c) {
			host.handles.get(h).style.cursor = ['default', 'pointer', 'text', 'crosshair', 'move', 'not-allowed', 'ew-resize', 'ns-resize', 'grab', 'grabbing'][c] ?? 'default';
		},
		next_event(p) {
			const ev = queue.shift();
			if (!ev) return 0;
			new Int32Array(host.memory().buffer, p, 7).set([...ev, 0, 0].slice(0, 7));
			return 1;
		},
		scrolls_at(f) {
			query = f;
		},
		start(frame) {
			const tick = () => {
				frameId = 0;
				if (stopped) return;
				if (windows.size > 0 && [...windows].every((h) => host.handles.get(h).hxmcShown === false)) return (frameId = requestAnimationFrame(tick));
				if (devicePixelRatio !== ratio) {
					ratio = devicePixelRatio;
					for (const h of windows) push([h, SCALE_CHANGE, 0, 0, 0, 0, 0]);
				}
				for (const h of windows) if (sync(h)) push([h, RESIZE, 0, host.handles.get(h).width, host.handles.get(h).height, 0, 0]);
				// (a frame that throws: no more frames, and the page told when it
				// asked, run's option onError)
				let more;
				try {
					more = host.call(frame);
				} catch (e) {
					stopped = true;
					if (!host.options.onError) throw e;
					host.options.onError(e);
					return;
				}
				if (host.exitCode && host.options.onError) host.options.onError(new Error('the program exited with code ' + host.exitCode));
				if (more) frameId = requestAnimationFrame(tick);
			};
			frameId = requestAnimationFrame(tick);
		},
	};
	return { hxmc_os };
}
