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

// The whole user address space: 2^47 bytes of addresses, one byte per card.
enum TableSize = size_t(1) << (47 - CardShift);

/**
 * The code the compiler emits loads this on each barrier, and indexes it
 * with `address >> CardShift`.
 */
extern(C) __gshared ubyte* __sd_gc_card_base;

// Mapped before any code that stores a pointer runs, not lazily.
pragma(crt_constructor)
extern(C) void __sd_gc_card_init() {
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
	__sd_gc_card_base[first .. last + 1] = 1;
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

	// Eight cards at a time: an exchange of the whole word is atomic against
	// the byte stores of the program, so a card set after it is seen next time.
	size_t i = lo;
	while (i < hi) {
		if ((i & 7) == 0 && i + 8 <= hi) {
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

	flush();
	return pages;
}

/**
 * Forget what was written so far (a collection is about to start).
 */
void clearCards(size_t start, size_t size) {
	collectCards(start, size, null);
}
