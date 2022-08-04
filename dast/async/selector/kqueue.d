module dast.async.selector.kqueue;

import dast.async.core;

// dfmt off
version(Kqueue):
import core.time,
	core.stdc.string,
	core.stdc.errno,
	core.sys.posix.sys.types, // for ssize_t, size_t
	core.sys.posix.signal,
	core.sys.posix.netinet.tcp,
	core.sys.posix.netinet.in_,
	core.sys.posix.unistd,
	core.sys.posix.time,
	dast.async.core,
	dast.async.timer.kqueue,
	std.exception,
	std.socket,
	std.string;
// dfmt on

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
		if (isDisposed)
			return;
		isDisposed = true;
		unregister(_event);
		core.sys.posix.unistd.close(_kqueueFD);
	}

	private bool isDisposed = false;

	override bool register(Channel watcher)
	in (watcher) {
		int err = -1;
		if (watcher.type == WatcherType.Timer) {
			kevent_t ev;
			auto watch = cast(TimerBase)watcher;
			if (watch is null)
				return false;
			size_t time = watch.time < 20 ? 20 : watch.time; // in millisecond
			EV_SET(&ev, watch.handle, EVFILT_TIMER, EV_ADD | EV_ENABLE | EV_CLEAR,
				0, time, cast(void*)watcher);
			err = kevent(_kqueueFD, &ev, 1, null, 0, null);
		} else {
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
			EV_SET(&(ev[0]), fd, EVFILT_READ, read, 0, 0, cast(void*)watcher);
			EV_SET(&(ev[1]), fd, EVFILT_WRITE, write, 0, 0, cast(void*)watcher);
			if (watcher.flag(WatchFlag.Read) && watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &(ev[0]), 2, null, 0, null);
			else if (watcher.flag(WatchFlag.Read))
				err = kevent(_kqueueFD, &(ev[0]), 1, null, 0, null);
			else if (watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &(ev[1]), 1, null, 0, null);
		}
		if (err < 0) {
			return false;
		}
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
		if (watcher.type == WatcherType.Timer) {
			kevent_t ev;
			auto watch = cast(TimerBase)watcher;
			if (watch is null)
				return false;
			EV_SET(&ev, fd, EVFILT_TIMER, EV_DELETE, 0, 0, cast(void*)watcher);
			err = kevent(_kqueueFD, &ev, 1, null, 0, null);
		} else {
			kevent_t[2] ev = void;
			EV_SET(&(ev[0]), fd, EVFILT_READ, EV_DELETE, 0, 0, cast(void*)watcher);
			EV_SET(&(ev[1]), fd, EVFILT_WRITE, EV_DELETE, 0, 0, cast(void*)watcher);
			if (watcher.flag(WatchFlag.Read) && watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &(ev[0]), 2, null, 0, null);
			else if (watcher.flag(WatchFlag.Read))
				err = kevent(_kqueueFD, &(ev[0]), 1, null, 0, null);
			else if (watcher.flag(WatchFlag.Write))
				err = kevent(_kqueueFD, &(ev[1]), 1, null, 0, null);
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

	// while(true)
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
				Channel watch = cast(Channel)(events[i].udata);
				if ((events[i].flags & EV_EOF) || (events[i].flags & EV_ERROR)) {
					watch.close();
					continue;
				}
				if (watch.type == WatcherType.Timer) {
					watch.onRead();
					continue;
				}
				if ((events[i].filter & EVFILT_WRITE) && watch.isRegistered) {
					// version(DebugMode) trace("The channel socket is: ", typeid(watch));
					SocketChannelBase wt = cast(SocketChannelBase)watch;
					assert(wt !is null);
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

enum : short {
	EVFILT_READ = -1,
	EVFILT_WRITE = -2,
	EVFILT_AIO = -3, /* attached to aio requests */
	EVFILT_VNODE = -4, /* attached to vnodes */
	EVFILT_PROC = -5, /* attached to struct proc */
	EVFILT_SIGNAL = -6, /* attached to struct proc */
	EVFILT_TIMER = -7, /* timers */
	EVFILT_MACHPORT = -8, /* Mach portsets */
	EVFILT_FS = -9, /* filesystem events */
	EVFILT_USER = -10, /* User events */
	EVFILT_VM = -12, /* virtual memory events */
	EVFILT_SYSCOUNT = 11
}

extern (D) void EV_SET(kevent_t* kevp, typeof(kevent_t.tupleof) args) @nogc nothrow {
	*kevp = kevent_t(args);
}

struct kevent_t {
	uintptr_t ident; /* identifier for this event */
	short filter; /* filter for event */
	ushort flags;
	uint fflags;
	intptr_t data;
	void* udata; /* opaque user data identifier */
}

enum {
	/* actions */
	EV_ADD = 0x0001, /* add event to kq (implies enable) */
	EV_DELETE = 0x0002, /* delete event from kq */
	EV_ENABLE = 0x0004, /* enable event */
	EV_DISABLE = 0x0008, /* disable event (not reported) */

	/* flags */
	EV_ONESHOT = 0x0010, /* only report one occurrence */
	EV_CLEAR = 0x0020, /* clear event state after reporting */
	EV_RECEIPT = 0x0040, /* force EV_ERROR on success, data=0 */
	EV_DISPATCH = 0x0080, /* disable event after reporting */

	EV_SYSFLAGS = 0xF000, /* reserved by system */
	EV_FLAG1 = 0x2000, /* filter-specific flag */

	/* returned values */
	EV_EOF = 0x8000, /* EOF detected */
	EV_ERROR = 0x4000, /* error, data contains errno */



}

enum {
	/*
	* data/hint flags/masks for EVFILT_USER, shared with userspace
	*
	* On input, the top two bits of fflags specifies how the lower twenty four
	* bits should be applied to the stored value of fflags.
	*
	* On output, the top two bits will always be set to NOTE_FFNOP and the
	* remaining twenty four bits will contain the stored fflags value.
	*/
	NOTE_FFNOP = 0x00000000, /* ignore input fflags */
	NOTE_FFAND = 0x40000000, /* AND fflags */
	NOTE_FFOR = 0x80000000, /* OR fflags */
	NOTE_FFCOPY = 0xc0000000, /* copy fflags */
	NOTE_FFCTRLMASK = 0xc0000000, /* masks for operations */
	NOTE_FFLAGSMASK = 0x00ffffff,

	NOTE_TRIGGER = 0x01000000, /* Cause the event to be
									triggered for output. */

	/*
	* data/hint flags for EVFILT_{READ|WRITE}, shared with userspace
	*/
	NOTE_LOWAT = 0x0001, /* low water mark */

	/*
	* data/hint flags for EVFILT_VNODE, shared with userspace
	*/
	NOTE_DELETE = 0x0001, /* vnode was removed */
	NOTE_WRITE = 0x0002, /* data contents changed */
	NOTE_EXTEND = 0x0004, /* size increased */
	NOTE_ATTRIB = 0x0008, /* attributes changed */
	NOTE_LINK = 0x0010, /* link count changed */
	NOTE_RENAME = 0x0020, /* vnode was renamed */
	NOTE_REVOKE = 0x0040, /* vnode access was revoked */

	/*
	* data/hint flags for EVFILT_PROC, shared with userspace
	*/
	NOTE_EXIT = 0x80000000, /* process exited */
	NOTE_FORK = 0x40000000, /* process forked */
	NOTE_EXEC = 0x20000000, /* process exec'd */
	NOTE_PCTRLMASK = 0xf0000000, /* mask for hint bits */
	NOTE_PDATAMASK = 0x000fffff, /* mask for pid */

	/* additional flags for EVFILT_PROC */
	NOTE_TRACK = 0x00000001, /* follow across forks */
	NOTE_TRACKERR = 0x00000002, /* could not track child */
	NOTE_CHILD = 0x00000004, /* am a child process */



}

extern (C) {
	int kqueue() @nogc nothrow;
	int kevent(int kq, const kevent_t* changelist, int nchanges,
		kevent_t* eventlist, int nevents, const timespec* timeout) @nogc nothrow;
}

enum SO_REUSEPORT = 0x0200;
