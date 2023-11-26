module dast.async.socket;
import dast.async.core,
std.exception;

version (Windows) {
	import core.sys.windows.windows,
	core.sys.windows.mswsock;
	public import dast.async.socket.iocp;
}

version (Posix) import core.stdc.errno;

/** TCP Client */
@safe abstract class StreamBase : SocketChannel {
	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	RecvHandler onReceived;
	SimpleHandler onDisconnected;

	@property final bufferSize() const => _rBuf.length;

	this(Selector loop, uint bufferSize = 4 * 1024) nothrow {
		super(loop, WT.TCP);
		flags |= WF.Read | WF.Write | WF.ETMode;
		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_rBuf = BUF(bufferSize);
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
				if (_isRegistered)
					close();
				else
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
			site += len;
			if (site >= _writeQueue.front.length) {
				_writeQueue.pop1();
				site = 0;
				_isWriting = false;
				debug (Log)
					info("written ", len, " bytes");

				if (!_writeQueue.empty)
					tryWrite();
			} else // if (sendDataBuf.length > len)
			{
				debug (Log)
					trace("remaining ", _wBuf.length - len, " bytes");
				// FIXME: sendDataBuf corrupted
				// tracef("%(%02X %)", sendDataBuf);
				// send remaining
				tryWrite();
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

				recv(); // continue reading
			} else {
				debug (Log)
					warning("connection broken: ", _socket.remoteAddress);
				disconnected();
				//	close();
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
		final tryWrite() {
			size_t len;
			while (_isRegistered && !isWriteCancelling && !_writeQueue.empty) {
				const data = _writeQueue.front.data;
				const n = tryWrite(data);
				if (!n) // error
					break;
				if (data.length == n) {
					debug (Log)
						trace("written ", n, " bytes");
					_writeQueue.pop1();
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

		void doConnect(Address addr) {
			_socket.connect(addr);
		}

		ubyte[] _rBuf;
	}

	WriteBufferQueue _writeQueue;
	version (Windows) :
nothrow:
	const(ubyte)[] _rBuf;
	final void recv() @trusted {
		_iocpRead.operation = IocpOperation.read;
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

	final tryWrite()
	in (!_writeQueue.empty) {
		if (_isWriting) {
			debug (Log)
				warning("Busy in writing on thread: ");
			return 0;
		}
		_isWriting = true;
		const data = _writeQueue.front.data[site .. $];
		const len = write(data);
		if (len < data.length) { // to fix the corrupted data
			debug (Log)
				warning("remaining ", data.length - len, " bytes");
			_wBuf = data;
		}
		return len;
	}

private:
	mixin checkErro;
	IocpContext _iocpRead, _iocpWrite;
	const(void)[] _wBuf;
	uint site;
	bool _isWriting;

	uint write(in void[] data) @trusted
	in (data.length) {
		_wBuf = data;
		uint dwSent = void;
		_iocpWrite.operation = IocpOperation.write;

		if (checkErro(WSASend(handle, cast(WSABUF*)&_wBuf, 1, &dwSent, 0,
				&_iocpWrite.overlapped, null), "write")) {
			close();
		}
		return dwSent;
	}
}
