module dast.async.timer.kqueue;

version (Kqueue)  : import core.stdc.errno,
core.sys.posix.netinet.tcp,
core.sys.posix.netinet.in_,
core.sys.posix.time,
core.sys.posix.unistd,
dast.async.core,
dast.async.timer.common,
std.socket;

class TimerBase : Timer {
	this() {
		_sock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		handle = _sock.handle;
	}

	socket_t handle;
	Socket _sock;
}
