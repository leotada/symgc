# oneday: a low-latency garbage collector for D

oneday is a fork of [symgc](https://github.com/symmetryinvestments/symgc), the SDC garbage collector ported to
ordinary D. It keeps symgc's allocator, which has no global lock, and moves the mark and the sweep beside the
program. A game written the ordinary D way, with `new`, closures, `~=` and associative arrays and no pools, should not
lose a frame to the collector.

**Status, 2026-10-12: a preview for testing.** Everything is measured on Linux x86-64. Windows and macOS code exists
but has not been built; Android and iOS need work (`platforms.md`). It is meant to be tried, measured and reported
on, not shipped yet.

## What it does, in numbers

The bullet-hell stress test (2 GiB level, 100,000 bullets per second, no pools, 30 s at 60 fps) on a Ryzen 7 3800X
under Linux 6.12, built with DMD 2.113:

| Collector | p99.9 frame | Worst frame | Frames over 16 ms (of 1,800) |
|---|---|---|---|
| druntime's GC | 138 ms | 141 ms | 4 |
| Upstream symgc | 24.7 ms | 28.0 ms | 3 |
| oneday, stop-the-world mark | 10.3 ms | 11.1 ms | 0 |
| oneday, concurrent mark (kernel tracker) | 1.1 ms | 1.3 ms | 0 |
| oneday, LDC with the card barrier | 0.77 ms | 0.87 ms | 0 |
| No collection at all (the game's own cost, DMD) | 0.97 ms | 0.98 ms | 0 |

The rest, including game models with six job threads and 8 GiB heaps, is in `benchmarks.md`.

## Which setup

| You have | You get | Read |
|---|---|---|
| A stock DMD 2.112+ or an LDC with a 2.112+ frontend | The allocator and the concurrent sweep everywhere; on Linux 6.7+ also the concurrent mark through the kernel | `integration.md`, section 1 |
| This project's DMD build (patched druntime) | The same, plus `GC.frameStats`, `excludeCurrentThread`, `step`, `defrag` | `integration.md`, section 4 |
| This project's LDC build | The concurrent mark through a compiler barrier on any Linux kernel, the lowest tail | `integration.md`, section 4 |

## The documents

| File | What it covers |
|---|---|
| `integration.md` | Adding it to a project with dub, DMD, LDC or GDC; selecting it; options; checking it runs; troubleshooting |
| `writing-code.md` | What to write and what to avoid; the frame loop, audio threads and loading screens; rules for C libraries |
| `how-it-works.md` | The allocator, a collection cycle step by step, write tracking, what still pauses, finalizers |
| `platforms.md` | Compilers and operating systems: what is checked, what is expected, what blocks |
| `benchmarks.md` | All numbers, with the commands that produced them |
| `testing.md` | How to help: what to run, the correctness battery, the report template |

## Five-minute start (Linux, DMD 2.112+)

```sh
cat > dub.sdl <<'EOF'
name "trygc"
targetType "executable"
dependency "symgc" path="<your clone of the fork>"
EOF
mkdir -p source && cat > source/app.d <<'EOF'
import symgc.gcobj;
import std.stdio;

class Node { Node next; int[8] payload; }

void main()
{
    Node head;
    foreach (i; 0 .. 20_000_000)
    {
        auto n = new Node;
        n.next = (i % 1000) ? head : null;   // the newest chain stays alive, older ones become garbage
        head = n;
    }
    writeln("done");
}
EOF
dub build -b release
./trygc --DRT-gcopt=gc:sdc     # prints "using SYM GC!"
./trygc                         # the same binary with druntime's GC
```

## Credits and licence

The collector is SDC's, by Amaury Sachet, ported to D by Steven Schveighoffer (symgc, MIT licence). The latency
work in this fork is documented patch by patch in `plans/symgc-patches/` of the dmd repository it was developed in.
