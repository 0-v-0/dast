module dast.async.selector;

version (OSX)
    version = Kqueue;
else version (iOS)
    version = Kqueue;
else version (TVOS)
    version = Kqueue;
else version (WatchOS)
    version = Kqueue;

version (linux)
	public import dast.async.selector.epoll;

else version (Kqueue)

	public import dast.async.selector.kqueue;

else version (Windows)
	public import dast.async.selector.iocp;

else
	static assert(0, "unsupported platform");
