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
	std.socket;
// dfmt on

class TimerBase : TimerChannelBase {
	this(Selector loop) {
		super(loop);
		setFlag(WF.Read);
		_sock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		handle = _sock.handle;
		_readBuffer = new UintObject;
	}

	~this() {
		close();
	}

	bool readTimer(scope ReadCallback read) {
		_error = [];
		_readBuffer.data = 1;
		if (read)
			read(_readBuffer);
		return false;
	}

	UintObject _readBuffer;
	Socket _sock;
}
