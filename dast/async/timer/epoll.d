module dast.async.timer.epoll;

// dfmt off
version (linux):
import dast.async.core,
	dast.async.timer.common,
	core.sys.posix.unistd,
	core.time,
	std.datetime,
	std.exception,
	std.socket;
import core.sys.posix.time : itimerspec, CLOCK_MONOTONIC;
// dfmt on

abstract class TimerBase : TimerChannelBase {
	this(Selector loop) {
		super(loop);
		setFlag(WatchFlag.Read, true);
		_readBuffer = new UintObject;
		this.handle = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	}

	~this() {
		close();
	}

	bool setTimer() {
		itimerspec its;
		ulong sec, nsec;
		sec = time / 1000;
		nsec = time % 1000 * 1_000_000;
		its.it_value.tv_sec = cast(typeof(its.it_value.tv_sec))sec;
		its.it_value.tv_nsec = cast(typeof(its.it_value.tv_nsec))nsec;
		its.it_interval.tv_sec = its.it_value.tv_sec;
		its.it_interval.tv_nsec = its.it_value.tv_nsec;
		const err = timerfd_settime(this.handle, 0, &its, null);
		return err != -1;
	}

	bool readTimer(scope ReadCallback read) {
		this.clearError();
		uint value;
		core.sys.posix.unistd.read(this.handle, &value, 8);
		this._readBuffer.data = value;
		if (read)
			read(this._readBuffer);
		return false;
	}

	UintObject _readBuffer;
}

/**
C APIs for timerfd
*/
enum {
	TFD_TIMER_ABSTIME = 1 << 0,
	TFD_CLOEXEC = 0x80000,
	TFD_NONBLOCK = 0x800
}

extern (C):
socket_t timerfd_create(int clockid, int flags) nothrow;
int timerfd_settime(int fd, int flags, const itimerspec* new_value, itimerspec* old_value) nothrow;
int timerfd_gettime(int fd, itimerspec* curr_value) nothrow;
