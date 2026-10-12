module d.gc.time;

import core.time;

enum ulong Microsecond = 10;
enum ulong Millisecond = 1000 * Microsecond;
enum ulong Second = 1000 * Millisecond;
enum ulong Minute = 60 * Second;
enum ulong Hour = 60 * Minute;
enum ulong Day = 24 * Hour;
enum ulong Week = 7 * Day;

ulong getMonotonicTime() {
	auto cur = MonoTime.currTime();
	return (cur - MonoTime.zero).total!"hnsecs";
}

/**
 * Sleep for about `us` microseconds. The collector paces itself with sleeps
 * of 50 to 100 microseconds, which Posix gives. Windows sleeps in ticks of
 * the system timer (a millisecond at best), so a short wait yields the core
 * instead of sleeping a whole tick, and a longer one sleeps in whole
 * milliseconds.
 */
void sleepMicros(uint us) {
	version(Windows) {
		import core.sys.windows.winbase : Sleep, SwitchToThread;
		if (us < 1000) {
			SwitchToThread();
		} else {
			Sleep((us + 999) / 1000);
		}
	} else version(Posix) {
		import core.sys.posix.unistd : usleep;
		usleep(us);
	}
}
