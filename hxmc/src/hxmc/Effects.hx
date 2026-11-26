package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;

// What operations and calls may do, declared in one place: per
// object-level operation and per call, the memory classes (Opt.MOther...)
// it may write and whether it may collect. Opt (value numbering, store
// forwarding, LICM, barriers), LoopVersion and Escape ask here.
//
// A call of a program function writes what its summary says
// (FuncInfo.writes, Facts.findEffects: its body's stores and its callees',
// to a fixed point; MIns.kills), plus what every call changes: the
// thread-locals of frames and the nursery, and what only calls change
// (MCallOnly). A call of unknown code (virtual, closure, structural, a C
// function the runtime does not describe) writes every class.
//
// A collection writes no memory the program reads, but it moves objects: a
// reference loaded before it is stale after it unless it was rooted (the
// lowering roots what lives across a GC point, as it was before the
// optimizer ran). So a GC point ends every load that may yield a reference
// (Opt.versions: an I64 load's version is its class's second one, which
// every GC point renews), and the shadow-stack slots, raw memory and what
// only calls change; an Int's or a Float's field, element or static loaded
// before it is still its value after it.
class Effects {
	// the classes a collection changes (beside the second versions of the
	// references' classes): the shadow-stack slots (the collector moves what
	// they refer to), raw memory (heap objects' addresses), the nursery's
	// bounds and what only calls change
	public static inline var GC_KILL = (1 << Opt.MOther) | (1 << Opt.MCallOnly) | Opt.TLS_BITS | (1 << Opt.MFrame) | Opt.FRAME_BITS;
	// what any call of a program function may change: its frame's push
	// (rt_sp, rt_sp_hw), thread-locals, what only calls change
	public static inline var CALL_KILL = Opt.TLS_BITS | (1 << Opt.MCallOnly);
	// unknown: every class (FuncInfo.writes, MIns.kills)
	public static inline var UNKNOWN = -1;

	// the class of a field at a byte offset (8 buckets: Opt.MFieldAt)
	public static inline function fieldAt(off:Int):Int
		return Opt.MFieldAt + ((off >> 3) & 7);

	// a field's byte offset (loc: its slot, an Int's or Bool's a 4-byte index; MemLower.access)
	public static inline function fieldOff(t:Ty, loc:Int, compact:Bool):Int
		return t.match(TRef(_) | TF64 | TI64 | TId) && !compact ? 8 * loc : 4 * loc;

	// what a store into a field writes
	public static inline function fieldStore(t:Ty, loc:Int, compact:Bool):Int
		return t.match(TVoid) ? 0 : (1 << fieldAt(fieldOff(t, loc, compact))) | (1 << Opt.MField) | (1 << Opt.MOther);

	// a structural store, at an offset only the object's shape knows
	public static inline var ANY_FIELD = Opt.FIELD_BITS | (1 << Opt.MField) | (1 << Opt.MOther);
	// an Array's store or push: its elements and its header (length, kind,
	// storage: the slow path grows or converts it)
	public static inline var ARRAY_STORE = (1 << Opt.MElem) | (1 << Opt.MHdr) | (1 << Opt.MOther);
	// a NativeArray's store: its elements
	public static inline var NARRAY_STORE = (1 << Opt.MElem) | (1 << Opt.MOther);
	// a raw store (hxmc.unsafe.Mem): any memory but the immutable, what only
	// calls change and the thread-locals
	public static inline var RAW_STORE = Opt.EVERY & ~(1 << Opt.MConst) & ~(1 << Opt.MCallOnly) & ~Opt.TLS_BITS;

	// a runtime function the program calls by name that is not one of its
	// own functions (FuncInfo: those have summaries), as the lowering
	// calls it (ECallHost): what it writes (UNKNOWN: not known here)
	public static function host(n:String):Int {
		if (hxmc.ir.FnLower.isPure(n)) return 0;
		if (StringTools.startsWith(n, "hxmc_unsafe_Mem_get") || n == "hxmc_unsafe_Mem_cstr") return 0;
		if (StringTools.startsWith(n, "hxmc_unsafe_Mem_set")) return RAW_STORE;
		if (StringTools.startsWith(n, "hxmc_narray_set_")) return NARRAY_STORE;
		// (allocations: memory nothing reads before; a collection apart)
		if (StringTools.startsWith(n, "hxmc_unsafe_Mem_alloc") || n == "hxmc_narray_new" || n == "hxmc_narray_lit") return 0;
		// (reads: a header's type index, a NativeArray seen as Dynamic, boxed)
		if (n == "hxmc_unsafe_Mem_typeIndexOf" || n == "hxmc_narray_dget") return 0;
		if (n == "hxmc_narray_dset") return NARRAY_STORE;
		if (n == "StringBuf_addChar") return RAW_STORE;
		var c = C.get(n);
		if (c != null) return c;
		return UNKNOWN;
	}

	// C functions the runtime calls: what they write of the memory the
	// program reads (malloc's own state is not; locks and atomics are
	// unknown: they make other threads' writes visible)
	static var C = [
		"strlen" => 0, "strcmp" => 0, "strncmp" => 0, "memcmp" => 0, "getenv" => 0, "clock_gettime" => 0, "sysconf" => 0, "malloc" => 0, "calloc" => 0, "realloc" => 0, "free" => 0,
		"memcpy" => RAW_STORE, "memmove" => RAW_STORE, "memset" => RAW_STORE
	];

	// program functions whose summaries are declared, not computed: the
	// safepoint poll (Safepoints) stops for another thread's collection;
	// the statics are taken as changed there (a loop that waits on one), the
	// objects' fields and arrays not (a collection writes none)
	public static function declared(sym:String):Null<Int>
		return switch sym {
			case "rt_poll": (1 << Opt.MGlobal) | (1 << Opt.MScalar) | (1 << Opt.MTls);
			case _: null;
		};

	// the classes a call writes (i.kills known: its callee's summary)
	public static inline function call(i:MIns):Int
		return i.kills | CALL_KILL | (i.keepsFrame ? 0 : GC_KILL);

	// whether an operation may collect (a GC point: references loaded
	// before it are not valid after it)
	public static function collects(i:MIns):Bool {
		if (i.op == Call) return !i.keepsFrame || i.returnsTwice;
		if (!i.isObj()) return false;
		return switch i.op {
			case New if (i.info.frame): false;
			case NullCheck | GetField | FieldAddr | EnumTag | TypeTest | ArrayLength | NArrayLength | NArrayGet | InitField | Tag | SetField | NArraySet | ArrayInit
				| NArrayInit | RefStore:
				false;
			case Untag: i.info.t.match(TRef(_));
			case ArrayGet: Opt.ptrElem(i.info.t) && !i.info.prechecked;
			case ArraySet if (i.info.prechecked && !Opt.ptrElem(i.info.t)): false;
			// (in the hit block of its test: no slow path)
			case AnonStore: false;
			case _: true;
		}
	}

	// the classes an object-level operation writes (a collection's apart:
	// collects; an operation that runs unknown code writes every class)
	public static function obj(i:MIns):Int
		return switch i.op {
			case NullCheck | GetField | FieldAddr | EnumTag | TypeTest | ArrayLength | NArrayLength | NArrayGet | InitField | Tag: 0;
			case Untag: 0;
			case ArrayGet: 0;
			// (allocations: memory no load sees before them)
			case New | NewDyn | NewArray | NewNArray | Box: 0;
			case SetField: fieldStore(i.info.t, i.info.loc, i.info.compact);
			case AnonStore: ANY_FIELD;
			case NArraySet | ArrayInit | NArrayInit: NARRAY_STORE;
			// (LoopVersion's copy: in range, of the kind: its elements only)
			case ArraySet if (i.info.prechecked && !Opt.ptrElem(i.info.t)): NARRAY_STORE;
			case ArraySet | ArrayPush: ARRAY_STORE;
			case RefStore: RAW_STORE;
			// (its selector's implementations' summaries, MirBuild)
			case VirtualCall if (i.kills != UNKNOWN): i.kills | CALL_KILL;
			case _: Opt.ALL;
		};
}
