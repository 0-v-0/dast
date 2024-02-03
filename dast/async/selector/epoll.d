module dast.async.selector.epoll;

version (linux)  : import dast.async.core,
core.time,
core.stdc.string,
core.stdc.errno,
core.sys.linux.epoll,
core.sys.linux.sys.eventfd,
core.sys.posix.netinet.tcp,
core.sys.posix.netinet.in_,
core.sys.posix.unistd;

version (HaveTimer) import dast.async.timer;

alias Selector = Epoll;

class Epoll : EpollEventChannel {
	this() {
		_eventHandle = epoll_create1(0);
		register(this);
	}

	~this() {
		dispose();
	}

	void dispose() {
		if (!_eventHandle)
			return;
		unregister(this);
		close(_eventHandle);
		_eventHandle = 0;
	}

	bool register(SocketChannel watcher)
	in (watcher) {
		// debug (Log) info("register, watcher fd=", watcher.handle);
		const fd = watcher.handle;
		assert(fd >= 0, "The watcher.handle is not initilized");

		// if (fd < 0) return false;
		epoll_event ev = buildEvent(watcher);
		if (epoll_ctl(_eventHandle, EPOLL_CTL_ADD, fd, &ev) != 0) {
			if (errno != EEXIST)
				return false;
		}
		return true;
	}

	bool reregister(SocketChannel watcher)
	in (watcher) {
		const fd = watcher.handle;
		if (fd < 0)
			return false;
		auto ev = buildEvent(watcher);
		return epoll_ctl(_eventHandle, EPOLL_CTL_MOD, fd, &ev) == 0;
	}

	bool unregister(SocketChannel watcher)
	in (watcher) {
		debug (Log)
			info("unregister watcher fd=", watcher.handle);

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

	mixin Loop;

	void onWeakUp() {
		epoll_event[64] events;
		const len = epoll_wait(_eventHandle, events.ptr, events.length, 10);
		foreach (i; 0 .. len) {
			auto watch = cast(SocketChannel)events[i].data.ptr;
			assert(watch);

			if (events[i].events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP)) {
				debug (Log)
					warning("close event: ", watch.handle);
				watch.close();
				continue;
			}

			if (watch.isRegistered && (events[i].events & EPOLLIN)) {
				watch.onRead();
			}

			if (watch.isRegistered && (events[i].events & EPOLLOUT)) {
				assert(cast(SocketChannel)watch);
				// watch.onWrite();
			}
		}
	}

	private int _eventHandle;
}

epoll_event buildEvent(SocketChannel watch) {
	uint events = EPOLLRDHUP | EPOLLERR | EPOLLHUP;
	const flags = watch.flags;
	if (flags & WF.Read)
		events |= EPOLLIN;
	if (flags & WF.Write)
		events |= EPOLLOUT;
	if (flags & WF.OneShot)
		events |= EPOLLONESHOT;
	if (flags & WF.ETMode)
		events |= EPOLLET;
	return epoll_event(events, epoll_data_t(watch));
}

class EpollEventChannel {
	this(Selector loop) {
		flags |= WF.Read;
		handle = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	}

	~this() {
		close();
	}

	/+void call() {
		ulong value = 1;
		write(handle, &value, value.sizeof);
	}+/

	void onRead() {
		ulong value = void;
		read(handle, &value, value.sizeof);
		_rBuf.data = value;
		//super.onRead();
	}
}
