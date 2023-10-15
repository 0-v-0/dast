module dast.async.selector.epoll;

version (linux)  : import dast.async.core,
dast.async.socket,
core.time,
core.stdc.string,
core.stdc.errno,
core.sys.linux.epoll,
core.sys.linux.sys.eventfd,
core.sys.posix.netinet.tcp,
core.sys.posix.netinet.in_,
core.sys.posix.unistd,
std.exception,
std.socket,
std.string;

version (HaveTimer) import dast.async.timer;

alias Selector = Epoll;

class Epoll {
	this() {
		_eventHandle = epoll_create1(0);
		_event = new EpollEventChannel(this);
		register(_event);
	}

	~this() {
		dispose();
	}

	void dispose() {
		if (!_eventHandle)
			return;
		unregister(_event);
		close(_eventHandle);
		_eventHandle = 0;
	}

	bool register(int fd, Channel watcher)
	in (watcher) {
		version (HaveTimer)
			if (watcher.type == WatcherType.Timer)
				setTimer(fd);

		// debug (Log) infof("register, watcher(fd=%d)", watcher.handle);
		const fd = watcher.handle;
		assert(fd >= 0, "The watcher.handle is not initilized!");

		// if (fd < 0) return false;
		epoll_event ev = buildEvent(watcher);
		if (epoll_ctl(_eventHandle, EPOLL_CTL_ADD, fd, &ev) != 0) {
			if (errno != EEXIST)
				return false;
		}
		return true;
	}

	bool reregister(Channel watcher)
	in (watcher) {
		const int fd = watcher.handle;
		if (fd < 0)
			return false;
		auto ev = buildEvent(watcher);
		return epoll_ctl(_eventHandle, EPOLL_CTL_MOD, fd, &ev) == 0;
	}

	bool unregister(Channel watcher)
	in (watcher) {
		debug (Log) info("unregister watcher fd=", watcher.handle);

		const fd = watcher.handle;
		if (fd < 0)
			return false;

		if (epoll_ctl(_eventHandle, EPOLL_CTL_DEL, fd, null)) {
			error("unregister failed, watcher.handle=", watcher.handle);
			return false;
		}
		// TODO: check this
		// watcher.clear();
		return true;
	}

	void onLoop(scope void delegate() weak) {
		running = true;
		do {
			weak();
			handleEvents();
		}
		while (running);
	}

	private void handleEvents() {
		epoll_event[64] events;
		const len = epoll_wait(_eventHandle, events.ptr, events.length, 10);
		foreach (i; 0 .. len) {
			auto watch = cast(Channel)events[i].data.ptr;
			if (watch is null) {
				debug (Log)
					warning("watcher is null");
				continue;
			}

			if (isErro(events[i].events)) {
				debug (Log)
					warning("close event: ", watch.handle);
				watch.close();
				continue;
			}

			if (watch.isRegistered && isRead(events[i].events)) {
				watch.onRead();
			}

			if (watch.isRegistered && isWrite(events[i].events)) {
				auto wt = cast(SocketChannelBase)watch;
				assert(wt);
				wt.onWriteDone();
				// watch.onWrite();
			}
		}
	}

	void stop() {
		running = false;
	}

protected @property nothrow:
	bool isErro(uint events) => (events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP)) != 0;

	bool isRead(uint events) => (events & EPOLLIN) != 0;

	bool isWrite(uint events) => (events & EPOLLOUT) != 0;

private:
	bool running;
	int _eventHandle;
	EventChannel _event;
}

epoll_event buildEvent(Channel watch) {
	epoll_event ev;
	ev.data.ptr = watch;
	ev.events = EPOLLRDHUP | EPOLLERR | EPOLLHUP;
	if (watch.flags & WF.Read)
		ev.events |= EPOLLIN;
	if (watch.flags & WF.Write)
		ev.events |= EPOLLOUT;
	if (watch.flags & WF.OneShot)
		ev.events |= EPOLLONESHOT;
	if (watch.flags & WF.ETMode)
		ev.events |= EPOLLET;
	return ev;
}

class EpollEventChannel : EventChannel {
	alias UlongObject = BaseTypeObject!ulong;
	this(Selector loop) {
		super(loop);
		setFlag(WF.Read);
		_readBuffer = new UlongObject;
		handle = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	}

	~this() {
		close();
	}

	override void call() {
		ulong value = 1;
		core.sys.posix.unistd.write(handle, &value, value.sizeof);
	}

	override void onRead() {
		readEvent();
		super.onRead();
	}

	bool readEvent(scope ReadCallback read = null) {
		_error = [];
		ulong value = void;
		core.sys.posix.unistd.read(handle, &value, value.sizeof);
		_readBuffer.data = value;
		if (read)
			read(_readBuffer);
		return false;
	}

	UlongObject _readBuffer;
}
