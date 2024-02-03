module dast.async.tcpstream;

import dast.async.core,
dast.async.selector,
std.exception;

version (Windows) import dast.async.iocp;

version (Posix) import core.stdc.errno;

/** TCP Client */
@safe class TcpStream : SocketChannel {
	import tame.meta;

	mixin Forward!"_socket";

	ConnectionHandler onConnected;
	SimpleHandler onClosed;
	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	RecvHandler onReceived;
	SimpleHandler onDisconnected;
	DataSentHandler onSent;

	@property final bufferSize() const => _rBuf.length;

	// client side
	this(Selector loop, AddressFamily family = AddressFamily.INET, uint bufferSize = 4 * 1024) {
		this(loop, new TcpSocket(family), bufferSize);
	}

	// server side
	this(Selector loop, Socket socket, uint bufferSize = 4 * 1024) nothrow {
		super(loop, WT.TCP);
		flags |= WF.Read | WF.Write | WF.ETMode;
		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_rBuf = BUF(bufferSize);
		this.socket = socket;
		try
			_isConnected = socket.isAlive;
		catch (Exception) {
		}
	}

	void connect(Address addr) @trusted {
		if (_isConnected)
			return;

		try {
			scope Address a = _socket.addressFamily == AddressFamily.INET6 ?
				new Internet6Address(0) : new InternetAddress(0);
			_socket.bind(a);
			doConnect(addr);
			start();
			_isConnected = true;
		} catch (Exception e)
			error(e);

		if (onConnected)
			onConnected(_isConnected);
	}

	void reconnect(Address addr) {
		if (_isConnected)
			close();
		_isConnected = false;
		socket = new TcpSocket(_socket ? _socket.addressFamily : AddressFamily.INET);
		connect(addr);
	}

	@property isConnected() const => _isConnected;

	override void start() nothrow {
		if (_isRegistered)
			return;
		_inLoop.register(this);
		_isRegistered = true;
		version (Windows)
			recv();
	}

	/// safe for big data sending
	void write(const void[] data) nothrow {
		if (!_isConnected)
			return errorOccurred("The connection has been closed");
		if (data.length)
			_writeQueue.push(data);
		if (_writeQueue.length >= _writeQueue.capacity / 2)
			flush();
	}

	override void close() {
		debug (Log) {
			if (!_writeQueue.empty)
				warning("Some data has not been sent yet");
		}

		clearQueue();
		super.close();
		_isConnected = false;
		_socket.shutdown(SocketShutdown.BOTH);
		_socket.close();

		if (onClosed)
			onClosed();
	}

	version (Posix) override void onRead() {
		debug (Log)
			trace("start reading");
		while (_isRegistered) {
			const len = _socket.receive(_rBuf);
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
				if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
					errorOccurred(text("Socket error on write: fd=", handle, ", message=", lastSocketError()));
			} else {
				debug (Log)
					warning("connection broken: ", _socket.remoteAddress);
				disconnected();
				_socket.close(); // release the resource
			}
			break;
		}
	}

	version (Windows) {
		/// Called by selector after data sent
		final onWrite(uint len) {
			if (isWriteCancelling) {
				clearQueue();
				isWriteCancelling = false;
				return;
			}
			_writeQueue.front = _writeQueue.front[len .. $];
			if (!_writeQueue.front.length) {
				const data = _writeQueue.pop();
				if (onSent)
					onSent(data);
				_isWriting = false;
				debug (Log)
					info("written ", len, " bytes");

				if (!_writeQueue.empty)
					flush();
			} else // if (sendDataBuf.length > len)
			{
				debug (Log)
					trace("remaining ", _wBuf.length - len, " bytes");
				// FIXME: sendDataBuf corrupted
				// tracef("%(%02X %)", sendDataBuf);
				flush(); // send remaining
			}
		}

		void onRead(uint len) {
			debug (Log)
				trace("data reading ", len, " bytes");

			if (len) {
				if (onReceived)
					onReceived(_rBuf[0 .. len]);
				debug (Log)
					trace("read ", len, " bytes");

				return recv(); // continue reading
			}
			debug (Log)
				warning("connection broken: ", _socket.remoteAddress);
			disconnected();
		}

		final flush() @trusted {
			if (_isWriting || _writeQueue.empty) {
				debug (Log)
					if (_isWriting)
						warning("Busy in writing on thread: ");
				return;
			}
			_isWriting = true;
			const data = _writeQueue.front;
			assert(data.length);
			_wBuf = data;
			_iocpWrite.operation = IocpOperation.write;
			if (checkErro(WSASend(handle, cast(WSABUF*)&_wBuf, 1, null, 0,
					&_iocpWrite.overlapped, null), "write")) {
				close();
			}
		}
	}

	private void disconnected() {
		_isRegistered = false;
		if (onDisconnected)
			onDisconnected();
	}

	bool isWriteCancelling;

protected:
	final clearQueue() {
		_writeQueue.clear();
		_isWriting = false;
	}

	version (Posix) {
		final flush() {
			size_t len;
			while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
				const data = _writeQueue.front;
				const n = tryWrite(data);
				if (!n) // error
					break;
				if (data.length == n) {
					debug (Log)
						trace("written ", n, " bytes");
					_writeQueue.dequeue();
					if (onSent)
						onSent(data);
					len += n;
				}
			}
			return len;
		}

		/// Try to write a block of data.
		final size_t tryWrite(in void[] data)
		in (data.length) {
			const len = _socket.send(data);
			debug (Log)
				trace("actually sent bytes: ", len, " / ", data.length);

			if (len > 0)
				return len;

			// FIXME: check more error status
			const err = errno;
			if (err != EINTR && err != EAGAIN && err != EWOULDBLOCK)
				errorOccurred(text("Socket error on write: fd=", handle,
						", errno=", err, ", message: ", lastSocketError()));
			return 0;
		}

		private void doConnect(Address addr) {
			_socket.connect(addr);
		}

		ubyte[] _rBuf;
	}

	bool _isConnected;

	WriteQueue _writeQueue;
version (Windows) :
nothrow:
	const(ubyte)[] _rBuf;
private:
	void recv() @trusted {
		uint dwReceived = void, dwFlags;

		debug (Log)
			trace("start receiving handle=", handle);

		checkErro(WSARecv(handle, cast(WSABUF*)&_rBuf, 1, &dwReceived, &dwFlags,
				&_iocpRead.overlapped, null), "recv");
	}

	void doConnect(Address addr) @trusted {
		_iocpWrite.operation = IocpOperation.connect;
		try
			checkErro(ConnectEx(handle, addr.name(), addr.nameLen(), null, 0, null,
					&_iocpWrite.overlapped), "connect");
		catch (Exception)
			assert(0);
	}

	mixin checkErro;
	IocpContext _iocpRead = {operation: IocpOperation.read}, _iocpWrite;
	const(void)[] _wBuf;
	bool _isWriting;
}
