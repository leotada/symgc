module d.gc.gctime;

/**
 * Time the program's own threads lose to memory management, so a program
 * can tell its own frame time from the collector's:
 *  - Alloc: the allocator's slow paths (refilling a thread bin from an arena,
 *    with its lock waits, and large allocations);
 *  - Collect: deciding on, starting or waiting for a collection, and helping
 *    the sweep (assist);
 *  - Pause: stopped by the collector (start and remark pauses).
 *
 * Each timer counts its own time only: whatever an inner timer recorded
 * meanwhile (a pause during a refill, a collection during an allocation) is
 * taken out, so the kinds add up without counting anything twice.
 *
 * Times are in hnsecs internally and reported in nanoseconds.
 */
enum GcTimeKind : uint {
	Alloc,
	Collect,
	Pause,
}

enum GcTimeKindCount = 3;

/// All threads since the start.
shared ulong[GcTimeKindCount] gGcTimeTotal;

/// This thread since it started.
ulong[GcTimeKindCount] tGcTime;
ulong tGcTimeSum;

struct GcTimer {
	ulong start;
	ulong innerAtStart;
	GcTimeKind kind;

	static GcTimer begin(GcTimeKind kind) {
		import d.gc.time;
		return GcTimer(getMonotonicTime(), tGcTimeSum, kind);
	}

	void end() {
		import d.gc.time;
		auto elapsed = getMonotonicTime() - start;
		auto inner = tGcTimeSum - innerAtStart;
		record(kind, elapsed > inner ? elapsed - inner : 0);
	}
}

void record(GcTimeKind kind, ulong hnsecs) {
	tGcTime[kind] += hnsecs;
	tGcTimeSum += hnsecs;

	import core.atomic : atomicOp;
	atomicOp!"+="(gGcTimeTotal[kind], hnsecs);
}

/**
 * The counters as nanoseconds, in `GcTimeKind` order.
 */
void readThread(ulong* dst) {
	foreach (i; 0 .. GcTimeKindCount) {
		dst[i] = tGcTime[i] * 100;
	}
}

void readTotal(ulong* dst) {
	import core.atomic : atomicLoad;
	foreach (i; 0 .. GcTimeKindCount) {
		dst[i] = atomicLoad(gGcTimeTotal[i]) * 100;
	}
}
