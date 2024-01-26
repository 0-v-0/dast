module dast.async.timer.common;

import dast.async.core;
import std.datetime;

enum CustomTimerMinTimeout = 50; // in ms
enum CustomTimerWheelSize = 500;
enum CustomTimerNextTimeout = cast(long)(CustomTimerMinTimeout * 2.0 / 3.0);

alias TimeoutHandler = void delegate(Object sender);

nothrow:

/**
	Timing Wheel manger Class
*/
class TimingWheel {
	/**
		constructor
		Params:
			wheelSize = the Wheel's element router
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
			tm = the timer
	*/
	void addNewTimer(WheelTimer tm, size_t wheel = 0) {
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
		tm._tw = this;
	}

	/**
		The Wheel go forward
		Params:
			size = forward's element size;
		Notes:
			all forward's element will timeout
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
	size_t nextWheel(size_t wheel) {
		auto next = wheel % _list.length;
		return (_now + next) % _list.length;
	}

	/// get the index which is farthest with current index
	size_t getPrev() const => (_now ? _now : _list.length) - 1;
	/// go forward a element,and return the element
	NullWheelTimer doNext() {
		++_now;
		if (_now == _list.length)
			_now = 0;
		return _list[_now];
	}
	/// rest a timer
	void rest(WheelTimer tm, size_t next) {
		remove(tm);
		addNewTimer(tm, next);
	}
	/// remove the timer
	void remove(WheelTimer tm) {
		tm._prev._next = tm._next;
		if (tm._next)
			tm._next._prev = tm._prev;
		tm._tw = null;
		tm._next = null;
		tm._prev = null;
	}

private:
	NullWheelTimer[] _list;
	size_t _now;
}

/**
	The timer parent's class
*/
abstract class WheelTimer {
	~this() {
		stop();
	}
	/**
		the function will be called when the timer timeout
	*/
	void onTimeout();

	pragma(inline, true) final {
		/// rest the timer
		void rest(size_t next = 0) {
			if (_tw) {
				_tw.rest(this, next);
			}
		}

		/// stop the time, it will remove from Wheel
		void stop() {
			if (_tw)
				_tw.remove(this);
		}

		/// the time is active
		@property isActive() const => _tw !is null;
	}
	/// whether the timer only run once
	bool oneShop;

private:
	WheelTimer _next;
	WheelTimer _prev;
	TimingWheel _tw;
}

/// the Header Timer in the wheel
class NullWheelTimer : WheelTimer {
	override void onTimeout() {
		WheelTimer tm = _next;

		while (tm) {
			// WheelTimer timer = tm._next;
			if (tm.oneShop) {
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

	class TestWheelTimer : WheelTimer {
		this() {
			time = Clock.currTime;
		}

		override void onTimeout() nothrow @trusted {
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
	void initialize() {
		if (_timeWheel is null)
			_timeWheel = new TimingWheel(CustomTimerWheelSize);
		_nextTime = Clock.currStdTime / 10_000 + CustomTimerMinTimeout;
	}

	int doWheel() {
		auto nowTime = Clock.currStdTime / 10_000;
		// trace("nowTime - _nextTime = ", nowTime - _nextTime);
		while (nowTime >= _nextTime) {
			_timeWheel.prevWheel();
			_nextTime += CustomTimerMinTimeout;
			nowTime = Clock.currStdTime / 10_000;
		}
		nowTime = _nextTime - nowTime;
		return cast(int)nowTime;
	}

	@property TimingWheel timeWheel() => _timeWheel;

private:
	TimingWheel _timeWheel;
	long _nextTime;
}

abstract class Timer {
	protected bool _isActive;
	protected size_t _interval = 1000;

	/// Timer tick handler - The handler will be handled in another thread
	TickedHandler ticked;

	@property const nothrow @nogc {
		///
		bool isActive() => _isActive;

		size_t wheelSize() => _wheelSize;

		size_t time() => _interval;

		/// in ms
		size_t interval() => _interval;
	}

	/// ditto
	@property interval(size_t v) {
		_interval = v;
		return this;
	}

	/// ditto
	@property interval(Duration duration) {
		_interval = cast(size_t)duration.total!"msecs";
		return this;
	}

	void start() {
		_isActive = true;
	}

	void stop() {
		_isActive = false;
	}

	void reset(size_t interval) {
		_interval = interval;
		reset();
	}

	void reset(Duration duration) {
		interval = duration;
		reset();
	}

	void reset() {
		if (_isActive) {
			stop();
			start();
		}
	}

	protected void onTick() {
		// trace("tick thread id: ", getTid());
		if (ticked)
			ticked(this);
	}

protected:
	uint _wheelSize, _circle;
}

class KissWheelTimer : WheelTimer {
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
