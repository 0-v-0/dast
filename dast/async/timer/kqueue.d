module dast.async.timer.kqueue;

// dfmt off
version (Kqueue):
import core.stdc.errno,
	core.sys.posix.sys.types, // for ssize_t, size_t
	core.sys.posix.netinet.tcp,
	core.sys.posix.netinet.in_,
	core.sys.posix.time,
	core.sys.posix.unistd,
	dast.async.core,
	dast.async.timer.common,
	dast.async.socket,
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
		this.clearError();
		this._readBuffer.data = 1;
		if (read)
			read(this._readBuffer);
		return false;
	}

	UintObject _readBuffer;
	Socket _sock;
}
