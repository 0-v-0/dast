module dast.async.selector.kqueue;

import dast.async.core;

version (OSX)
    version = Kqueue;
else version (iOS)
    version = Kqueue;
else version (TVOS)
    version = Kqueue;
else version (WatchOS)
    version = Kqueue;

version (Kqueue)  : import core.time,
core.stdc.string,
core.stdc.errno,
core.sys.darwin.sys.event,
core.sys.posix.signal,
core.sys.posix.netinet.tcp,
core.sys.posix.netinet.in_,
core.sys.posix.unistd,
core.sys.posix.time,
dast.async.core;

version (HaveTimer) import dast.async.timer.kqueue;

alias Selector = Kqueue;

class Kqueue : KqueueEventChannel {
	this() {
		_eventHandle = kqueue();
		register(handle);
	}

	~this() {
		dispose();
	}

	void dispose() {
		if (!_eventHandle)
			return;
		unregister(this);
		.close(_eventHandle);
		_eventHandle = 0;
	}

	bool register(SocketChannel watcher) @trusted nothrow
	in (watcher) {
		int err = -1;
		if (watcher.type != WT.Timer) {
			const fd = watcher.handle;
			if (fd < 0)
				return false;
			kevent_t[2] ev = void;
			const flags = watcher.flags;
			short read = EV_ADD | EV_ENABLE;
			short write = EV_ADD | EV_ENABLE;
			if (flags & WF.ETMode) {
				read |= EV_CLEAR;
				write |= EV_CLEAR;
			}
			EV_SET(&ev[0], fd, EVFILT_READ, read, 0, 0, cast(void*)watcher);
			EV_SET(&ev[1], fd, EVFILT_WRITE, write, 0, 0, cast(void*)watcher);
			if ((flags & (WF.Read | WF.Write)) == (WF.Read | WF.Write))
				err = kevent(_eventHandle, &ev[0], 2, null, 0, null);
			else if (flags & WF.Read)
				err = kevent(_eventHandle, &ev[0], 1, null, 0, null);
			else if (flags & WF.Write)
				err = kevent(_eventHandle, &ev[1], 1, null, 0, null);
		} else {
			version (HaveTimer) {
				kevent_t ev;
				auto watch = cast(TimerBase)watcher;
				if (watch is null)
					return false;
				size_t time = watch.time < 20 ? 20 : watch.time; // in millisecond
				EV_SET(&ev, watch.handle, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_CLEAR,
					0, time, cast(void*)watcher);
				err = kevent(_eventHandle, &ev, 1, null, 0, null);
			}
		}
		return err >= 0;
	}

	bool reregister(SocketChannel watcher)
	in (watcher) {
		// Kqueue does not support reregister
		return false;
	}

	bool unregister(SocketChannel watcher) @trusted nothrow
	in (watcher) {
		const fd = watcher.handle;
		if (fd < 0)
			return false;

		int err = -1;
		if (watcher.type != WT.Timer) {
			kevent_t[2] ev = void;
			EV_SET(&ev[0], fd, EVFILT_READ, EV_DELETE, 0, 0, cast(void*)watcher);
			EV_SET(&ev[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, cast(void*)watcher);
			const flags = watcher.flags;
			if ((flags & (WF.Read | WF.Write)) == (WF.Read | WF.Write))
				err = kevent(_eventHandle, &ev[0], 2, null, 0, null);
			else if (flags & WF.Read)
				err = kevent(_eventHandle, &ev[0], 1, null, 0, null);
			else if (flags & WF.Write)
				err = kevent(_eventHandle, &ev[1], 1, null, 0, null);
		} else {
			version (HaveTimer) {
				kevent_t ev;
				auto watch = cast(TimerBase)watcher;
				if (!watch)
					return false;
				EV_SET(&ev, fd, EVFILT_TIMER, EV_DELETE, 0, 0, cast(void*)watcher);
				err = kevent(_eventHandle, &ev, 1, null, 0, null);
			}
		}
		return err >= 0;
	}

	// override bool weakUp()
	// {
	//     call();
	//     return true;
	// }

	void onWeakUp() @system {
		kevent_t[64] events;
		const len = kevent(_eventHandle, null, 0, events.ptr, events.length, &tspec);
		if (len < 1)
			return;
		foreach (i; 0 .. len) {
			auto watch = cast(SocketChannel)(events[i].udata);
			if (events[i].flags & (EV_EOF | EV_ERROR)) {
				watch.close();
				continue;
			}
			version (HaveTimer)
				if (watch.type == WT.Timer) {
					watch.onRead();
					continue;
				}
			if (watch.isRegistered) {
				// if (events[i].filter & EVFILT_WRITE) {
				// debug (Log) trace("The channel socket is: ", typeid(watch));
				// assert(cast(SocketChannel)watch);
				// }

				if (events[i].filter & EVFILT_READ)
					watch.onRead();
			}
		}
	}

	private int _eventHandle;
}

private immutable tspec = timespec(1, 1000 * 10);

class KqueueEventChannel : SocketChannel {
    this(Selector loop) {
        super(loop);
		flags |= WF.Read;
		_pair = socketPair();
		_pair[0].blocking = false;
		_pair[1].blocking = false;
		handle = _pair[1].handle;
	}

	~this() {
		close();
	}

	/+ void call() {
		_pair[0].send("call");
	}+/

	override void onRead() {
		ubyte[128] data = void;
		while (_pair[1].receive(data) > 0) {
		}
	}

	Socket[2] _pair;
}
