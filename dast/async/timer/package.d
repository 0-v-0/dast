module dast.async.timer;

public import dast.async.timer.common;

version (linux)
	public import dast.async.timer.epoll;
else version (Kqueue)
	public import dast.async.timer.kqueue;
else version (Windows)
	public import dast.async.timer.iocp;
