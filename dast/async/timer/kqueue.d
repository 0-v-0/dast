module dast.async.timer.kqueue;

// dfmt off
version (Kqueue):
import core.stdc.errno,
	core.sys.posix.netinet.tcp,
	core.sys.posix.netinet.in_,
	core.sys.posix.time,
	core.sys.posix.unistd,
	dast.async.core,
	dast.async.timer.common,
	std.exception,
	std.socket;
// dfmt on

class TimerBase : TimerChannelBase {
	this(Selector loop) {
		super(loop);
		setFlag(WatchFlag.Read, true);
		_sock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		handle = _sock.handle;
		_readBuffer = new UintObject;
	}

	~this() {
		close();
	}

	bool readTimer(scope ReadCallback read) {
		clearError();
		_readBuffer.data = 1;
		if (read)
			read(_readBuffer);
		return false;
	}

	UintObject _readBuffer;
	Socket _sock;
}
