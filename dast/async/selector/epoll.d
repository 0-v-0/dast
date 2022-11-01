module dast.async.selector.epoll;

// dfmt off
version(linux):
import dast.async.core,
	dast.async.socket,
	core.time,
	core.stdc.string,
	core.stdc.errno,
	core.sys.posix.netinet.tcp,
	core.sys.posix.netinet.in_,
	core.sys.posix.unistd;
version (HaveTimer) import dast.async.timer;
import std.exception,
	std.socket,
	std.string;
// dfmt on

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
		core.sys.posix.unistd.close(_epollFD);
	}

	private bool isDisposed;

	override bool register(Channel watcher)
	in (watcher) {
		version (HaveTimer)
			if (watcher.type == WatcherType.Timer) {
				auto wt = cast(TimerBase)watcher;
				if (wt)
					wt.setTimer();
			}

		// version(DebugMode) infof("register, watcher(fd=%d)", watcher.handle);
		const fd = watcher.handle;
		assert(fd >= 0, "The watcher.handle is not initilized!");

		// if(fd < 0) return false;
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
		// version(DebugMode) infof("unregister watcher(fd=%d)", watcher.handle);

		const int fd = watcher.handle;
		if (fd < 0)
			return false;

		if ((epoll_ctl(_epollFD, EPOLL_CTL_DEL, fd, null)) != 0) {
			errorf("unregister failed, watcher.handle=%d", watcher.handle);
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
					warningf("watcher is null");
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

protected:
	bool isErro(uint events) nothrow => (events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP)) != 0;

	bool isRead(uint events) nothrow => (events & EPOLLIN) != 0;

	bool isWrite(uint events) nothrow => (events & EPOLLOUT) != 0;

	static epoll_event buildEpollEvent(Channel watch) {
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

private:
	bool running;
	int _epollFD;
	EventChannel _event;
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
		readEvent((Object obj) {});
		super.onRead();
	}

	bool readEvent(scope ReadCallback read) {
		clearError();
		ulong value;
		core.sys.posix.unistd.read(handle, &value, value.sizeof);
		_readBuffer.data = value;
		if (read)
			read(_readBuffer);
		return false;
	}

	UlongObject _readBuffer;
}

enum {
	EFD_SEMAPHORE = 0x1,
	EFD_CLOEXEC = 0x80000,
	EFD_NONBLOCK = 0x800
}

enum {
	EPOLL_CLOEXEC = 0x80000,
	EPOLL_NONBLOCK = 0x800
}

enum {
	EPOLLIN = 0x001,
	EPOLLPRI = 0x002,
	EPOLLOUT = 0x004,
	EPOLLRDNORM = 0x040,
	EPOLLRDBAND = 0x080,
	EPOLLWRNORM = 0x100,
	EPOLLWRBAND = 0x200,
	EPOLLMSG = 0x400,
	EPOLLERR = 0x008,
	EPOLLHUP = 0x010,
	EPOLLRDHUP = 0x2000, // since Linux 2.6.17
	EPOLLONESHOT = 1u << 30,
	EPOLLET = 1u << 31
}

/* Valid opcodes ("op" parameter) to issue to epoll_ctl().  */
enum {
	EPOLL_CTL_ADD = 1, // Add a file descriptor to the interface.
	EPOLL_CTL_DEL = 2, // Remove a file descriptor from the interface.
	EPOLL_CTL_MOD = 3, // Change file descriptor epoll_event structure.
}

// dfmt off
extern (C) : @system nothrow :
// dfmt on

align(1) struct epoll_event {
align(1):
	uint events;
	epoll_data_t data;
}

union epoll_data_t {
	void* ptr;
	int fd;
	uint u32;
	ulong u64;
}

int epoll_create(int size);
int epoll_create1(int flags);
int epoll_ctl(int epfd, int op, int fd, epoll_event* event);
int epoll_wait(int epfd, epoll_event* events, int maxevents, int timeout);

socket_t eventfd(uint initval, int flags);
