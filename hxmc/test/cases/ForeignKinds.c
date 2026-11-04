// The C side of ForeignKinds.hx, built per target by the corpus harness (zig
// cc): a small reference-counted object system, as a kind of foreign objects
// sees one (hxmc.rt.Foreign). An object has a count, an id, the peer entry
// its Haxe object has (as Objective-C's instance variable hxmc_peer), the
// objects it holds (native retains) and the weak cells that refer to it
// (nulled as it is freed, as objc_storeWeak's). Freeing one logs its id and
// the tag of the thread that freed it, and calls a hook (a destructor that
// runs Haxe code, as an Objective-C mode class's dealloc).
#include <stdint.h>
#include <stdlib.h>

typedef struct fo {
	intptr_t rc;
	intptr_t id;
	intptr_t peer;
	struct fo *held[4];
	void **weak[8];
	int nweak;
} fo;

static intptr_t live, made, batches, batch_ends, counts, wakes;
static intptr_t freed[1 << 16], freed_tag[1 << 16];
static int nfreed;
static int (*tag)(void);
static void (*on_free)(void *, int);
static intptr_t lock_word;

static void lock(void) {
	while (__atomic_exchange_n(&lock_word, 1, __ATOMIC_ACQUIRE)) {}
}

static void unlock(void) {
	__atomic_store_n(&lock_word, 0, __ATOMIC_RELEASE);
}

// (the tag of the calling thread: a hook of the Haxe side's, its thread-local)
void fo_on_tag(void *f) { tag = (int (*)(void))f; }
void fo_on_free(void *f) { on_free = (void (*)(void *, int))f; }

void *fo_new(intptr_t id) {
	fo *o = calloc(1, sizeof(fo));
	o->rc = 1;
	o->id = id;
	o->peer = -1;
	__atomic_add_fetch(&live, 1, __ATOMIC_SEQ_CST);
	__atomic_add_fetch(&made, 1, __ATOMIC_SEQ_CST);
	return o;
}

void *fo_retain(void *p) {
	__atomic_add_fetch(&((fo *)p)->rc, 1, __ATOMIC_SEQ_CST);
	return p;
}

intptr_t fo_release(void *p) {
	fo *o = p;
	intptr_t n = __atomic_sub_fetch(&o->rc, 1, __ATOMIC_SEQ_CST);
	if (n != 0) return n;
	lock();
	for (int i = 0; i < o->nweak; i++) *o->weak[i] = 0;
	o->nweak = 0;
	if (nfreed < (1 << 16)) {
		freed[nfreed] = o->id;
		freed_tag[nfreed] = tag ? tag() : 0;
		nfreed++;
	}
	unlock();
	for (int i = 0; i < 4; i++)
		if (o->held[i]) fo_release(o->held[i]);
	if (on_free) on_free(o, (int)o->id);
	__atomic_sub_fetch(&live, 1, __ATOMIC_SEQ_CST);
	free(o);
	return 0;
}

intptr_t fo_count(void *p) {
	counts++;
	return __atomic_load_n(&((fo *)p)->rc, __ATOMIC_SEQ_CST);
}

intptr_t fo_id(void *p) { return ((fo *)p)->id; }
intptr_t fo_peer(void *p) { return ((fo *)p)->peer; }
void fo_set_peer(void *p, intptr_t i) { ((fo *)p)->peer = i; }

// the native side holding b in a's slot i (a native retain), or letting go
void fo_hold(void *a, intptr_t i, void *b) {
	fo *o = a;
	if (b) fo_retain(b);
	void *old = o->held[i];
	o->held[i] = b;
	if (old) fo_release(old);
}

// weak cells: *cell refers to o until o is freed
void fo_weak_init(void **cell, void *p) {
	*cell = p;
	if (!p) return;
	fo *o = p;
	lock();
	o->weak[o->nweak++] = cell;
	unlock();
}

void *fo_weak_load(void **cell) {
	lock();
	fo *o = *cell;
	if (o) __atomic_add_fetch(&o->rc, 1, __ATOMIC_SEQ_CST);
	unlock();
	return o;
}

void fo_weak_destroy(void **cell) {
	lock();
	fo *o = *cell;
	if (o)
		for (int i = 0; i < o->nweak; i++)
			if (o->weak[i] == cell) {
				o->weak[i] = o->weak[--o->nweak];
				break;
			}
	*cell = 0;
	unlock();
}

void *fo_batch_begin(void) { return (void *)++batches; }
void fo_batch_end(void *t) { (void)t; batch_ends++; }
void fo_wake(intptr_t thread) { (void)thread; __atomic_add_fetch(&wakes, 1, __ATOMIC_SEQ_CST); }

intptr_t fo_live(void) { return __atomic_load_n(&live, __ATOMIC_SEQ_CST); }
intptr_t fo_made(void) { return made; }
intptr_t fo_batches(void) { return batches; }
intptr_t fo_batch_ends(void) { return batch_ends; }
intptr_t fo_wakes(void) { return __atomic_load_n(&wakes, __ATOMIC_SEQ_CST); }
intptr_t fo_nfreed(void) { return nfreed; }
intptr_t fo_freed(intptr_t i) { return freed[i]; }
intptr_t fo_freed_tag(intptr_t i) { return freed_tag[i]; }
void fo_clear_log(void) { nfreed = 0; }
