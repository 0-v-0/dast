module dast.async.timer.epoll;

version (linux)  : import dast.async.core,
dast.async.timer.common,
core.sys.posix.unistd,
core.sys.linux.timerfd,
core.time,
std.datetime,
std.exception,
std.socket;

abstract class TimerBase : TimerChannelBase {
	this(Selector loop) {
		super(loop);
		setFlag(WF.Read);
		_readBuffer = new UintObject;
		this.handle = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	}

	~this() {
		close();
	}

	bool readTimer(scope ReadCallback read) {
		_error = [];
		uint value;
		core.sys.posix.unistd.read(this.handle, &value, 8);
		_readBuffer.data = value;
		if (read)
			read(_readBuffer);
		return false;
	}

	UintObject _readBuffer;
}

package bool setTimer(int fd) {
	itimerspec its;
	ulong sec = time / 1000,
	nsec = time % 1000 * 1_000_000;
	its.it_value.tv_sec = cast(typeof(its.it_value.tv_sec))sec;
	its.it_value.tv_nsec = cast(typeof(its.it_value.tv_nsec))nsec;
	its.it_interval.tv_sec = its.it_value.tv_sec;
	its.it_interval.tv_nsec = its.it_value.tv_nsec;
	const err = timerfd_settime(fd, 0, &its, null);
	return err != -1;
}
