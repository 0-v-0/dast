module dast.async.timer.common;

import dast.async.core;
import std.datetime;

alias TickedHandler = void delegate(Object sender),
TimeoutHandler = void delegate(Object sender);

/++
	Timing Wheel manger Class
+/
nothrow class TimingWheel {
	/++
		constructor
		Params:
			wheelSize = the Wheel's element router
	+/
	this(uint wheelSize) {
		if (wheelSize == 0)
			wheelSize = 2;
		_list = new NullWheelTimer[wheelSize];
		foreach (ref timer; _list)
			timer = new NullWheelTimer;
	}

	/++
		add a Timer into the Wheel
		Params:
			tm = the timer
	+/
	void addTimer(WheelTimer tm, size_t wheel = 0) {
		size_t index;
		if (wheel > 0)
			index = nextWheel(wheel);
		else
			index = getPrev();

		NullWheelTimer timer = _list[index];
		tm.next = timer.next;
		tm.prev = timer;
		if (timer.next)
			timer.next.prev = tm;
		timer.next = tm;
		tm.tw = this;
	}

	/++
		The Wheel go forward
		Params:
			size = forward's element size;
		Notes:
			all forward's element will timeout
	+/
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
		addTimer(tm, next);
	}

	/// remove the timer
	void remove(WheelTimer tm) {
		tm.prev.next = tm.next;
		if (tm.next)
			tm.next.prev = tm.prev;
		tm.tw = null;
		tm.next = null;
		tm.prev = null;
	}

private:
	NullWheelTimer[] _list;
	size_t _now;
}

/++
	The timer parent's class
+/
nothrow abstract class WheelTimer {
	~this() {
		stop();
	}
	/++
		the function will be called when the timer timeout
	+/
	void onTimeout();

	pragma(inline, true) final {
		/// rest the timer
		void rest(size_t next = 0) {
			if (tw) {
				tw.rest(this, next);
			}
		}

		/// stop the time, it will remove from Wheel
		void stop() {
			if (tw)
				tw.remove(this);
		}

		/// the time is active
		@property isActive() const => tw !is null;
	}
	/// whether the timer only run once
	bool oneShop;

private:
	WheelTimer next;
	WheelTimer prev;
	TimingWheel tw;
}

/// the Header Timer in the wheel
class NullWheelTimer : WheelTimer {
	override void onTimeout() {
		WheelTimer tm = next;

		while (tm) {
			// WheelTimer timer = tm.next;
			if (tm.oneShop) {
				tm.stop();
			}
			tm.onTimeout();
			tm = tm.next;
		}
	}
}

///
unittest {
	import std.datetime;
	import core.thread;
	import std.exception;
	import tame.io.stdio;

	class TestWheelTimer : WheelTimer {
		this() {
			time = Clock.currTime;
		}

		override void onTimeout() nothrow @trusted {
			collectException(writeln("\nid is ", id, " \tcurrTime: ",
					Clock.currTime.toSimpleString(), "\tnew time: ", time.toSimpleString()));
		}

		size_t id;
		private SysTime time;
	}

	writeln("start");
	auto wheel = new TimingWheel(5);
	auto timers = new TestWheelTimer[5];
	foreach (tm; 0 .. 5) {
		timers[tm] = new TestWheelTimer;
	}

	foreach (i, timer; timers) {
		timer.id = i;
		wheel.addTimer(timer);
		writeln("i = ", i);
	}
	writeln("prevWheel(5) _now = ", wheel._now);
	wheel.prevWheel(5);
	Thread.sleep(2.seconds);
	timers[4].stop();
	writeln("prevWheel(5) _now = ", wheel._now);
	wheel.prevWheel(5);
	Thread.sleep(2.seconds);
	writeln("prevWheel(3) _now = ", wheel._now);
	wheel.prevWheel(3);
	assert(wheel._now == 3);
	timers[2].rest();
	timers[4].rest();
	writeln("rest prevWheel(2) _now = ", wheel._now);
	wheel.prevWheel(2);
	assert(wheel._now == 0);

	foreach (u; 0 .. 20) {
		Thread.sleep(2.seconds);
		writeln("prevWheel() _now = ", wheel._now);
		wheel.prevWheel();
	}
}

nothrow:

struct CustomTimer {
	enum MinTimeout = 50; // in ms
	enum WheelSize = 500;
	enum NextTimeout = cast(long)(MinTimeout * 2 / 3.0);

	void initialize() {
		if (_wheel is null)
			_wheel = new TimingWheel(WheelSize);
		_nextTime = Clock.currStdTime / 10_000 + MinTimeout;
	}

	int doWheel() {
		auto nowTime = Clock.currStdTime / 10_000;
		// trace("nowTime - _nextTime = ", nowTime - _nextTime);
		while (nowTime >= _nextTime) {
			_wheel.prevWheel();
			_nextTime += MinTimeout;
			nowTime = Clock.currStdTime / 10_000;
		}
		nowTime = _nextTime - nowTime;
		return cast(int)nowTime;
	}

	@property TimingWheel timeWheel() => _wheel;

private:
	TimingWheel _wheel;
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
