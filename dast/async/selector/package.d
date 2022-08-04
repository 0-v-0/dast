module dast.async.selector;

version (linux)
	public import dast.async.selector.epoll;

else version (Kqueue)

	public import dast.async.selector.kqueue;

else version (Windows)
	public import dast.async.selector.iocp;

else
	static assert(0, "unsupported platform");
