module dast.async.selector.kqueue;

import dast.async.core;

version (Kqueue)  : import core.time,
core.stdc.string,
core.stdc.errno,
core.sys.darwin.sys.event,
core.sys.posix.signal,
core.sys.posix.netinet.tcp,
core.sys.posix.netinet.in_,
core.sys.posix.unistd,
core.sys.posix.time,
dast.async.core,
std.socket,
std.string;

version (HaveTimer) import dast.async.timer.kqueue;

class SelectorBase : Selector {
	this() {
		_kqueueFD = kqueue();
		_event = new KqueueEventChannel(this);
		register(_event);
	}

	~this() {
		dispose();
	}

	void dispose() {
		if (!isDisposed)
			return;
		isDisposed = true;
		unregister(_event);
		close(_kqueueFD);
	}

	private bool isDisposed = false;

	override bool register(Channel watcher)
	in (watcher) {
		int err = -1;
		if (watcher.type != WatcherType.Timer) {
			const int fd = watcher.handle;
			if (fd < 0)
				return false;
			kevent_t[2] ev = void;
			short read = EV_ADD | EV_ENABLE;
			short write = EV_ADD | EV_ENABLE;
			if (watcher.flag(WatchFlag.ETMode)) {
				read |= EV_CLEAR;
				write |= EV_CLEAR;
			}
			EV_SET(&ev[0], fd, EVFILT_READ, read, 0, 0, cast(void*)watcher);
			EV_SET(&ev[1], fd, EVFILT_WRITE, write, 0, 0, cast(void*)watcher);
			if (watcher.flag(WatchFlag.Read) && watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &ev[0], 2, null, 0, null);
			else if (watcher.flag(WatchFlag.Read))
				err = kevent(_kqueueFD, &ev[0], 1, null, 0, null);
			else if (watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &ev[1], 1, null, 0, null);
		} else {
			version (HaveTimer) {
				kevent_t ev;
				auto watch = cast(TimerBase)watcher;
				if (watch is null)
					return false;
				size_t time = watch.time < 20 ? 20 : watch.time; // in millisecond
				EV_SET(&ev, watch.handle, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_CLEAR,
					0, time, cast(void*)watcher);
				err = kevent(_kqueueFD, &ev, 1, null, 0, null);
			}
		}
		if (err < 0)
			return false;
		// watcher.currtLoop = this;
		_event.setNext(watcher);
		return true;
	}

	override bool reregister(Channel watcher) {
		throw new Exception("The Kqueue does not support reregister!");
		//return false;
	}

	override bool unregister(Channel watcher)
	in (watcher) {
		const fd = watcher.handle;
		if (fd < 0)
			return false;

		int err = -1;
		if (watcher.type != WatcherType.Timer) {
			kevent_t[2] ev = void;
			EV_SET(&ev[0], fd, EVFILT_READ, EV_DELETE, 0, 0, cast(void*)watcher);
			EV_SET(&ev[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, cast(void*)watcher);
			if (watcher.flag(WatchFlag.Read) && watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &ev[0], 2, null, 0, null);
			else if (watcher.flag(WatchFlag.Read))
				err = kevent(_kqueueFD, &ev[0], 1, null, 0, null);
			else if (watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &ev[1], 1, null, 0, null);
		} else {
			version (HaveTimer) {
				kevent_t ev;
				auto watch = cast(TimerBase)watcher;
				if (!watch)
					return false;
				EV_SET(&ev, fd, EVFILT_TIMER, EV_DELETE, 0, 0, cast(void*)watcher);
				err = kevent(_kqueueFD, &ev, 1, null, 0, null);
			}
		}
		if (err < 0)
			return false;
		// watcher.currtLoop = null;
		watcher.clear();
		return true;
	}

	// override bool weakUp()
	// {
	//     _event.call();
	//     return true;
	// }

	void onLoop(scope void delegate() weak) {
		running = true;
		auto tspec = timespec(1, 1000 * 10);
		do {
			weak();
			kevent_t[64] events;
			auto len = kevent(_kqueueFD, null, 0, events.ptr, events.length, &tspec);
			if (len < 1)
				continue;
			foreach (i; 0 .. len) {
				auto watch = cast(Channel)(events[i].udata);
				if ((events[i].flags & EV_EOF) || (events[i].flags & EV_ERROR)) {
					watch.close();
					continue;
				}
				version (HaveTimer)
					if (watch.type == WatcherType.Timer) {
						watch.onRead();
						continue;
					}
				if ((events[i].filter & EVFILT_WRITE) && watch.isRegistered) {
					// version(DebugMode) trace("The channel socket is: ", typeid(watch));
					auto wt = cast(SocketChannelBase)watch;
					assert(wt);
					wt.onWriteDone();
				}

				if ((events[i].filter & EVFILT_READ) && watch.isRegistered)
					watch.onRead();
			}
		}
		while (running);
	}

	override void stop() {
		running = false;
	}

private:
	bool running;
	int _kqueueFD;
	EventChannel _event;
}

class KqueueEventChannel : EventChannel {
	this(Selector loop) {
		super(loop);
		setFlag(WatchFlag.Read, true);
		_pair = socketPair();
		_pair[0].blocking = false;
		_pair[1].blocking = false;
		handle = _pair[1].handle;
	}

	~this() {
		close();
	}

	override void call() {
		_pair[0].send("call");
	}

	override void onRead() {
		ubyte[128] data = void;
		while (_pair[1].receive(data) > 0) {
		}

		super.onRead();
	}

	Socket[2] _pair;
}
