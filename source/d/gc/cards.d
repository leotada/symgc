module d.gc.cards;

/**
 * Card marking, the compiler-assisted way to know what the program wrote.
 *
 * With `-version=Symgc_cards` the collector does not ask the kernel which
 * pages were written (d.gc.dirty); the compiler says so. Code built with
 * ldc2 `-gc-card-marking` sets one byte in the card table, `base[addr >> 9]`,
 * after each store of a pointer to memory that is not on the stack or a
 * global, and after each memcpy/memmove to such memory. The collector reads
 * and clears the table to find the 512 byte cards to scan again.
 *
 * Compared to the kernel route: a store that is not a pointer (a float in an
 * object that is written every frame) dirties nothing, nothing faults after a
 * collection cycle starts, and the pause only depends on the pointers the
 * program wrote. The price: every store of a pointer costs three more
 * instructions, and writes that do not come from instrumented code (a C
 * library, `read()` into a buffer) are not seen.
 */


import core.sys.posix.sys.mman;
import core.atomic;

enum CardShift = 9;
enum CardSize = size_t(1) << CardShift;

// One summary byte per 64 KiB (128 cards): set with each card, it lets the
// collector skip the 64 KiB regions with nothing dirty without reading their
// cards, which is what keeps the pause small for a heap of many GiB.
enum SummaryShift = 16;
enum CardsPerSummary = size_t(1) << (SummaryShift - CardShift);
enum SummarySize = size_t(1) << (47 - SummaryShift);

// The whole user address space: 2^47 bytes of addresses, one byte per card.
enum TableSize = size_t(1) << (47 - CardShift);

/**
 * The code the compiler emits loads this on each barrier, and indexes it
 * with `address >> CardShift`.
 */
extern(C) __gshared ubyte* __sd_gc_card_base;
extern(C) __gshared ubyte* __sd_gc_card_summary_base;

/**
 * Mapped before any code that stores a pointer runs, not lazily. The
 * constructors of the program run in no defined order, so this goes in
 * `.preinit_array`, which the dynamic loader runs before all of them.
 */
extern(C) void __sd_gc_card_init() {
	if (__sd_gc_card_base !is null) {
		return;
	}

	enum NoReserve = 0x4000; // MAP_NORESERVE on Linux
	auto q = mmap(null, SummarySize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | NoReserve, -1, 0);
	if (q is MAP_FAILED) {
		import core.stdc.stdio : fputs, stderr;
		import core.stdc.stdlib : abort;
		fputs("symgc: cannot map the card summary\n", stderr);
		abort();
	}

	__sd_gc_card_summary_base = cast(ubyte*) q;

	enum MAP_NORESERVE = 0x4000; // Linux
	enum Flags = MAP_PRIVATE | MAP_ANON | MAP_NORESERVE;
	auto p = mmap(null, TableSize, PROT_READ | PROT_WRITE, Flags, -1, 0);
	if (p is MAP_FAILED) {
		import core.stdc.stdio : fputs, stderr;
		import core.stdc.stdlib : abort;
		fputs("symgc: cannot map the card table\n", stderr);
		abort();
	}

	__sd_gc_card_base = cast(ubyte*) p;
}

/**
 * Mark every card of a range. The compiler calls this after a copy that
 * may carry pointers into memory it cannot see through.
 */
extern(C) void __sd_gc_card_range(void* dst, size_t size) {
	if (size == 0) {
		return;
	}

	auto first = cast(size_t) dst >> CardShift;
	auto last = (cast(size_t) dst + size - 1) >> CardShift;
	auto cards = __sd_gc_card_base;
	auto sums = __sd_gc_card_summary_base;

	/**
	 * A copy of up to a few cards is the common one (an array of a few
	 * elements, a struct): plain byte stores. The slice assignments below
	 * are calls to memset, which cost more than the copy itself for a small
	 * array (copying 8 ints: 2.3 ns without the barrier, 8.3 ns with it).
	 * The stores are atomic, relaxed, so that the compiler does not turn
	 * the loop back into a memset.
	 */
	enum SmallRange = 4;
	if (last - first < SmallRange) {
		foreach (c; first .. last + 1) {
			atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (cards + c), ubyte(1));
		}

		auto s = first >> (SummaryShift - CardShift);
		atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (sums + s), ubyte(1));
		auto e = last >> (SummaryShift - CardShift);
		if (e != s) {
			atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (sums + e), ubyte(1));
		}

		return;
	}

	cards[first .. last + 1] = 1;
	sums[(first >> (SummaryShift - CardShift)) .. (last >> (SummaryShift - CardShift)) + 1] = 1;
}

/**
 * Read and clear the cards of [start, start + size), calling `dg` with the
 * page aligned runs that cover the dirty ones. Returns the number of pages.
 */
size_t collectCards(size_t start, size_t size, scope void delegate(const(void)*, size_t) dg) {
	enum PageSize = 4096;
	enum CardsPerPage = PageSize / CardSize;

	auto lo = start >> CardShift;
	auto hi = (start + size) >> CardShift;
	auto base = __sd_gc_card_base;

	size_t pages = 0;
	size_t runLo = 0;
	size_t runHi = 0;

	void flush() {
		if (runLo < runHi) {
			pages += (runHi - runLo) / PageSize;
			if (dg !is null) {
				dg(cast(const(void)*) runLo, runHi - runLo);
			}
		}

		runLo = runHi = 0;
	}

	void page(size_t pageIndex) {
		auto s = pageIndex * PageSize;
		if (s == runHi && runHi != 0) {
			runHi = s + PageSize;
			return;
		}

		flush();
		runLo = s;
		runHi = s + PageSize;
	}

	// The summary says which 64 KiB regions have a dirty card. It is read and
	// cleared first, so a card set meanwhile sets its summary again.
	auto sbase = __sd_gc_card_summary_base;
	auto slo = lo >> (SummaryShift - CardShift);
	auto shi = (hi + CardsPerSummary - 1) >> (SummaryShift - CardShift);

	foreach (si; slo .. shi) {
		auto sb = cast(shared(ubyte)*) (sbase + si);
		if (atomicLoad!(MemoryOrder.raw)(*sb) == 0) {
			continue;
		}

		atomicStore!(MemoryOrder.rel)(*sb, ubyte(0));

		auto from = si << (SummaryShift - CardShift);
		auto to = from + CardsPerSummary;
		if (from < lo) {
			from = lo;
		}
		if (to > hi) {
			to = hi;
		}

		// Eight cards at a time: an exchange of the whole word is atomic
		// against the byte stores of the program, so a card set after it
		// is seen next time.
		size_t i = from;
		while (i < to) {
			if ((i & 7) == 0 && i + 8 <= to) {
				auto w = cast(shared(ulong)*) (base + i);
				if (atomicLoad!(MemoryOrder.raw)(*w) == 0) {
					i += 8;
					continue;
				}

				auto v = atomicExchange!(MemoryOrder.acq_rel)(w, 0UL);
				foreach (j; 0 .. 8) {
					if ((v >> (8 * j)) & 0xff) {
						page((i + j) / CardsPerPage);
					}
				}

				i += 8;
				continue;
			}

			auto b = cast(shared(ubyte)*) (base + i);
			if (atomicExchange!(MemoryOrder.acq_rel)(b, ubyte(0))) {
				page(i / CardsPerPage);
			}

			i++;
		}
	}

	flush();
	return pages;
}

/**
 * Forget what was written so far (a collection is about to start).
 */
void clearCards(size_t start, size_t size) {
	collectCards(start, size, null);
}

version(LDC) {
	import ldc.attributes : section;

	@section(".preinit_array") __gshared extern(C) void function() __sd_gc_card_preinit = &__sd_gc_card_init;
}
