// The C side of ComTyped.hx: ComCalls_dyn.c's counter, with two methods
// more for typed parameters: an array and its count, two [out] interfaces.
#ifdef _WIN32
#define COBJMACROS
#include <windows.h>
#include <oleauto.h>
#include <stdint.h>
#include <stddef.h>

#define EXPORT __declspec(dllexport)

typedef struct { int32_t x, y; } Pt;
typedef struct { double a, b, c; } Big;

// {6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A01} ICounter, {...02} ISecond, {...03} ICallback, {...05} ICounter2
static const GUID IID_ICounter = {0x6A1B0C2D, 0x0001, 0x4E5F, {0x8A, 0x9B, 0x0C, 0x1D, 0x2E, 0x3F, 0x4A, 0x01}};
static const GUID IID_ISecond = {0x6A1B0C2D, 0x0001, 0x4E5F, {0x8A, 0x9B, 0x0C, 0x1D, 0x2E, 0x3F, 0x4A, 0x02}};
static const GUID IID_ICallback = {0x6A1B0C2D, 0x0001, 0x4E5F, {0x8A, 0x9B, 0x0C, 0x1D, 0x2E, 0x3F, 0x4A, 0x03}};
static const GUID IID_ICounter2 = {0x6A1B0C2D, 0x0001, 0x4E5F, {0x8A, 0x9B, 0x0C, 0x1D, 0x2E, 0x3F, 0x4A, 0x05}};
static const GUID IID_IUnknown_ = {0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

// ICallback (implemented in Haxe): Run(x, [out, retval] r), Name([out, retval] BSTR)
typedef struct ICallback ICallback;
typedef struct {
	HRESULT(STDMETHODCALLTYPE *QueryInterface)(ICallback *, REFIID, void **);
	ULONG(STDMETHODCALLTYPE *AddRef)(ICallback *);
	ULONG(STDMETHODCALLTYPE *Release)(ICallback *);
	HRESULT(STDMETHODCALLTYPE *Run)(ICallback *, int32_t, int32_t *);
	HRESULT(STDMETHODCALLTYPE *Name)(ICallback *, BSTR *);
	HRESULT(STDMETHODCALLTYPE *Mix)(ICallback *, LPCWSTR, Pt, double, int32_t *);
	Pt *(STDMETHODCALLTYPE *Where)(ICallback *, Pt *, int32_t);
	HRESULT(STDMETHODCALLTYPE *Flag)(ICallback *, BOOL, int32_t *);
	BOOL(STDMETHODCALLTYPE *Even)(ICallback *, int32_t);
} ICallbackVtbl;
struct ICallback { const ICallbackVtbl *lpVtbl; };

typedef struct Counter Counter;
typedef struct {
	HRESULT(STDMETHODCALLTYPE *QueryInterface)(Counter *, REFIID, void **);
	ULONG(STDMETHODCALLTYPE *AddRef)(Counter *);
	ULONG(STDMETHODCALLTYPE *Release)(Counter *);
	HRESULT(STDMETHODCALLTYPE *Add)(Counter *, int32_t);
	HRESULT(STDMETHODCALLTYPE *Get)(Counter *, int32_t *);
	HRESULT(STDMETHODCALLTYPE *Fail)(Counter *, int32_t);
	HRESULT(STDMETHODCALLTYPE *Check)(Counter *, int32_t);
	double(STDMETHODCALLTYPE *Twice)(Counter *, double);
	Pt *(STDMETHODCALLTYPE *Corner)(Counter *, Pt *);
	HRESULT(STDMETHODCALLTYPE *SumPt)(Counter *, Pt, int32_t *);
	HRESULT(STDMETHODCALLTYPE *SumBig)(Counter *, Big, double *);
	HRESULT(STDMETHODCALLTYPE *GetPt)(Counter *, Pt *);
	HRESULT(STDMETHODCALLTYPE *Echo)(Counter *, BSTR, BSTR *);
	HRESULT(STDMETHODCALLTYPE *Greet)(Counter *, LPCWSTR, LPWSTR *);
	HRESULT(STDMETHODCALLTYPE *EchoVariant)(Counter *, VARIANT, VARIANT *);
	HRESULT(STDMETHODCALLTYPE *Call)(Counter *, ICallback *, int32_t, int32_t *);
	HRESULT(STDMETHODCALLTYPE *Hold)(Counter *, ICallback *);
	HRESULT(STDMETHODCALLTYPE *Drop)(Counter *);
	HRESULT(STDMETHODCALLTYPE *Self)(Counter *, Counter **);
	HRESULT(STDMETHODCALLTYPE *Child)(Counter *, Counter **);
	HRESULT(STDMETHODCALLTYPE *Outs)(Counter *, int32_t *, double *);
	HRESULT(STDMETHODCALLTYPE *More)(Counter *, int32_t, int32_t *);
	HRESULT(STDMETHODCALLTYPE *Flag)(Counter *, BOOL, int32_t *);
	BOOL(STDMETHODCALLTYPE *Truthy)(Counter *, int32_t);
	HRESULT(STDMETHODCALLTYPE *IsBig)(Counter *, int32_t, BOOL *);
	HRESULT(STDMETHODCALLTYPE *SumAll)(Counter *, const int32_t *, int32_t, int32_t *);
	HRESULT(STDMETHODCALLTYPE *Pair)(Counter *, Counter **, Counter **);
} CounterVtbl;
// ISecond: the same object's second interface: Value([out, retval])
typedef struct {
	HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
	ULONG(STDMETHODCALLTYPE *AddRef)(void *);
	ULONG(STDMETHODCALLTYPE *Release)(void *);
	HRESULT(STDMETHODCALLTYPE *Value)(void *, int32_t *);
} SecondVtbl;
struct Counter {
	const CounterVtbl *lpVtbl;
	const SecondVtbl *second;
	LONG rc;
	int32_t n;
	ICallback *held;
};

static LONG live;
static DWORD released_on;
static HRESULT (*pVariantCopy)(VARIANT *, const VARIANT *);
static BSTR (*pSysAllocString)(const OLECHAR *);
static void (*pSysFreeString)(BSTR);
static void *(*pCoTaskMemAlloc)(SIZE_T);

static void load(void) {
	if (pVariantCopy) return;
	HMODULE oa = LoadLibraryA("oleaut32.dll"), ole = LoadLibraryA("ole32.dll");
	pVariantCopy = (void *)GetProcAddress(oa, "VariantCopy");
	pSysAllocString = (void *)GetProcAddress(oa, "SysAllocString");
	pSysFreeString = (void *)GetProcAddress(oa, "SysFreeString");
	pCoTaskMemAlloc = (void *)GetProcAddress(ole, "CoTaskMemAlloc");
}

// (a BSTR's length: its prefix's bytes, halved; SysStringLen without oleaut32 linked)
static UINT blen(BSTR s) { return s ? ((UINT *)s)[-1] / 2 : 0; }

static Counter *from_second(void *s) { return (Counter *)((char *)s - offsetof(Counter, second)); }

static HRESULT STDMETHODCALLTYPE c_qi(Counter *c, REFIID riid, void **ppv) {
	if (IsEqualGUID(riid, &IID_IUnknown_) || IsEqualGUID(riid, &IID_ICounter) || IsEqualGUID(riid, &IID_ICounter2)) *ppv = c;
	else if (IsEqualGUID(riid, &IID_ISecond)) *ppv = &c->second;
	else {
		*ppv = NULL;
		return E_NOINTERFACE;
	}
	InterlockedIncrement(&c->rc);
	return S_OK;
}
static ULONG STDMETHODCALLTYPE c_addref(Counter *c) { return InterlockedIncrement(&c->rc); }
static ULONG STDMETHODCALLTYPE c_release(Counter *c) {
	LONG n = InterlockedDecrement(&c->rc);
	if (n == 0) {
		if (c->held) c->held->lpVtbl->Release(c->held);
		HeapFree(GetProcessHeap(), 0, c);
		released_on = GetCurrentThreadId();
		InterlockedDecrement(&live);
	}
	return n;
}
static HRESULT STDMETHODCALLTYPE c_add(Counter *c, int32_t n) { c->n += n; return S_OK; }
static HRESULT STDMETHODCALLTYPE c_get(Counter *c, int32_t *out) { *out = c->n; return S_OK; }
static HRESULT STDMETHODCALLTYPE c_fail(Counter *c, int32_t code) { return code; }
static double STDMETHODCALLTYPE c_twice(Counter *c, double x) { return 2 * x; }
// (a struct result of a C++ method: through a pointer after this, returned)
static Pt *STDMETHODCALLTYPE c_corner(Counter *c, Pt *r) { r->x = c->n; r->y = -c->n; return r; }
static HRESULT STDMETHODCALLTYPE c_sumpt(Counter *c, Pt p, int32_t *out) { *out = p.x + p.y; return S_OK; }
static HRESULT STDMETHODCALLTYPE c_sumbig(Counter *c, Big b, double *out) { *out = b.a + b.b + b.c; return S_OK; }
static HRESULT STDMETHODCALLTYPE c_getpt(Counter *c, Pt *out) { out->x = 7; out->y = c->n; return S_OK; }
static HRESULT STDMETHODCALLTYPE c_echo(Counter *c, BSTR in, BSTR *out) {
	load();
	UINT n = blen(in);
	// (the string twice, with the length its prefix says: an embedded NUL kept)
	WCHAR buf[512];
	if (n > 250) return E_INVALIDARG;
	for (UINT i = 0; i < n; i++) buf[i] = buf[n + i] = in[i];
	HMODULE oa = LoadLibraryA("oleaut32.dll");
	BSTR (*allocLen)(const OLECHAR *, UINT) = (void *)GetProcAddress(oa, "SysAllocStringLen");
	*out = allocLen(buf, 2 * n);
	return S_OK;
}
static HRESULT STDMETHODCALLTYPE c_greet(Counter *c, LPCWSTR name, LPWSTR *out) {
	load();
	static const WCHAR hello[] = L"hello, ";
	size_t a = lstrlenW(hello), b = lstrlenW(name);
	WCHAR *r = pCoTaskMemAlloc((a + b + 1) * sizeof(WCHAR));
	memcpy(r, hello, a * sizeof(WCHAR));
	memcpy(r + a, name, (b + 1) * sizeof(WCHAR));
	*out = r;
	return S_OK;
}
static HRESULT STDMETHODCALLTYPE c_echovariant(Counter *c, VARIANT in, VARIANT *out) {
	load();
	// (an I4 doubled, an R8 halved, anything else copied)
	if (V_VT(&in) == VT_I4) {
		V_VT(out) = VT_I4;
		V_I4(out) = 2 * V_I4(&in);
		return S_OK;
	}
	if (V_VT(&in) == VT_R8) {
		V_VT(out) = VT_R8;
		V_R8(out) = V_R8(&in) / 2;
		return S_OK;
	}
	return pVariantCopy(out, &in);
}
static HRESULT STDMETHODCALLTYPE c_call(Counter *c, ICallback *cb, int32_t x, int32_t *out) { return cb->lpVtbl->Run(cb, x, out); }
static HRESULT STDMETHODCALLTYPE c_hold(Counter *c, ICallback *cb) {
	if (c->held) c->held->lpVtbl->Release(c->held);
	c->held = cb;
	if (cb) cb->lpVtbl->AddRef(cb);
	return S_OK;
}
static HRESULT STDMETHODCALLTYPE c_drop(Counter *c) {
	if (c->held) c->held->lpVtbl->Release(c->held);
	c->held = NULL;
	return S_OK;
}
static HRESULT STDMETHODCALLTYPE c_self(Counter *c, Counter **out) {
	c_addref(c);
	*out = c;
	return S_OK;
}
EXPORT HRESULT counter_new(Counter **out);
static HRESULT STDMETHODCALLTYPE c_child(Counter *c, Counter **out) { return counter_new(out); }
static HRESULT STDMETHODCALLTYPE c_outs(Counter *c, int32_t *a, double *b) {
	*a = c->n + 1;
	*b = c->n / 4.0;
	return S_OK;
}
static HRESULT STDMETHODCALLTYPE c_more(Counter *c, int32_t x, int32_t *out) { *out = x * 10 + c->n; return S_OK; }
// BOOLs: 32-bit ints, any but zero true (256's low byte is zero)
static HRESULT STDMETHODCALLTYPE c_flag(Counter *c, BOOL b, int32_t *out) { *out = b; return S_OK; }
static BOOL STDMETHODCALLTYPE c_truthy(Counter *c, int32_t x) { return x; }
static HRESULT STDMETHODCALLTYPE c_isbig(Counter *c, int32_t x, BOOL *out) { *out = x > 100 ? 256 : 0; return S_OK; }
static HRESULT STDMETHODCALLTYPE c_sumall(Counter *c, const int32_t *v, int32_t n, int32_t *out) {
	int32_t s = 0;
	for (int32_t i = 0; i < n; i++) s += v[i];
	*out = s;
	return S_OK;
}
static HRESULT STDMETHODCALLTYPE c_pair(Counter *c, Counter **a, Counter **b) {
	HRESULT hr = counter_new(a);
	if (FAILED(hr)) return hr;
	*b = NULL;
	return S_OK;
}

static HRESULT STDMETHODCALLTYPE s_qi(void *s, REFIID riid, void **ppv) { return c_qi(from_second(s), riid, ppv); }
static ULONG STDMETHODCALLTYPE s_addref(void *s) { return c_addref(from_second(s)); }
static ULONG STDMETHODCALLTYPE s_release(void *s) { return c_release(from_second(s)); }
static HRESULT STDMETHODCALLTYPE s_value(void *s, int32_t *out) { *out = 1000 + from_second(s)->n; return S_OK; }

static const CounterVtbl counter_vtbl = {c_qi, c_addref, c_release, c_add, c_get, c_fail, c_fail, c_twice, c_corner, c_sumpt, c_sumbig,
	c_getpt, c_echo, c_greet, c_echovariant, c_call, c_hold, c_drop, c_self, c_child, c_outs, c_more, c_flag, c_truthy, c_isbig, c_sumall, c_pair};
static const SecondVtbl second_vtbl = {s_qi, s_addref, s_release, s_value};

EXPORT HRESULT counter_new(Counter **out) {
	Counter *c = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(Counter));
	c->lpVtbl = &counter_vtbl;
	c->second = &second_vtbl;
	c->rc = 1;
	InterlockedIncrement(&live);
	*out = c;
	return S_OK;
}

// the counters alive, and the Win32 id of the thread that freed the last one
EXPORT int32_t counter_live(void) { return live; }
EXPORT int32_t counter_released_on(void) { return released_on; }

// a span and a counter: its length and the count
EXPORT int32_t counter_peek(const uint8_t *p, size_t n, Counter *c) { return (int32_t)n + c->n; }

// a COM interface a Haxe class implements, called from C: on this thread,
// and from a thread of C's own (one the runtime did not start)
EXPORT int32_t callback_run(ICallback *cb, int32_t x) {
	int32_t r = -1;
	HRESULT hr = cb->lpVtbl->Run(cb, x, &r);
	return SUCCEEDED(hr) ? r : hr;
}

EXPORT int32_t callback_name_length(ICallback *cb) {
	load();
	BSTR s = NULL;
	if (FAILED(cb->lpVtbl->Name(cb, &s))) return -1;
	int32_t n = blen(s);
	pSysFreeString(s);
	return n;
}

EXPORT int32_t callback_mix(ICallback *cb) {
	int32_t r = 0;
	Pt p = {3, 4};
	HRESULT hr = cb->lpVtbl->Mix(cb, L"mixé", p, 0.5, &r);
	return SUCCEEDED(hr) ? r : hr;
}

// a direct struct result of a Haxe method (through the pointer after this, returned)
EXPORT int32_t callback_where(ICallback *cb, int32_t k) {
	Pt p = {-1, -1};
	Pt *r = cb->lpVtbl->Where(cb, &p, k);
	return r == &p ? p.x * 100 + p.y : -1;
}

// a direct struct result's call without its pointer: the result null (not an HRESULT)
EXPORT int32_t callback_where_null(ICallback *cb) { return cb->lpVtbl->Where(cb, NULL, 1) == NULL; }

// BOOLs of a Haxe method: an argument of 256 (true, its low byte zero), and a result's int
EXPORT int32_t callback_flag(ICallback *cb, int32_t v) {
	int32_t r = -1;
	HRESULT hr = cb->lpVtbl->Flag(cb, v, &r);
	return SUCCEEDED(hr) ? r : hr;
}
EXPORT int32_t callback_even(ICallback *cb, int32_t x) { return cb->lpVtbl->Even(cb, x); }

// the HRESULT of QueryInterface for ICallback, ICounter (no) and IUnknown;
// whether IUnknown's pointer is the same for two interfaces (identity)
EXPORT int32_t callback_qi(ICallback *cb) {
	void *p = NULL, *u = NULL, *u2 = NULL;
	int32_t r = 0;
	if (SUCCEEDED(cb->lpVtbl->QueryInterface(cb, &IID_ICallback, &p))) { r |= 1; ((ICallback *)p)->lpVtbl->Release(p); }
	if (FAILED(cb->lpVtbl->QueryInterface(cb, &IID_ICounter, &p)) && p == NULL) r |= 2;
	if (SUCCEEDED(cb->lpVtbl->QueryInterface(cb, &IID_IUnknown_, &u))) {
		r |= 4;
		if (SUCCEEDED(((IUnknown *)u)->lpVtbl->QueryInterface(u, &IID_IUnknown_, &u2))) {
			if (u == u2) r |= 8;
			((IUnknown *)u2)->lpVtbl->Release(u2);
		}
		((IUnknown *)u)->lpVtbl->Release(u);
	}
	return r;
}

// AddRef then Release: the count COM sees
EXPORT int32_t com_count(IUnknown *u) {
	u->lpVtbl->AddRef(u);
	return u->lpVtbl->Release(u);
}

// a Haxe object's interface kept by C (AddRef), called later, released
static ICallback *kept;
EXPORT void callback_keep(ICallback *cb) {
	if (cb) cb->lpVtbl->AddRef(cb);
	if (kept) kept->lpVtbl->Release(kept);
	kept = cb;
}
EXPORT int32_t callback_kept_run(int32_t x) { return kept ? callback_run(kept, x) : -1; }

typedef struct { ICallback *cb; int32_t x, r; } Job;
static DWORD WINAPI worker(void *p) {
	Job *j = p;
	int32_t sum = 0;
	for (int i = 0; i < 100; i++) sum += callback_run(j->cb, j->x + i);
	j->r = sum;
	return 0;
}

// n threads of C's own calling cb->Run(x + i) 100 times each: the sum
EXPORT int32_t callback_threads(ICallback *cb, int32_t n, int32_t x) {
	Job jobs[8];
	HANDLE hs[8];
	if (n > 8) n = 8;
	for (int i = 0; i < n; i++) {
		jobs[i].cb = cb;
		jobs[i].x = x;
		jobs[i].r = 0;
		hs[i] = CreateThread(NULL, 0, worker, &jobs[i], 0, NULL);
	}
	WaitForMultipleObjects(n, hs, TRUE, INFINITE);
	int32_t sum = 0;
	for (int i = 0; i < n; i++) {
		CloseHandle(hs[i]);
		sum += jobs[i].r;
	}
	return sum;
}

// ITake (implemented in Haxe): Take(counter), Ping(), called by a thread of
// C's own (the runtime attaches it): the counter's value made there is
// released there, once the Haxe side dropped it, as the thread leaves Haxe
typedef struct ITake ITake;
typedef struct {
	HRESULT(STDMETHODCALLTYPE *QueryInterface)(ITake *, REFIID, void **);
	ULONG(STDMETHODCALLTYPE *AddRef)(ITake *);
	ULONG(STDMETHODCALLTYPE *Release)(ITake *);
	HRESULT(STDMETHODCALLTYPE *Take)(ITake *, Counter *);
	HRESULT(STDMETHODCALLTYPE *Ping)(ITake *);
} ITakeVtbl;
struct ITake { const ITakeVtbl *lpVtbl; };

static HANDLE took, go, taker;
static DWORD taker_id;
static DWORD WINAPI taker_main(void *p) {
	ITake *t = p;
	Counter *c;
	counter_new(&c);
	t->lpVtbl->Take(t, c);
	c_release(c);
	SetEvent(took);
	WaitForSingleObject(go, INFINITE);
	t->lpVtbl->Ping(t);
	return 0;
}

// the thread started, once Take returned: its Win32 id
EXPORT int32_t taker_start(ITake *t) {
	took = CreateEventA(NULL, FALSE, FALSE, NULL);
	go = CreateEventA(NULL, FALSE, FALSE, NULL);
	taker = CreateThread(NULL, 0, taker_main, t, 0, &taker_id);
	WaitForSingleObject(took, INFINITE);
	return taker_id;
}

// the thread's Ping, then its end
EXPORT void taker_finish(void) {
	SetEvent(go);
	WaitForSingleObject(taker, INFINITE);
	CloseHandle(taker);
	CloseHandle(took);
	CloseHandle(go);
}
#endif
