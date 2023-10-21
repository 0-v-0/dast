module dast.async.timer.iocp;

version (Windows)  : import core.time,
dast.async.core,
dast.async.timer.common,
std.datetime;

class TimerBase : Timer {
	this() {
		_timer = new KissWheelTimer;
		_timer.timeout = (Object) {
			_timer.rest(wheelSize);
			//onRead();
		};
	}

	// override void start(bool immediately = false, bool once = false) {
	// 	setTimerOut();
	// 	super.start(immediately, once);
	// }

	override void stop() {
		_timer.stop();
		super.stop();
	}

	bool setTimerOut() {
		if (!_interval)
			return false;
		_interval = _interval > 20 ? _interval : 20;
		auto size = _interval / CustomTimerMinTimeout;
		const superfluous = _interval % CustomTimerMinTimeout;
		size += superfluous > CustomTimerNextTimeout ? 1 : 0;
		size = size > 0 ? size : 1;
		_wheelSize = cast(uint)size;
		_circle = _wheelSize / CustomTimerWheelSize;
		return true;
	}

	@property KissWheelTimer timer() pure => _timer;

	private KissWheelTimer _timer;
}
