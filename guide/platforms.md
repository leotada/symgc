# Platforms and compilers

State on 2026-10-12. "Checked" means run on the project's test machine (openSUSE Leap 16, Linux 6.12, Ryzen 7
3800X). Everything else is marked as expected or unknown. Reports from other systems are what this preview is for;
see `testing.md`.

## Compilers

| Compiler | Frontend | Upstream symgc | oneday | Concurrent mark | Card barrier | Status |
|---|---|---|---|---|---|---|
| DMD 2.109 and older | ≤ 2.109 | Does not build (no `ThreadBase.tlsGCData`) | Same | — | — | Checked |
| LDC 1.40 | 2.110 | Does not build (same) | Same | — | — | Checked |
| GDC 15.3 | 2.111 | Builds; works with one thread; dies at the first collection once a second druntime thread exists | Same | Same crash | — | Checked |
| Unpatched druntime from dmd `master` (2.113 in development) | 2.113 | Not tried | Works | Kernel tracker, Linux 6.7+ (`mark_race`, `finalizer_order` pass) | — | Checked |
| DMD 2.112 or newer, stock release | ≥ 2.112 | Supported by upstream | Builds | Kernel tracker expected, as above | — | Expected; please report |
| LDC with a 2.112+ frontend, stock | ≥ 2.112 | Supported by upstream | Builds | Kernel tracker expected, as above | — | Expected; please report |
| DMD 2.113 from this project (patched druntime) | 2.113 | Works | Works | Kernel tracker, Linux 6.7+ | — | Checked |
| LDC 1.43-git from this project (`gc-card-marking`) | 2.113 | Does not run on this runtime | Works | Cards, or the kernel tracker | Yes | Checked |

**Why GDC 15 fails:** its druntime (2.111) has `tlsGCData` but not the GC's thread-init hook, which druntime gained
in April 2025 (2.112). The collector never learns about the threads druntime starts and asserts when it tries to
stop them. Supporting 2.111 inside the fork is planned (attach a thread on its first allocation). Until then, GDC
needs a release whose druntime is 2.112 or newer.

**The druntime from this project** adds two things: the game-engine calls in `core.memory.GC` (`frameStats`,
`excludeCurrentThread`, `step`, `defrag`, ...) and a 2-line fix that lets a collector stop the world from its own
thread. oneday needs neither: without the calls it simply does not offer them, and without the fix its GC thread
poses as a placeholder thread while it scans (`core/thread/symthread.d`), which an unpatched druntime accepts.

## Operating systems

| OS | Upstream symgc | oneday | Write tracking available | Known blockers |
|---|---|---|---|---|
| Linux x86-64 | Supported | Measured (every number in `benchmarks.md`) | Cards (patched LDC); kernel tracker on 6.7+ | None |
| Linux arm64 | Tested upstream (4 KiB pages) | Never built | Cards expected to work; the kernel tracker hard-codes x86-64 syscall numbers | The syscall numbers in `d/gc/dirty.d` |
| Windows x64 | Supported with DMD 2.112+ | Code written (card table with `VirtualAlloc`, `.CRT$XCU` start-up), never built | Cards (patched LDC); a `GetWriteWatch` tracker is planned | Untested |
| macOS (Intel, Apple Silicon) | Unknown | Code written (`__mod_init_func` start-up, Darwin `mmap`), never built | Cards (patched LDC) | Untested; DMD only targets Intel |
| Android arm64 | Unknown | Never built | Cards (patched LDC) | The barrier does not mask tagged pointers (Android 11+); the card table is set up from `.preinit_array`, which shared libraries ignore; the 256 GiB table does not fit 39-bit address spaces |
| iOS | Unknown | Never built | Cards (patched LDC), after the Android fixes | Same as Android, plus Apple's limits on virtual memory |

Without write tracking the collector still works everywhere it builds: the mark stops the program, and the sweep
runs beside it.

## Which compiler for which target

| | Linux x86-64 | Linux arm64 | Windows x64 | macOS Intel | macOS Apple Silicon | Android | iOS |
|---|---|---|---|---|---|---|---|
| DMD | Yes | No | Yes | Yes | Through Rosetta | No | No |
| LDC | Yes | Yes | Yes | Yes | Yes | Yes | Yes, less tested |
| GDC | Yes | Yes | MinGW | Unknown | Unknown | No | No |

Phones mean LDC. The plan to make the barrier come from the shared D frontend, so that DMD, LDC and GDC all emit it
for every target they support, is in `plans/cross_platform_gc_plan.md` of the dmd repository.

## Machine requirements

* With cards: the card table reserves 256 GiB (+2 GiB summary) of address space with `MAP_NORESERVE`, so
  `vm.overcommit_memory` must be 0 or 1.
* Kernel tracker: Linux 6.7+ with `userfaultfd` available to unprivileged processes in user mode
  (`UFFD_USER_MODE_ONLY`, the default on most distributions). If it is not available, the collector falls back to the
  stop-the-world mark without telling you; `SYMGC_DIRTY=0` forces that fallback for comparisons.
