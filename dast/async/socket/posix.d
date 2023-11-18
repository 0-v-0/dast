module dast.async.socket.posix;

version (Posix)  : import core.stdc.errno,
core.stdc.string,
dast.async.core,
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

	override void onRead() {
		debug (Log)
			trace("start reading");
		while (_isRegistered) {
			const len = socket.receive(_rBuf);
			debug (Log)
				trace("read nbytes...", len);

			if (len > 0) {
				if (onReceived)
					onReceived(_rBuf[0 .. len]);

				// It's possible that more data are waiting for read in inner buffer
				if (len == _rBuf.length)
					continue;
			} else if (len < 0) {
				// FIXME: Needing refactor or cleanup
				// check more error status
				if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
					errorOccurred(text("Socket error on write: fd=", handle, ", message=", lastSocketError()));
				}
			} else {
				debug (Log)
					warning("connection broken: ", _socket.remoteAddress);
				disconnected();
				if (_isRegistered)
					close();
				else
					socket.close(); // release the sources
			}
			break;
		}
	}

	private void disconnected() {
		_isRegistered = false;
		if (onDisconnected)
			onDisconnected();
	}

protected:

	final void tryWrite() {
		size_t len;
		while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
			const data = _writeQueue.front;
			const n = tryWrite(data);
			if (!n) // error
				break;
			if (data.length == n) {
				debug (Log)
					trace("finishing data writing ", n, " bytes");
				_writeQueue.dequeue();
				len += n;
			}
		}
		return len;
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

		// FIXME: Needing refactor or cleanup
		// check more error status
		const err = errno;
		if (err != EINTR && err != EAGAIN && err != EWOULDBLOCK)
			errorOccurred(text("Socket error on write: fd=", handle,
					", errno=", err, ", message: ", lastSocketError()));
		return 0;
	}

	void doConnect(Address addr) {
		socket.connect(addr);
	}

	bool isWriteCancelling;
	ubyte[] _rBuf;
	WriteBufferQueue _writeQueue;
}
