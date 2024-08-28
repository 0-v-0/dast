module dast.async.timer;

public import dast.async.timer.common;

version (OSX)
    version = Kqueue;
else version (iOS)
    version = Kqueue;
else version (TVOS)
    version = Kqueue;
else version (WatchOS)
    version = Kqueue;

version (linux)
	public import dast.async.timer.epoll;
else version (Kqueue)
	public import dast.async.timer.kqueue;
else version (Windows)
	public import dast.async.timer.iocp;
else
	static assert(0, "unsupported platform");
