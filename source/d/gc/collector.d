module d.gc.collector;

import d.gc.arena;
import d.gc.emap;
import d.gc.range;
import d.gc.spec;
import d.gc.tcache;
import d.gc.time;
import d.gc.util;
import core.thread.symthread;

struct CollectionInfo {
	size_t usedPages;
	size_t freeBytes;
	size_t pauseTime;
	size_t start;
	size_t stop;
}

/**
 * What the second half of a cycle (the sweep) needs from the first half.
 */
struct CycleContext {
	ubyte gcCycle;
	size_t threadCount;
	CollectionInfo info;

	// Only used by the phase trace.
	ulong pauseStartTime, tStopped, tPrepared, tMarked, tFlushed;
}

struct Collector {
	ThreadCache* treadCache;

	this(ThreadCache* tc) {
		this.treadCache = tc;
	}

	@property
	ref CachedExtentMap emap() {
		return threadCache.emap;
	}

	bool maybeRunGCCycle() {
		return gCollectorState.maybeRunGCCycle(this);
	}

	/**
	 * While a sweep runs, a thread that is about to allocate and finds the
	 * heap too far past where the cycle started helps the sweeper, until the
	 * sweep is over or the heap is back under the limit. This is what keeps
	 * a program that allocates faster than the sweeper reclaims from growing
	 * without bound: the sweeper is paced to stay out of the way of the
	 * mutators, not to let them run away.
	 */
	void assistSweep() {
		import d.gc.extent : gSweepCycle;
		import d.gc.page : gSweepHardLimit;

		if (gSweepCycle.load() == 0 || Arena.computeUsedPageCount() <= gSweepHardLimit) {
			return;
		}

		threadCache.startCollection();
		scope(exit) threadCache.endCollection();

		while (gSweepCycle.load() != 0 && Arena.computeUsedPageCount() > gSweepHardLimit) {
			bool more = false;
			foreach (i; 0 .. ArenaCount) {
				auto a = Arena.getIfInitialized(i);
				if (a !is null) {
					more |= a.assistSweep(emap);
				}
			}

			if (!more) {
				break;
			}

			// Another thread may be in the middle of a step.
			import symgc.thread : sched_yield;
			sched_yield();
		}
	}

	void runGCCycle() {
		// An explicit collection is synchronous: let a running background
		// sweep end first, it needs the collector lock to finish.
		gSweeper.waitIdle();

		gCollectorState.mutex.lock();
		scope(exit) gCollectorState.mutex.unlock();

		CollectionInfo info;
		runGCCycleLocked(info, false);
	}

private:
	/**
	 * Run a collection cycle. The stop-the-world part always runs on this
	 * thread. The sweep, which happens after the world restarts, runs here
	 * too unless `allowAsync` is set and the background sweeper takes it, in
	 * which case this returns true and the sweeper does the rest, including
	 * updating `info` in the collector state.
	 */
	bool runGCCycleLocked(ref CollectionInfo info, bool allowAsync) {
		CycleContext ctx;
		ctx.info.start = getMonotonicTime();
		scope(exit) info = ctx.info;
		assert(gCollectorState.mutex.isHeld(), "Mutex not held!");
		assert(!threadCache.state.busy, "Cannot run GC cycle while busy!");

		// Make sure we do not try to collect during a collection.
		auto oldGCActivationState = threadCache.activateGC(false);
		scope(exit) threadCache.activateGC(oldGCActivationState);

		import d.gc.global;
		auto gcCycle = gState.nextGCCycle();
		ctx.gcCycle = gcCycle;

		// set up the scanner
		import d.gc.scanner;

		// start the threads
		auto threadCount = gCollectorState.scanningThreads;
		if (threadCount == 0) {
			import d.gc.cpu;
			threadCount = getCoreCount();
			assert(threadCount >= 1, "Expected at least one thread!");
		}

		import symgc.thread;
		auto nScanningThreads = threadCount - 1;
		startGCThreads(nScanningThreads);
		ctx.threadCount = threadCount;

		import d.gc.thread;
		auto pauseStartTime = getMonotonicTime();
		ctx.pauseStartTime = pauseStartTime;
		stopTheWorld();
		ctx.tStopped = getMonotonicTime();

		import d.gc.region;
		auto dataRange = gDataRegionAllocator.computeAddressRange();
		auto ptrRange = gPointerRegionAllocator.computeAddressRange();

		import d.gc.range;
		auto managedAddressSpace = dataRange.merge(ptrRange);

		// Start pause: prepare the arenas and turn the SATB log on.
		cycleStart(managedAddressSpace, gcCycle);
		ctx.tPrepared = getMonotonicTime();

		// Go on and on until all worklists are empty.
		markGC(gcCycle, managedAddressSpace);

		// Remark pause: nothing is queued yet, because the world is still stopped.
		cycleRemark();
		ctx.tMarked = getMonotonicTime();

		version(Symgc_druntime_hooks) {
			import core.thread.symthread;
			// note, this skips our own threadcache's cache, but that's OK we're about to flush it.
			ctx.info.freeBytes = getTotalCachedAllocations();
		}
		restartTheWorld();
		ctx.info.pauseTime = getMonotonicTime() - pauseStartTime;

		/**
		 * We might have allocated, and therefore refilled the bin
		 * during the collection process. As a result, slots in the
		 * bins may not be marked at this point.
		 *
		 * The straightforward way to handle this is simply to flush
		 * the bins.
		 *
		 * Alternatively, we could make sure the slots are marked.
		 */
		threadCache.flush();

		/**
		 * The mark is over and the bins are empty, so threads can run and
		 * allocate while we sweep: they only get slabs the sweep has put
		 * back, or fresh ones. Thread creation is allowed again too.
		 */
		clearWorldProbation();

		ctx.tFlushed = getMonotonicTime();

		version(Windows) {
			enum canSweepAsync = false;
		} else version(Symgc_sync_sweep) {
			enum canSweepAsync = false;
		} else {
			enum canSweepAsync = true;
		}

		if (canSweepAsync && allowAsync && gSweeper.submit(ctx)) {
			return true;
		}

		finishCycle(ctx);
		return false;
	}

	/**
	 * The part of the cycle that runs after the world restarted: the sweep
	 * and the bookkeeping. It runs on the sweeper thread when there is one.
	 */
	void finishCycle(ref CycleContext ctx) {
		auto pageCollectStats = collect(ctx.gcCycle);

		import d.gc.extent;
		gSweepCycle.store(0);

		version(Symgc_phase_trace) {
			import core.stdc.stdio : fprintf, stderr;
			auto tSwept = getMonotonicTime();
			enum us = 10.0; // time unit is 100 ns
			fprintf(stderr, "gcphase part1=%.0f threads=%zu start_threads=%.0f stop=%.0f prepare=%.0f mark=%.0f restart=%.0f sweep=%.0f total=%.0f us\n",
				(ctx.tFlushed - ctx.info.start) / us,
				cast(size_t) ctx.threadCount,
				(ctx.pauseStartTime - ctx.info.start) / us, (ctx.tStopped - ctx.pauseStartTime) / us,
				(ctx.tPrepared - ctx.tStopped) / us, (ctx.tMarked - ctx.tPrepared) / us,
				(ctx.pauseStartTime + ctx.info.pauseTime - ctx.tMarked) / us,
				(tSwept - ctx.tFlushed) / us, (tSwept - ctx.info.start) / us);
			import d.gc.page : gSweepT, gSweepHardLimit;
			fprintf(stderr, "gcheap hardLimit=%zu pages, used now=%zu pages, survivors=%zu pages\n",
				cast(size_t) gSweepHardLimit, Arena.computeUsedPageCount(), cast(size_t) pageCollectStats.pagesCommitted);
			fprintf(stderr, "sweepparts dense: scan=%.0f deadfree=%.0f outlined=%.0f minimize=%.0f | sparse: scan=%.0f deadfree=%.0f minimize=%.0f | longest step=%.0f us\n",
				gSweepT[0] / us, gSweepT[1] / us, gSweepT[2] / us, gSweepT[3] / us,
				gSweepT[4] / us, gSweepT[5] / us, gSweepT[6] / us, gSweepT[7] / us);
			gSweepT[] = 0;
		}

		ctx.info.usedPages = pageCollectStats.pagesCommitted;
		ctx.info.freeBytes += pageCollectStats.pagesCommitted * PageSize - pageCollectStats.bytesAllocated;

		/**
		 * Removing roots cannot realloc while inside a finalizer,
		 * because that could cause a deadlock. So we must periodically
		 * minimize the roots array, never when inside the collect
		 * phase.
		 */
		import d.gc.global;
		gState.minimizeRoots();

		ctx.info.stop = getMonotonicTime();
	}

	/**
	 * The cycle is split in a start pause, the mark, and a remark pause. For
	 * now all three run with the world stopped, which must behave exactly as
	 * before: mutators cannot log anything, so the SATB queue stays empty.
	 * Making the mark concurrent moves the restart between the first two.
	 */
	void cycleStart(AddressRange managedAddressSpace, ubyte gcCycle) {
		import d.gc.satb;
		assert(!satbMarking(), "Marking flag already set!");

		prepareGCCycle();

		/**
		 * Empty the bins while the world is stopped. From now on a slab can
		 * only be allocated from once the sweep has visited it and put it
		 * back, so threads can allocate during the sweep.
		 */
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.clearBinsForCollection();
			}
		}

		// Extents created from now on are born after the mark.
		import d.gc.extent;
		gSweepCycle.store(gcCycle);

		/**
		 * The sweeper is paced unless the heap grows past 1/8 over the
		 * collection target, and the threads that allocate help when it
		 * grows past 1/4. The limits are relative to the target, which
		 * comes from what survived, and not to the heap size now: that
		 * one includes whatever the heap grew by during the last sweep, so
		 * limits based on it would grow from one cycle to the next.
		 */
		import d.gc.page : gSweepGrowthLimit, gSweepHardLimit;
		auto usedPages = Arena.computeUsedPageCount();
		auto target = (cast(CollectorState*) &gCollectorState).nextTarget;
		version(Symgc_phase_trace) {
			import core.stdc.stdio : fprintf, stderr;
			fprintf(stderr, "gcstart used=%zu pages nextTarget=%zu pages\n", usedPages, cast(size_t) target);
		}

		gSweepGrowthLimit = target + target / 8;
		gSweepHardLimit = target + target / 4;

		import d.gc.page : gSweepRetainPages;
		gSweepRetainPages = target;

		auto lo = managedAddressSpace.ptr;
		satbBegin(lo, lo + managedAddressSpace.size);
	}

	void cycleRemark() {
		import d.gc.satb;
		satbFlushThread();
		auto n = satbDrain((void*) { assert(false, "Pointer logged while the world was stopped!"); });
		assert(n == 0);
		satbEnd();
	}

	void prepareGCCycle() {
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.prepareGCCycle(emap);
			}
		}
	}

	CollectStats collect(ubyte gcCycle) {
		threadCache.startCollection();
		scope(exit) threadCache.endCollection();

		CollectStats stats;
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.collect(emap, gcCycle, stats);
			}
		}
		return stats;
	}
}

uint disableAutomaticCollections() {
	return gCollectorState.disableAutomaticCollections();
}

uint enableAutomaticCollections() {
	return gCollectorState.enableAutomaticCollections();
}

void collectorPrepareForFork() {
	// The child would not have the sweeper thread, so let a sweep end first.
	while (true) {
		gCollectorState.mutex.lock();
		if (!gSweeper.isActive) {
			return;
		}

		gCollectorState.mutex.unlock();
		gSweeper.waitIdle();
	}
}

void collectorPostForkParent() {
	gCollectorState.mutex.unlock();
}

void collectorPostForkChild() {
	gSweeper.resetAfterFork();
	gCollectorState.mutex.__clear();
}

void setScanningThreads(uint nThreads) {
	gCollectorState.setScanningThreads(nThreads);
}

void setHeapSizeLimit(size_t limit) {
	gCollectorState.setHeapSizeLimit(limit);
}

CollectionInfo lastCollectionInfo() {
	gCollectorState.mutex.lock();
	scope(exit) gCollectorState.mutex.unlock();

	return (cast(CollectorState*)&gCollectorState).lastCollectionInfo;
}

/**
 * Stop the background sweeper thread, if there is one. Called when the GC
 * is torn down.
 */
void cleanupSweeper() {
	gSweeper.stop();
}

/**
 * The sweep and the end of cycle bookkeeping run on a thread of their own, so
 * the thread that triggered the collection is back to its work as soon as the
 * world restarts. It is a GC thread: never paused for a collection, and not
 * scanned. A new cycle does not start while it is running.
 *
 * Finalizers run on this thread, with `inFinalizer` set as usual.
 */
struct Sweeper {
private:
	import d.sync.mutex;
	Mutex mutex;

	bool started;
	bool pending;
	bool active;
	bool stopping;

	CycleContext ctx;

	import symgc.thread : ThreadHandle;
	ThreadHandle thread;

public:
	/**
	 * Hand a cycle over to the sweeper. Returns false if there is no sweeper
	 * thread and none could be started, in which case the caller sweeps.
	 */
	bool submit(ref CycleContext c) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		auto self = cast(Sweeper*) &this;
		assert(!self.active, "A sweep is already running!");

		if (!self.started && !self.startThread()) {
			return false;
		}

		self.ctx = c;
		self.pending = true;
		self.active = true;
		return true;
	}

	@property
	bool isActive() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Sweeper*) &this).active;
	}

	void waitIdle() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		mutex.waitFor(&(cast(Sweeper*) &this).isIdle);
	}

	void stop() shared {
		auto self = cast(Sweeper*) &this;

		{
			mutex.lock();
			scope(exit) mutex.unlock();

			if (!self.started) {
				return;
			}

			self.stopping = true;
		}

		import symgc.thread : joinGCThread;
		joinGCThread(self.thread);

		mutex.lock();
		scope(exit) mutex.unlock();

		self.started = false;
		self.stopping = false;
	}

	/**
	 * The child of a fork has no sweeper thread. The parent made sure no
	 * sweep was running when it forked.
	 */
	void resetAfterFork() shared {
		mutex.__clear();

		auto self = cast(Sweeper*) &this;
		self.started = false;
		self.pending = false;
		self.active = false;
		self.stopping = false;
	}

private:
	bool isIdle() {
		return !active;
	}

	bool hasWork() {
		return pending || stopping;
	}

	bool startThread() {
		import symgc.thread;

		static void entry(void* arg) {
			import d.gc.tcache;

			// Never collect from the sweeper.
			threadCache.activateGC(false);

			version(Symgc_phase_trace) {
				import core.stdc.stdio : fprintf, stderr;
				import core.sys.posix.pthread : pthread_self;
				fprintf(stderr, "sweeper thread=%p\n", cast(void*) pthread_self());
			}

			// Tuning knob, percent of the time the sweeper may run.
			import core.stdc.stdlib : getenv, atoi;
			if (auto duty = getenv("SYMGC_SWEEP_DUTY")) {
				import d.gc.page : gSweepDutyPercent;
				auto percent = atoi(duty);
				gSweepDutyPercent = percent < 1 ? 1 : (percent > 100 ? 100 : percent);
			}

			/**
			 * Background work: when it shares a core with a mutator, the
			 * mutator comes first. On Linux a nice value applies to the
			 * calling thread only.
			 */
			version(linux) {
				import core.sys.posix.sys.resource : setpriority, PRIO_PROCESS;
				setpriority(PRIO_PROCESS, 0, 10);
			}

			(cast(shared(Sweeper)*) arg).run();
		}

		// Static, because it must survive until the thread starts.
		static ThreadRunner!(typeof(&entry)) runner;
		runner.fun = &entry;
		runner.arg = cast(void*) &this;

		started = createGCThread(&thread, &runner);
		return started;
	}

	void run() shared {
		auto self = cast(Sweeper*) &this;

		while (true) {
			CycleContext c;

			{
				mutex.lock();
				scope(exit) mutex.unlock();

				mutex.waitFor(&self.hasWork);
				if (self.stopping) {
					return;
				}

				self.pending = false;
				c = self.ctx;
			}

			import d.gc.tcache;
			auto collector = Collector(&threadCache);
			collector.finishCycle(c);

			/**
			 * This thread is not scanned. Anything it allocated (finishing
			 * the cycle reallocates the roots) and kept in its thread cache
			 * would look dead to the next cycle's sweep, and be freed from
			 * under it. So nothing stays in the cache between cycles.
			 */
			threadCache.flush();

			gCollectorState.completeAsyncCycle(c.info);

			mutex.lock();
			scope(exit) mutex.unlock();

			self.active = false;
		}
	}
}

shared Sweeper gSweeper;

private:
struct CollectorState {
private:
	import d.sync.mutex;
	Mutex mutex;
	uint disableCount;

	// This makes for a 32MB default target.
	enum DefaultMinHeapSize = 32 * 1024 * 1024 / PageSize;
	enum DefaultMaxHeapSize = AddressSpace / PageSize;

	/**
	 * Data about the last collection cycle.
	 */
	CollectionInfo lastCollectionInfo;

	/**
	 * Filtered data over several collection.
	 */
	ulong amortizedDuration;

	size_t amortizedHeapSize = DefaultMinHeapSize;
	size_t peakHeapSize = DefaultMinHeapSize;

	/**
	 * Track the targets to meet before collecting.
	 */
	ulong lastTargetAdjustment;

	size_t nextTarget = DefaultMinHeapSize;

	/**
	 * Configuration.
	 */
	// Do not try to collect bellow this heap size.
	size_t minHeapSize = DefaultMinHeapSize;
	size_t maxHeapSize = DefaultMaxHeapSize;

	// Decay by 12.5% per time interval.
	ubyte lgTargetDecay = 3;

	// Keep a minimum overhead of 12.5% over the current heap size.
	ubyte lgMinOverhead = 3;

	// How many threads to run for scanning. 0 to use the cpu count.
	uint scanningThreads = 0;

public:
	bool maybeRunGCCycle(ref Collector collector) shared {
		// Do not unnecessarily create contention on this mutex.
		if (!mutex.tryLock()) {
			return false;
		}

		scope(exit) mutex.unlock();
		return (cast(CollectorState*) &this).maybeRunGCCycleImpl(collector);
	}

	void setScanningThreads(uint nThreads) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(CollectorState*) &this).scanningThreads = nThreads;
	}

	void setHeapSizeLimit(size_t limit) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(CollectorState*) &this).maxHeapSize = limit / PageSize;
	}

	uint disableAutomaticCollections() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this).disableAutomaticCollectionsImpl();
	}

	uint enableAutomaticCollections() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this).enableAutomaticCollectionsImpl();
	}

private:
	bool maybeRunGCCycleImpl(ref Collector collector) {
		assert(mutex.isHeld(), "mutex not held!");

		if (!needCollection()) {
			return false;
		}

		runGCCycle(collector);
		return true;
	}

	bool needCollection() {
		auto now = getMonotonicTime();
		auto interval = max(amortizedDuration, 100 * Millisecond);

		while (now - lastTargetAdjustment >= interval) {
			auto delta = nextTarget - lastCollectionInfo.usedPages;
			delta -= delta >> lgTargetDecay;
			delta += lastCollectionInfo.usedPages >> (lgTargetDecay + lgMinOverhead);

			auto newTarget = lastCollectionInfo.usedPages + delta;
			if (newTarget == nextTarget) {
				// Limit reached.
				lastTargetAdjustment = now;
				break;
			}

			lastTargetAdjustment += interval;
			nextTarget = newTarget;
		}

		if (disableCount > 0) {
			return false;
		}

		// A cycle is still sweeping.
		if (gSweeper.isActive) {
			return false;
		}

		auto currentHeapSize = Arena.computeUsedPageCount();
		return currentHeapSize >= nextTarget;
	}

	void runGCCycle(ref Collector collector) {
		assert(mutex.isHeld(), "mutex not held!");

		CollectionInfo info;
		if (collector.runGCCycleLocked(info, true)) {
			// The sweeper ends the cycle, see `completeAsyncCycle`.
			return;
		}

		lastCollectionInfo = info;
		updateTargetPageCount();
	}

public:
	/**
	 * Called by the sweeper when it is done with a cycle it was handed.
	 */
	void completeAsyncCycle(ref CollectionInfo info) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		auto self = cast(CollectorState*) &this;
		self.lastCollectionInfo = info;
		self.updateTargetPageCount();
	}

private:

	void updateTargetPageCount() {
		// This creates a low pass filter.
		static next(size_t base, size_t n) {
			return base - (base >> 3) + (n >> 3);
		}

		amortizedDuration =
			next(amortizedDuration, lastCollectionInfo.stop - lastCollectionInfo.start);

		amortizedHeapSize = next(amortizedHeapSize, lastCollectionInfo.usedPages);
		peakHeapSize = max(next(peakHeapSize, lastCollectionInfo.usedPages), lastCollectionInfo.usedPages);

		// Peak target at 1.625x the peak to prevent heap explosion.
		auto tpeak = peakHeapSize + (peakHeapSize >> 1) + (peakHeapSize >> 3);

		// Baseline target at 2x so we don't shrink the heap too fast.
		auto tbaseline = 2 * amortizedHeapSize;

		// We set the target at 2x the current heap size.
		auto target = 2 * lastCollectionInfo.usedPages;

		// Clamp the target using tpeak and tbaseline.
		target = max(target, tbaseline);
		target = min(target, tpeak);

		// Clamp the target based on configuration.
		target = max(target, minHeapSize);
		target = min(target, maxHeapSize);

		// Update target.
		lastTargetAdjustment = lastCollectionInfo.stop;
		nextTarget = target;
	}

	uint disableAutomaticCollectionsImpl() {
		assert(mutex.isHeld(), "mutex not held!");

		return disableCount++;
	}

	uint enableAutomaticCollectionsImpl() {
		assert(mutex.isHeld(), "mutex not held!");
		assert(disableCount > 0);

		return disableCount--;
	}
}

shared CollectorState gCollectorState;
