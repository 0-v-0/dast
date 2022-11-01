module dast.async.timer.common;

import dast.async.core;
import std.datetime;
import std.exception;

enum CustomTimerMinTimeout = 50; // in ms
enum CustomTimerWheelSize = 500;
enum CustomTimer_Next_Timeout = cast(long)(CustomTimerMinTimeout * 2.0 / 3.0);

alias UintObject = BaseTypeObject!uint;

interface ITimer {

	///
	bool isActive();

	/// in ms
	size_t interval();

	/// ditto
	ITimer interval(size_t v);

	/// ditto
	ITimer interval(Duration duration);

	///
	ITimer onTick(TickedEventHandler handler);

	/// immediately: true to call first event immediately
	/// once: true to call timed event only once
	void start(bool immediately = false, bool once = false);

	void stop();

	void reset(bool immediately = false, bool once = false);

	void reset(size_t interval);

	void reset(Duration duration);
}

/**
	Timing Wheel manger Class
*/
class TimingWheel {
	/**
		constructor
		Params:
			wheelSize = the Wheel's element router.
	*/
	this(uint wheelSize) {
		if (wheelSize == 0)
			wheelSize = 2;
		_list = new NullWheelTimer[wheelSize];
		foreach (ref timer; _list)
			timer = new NullWheelTimer;
	}

	/**
		add a Timer into the Wheel
		Params:
			tm = the timer.
	*/
	pragma(inline) void addNewTimer(WheelTimer tm, size_t wheel = 0) {
		size_t index;
		if (wheel > 0)
			index = nextWheel(wheel);
		else
			index = getPrev();

		NullWheelTimer timer = _list[index];
		tm._next = timer._next;
		tm._prev = timer;
		if (timer._next)
			timer._next._prev = tm;
		timer._next = tm;
		tm._manger = this;
	}

	/**
		The Wheel go forward
		Params:
			size = forward's element size;
		Notes:
			all forward's element will timeout.
	*/
	void prevWheel(uint size = 1) {
		if (size == 0)
			return;
		foreach (i; 0 .. size) {
			NullWheelTimer timer = doNext();
			timer.onTimeout();
		}
	}

protected:
	/// get next wheel times 's Wheel
	pragma(inline) size_t nextWheel(size_t wheel) {
		auto next = wheel % _list.length;
		return (_now + next) % _list.length;
	}

	/// get the index which is farthest with current index.
	size_t getPrev() const => (_now ? _now : _list.length) - 1;
	/// go forward a element,and return the element.
	pragma(inline) NullWheelTimer doNext() {
		++_now;
		if (_now == _list.length)
			_now = 0;
		return _list[_now];
	}
	/// rest a timer.
	pragma(inline) void rest(WheelTimer tm, size_t next) {
		remove(tm);
		addNewTimer(tm, next);
	}
	/// remove the timer.
	pragma(inline) void remove(WheelTimer tm) {
		tm._prev._next = tm._next;
		if (tm._next)
			tm._next._prev = tm._prev;
		tm._manger = null;
		tm._next = null;
		tm._prev = null;
	}

private:
	NullWheelTimer[] _list;
	size_t _now;
}

/**
	The timer parent's class.
*/
abstract class WheelTimer {
	~this() {
		stop();
	}
	/**
		the function will be called when the timer timeout.
	*/
	void onTimeout();

	/// rest the timer.
	pragma(inline) final void rest(size_t next = 0) {
		if (_manger) {
			_manger.rest(this, next);
		}
	}

	/// stop the time, it will remove from Wheel.
	pragma(inline) final void stop() {
		if (_manger)
			_manger.remove(this);
	}

	/// the time is active.
	pragma(inline, true) final bool isActive() const => _manger !is null;

	/// get the timer only run once.
	pragma(inline, true) final @property oneShop() => _oneShop;
	/// set the timer only run once.
	pragma(inline) final @property oneShop(bool one) {
		_oneShop = one;
	}

private:
	WheelTimer _next;
	WheelTimer _prev;
	TimingWheel _manger;
	bool _oneShop;
}

/// the Header Timer in the wheel.
class NullWheelTimer : WheelTimer {
	override void onTimeout() {
		WheelTimer tm = _next;

		while (tm) {
			// WheelTimer timer = tm._next;
			if (tm.oneShop()) {
				tm.stop();
			}
			tm.onTimeout();
			tm = tm._next;
		}
	}
}

unittest {
	import std.datetime;
	import std.stdio;
	import std.conv : to;
	import core.thread;
	import std.exception;

	@trusted class TestWheelTimer : WheelTimer {
		this() {
			time = Clock.currTime;
		}

		override void onTimeout() nothrow {
			collectException(writeln("\nname is ", name, " \tcutterTime is : ",
					Clock.currTime.toSimpleString(), "\t new time is : ", time.toSimpleString()));
		}

		string name;
		private SysTime time;
	}

	writeln("start");
	auto wheel = new TimingWheel(5);
	auto timers = new TestWheelTimer[5];
	foreach (tm; 0 .. 5) {
		timers[tm] = new TestWheelTimer;
	}

	int i;
	foreach (timer; timers) {
		timer.name = i.to!string;
		wheel.addNewTimer(timer);
		writeln("i  = ", i);
		++i;
	}
	writeln("prevWheel(5) the _now = ", wheel._now);
	wheel.prevWheel(5);
	Thread.sleep(2.seconds);
	timers[4].stop();
	writeln("prevWheel(5) the _now = ", wheel._now);
	wheel.prevWheel(5);
	Thread.sleep(2.seconds);
	writeln("prevWheel(3) the _now = ", wheel._now);
	wheel.prevWheel(3);
	assert(wheel._now == 3);
	timers[2].rest();
	timers[4].rest();
	writeln("rest prevWheel(2) the _now = ", wheel._now);
	wheel.prevWheel(2);
	assert(wheel._now == 0);

	foreach (u; 0 .. 20) {
		Thread.sleep(2.seconds);
		writeln("prevWheel() the _now = ", wheel._now);
		wheel.prevWheel();
	}
}

struct CustomTimer {
	void init() {
		if (_timeWheel is null)
			_timeWheel = new TimingWheel(CustomTimerWheelSize);
		_nextTime = Clock.currStdTime / 10000 + CustomTimerMinTimeout;
	}

	int doWheel() {
		auto nowTime = Clock.currStdTime / 10000;
		// tracef("nowTime - _nextTime = %d", nowTime - _nextTime);
		while (nowTime >= _nextTime) {
			_timeWheel.prevWheel();
			_nextTime += CustomTimerMinTimeout;
			nowTime = Clock.currStdTime / 10000;
		}
		nowTime = _nextTime - nowTime;
		return cast(int)nowTime;
	}

	@property TimingWheel timeWheel() => _timeWheel;

private:
	TimingWheel _timeWheel;
	long _nextTime;
}

abstract class TimerChannelBase : Channel, ITimer {
	protected bool _isActive;
	protected size_t _interval = 1000;

	/// Timer tick handler
	TickedEventHandler ticked;

	this(Selector loop) {
		super(loop, WatcherType.Timer);
		_timeOut = 50;
	}

	@property const nothrow @nogc {
		///
		bool isActive() => _isActive;

		size_t wheelSize() => _wheelSize;

		size_t time() => _interval;

		/// in ms
		size_t interval() => _interval;
	}

	/// ditto
	@property ITimer interval(size_t v) {
		_interval = v;
		return this;
	}

	/// ditto
	@property ITimer interval(Duration duration) {
		_interval = cast(size_t)duration.total!"msecs";
		return this;
	}

	/// The handler will be handled in another thread.
	ITimer onTick(TickedEventHandler handler) {
		this.ticked = handler;
		return this;
	}

	void start() {
		_inLoop.register(this);
		_isRegistered = true;
		_isActive = true;
	}

	void stop() {
		if (_isActive) {
			_isActive = false;
			onClose();
		}
	}

	void reset(size_t interval) {
		this.interval = interval;
		reset();
	}

	void reset(Duration duration) {
		this.interval = duration;
		reset();
	}

	void reset() {
		if (_isActive) {
			stop();
			start();
		}
	}

	override void close() {
		onClose();
	}

	protected void onTick() {
		// trace("tick thread id: ", getTid());
		if (ticked)
			ticked(this);
	}

protected:
	uint _wheelSize;
	uint _circle;
	size_t _timeOut;
}

alias TimeoutHandler = void delegate(Object sender);

class KissWheelTimer : WheelTimer {
	this() {
		// time = Clock.currTime;
	}

	// override void onTimeout() nothrow
	// {
	//     collectException(trace("\nname is ", name, " \tcutterTime is : ",
	//             Clock.currTime.toSimpleString(), "\t new time is : ", time.toSimpleString()));
	// }

	override void onTimeout() {
		_now++;
		if (_now >= _circle) {
			_now = 0;
			// rest(_wheelSize);
			// if(_watcher)
			//     catchAndLogException(_watcher.onRead);

			if (timeout)
				timeout(this);
		}
	}

	TimeoutHandler timeout;

private:
	// SysTime time;
	// uint _wheelSize;
	uint _circle;
	uint _now;
}
