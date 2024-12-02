module dast.async.tcpclient;

import core.sync,
dast.async.core,
dast.async.selector,
tame.buffer,
tame.meta;

version (Windows) import dast.async.iocp;

version (Posix) import core.stdc.errno;

alias ConnectionHandler = void delegate(in Address addr) @safe;

/// TCP Client
@safe class TCPClient : SocketChannel {
	mixin Forward!"_socket";

	ConnectionHandler onConnected;
	SimpleHandler onClosed;
	/++
		Warning: The received data is stored a inner buffer.
		you would make a copy of it.
	+/
	RecvHandler onReceived;
	SimpleHandler onDisconnected;

	@property final bufferSize() const => _rBuf.length;

	// client side
	this(EventLoop loop, AddrFamily family = AddrFamily.IPv4, uint bufferSize = 4 * 1024) {
		this(loop, tcpSocket(family), bufferSize);
	}

	// server side
	this(EventLoop loop, Socket socket, uint bufferSize = 4 * 1024) nothrow @trusted {
		super(loop, WT.TCP);
		flags |= WF.ReadWrite | WF.ETMode;
		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_rBuf = BUF(bufferSize);
		this.socket = socket;
		_connected = socket.isAlive;
	}

	void connect(in Address addr) @trusted {
		if (_connected)
			return;

		try {
			const a = _socket.addressFamily == AddrFamily.IPv6 ?
				IPv6Addr(0) : IPv4Addr(0);
			_socket.bind(a);
			doConnect(addr);
			start();
			_connected = true;
			if (onConnected)
				onConnected(addr);
		} catch (Exception e)
			debug (Log) {
				error(e);
			}
	}

	void reconnect(in Address addr) {
		if (_connected)
			close();
		_connected = false;
		socket = tcpSocket(_socket.addressFamily ? _socket.addressFamily : AddrFamily.IPv4);
		connect(addr);
	}

	@property isConnected() const => _connected;

	void start() nothrow {
		if (_isRegistered)
			return;
		_loop.register(this);
		_isRegistered = true;
		version (Windows)
			recv();
	}

	/// safe for big data sending
	void write(const void[] data) nothrow @trusted {
		if (!_connected)
			return onError("The connection has been closed");
		if (data.length) {
			//auto buf = new WSABUF;
			//*cast(const(void)[]*)buf = data;
			_iocpWrite.operation = IocpOperation.write;
			if (checkErr(WSASend(handle, cast(WSABUF*)&data, 1, null, 0,
					&_iocpWrite.overlapped, null), "write")) {
				close();
			}
		}
	}

	override void close() {
		debug (Log) {
			if (!_writeQueue.empty)
				warning("Some data has not been sent yet");
		}

		super.close();
		_connected = false;
		_socket.shutdown(SocketShutdown.both);
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
				if (errno != EINTR && errno != EAGAIN)
					onError(text("Socket error on write: fd=", handle, ", message=", lastSocketError()));
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
		final onWrite(uint len) @trusted {
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
		}
	}

	private void disconnected() {
		_isRegistered = false;
		if (onDisconnected)
			onDisconnected();
	}

protected:
	final clearQueue() {
		//mutex.lock_nothrow();
		//scope (exit)
		//mutex.unlock_nothrow();
		//_writeQueue.clear();
	}

	version (Posix) {
		bool cancelWriting;

		public final flush() nothrow @trusted {
			size_t len;
			while (_isRegistered && !cancelWriting && !_writeQueue.empty) {
				const data = _writeQueue.front;
				const n = tryWrite(data);
				if (!n) // error
					break;
				if (data.length == n) {
					debug (Log)
						trace("written ", n, " bytes");
					_writeQueue.pop();
					if (onSent)
						onSent(data);
					len += n;
					mutex.lock_nothrow();
					scope (exit)
						mutex.unlock_nothrow();
					try
						cond.notify();
					catch (Exception) {
						assert(0);
					}
				}
			}
			return len;
		}

		/// Try to write a block of data.
		final size_t tryWrite(in void[] data) nothrow
		in (data.length) {
			const len = _socket.send(data);
			debug (Log)
				trace("actually sent bytes: ", len, " / ", data.length);

			if (len > 0)
				return len;

			// FIXME: check more error status
			const err = errno;
			if (err != EINTR && err != EAGAIN && err != EWOULDBLOCK) {
				onError(text("Socket error on write: fd=", handle,
						", errno=", err, ", message: ", lastSocketError()));
			}
			return 0;
		}

		private void doConnect(in Address addr) {
			_socket.connect(addr);
		}

		ubyte[] _rBuf;
	}

	bool _connected;

	//WriteQueue _writeQueue;
version (Windows) :
nothrow:
	const(ubyte)[] _rBuf;
private:
	void recv() @trusted {
		uint dwReceived = void, dwFlags;

		debug (Log)
			trace("start receiving handle=", handle);

		checkErr(WSARecv(handle, cast(WSABUF*)&_rBuf, 1, &dwReceived, &dwFlags,
				&_iocpRead.overlapped, null), "recv");
	}

	void doConnect(in Address addr) @trusted {
		_iocpWrite.operation = IocpOperation.connect;
		checkErr(ConnectEx(handle, addr.name, addr.nameLen, null, 0, null,
				&_iocpWrite.overlapped), "connect");
	}

	mixin checkErr;
	IocpContext _iocpRead = {operation: IocpOperation.read}, _iocpWrite;
}
