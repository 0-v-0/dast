module dast.async.timer.kqueue;

version (OSX)
    version = Kqueue;
else version (iOS)
    version = Kqueue;
else version (TVOS)
    version = Kqueue;
else version (WatchOS)
    version = Kqueue;

version (Kqueue)  : import core.stdc.errno,
core.sys.posix.netinet.tcp,
core.sys.posix.netinet.in_,
core.sys.posix.time,
core.sys.posix.unistd,
dast.async.core,
dast.async.timer.common;

class TimerBase : Timer {
	this() {
		_sock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		handle = _sock.handle;
	}

	socket_t handle;
	Socket _sock;
}
