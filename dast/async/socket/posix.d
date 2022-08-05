module dast.async.socket.posix;

// dfmt off
version(Posix):
import core.stdc.errno,
	core.stdc.string,
	dast.async.core,
	std.conv,
	std.exception,
	std.format,
	std.process,
	std.socket,
	std.string;
import core.sys.posix.sys.socket : accept;
// dfmt on

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
			infof("Listener fd=%d, client fd=%d", handle, clientFd);

		if (handler)
			handler(new Socket(clientFd, _socket.addressFamily));
		return true;
	}

	override void onWriteDone() {
		debug (Log)
			tracef("a new connection created");
	}
}

/**
TCP Client
*/
abstract class StreamBase : SocketChannelBase {
	SimpleEventHandler disconnectionHandler;
	// DataWrittenHandler sentHandler;

	protected bool _isConnected; //if server side always true.
	// alias UbyteArrayObject = BaseTypeObject!(ubyte[]);

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

	/**
	*/
	protected bool tryRead() {
		bool isDone = true;
		clearError();
		ptrdiff_t len = socket.receive(cast(void[])_readBuffer);
		debug (Log)
			trace("read nbytes...", len);

		if (len > 0) {
			if (onDataReceived)
				onDataReceived(_readBuffer[0 .. len]);

			// It's prossible that more data are wainting for read in inner buffer.
			if (len == _readBuffer.length)
				isDone = false;
		} else if (len < 0) {
			// FIXME: Needing refactor or cleanup -@Administrator at 2018-5-8 16:06:13
			// check more error status
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				_error = true;
				_erroString = cast(string)fromStringz(strerror(errno));
			}

			debug (Log)
				warningf("read error: isDone=%s, errno=%d, message=%s",
					isDone, errno, cast(string)fromStringz(strerror(errno)));
		} else {
			debug (Log)
				warningf("connection broken: %s", _socket.remoteAddress);
			onDisconnected();
			if (_isClosed)
				socket.close(); // release the sources
			else
				close();
		}

		return isDone;
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
	// TODO: create a examlple for test
	*/
	protected void tryWriteAll(in ubyte[] data) {
		const nBytes = socket.send(data);
		// debug(Log)
		tracef("actually sent bytes: %d / %d", nBytes, data.length);

		if (nBytes > 0) {
			if (canWriteAgain && nBytes < data.length) //  && writeRetries < writeRetryLimit
			{
				// debug(Log)
				writeRetries++;
				tracef("[%d] rewrite: written %d, remaining: %d, total: %d",
					writeRetries, nBytes, data.length - nBytes, data.length);
				if (writeRetries > writeRetryLimit)
					warning("You are writting a Big block of data!!!");

				tryWriteAll(data[nBytes .. $]);
			} else
				writeRetries = 0;

		} else if (nBytes == Socket.ERROR) {
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				string msg = lastSocketError();
				warningf("errno=%d, message: %s", errno, msg);
				_error = true;
				_erroString = msg;

				errorOccurred(msg);
			} else {
				// debug(Log)
				warningf("errno=%d, message: %s", errno, lastSocketError());
				if (canWriteAgain) {
					import core.thread;
					import core.time;

					writeRetries++;
					tracef("[%d] rewrite: written %d, remaining: %d, total: %d",
						writeRetries, nBytes, data.length - nBytes, data.length);
					if (writeRetries > writeRetryLimit)
						warning("You are writting a Big block of data!!!");
					warning("Wait for a 100 msecs to try again");
					Thread.sleep(100.msecs);
					tryWriteAll(data);
				}
			}
		} else {
			debug (Log) {
				warningf("nBytes=%d, message: %s", nBytes, lastSocketError());
				assert(0, "Undefined behavior!");
			} else {
				_error = true;
				_erroString = lastSocketError();
			}
		}
	}

	/**
	Try to write a block of data.
	*/
	protected size_t tryWrite(in ubyte[] data) {
		const nBytes = socket.send(data);
		debug (Log)
			tracef("actually sent bytes: %d / %d", nBytes, data.length);

		if (nBytes > 0) {
			return nBytes;
		} else if (nBytes == Socket.ERROR) {
			debug (Log)
				warningf("errno=%d, message: %s", errno, lastSocketError());

			// FIXME: Needing refactor or cleanup -@Administrator at 2018-5-8 16:07:38
			// check more error status
			if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
				_error = true;
				_erroString = lastSocketError();
				warningf("errno=%d, message: %s", errno, _erroString);
			}
		} else {
			debug (Log) {
				warningf("nBytes=%d, message: %s", nBytes, lastSocketError());
				assert(0, "Undefined behavior!");
			} else {
				_error = true;
				_erroString = lastSocketError();
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
			tracef("done with data writing");
	}

	// protected UbyteArrayObject _readBuffer;
	private const(ubyte)[] _readBuffer;
	protected WriteBufferQueue _writeQueue;
	protected bool isWriteCancelling;

	/**
	* Warning: The received data is stored a inner buffer. For a data safe,
	* you would make a copy of it.
	*/
	DataReceivedHandler onDataReceived;
}

/**
UDP Socket
*/
abstract class DatagramSocketBase : SocketChannelBase {
	this(Selector loop, AddressFamily family = AddressFamily.INET, int bufferSize = 4096 * 2) {
		import std.array;

		super(loop, WatcherType.UDP);
		setFlag(WatchFlag.Read, true);
		setFlag(WatchFlag.ETMode, false);

		socket = new UdpSocket(family);
		// _socket.blocking = false;
		_readBuffer = new UdpDataObject;
		_readBuffer.data = uninitializedArray!(ubyte[])(bufferSize);

		if (family == AddressFamily.INET)
			_bindAddress = new InternetAddress(InternetAddress.PORT_ANY);
		else if (family == AddressFamily.INET6)
			_bindAddress = new Internet6Address(Internet6Address.PORT_ANY);
		else
			_bindAddress = new UnknownAddress;
	}

	final void bind(Address addr) {
		if (!_binded) {
			_bindAddress = addr;
			socket.bind(_bindAddress);
			_binded = true;
		}
	}

	final bool isBind() {
		return _binded;
	}

	Address bindAddr() {
		return _bindAddress;
	}

protected:
	UdpDataObject _readBuffer;
	bool _binded;
	Address _bindAddress;

	bool tryRead(scope ReadCallback read) {
		scope Address createAddress() {
			if (AddressFamily.INET == socket.addressFamily)
				return new InternetAddress;
			if (AddressFamily.INET6 == socket.addressFamily)
				return new Internet6Address;
			throw new AddressException(
				"Unsupported addressFamily. It can only be AddressFamily.INET or AddressFamily.INET6");
		}

		_readBuffer.addr = createAddress();
		auto data = _readBuffer.data;
		scope (exit)
			_readBuffer.data = data;
		auto len = socket.receiveFrom(_readBuffer.data, _readBuffer.addr);
		if (len > 0) {
			_readBuffer.data = _readBuffer.data[0 .. len];
			read(_readBuffer);
		}
		return false;
	}

public:
	override void onWriteDone() {
		// notified by kqueue selector when data writing done
		debug (Log)
			tracef("done with data writing");
	}
}
