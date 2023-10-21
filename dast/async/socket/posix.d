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
abstract class ListenerBase : SocketChannelBase {
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
abstract class StreamBase : SocketChannelBase {
	SimpleHandler disconnectedHandler;

	protected this() {
	}

	this(Selector loop, size_t bufferSize = 4 * 1024) {
		import std.array;

		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_readBuf = uninitializedArray!(ubyte[])(bufferSize);
		super(loop, WT.TCP);
		flags |= WF.Read | WF.Write | WF.ETMode;
	}

	int writeRetryLimit = 5;
	private int writeRetries = 0;

protected:
	bool tryRead() {
		_error = [];
		const len = socket.receive(_readBuf);
		debug (Log)
			trace("read nbytes...", len);

		if (len > 0) {
			if (onReceived)
				onReceived(_readBuf[0 .. len]);

			// It's possible that more data are waiting for read in inner buffer
			if (len == _readBuf.length)
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
			onDisconnected();
			if (_isRegistered)
				close();
			else
				socket.close(); // release the sources
		}
		return true;
	}

	void onDisconnected() {
		_isRegistered = false;
		if (disconnectedHandler)
			disconnectedHandler();
	}
	/*
	Warning: It will try the best to write all the data.
		TODO: create a example for test

	void tryWriteAll(in ubyte[] data) {
		const len = socket.send(data);
		debug (Log)
			trace("actually sent bytes: ", len, " / ", data.length);

		if (len > 0) {
			if (len < data.length) { // && writeRetries < writeRetryLimit
				// debug (Log)
				writeRetries++;
				trace("[", writeRetries, "] rewrite: written ", len,
					", remaining: ", data.length - len, ", total: ", data.length);
				if (writeRetries > writeRetryLimit)
					warning("You are writing a big block of data!!!");

				tryWriteAll(data[len .. $]);
			} else
				writeRetries = 0;

		} else if (len == Socket.ERROR) {
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				string msg = lastSocketError();
				warning("errno=", errno, ", message: ", msg);
				_error = msg;

				errorOccurred(msg);
			} else {
				// debug (Log)
				warning("errno=", errno, ", message: ", lastSocketError());
				import core.thread;
				import core.time;

				writeRetries++;
				tracef("[%d] rewrite: written %d, remaining: %d, total: %d",
					writeRetries, len, data.length - len, data.length);
				if (writeRetries > writeRetryLimit)
					warning("You are writing a big block of data!!!");
				warning("Wait for a 100 msecs to try again");
				Thread.sleep(100.msecs);
				tryWriteAll(data);
			}
		} else {
			debug (Log) {
				warning("len=", len, ", message: ", lastSocketError());
				assert(0, "Undefined behavior");
			} else {
				_error = lastSocketError();
			}
		}
	}*/

	/**
	Try to write a block of data.
	*/
	final size_t tryWrite(in void[] data) {
		const len = socket.send(data);
		debug (Log)
			trace("actually sent bytes: ", len, " / ", data.length);

		if (len > 0)
			return len;

		if (len == Socket.ERROR) {
			debug (Log)
				warning("errno=", errno, ", message: ", lastSocketError());

			// FIXME: Needing refactor or cleanup
			// check more error status
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				_error = lastSocketError();
				warning("errno=", errno, ", message: ", _error);
			}
		} else {
			debug (Log) {
				warning("len=", len, ", message: ", lastSocketError());
				assert(0, "Undefined behavior");
			} else {
				_error = lastSocketError();
			}
		}
		return 0;
	}

	void doConnect(Address addr) {
		socket.connect(addr);
	}

	bool isWriteCancelling;
	ubyte[] _readBuf;
	WriteBufferQueue _writeQueue;

	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	public RecvHandler onReceived;
}
