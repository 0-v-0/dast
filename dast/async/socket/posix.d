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
		super(loop, WatcherType.Accept);
		setFlag(WatchFlag.Read, true);
		socket = new TcpSocket(family);
	}

	protected bool onAccept(scope AcceptHandler handler) {
		debug (Log)
			trace("new connection coming...");
		clearError();
		auto clientFd = cast(socket_t)accept(handle, null, null);
		if (clientFd == socket_t.init)
			return false;

		debug (Log)
			info("Listener fd=", handle, " accepted a new connection, client fd=", clientFd);

		if (handler)
			handler(new Socket(clientFd, _socket.addressFamily));
		return true;
	}

	override void onWriteDone() {
		debug (Log)
			trace("a new connection created");
	}
}

/**
TCP Client
*/
abstract class StreamBase : SocketChannelBase {
	SimpleEventHandler disconnectionHandler;

	protected bool _isConnected; //if server side always true.

	protected this() {
	}

	this(Selector loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4096 * 2) {
		import std.array;

		// _readBuffer = new UbyteArrayObject;
		debug (Log)
			trace("Buffer size for read: ", bufferSize);
		_readBuffer = uninitializedArray!(ubyte[])(bufferSize);
		super(loop, WatcherType.TCP);
		setFlag(WatchFlag.Read, true);
		setFlag(WatchFlag.Write, true);
		setFlag(WatchFlag.ETMode, true);
	}

	///
	protected bool tryRead() {
		bool done = true;
		clearError();
		ptrdiff_t len = socket.receive(cast(void[])_readBuffer);
		debug (Log)
			trace("read nbytes...", len);

		if (len > 0) {
			if (onReceived)
				onReceived(_readBuffer[0 .. len]);

			// It's prossible that more data are wainting for read in inner buffer.
			if (len == _readBuffer.length)
				done = false;
		} else if (len < 0) {
			// FIXME: Needing refactor or cleanup
			// check more error status
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				_error = cast(string)fromStringz(strerror(errno));
			}

			debug (Log)
				warning("read error: done=", done, ", errno=", errno, ", message: ", _error);
		} else {
			debug (Log)
				warning("connection broken: ", _socket.remoteAddress);
			onDisconnected();
			if (_isClosed)
				socket.close(); // release the sources
			else
				close();
		}

		return done;
	}

	protected void onDisconnected() {
		_isConnected = false;
		_isClosed = true;
		if (disconnectionHandler)
			disconnectionHandler();
	}

	protected bool canWriteAgain = true;
	int writeRetryLimit = 5;
	private int writeRetries = 0;

	/**
	Warning: It will try the best to write all the data.
		TODO: create a example for test
	*/
	protected void tryWriteAll(in ubyte[] data) {
		const len = socket.send(data);
		// debug(Log)
		trace("actually sent bytes: ", len, " / ", data.length);

		if (len > 0) {
			if (canWriteAgain && len < data.length) //  && writeRetries < writeRetryLimit
			{
				// debug(Log)
				writeRetries++;
				tracef("[%d] rewrite: written %d, remaining: %d, total: %d",
					writeRetries, len, data.length - len, data.length);
				if (writeRetries > writeRetryLimit)
					warning("You are writting a big block of data!!!");

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
				// debug(Log)
				warning("errno=", errno, ", message: ", lastSocketError());
				if (canWriteAgain) {
					import core.thread;
					import core.time;

					writeRetries++;
					tracef("[%d] rewrite: written %d, remaining: %d, total: %d",
						writeRetries, len, data.length - len, data.length);
					if (writeRetries > writeRetryLimit)
						warning("You are writting a Big block of data!!!");
					warning("Wait for a 100 msecs to try again");
					Thread.sleep(100.msecs);
					tryWriteAll(data);
				}
			}
		} else {
			debug (Log) {
				warning("len=", len, ", message: ", lastSocketError());
				assert(0, "Undefined behavior!");
			} else {
				_error = lastSocketError();
			}
		}
	}

	/**
	Try to write a block of data.
	*/
	protected size_t tryWrite(in ubyte[] data) {
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
				assert(0, "Undefined behavior!");
			} else {
				_error = lastSocketError();
			}
		}
		return 0;
	}

	protected void doConnect(Address addr) {
		socket.connect(addr);
	}

	void cancelWrite() {
		isWriteCancelling = true;
	}

	override void onWriteDone() {
		// notified by kqueue selector when data writing done
		debug (Log)
			trace("done with data writing");
	}

	// protected UbyteArrayObject _readBuffer;
	private const(ubyte)[] _readBuffer;
	protected WriteBufferQueue _writeQueue;
	protected bool isWriteCancelling;

	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	DataReceivedHandler onReceived;
}
