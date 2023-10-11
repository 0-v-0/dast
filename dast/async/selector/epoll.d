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

class SelectorBase : Selector {
	this() {
		_epollFD = epoll_create1(0);
		_event = new EpollEventChannel(this);
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
		close(_epollFD);
	}

	override bool register(Channel watcher)
	in (watcher) {
		version (HaveTimer)
			if (watcher.type == WatcherType.Timer) {
				auto wt = cast(TimerBase)watcher;
				if (wt)
					wt.setTimer();
			}

		// debug (Log) infof("register, watcher(fd=%d)", watcher.handle);
		const fd = watcher.handle;
		assert(fd >= 0, "The watcher.handle is not initilized!");

		// if (fd < 0) return false;
		epoll_event ev = buildEpollEvent(watcher);
		if (epoll_ctl(_epollFD, EPOLL_CTL_ADD, fd, &ev) != 0) {
			if (errno != EEXIST)
				return false;
		}

		_event.setNext(watcher);
		return true;
	}

	override bool reregister(Channel watcher)
	in (watcher) {
		const int fd = watcher.handle;
		if (fd < 0)
			return false;
		auto ev = buildEpollEvent(watcher);
		return epoll_ctl(_epollFD, EPOLL_CTL_MOD, fd, &ev) == 0;
	}

	override bool unregister(Channel watcher)
	in (watcher) {
		// debug (Log) infof("unregister watcher(fd=%d)", watcher.handle);

		const int fd = watcher.handle;
		if (fd < 0)
			return false;

		if ((epoll_ctl(_epollFD, EPOLL_CTL_DEL, fd, null)) != 0) {
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
		const int len = epoll_wait(_epollFD, events.ptr, events.length, 10);
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

	override void stop() {
		running = false;
	}

protected @property nothrow:
	bool isErro(uint events) => (events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP)) != 0;

	bool isRead(uint events) => (events & EPOLLIN) != 0;

	bool isWrite(uint events) => (events & EPOLLOUT) != 0;

private:
	bool isDisposed;
	bool running;
	int _epollFD;
	EventChannel _event;
}

epoll_event buildEpollEvent(Channel watch) {
	epoll_event ev;
	ev.data.ptr = cast(void*)watch;
	ev.events = EPOLLRDHUP | EPOLLERR | EPOLLHUP;
	if (watch.flag(WatchFlag.Read))
		ev.events |= EPOLLIN;
	if (watch.flag(WatchFlag.Write))
		ev.events |= EPOLLOUT;
	if (watch.flag(WatchFlag.OneShot))
		ev.events |= EPOLLONESHOT;
	if (watch.flag(WatchFlag.ETMode))
		ev.events |= EPOLLET;
	return ev;
}

class EpollEventChannel : EventChannel {
	alias UlongObject = BaseTypeObject!ulong;
	this(Selector loop) {
		super(loop);
		setFlag(WatchFlag.Read, true);
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
		clearError();
		ulong value = void;
		core.sys.posix.unistd.read(handle, &value, value.sizeof);
		_readBuffer.data = value;
		if (read)
			read(_readBuffer);
		return false;
	}

	UlongObject _readBuffer;
}
