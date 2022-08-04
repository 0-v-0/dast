module dast.async.timer.iocp;

// dfmt off
version (Windows):
import core.time,
	dast.async.core,
	dast.async.timer.common,
	std.datetime;
// dfmt on

class TimerBase : TimerChannelBase {
	this(Selector loop) {
		super(loop);
		setFlag(WatchFlag.Read, true);
		_timer = new KissWheelTimer;
		_timer.timeout = &onTimerTimeout;
		_readBuffer = new UintObject;
	}

	bool readTimer(scope ReadCallback read) {
		this.clearError();
		this._readBuffer.data = 1;
		if (read)
			read(this._readBuffer);
		return false;
	}

	// override void start(bool immediately = false, bool once = false) {
	// 	this.setTimerOut();
	// 	super.start(immediately, once);
	// }

	private void onTimerTimeout(Object) {
		_timer.rest(wheelSize);
		this.onRead();
	}

	override void stop() {
		_timer.stop();
		super.stop();
	}

	bool setTimerOut() {
		if (_interval > 0) {
			_interval = _interval > 20 ? _interval : 20;
			auto size = _interval / CustomTimerMinTimeout;
			const superfluous = _interval % CustomTimerMinTimeout;
			size += superfluous > CustomTimer_Next_Timeout ? 1 : 0;
			size = size > 0 ? size : 1;
			_wheelSize = cast(uint)size;
			_circle = _wheelSize / CustomTimerWheelSize;
			return true;
		}
		return false;
	}

	@property KissWheelTimer timer() {
		return _timer;
	}

	UintObject _readBuffer;

	private KissWheelTimer _timer;
}
