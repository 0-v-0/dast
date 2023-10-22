module dast.async.socket.posix;

version (Posix)  : import core.stdc.errno,
core.stdc.string,
dast.async.core,
std.exception,
std.socket,
std.string,
core.sys.posix.sys.socket : accept;

/**
TCP Server
*/
abstract class ListenerBase : SocketChannel {
	this(Selector loop, AddressFamily family = AddressFamily.INET) {
		super(loop, WT.Accept);
		flags |= WF.Read;
		socket = new TcpSocket(family);
	}

	protected bool onAccept(scope AcceptHandler handler) {
		_error = [];
		const clientFd = accept(handle, null, null);
		if (clientFd < 0)
			return false;

		debug (Log)
			info("Listener fd=", handle, " accepted a new connection, client fd=", clientFd);

		if (handler)
			handler(new Socket(clientFd, _socket.addressFamily));
		return true;
	}
}

/**
TCP Client
*/
abstract class StreamBase : SocketChannel {
	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	RecvHandler onReceived;
	SimpleHandler onDisconnected;

	this(Selector loop, uint bufferSize = 4 * 1024) {
		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_rBuf = BUF(bufferSize);
		super(loop, WT.TCP);
		flags |= WF.Read | WF.Write | WF.ETMode;
	}

protected:
	final bool tryRead() {
		_error = [];
		const len = socket.receive(_rBuf);
		debug (Log)
			trace("read nbytes...", len);

		if (len > 0) {
			if (onReceived)
				onReceived(_rBuf[0 .. len]);

			// It's possible that more data are waiting for read in inner buffer
			if (len == _rBuf.length)
				return false;
		} else if (len < 0) {
			// FIXME: Needing refactor or cleanup
			// check more error status
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				_error = cast(string)fromStringz(strerror(errno));
			}

			debug (Log)
				warning("read error: errno=", errno, ", message: ", _error);
		} else {
			debug (Log)
				warning("connection broken: ", _socket.remoteAddress);
			disconnected();
			if (_isRegistered)
				close();
			else
				socket.close(); // release the sources
		}
		return true;
	}

	private void disconnected() {
		_isRegistered = false;
		if (onDisconnected)
			onDisconnected();
	}

	/**
	Try to write a block of data.
	*/
	final size_t tryWrite(in void[] data)
	in (data.length) {
		const len = socket.send(data);
		debug (Log)
			trace("actually sent bytes: ", len, " / ", data.length);

		if (len > 0)
			return len;

		debug (Log)
			warning("errno=", errno, ", message: ", lastSocketError());

		// FIXME: Needing refactor or cleanup
		// check more error status
		if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
			_error = lastSocketError();
			warning("errno=", errno, ", message: ", _error);
		}
		return 0;
	}

	void doConnect(Address addr) {
		socket.connect(addr);
	}

	bool isWriteCancelling;
	ubyte[] _rBuf;
	WriteBufferQueue _writeQueue;
}
